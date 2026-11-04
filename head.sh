#!/usr/bin/env bash
#
# head.sh — make this Ubuntu machine the head of the home cluster.
#
# The head owns all shared state: model files, the k3s join token, the NFS
# share, the pinned llama.cpp version, and the one service (clusterd) that
# serves the join files, collects heartbeats and shows the dashboard.
# Idempotent: re-run after changes.
#
# What it does, in order:
#   1. preflight   root, Ubuntu/Debian, LAN iface (wired > Wi-Fi), GPU
#   2. packages    build tools, nfs-kernel-server, avahi, python3, vulkan deps
#   3. tailscale   install + `tailscale up --ssh` (skippable)
#   4. share       /srv/cluster/{models,join,state,logs} exported over NFS to the LAN
#   5. k3s         server, kubeconfig readable, token published to the join dir
#   6. llama.cpp   build llama-server/llama-cli/llama-bench with the GPU backend
#   7. clusterd    join service + dashboard on :8787, node agent on :8788,
#                  cluster-head.local mDNS alias, `cluster` command
#   8. publish     cluster.env (pins), token, worker.sh, android.sh, join.sh
#   9. host tweaks ufw rules, ignore laptop lid close
#
# Usage:
#   sudo ./head.sh                 # from a checkout of this repo
#   sudo ./head.sh --gpu cuda      # pick the GPU backend (auto: vulkan if a GPU exists)
#   sudo ./head.sh --dry-run       # print the plan only
#   sudo ./head.sh --leave         # undo (keeps /srv/cluster/models)
#
set -euo pipefail

CONF_DIR=/etc/home-cluster
ENV_FILE=$CONF_DIR/head.env
ROOT=/srv/cluster
JOIN_DIR=$ROOT/join
STATE_DIR=$ROOT/state
LOG_DIR=$ROOT/logs
MODELS_DIR=$ROOT/models
INSTALL_DIR=/opt/llama.cpp
SRC_DIR=$INSTALL_DIR/src
APP_DIR=/opt/home-cluster
SERVICE_USER=cluster
SERVICE_HOME=/var/lib/home-cluster
LLAMA_REPO=https://github.com/ggml-org/llama.cpp
REPO_URL=${REPO_URL:-https://github.com/sxi9/home-cluster-.git}
K3S_PORT=6443
CLUSTERD_PORT=8787
AGENT_PORT=8788
LLAMA_PORT=8080
RPC_PORT=50052
MDNS_NAME=cluster-head

NODE_NAME=""
LAN_IFACE=""
GPU="${GPU:-auto}"
GPU_NAME=""
LLAMA_REF="master"      # resolved to a commit and pinned for every worker
K3S_VERSION=""
TS_AUTHKEY="${TS_AUTHKEY:-}"
HEAD_SSH=""             # Tailscale name workers ssh to; defaults to the hostname
DO_TAILSCALE=1 DO_NFS=1 DO_K3S=1 DO_BUILD=1 DO_LID=1 DRY_RUN=0 LEAVE=0

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf '    + %s\n' "$*"; else "$@"; fi; }
write_file() {
  local path=$1 mode=${2:-0644} owner=${3:-root:root} content; content=$(cat)
  if (( DRY_RUN )); then printf '    + write %s (%s %s)\n' "$path" "$mode" "$owner"; printf '%s\n' "$content" | sed 's/^/        | /'; return; fi
  install -d -m 0755 "$(dirname "$path")"
  printf '%s\n' "$content" > "$path.tmp"; chmod "$mode" "$path.tmp"; chown "$owner" "$path.tmp"; mv -f "$path.tmp" "$path"
}

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  cat <<USAGE
Options:
  --name NAME            hostname / k3s node name (default: current hostname)
  --head-ssh NAME        Tailscale name workers use for ssh (default: hostname)
  --lan-iface IFACE      interface for cluster traffic (auto: wired, else Wi-Fi)
  --gpu KIND             auto|vulkan|cuda|hip|cpu
  --llama-ref REF        llama.cpp ref to build and pin (default: master, pinned to its commit)
  --k3s-version VER      pin k3s (default: installer default, then pinned)
  --mdns-name NAME       publish NAME.local for the join service (default $MDNS_NAME)
  --tailscale-authkey K  non-interactive 'tailscale up'
  --no-tailscale | --no-nfs | --no-k3s | --no-build | --no-lid-ignore
  --dry-run | --leave | -h
USAGE
}

parse_args() {
  while (( $# )); do
    case $1 in
      --name) NODE_NAME=$2; shift 2 ;;
      --head-ssh) HEAD_SSH=$2; shift 2 ;;
      --lan-iface) LAN_IFACE=$2; shift 2 ;;
      --gpu) GPU=$2; shift 2 ;;
      --llama-ref) LLAMA_REF=$2; shift 2 ;;
      --k3s-version) K3S_VERSION=$2; shift 2 ;;
      --mdns-name) MDNS_NAME=$2; shift 2 ;;
      --tailscale-authkey) TS_AUTHKEY=$2; shift 2 ;;
      --no-tailscale) DO_TAILSCALE=0; shift ;;
      --no-nfs) DO_NFS=0; shift ;;
      --no-k3s) DO_K3S=0; shift ;;
      --no-build) DO_BUILD=0; shift ;;
      --no-lid-ignore) DO_LID=0; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --leave) LEAVE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

load_saved() {
  [[ -r $ENV_FILE ]] || return 0
  log "loading saved settings from $ENV_FILE (flags override)"
  local k v
  while IFS='=' read -r k v; do
    case $k in NODE_NAME|LAN_IFACE|GPU|LLAMA_REF|K3S_VERSION|HEAD_SSH|MDNS_NAME) printf -v "$k" '%s' "$v" ;; esac
  done < <(grep -E '^[A-Z0-9_]+=' "$ENV_FILE")
}

# ----------------------------------------------------------------------------
preflight() {
  log "preflight"
  [[ $EUID -eq 0 ]] || die "run as root (sudo ./head.sh)"
  # shellcheck disable=SC1091
  . /etc/os-release
  case ${ID:-}:${ID_LIKE:-} in *ubuntu*|*debian*) ;; *) die "expects Ubuntu/Debian" ;; esac
  command -v ip >/dev/null || die "iproute2 missing"
  command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl ca-certificates; }
  case $(uname -m) in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; *) die "unsupported arch" ;; esac
  HAS_SYSTEMD=0; [[ -d /run/systemd/system ]] && HAS_SYSTEMD=1
  (( HAS_SYSTEMD )) || die "the head needs systemd"
  detect_lan
  detect_gpu
  NODE_NAME=${NODE_NAME:-$(hostname -s)}
  HEAD_SSH=${HEAD_SSH:-$NODE_NAME}
  MEM_TOTAL_MB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")
  cat <<INFO
    head        : $NODE_NAME ($ARCH, ${MEM_TOTAL_MB} MB RAM, $(nproc) cpus)
    lan         : $LAN_IFACE $LAN_IP ($LINK_TYPE), subnet $LAN_SUBNET
    gpu         : $GPU${GPU_NAME:+ ($GPU_NAME)}
    share       : $ROOT (nfs to $LAN_SUBNET)
    join url    : http://$LAN_IP:$CLUSTERD_PORT  (also http://$MDNS_NAME.local:$CLUSTERD_PORT)
    llama.cpp   : $LLAMA_REF
INFO
}

detect_lan() {
  if [[ -z $LAN_IFACE ]]; then
    local cand
    while read -r cand; do
      case $cand in tailscale*|docker*|cni*|flannel*|veth*|lo|br-*) continue ;; esac
      LAN_IFACE=$cand
      case $cand in en*|eth*) break ;; esac
    done < <(ip -o -4 route show default | awk '{print $5}')
  fi
  [[ -n $LAN_IFACE ]] || die "no default-route interface; pass --lan-iface"
  if [[ -d /sys/class/net/$LAN_IFACE/wireless || $LAN_IFACE == wl* ]]; then
    LINK_TYPE=wifi; warn "$LAN_IFACE is Wi-Fi; the head should really be wired"
  else LINK_TYPE=wired; fi
  LAN_IP=$(ip -o -4 addr show dev "$LAN_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -n1)
  [[ -n $LAN_IP ]] || die "no IPv4 address on $LAN_IFACE"
  local cidr; cidr=$(ip -o -4 addr show dev "$LAN_IFACE" | awk '{print $4}' | head -n1)
  LAN_SUBNET=$(python3 -c "import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)" "$cidr" 2>/dev/null || echo "$cidr")
}

detect_gpu() {
  local vendor="" dev name=""
  for dev in /sys/class/drm/card[0-9]*/device; do
    [[ -r $dev/vendor ]] || continue; vendor=$(<"$dev/vendor"); break
  done
  case $vendor in 0x10de) GPU_VENDOR=nvidia ;; 0x1002) GPU_VENDOR=amd ;; 0x8086) GPU_VENDOR=intel ;; *) GPU_VENDOR=none ;; esac
  if command -v nvidia-smi >/dev/null; then name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true); fi
  GPU_NAME=${name:-}; [[ -z $GPU_NAME && $GPU_VENDOR != none ]] && GPU_NAME=$GPU_VENDOR
  [[ $GPU == auto ]] && { [[ $GPU_VENDOR == none ]] && GPU=cpu || GPU=vulkan; }
  case $GPU in
    cpu|vulkan) ;;
    cuda) command -v nvcc >/dev/null || [[ -x /usr/local/cuda/bin/nvcc ]] || die "--gpu cuda needs the CUDA toolkit; or use --gpu vulkan" ;;
    hip)  [[ -d /opt/rocm ]] || die "--gpu hip needs ROCm in /opt/rocm; or use --gpu vulkan" ;;
    *) die "unknown --gpu $GPU" ;;
  esac
  return 0
}

# ----------------------------------------------------------------------------
install_packages() {
  log "packages"
  local pkgs=(curl ca-certificates git cmake build-essential pkg-config python3 jq openssh-server
              nfs-kernel-server avahi-daemon avahi-utils libnss-mdns)
  [[ $GPU == vulkan ]] && pkgs+=(libvulkan-dev glslc mesa-vulkan-drivers vulkan-tools)
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update -qq
  run apt-get install -y -qq --no-install-recommends "${pkgs[@]}"
  run systemctl enable --now ssh avahi-daemon
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    run useradd --system --home-dir "$SERVICE_HOME" --create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
  local g; for g in video render; do getent group "$g" >/dev/null && run usermod -aG "$g" "$SERVICE_USER"; done
  return 0
}

setup_tailscale() {
  (( DO_TAILSCALE )) || { log "tailscale: skipped"; return; }
  log "tailscale"
  command -v tailscale >/dev/null || run sh -c 'curl -fsSL https://tailscale.com/install.sh | sh'
  run systemctl enable --now tailscaled
  local args=(--ssh --accept-dns --hostname "$HEAD_SSH")
  [[ -n $TS_AUTHKEY ]] && args+=(--authkey "$TS_AUTHKEY")
  if (( DRY_RUN )); then run tailscale up "${args[@]}"
  elif tailscale status >/dev/null 2>&1; then log "tailscale already up"
  else tailscale up "${args[@]}"; fi
  TS_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
}

setup_share() {
  log "share: $ROOT"
  run install -d -m 0755 "$ROOT"
  run install -d -m 2775 -o root -g "$SERVICE_USER" "$MODELS_DIR"
  run install -d -m 0755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$JOIN_DIR" "$STATE_DIR" "$LOG_DIR"
  (( DO_NFS )) || return 0
  local line="$ROOT $LAN_SUBNET(rw,sync,no_subtree_check,no_root_squash)"
  if grep -qs "^$ROOT " /etc/exports; then run sed -i "s|^$ROOT .*|$line|" /etc/exports
  elif (( DRY_RUN )); then printf '    + append to /etc/exports: %s\n' "$line"
  else printf '%s\n' "$line" >> /etc/exports; fi
  run systemctl enable --now nfs-server
  run exportfs -ra
}

setup_k3s() {
  (( DO_K3S )) || { log "k3s: skipped"; return; }
  log "k3s server on $LAN_IP:$K3S_PORT"
  local args=(server --node-name "$NODE_NAME" --node-ip "$LAN_IP" --flannel-iface "$LAN_IFACE"
              --write-kubeconfig-mode 644 --tls-san "$NODE_NAME" --tls-san "$LAN_IP"
              --node-label home-cluster/role=head --node-label "home-cluster/gpu=$GPU"
              --node-label "home-cluster/link=$LINK_TYPE" --node-label "home-cluster/ram-mb=$MEM_TOTAL_MB")
  [[ -n ${TS_IP:-} ]] && args+=(--tls-san "$TS_IP")
  if (( DRY_RUN )); then printf '    + curl -sfL https://get.k3s.io | %s sh -s - %s\n' "${K3S_VERSION:+INSTALL_K3S_VERSION=$K3S_VERSION}" "${args[*]}"; return; fi
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - "${args[@]}"
  local _try; for _try in $(seq 1 60); do : "$_try"; [[ -s /var/lib/rancher/k3s/server/node-token ]] && break; sleep 2; done
  [[ -s /var/lib/rancher/k3s/server/node-token ]] || die "k3s did not produce a node token; see journalctl -u k3s"
  K3S_VERSION=$(k3s --version | awk 'NR==1 {print $3}')
  install -m 0640 -o root -g "$SERVICE_USER" /var/lib/rancher/k3s/server/node-token "$JOIN_DIR/token"
  mkdir -p /root/.kube && ln -sf /etc/rancher/k3s/k3s.yaml /root/.kube/config
}

build_llama() {
  (( DO_BUILD )) || { log "build: skipped"; LLAMA_REF=$(cat "$INSTALL_DIR/BUILT_REF" 2>/dev/null | cut -d: -f1 || echo "$LLAMA_REF"); return; }
  log "llama.cpp @ $LLAMA_REF ($GPU backend)"
  [[ -d $SRC_DIR/.git ]] || run git clone --quiet "$LLAMA_REPO" "$SRC_DIR"
  run git -C "$SRC_DIR" fetch --quiet --tags origin
  run git -C "$SRC_DIR" checkout --quiet --force "$LLAMA_REF"
  [[ $LLAMA_REF == master ]] && run git -C "$SRC_DIR" pull --quiet --ff-only
  # Pin to the exact commit: workers must build the same one (RPC protocol).
  LLAMA_REF=$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo "$LLAMA_REF")
  if [[ -x $INSTALL_DIR/bin/llama-server && $(cat "$INSTALL_DIR/BUILT_REF" 2>/dev/null) == "$LLAMA_REF:$GPU" ]]; then
    log "already built $LLAMA_REF for $GPU"; return
  fi
  local -a gpu_flags=()
  case $GPU in
    vulkan) gpu_flags=(-DGGML_VULKAN=ON) ;;
    cuda)   gpu_flags=(-DGGML_CUDA=ON) ;;
    hip)    local gfx; gfx=$(/opt/rocm/bin/rocminfo 2>/dev/null | sed -n 's/^\s*Name:\s*\(gfx[0-9a-f]*\).*/\1/p' | head -n1)
            gpu_flags=(-DGGML_HIP=ON ${gfx:+-DAMDGPU_TARGETS=$gfx} -DCMAKE_C_COMPILER=/opt/rocm/llvm/bin/clang -DCMAKE_CXX_COMPILER=/opt/rocm/llvm/bin/clang++) ;;
  esac
  run rm -rf "$SRC_DIR/build"
  run cmake -S "$SRC_DIR" -B "$SRC_DIR/build" -DCMAKE_BUILD_TYPE=Release -DGGML_RPC=ON -DGGML_NATIVE=ON \
      -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON \
      -DLLAMA_BUILD_SERVER=ON "${gpu_flags[@]}"
  run cmake --build "$SRC_DIR/build" --config Release -j "$(nproc)" --target llama-server llama-cli llama-bench rpc-server
  run install -d -m 0755 "$INSTALL_DIR/bin"
  local b; for b in llama-server llama-cli llama-bench rpc-server; do run install -m 0755 "$SRC_DIR/build/bin/$b" "$INSTALL_DIR/bin/$b"; done
  # shared libs, when llama.cpp was built shared
  if compgen -G "$SRC_DIR/build/bin/*.so*" >/dev/null; then run cp -a "$SRC_DIR"/build/bin/*.so* "$INSTALL_DIR/bin/"; fi
  printf '%s:%s\n' "$LLAMA_REF" "$GPU" | write_file "$INSTALL_DIR/BUILT_REF"
}

# repo files: next to this script, or a clone of the repo
locate_repo() {
  if [[ -n $SCRIPT_DIR && -r $SCRIPT_DIR/head/clusterd.py ]]; then REPO_DIR=$SCRIPT_DIR; return; fi
  REPO_DIR=$APP_DIR/src
  log "fetching the repo into $REPO_DIR"
  if [[ -d $REPO_DIR/.git ]]; then run git -C "$REPO_DIR" pull --quiet --ff-only
  else run git clone --quiet "$REPO_URL" "$REPO_DIR"; fi
}

install_app() {
  log "clusterd, agent, cluster command"
  locate_repo
  run install -d -m 0755 "$APP_DIR"
  run install -m 0755 "$REPO_DIR/head/clusterd.py" "$APP_DIR/clusterd.py"
  run install -m 0644 "$REPO_DIR/dashboard/index.html" "$APP_DIR/index.html"
  run install -m 0755 "$REPO_DIR/agent/cluster-agent.py" "$APP_DIR/cluster-agent.py"
  run install -m 0755 "$REPO_DIR/bin/cluster" /usr/local/bin/cluster
  write_file "$ENV_FILE" 0644 <<ENV
# home-cluster head settings — written by head.sh
NODE_NAME=$NODE_NAME
ROLE=head
HEAD=$LAN_IP
HEAD_SSH=$HEAD_SSH
JOIN_URL=http://$LAN_IP:$CLUSTERD_PORT
LAN_IFACE=$LAN_IFACE
LAN_IP=$LAN_IP
LINK_TYPE=$LINK_TYPE
GPU=$GPU
GPU_NAME=$GPU_NAME
MDNS_NAME=$MDNS_NAME
CLUSTER_ROOT=$ROOT
JOIN_DIR=$JOIN_DIR
STATE_DIR=$STATE_DIR
LOG_DIR=$LOG_DIR
MODELS_DIR=$MODELS_DIR
LLAMA_BIN=$INSTALL_DIR/bin
LLAMA_PORT=$LLAMA_PORT
LLAMA_REF=$LLAMA_REF
K3S_VERSION=$K3S_VERSION
RPC_PORT=$RPC_PORT
CLUSTERD_PORT=$CLUSTERD_PORT
AGENT_PORT=$AGENT_PORT
DASHBOARD_HTML=$APP_DIR/index.html
ENV
  write_file /etc/systemd/system/clusterd.service 0644 <<UNIT
[Unit]
Description=home-cluster head service (join files, heartbeats, dashboard)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Environment=CLUSTER_ENV=$ENV_FILE
ExecStart=/usr/bin/python3 $APP_DIR/clusterd.py
Restart=always
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
  write_file /etc/systemd/system/cluster-agent.service 0644 <<UNIT
[Unit]
Description=home-cluster node agent (head)
After=network-online.target clusterd.service

[Service]
Type=simple
User=$SERVICE_USER
Environment=CLUSTER_ENV=$ENV_FILE
ExecStart=/usr/bin/python3 $APP_DIR/cluster-agent.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  write_file /etc/systemd/system/cluster-mdns.service 0644 <<UNIT
[Unit]
Description=home-cluster mDNS alias $MDNS_NAME.local
After=avahi-daemon.service
Requires=avahi-daemon.service

[Service]
Type=simple
ExecStart=/usr/bin/avahi-publish -a -R $MDNS_NAME.local $LAN_IP
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  run systemctl daemon-reload
  run systemctl enable --now clusterd.service cluster-agent.service cluster-mdns.service
  run systemctl restart clusterd.service cluster-agent.service cluster-mdns.service
}

publish_join() {
  log "publishing join files to $JOIN_DIR"
  write_file "$JOIN_DIR/cluster.env" 0644 "$SERVICE_USER:$SERVICE_USER" <<ENV
# published by head.sh — workers take these pins; flags on worker.sh still win
HEAD=$LAN_IP
HEAD_SSH=$HEAD_SSH
JOIN_URL=http://$LAN_IP:$CLUSTERD_PORT
RPC_PORT=$RPC_PORT
LLAMA_REF=$LLAMA_REF
K3S_VERSION=$K3S_VERSION
ENV
  run cp -f "$JOIN_DIR/cluster.env" "$ROOT/cluster.env"
  local f; for f in worker.sh android.sh join.sh; do
    [[ -r $REPO_DIR/$f ]] && run install -m 0644 -o "$SERVICE_USER" "$REPO_DIR/$f" "$JOIN_DIR/$f"
  done
  run install -m 0644 -o "$SERVICE_USER" "$REPO_DIR/agent/cluster-agent.py" "$JOIN_DIR/cluster-agent.py"
  [[ -s $JOIN_DIR/token ]] || warn "no k3s token published yet (k3s skipped?); workers will prompt for one"
}

configure_firewall() {
  command -v ufw >/dev/null || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  log "ufw: allowing cluster traffic from $LAN_SUBNET"
  local p
  for p in "$K3S_PORT/tcp" "$CLUSTERD_PORT/tcp" "$AGENT_PORT/tcp" "$LLAMA_PORT/tcp" 2049/tcp 10250/tcp 8472/udp 5353/udp; do
    run ufw allow in on "$LAN_IFACE" from "$LAN_SUBNET" to any port "${p%/*}" proto "${p#*/}" comment 'home-cluster'
  done
  run ufw allow in on tailscale0 to any port 22 proto tcp comment 'home-cluster ssh'
  run ufw allow in on tailscale0 to any port "$CLUSTERD_PORT" proto tcp comment 'home-cluster dashboard'
  run ufw allow in on tailscale0 to any port "$LLAMA_PORT" proto tcp comment 'home-cluster llama-server'
}

keep_awake() {
  (( DO_LID )) || return 0
  [[ -d /proc/acpi/button/lid ]] || return 0
  log "logind: ignore lid close"
  write_file /etc/systemd/logind.conf.d/home-cluster.conf 0644 <<CONF
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
CONF
  run systemctl kill -s HUP systemd-logind
  run systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
}

summary() {
  log "done"
  cat <<SUMMARY

  Head $NODE_NAME is up.   dashboard: http://$LAN_IP:$CLUSTERD_PORT   share: $ROOT

  Join an Ubuntu laptop (run on that machine):
      curl -fsSL http://$LAN_IP:$CLUSTERD_PORT/worker.sh | sudo bash

  Join a rooted Android phone (in Termux):
      curl -fsSL http://$LAN_IP:$CLUSTERD_PORT/android.sh | bash

  Then, on the head:
      cluster nodes                              # who is awake
      cp model.gguf $MODELS_DIR/
      cluster run model.gguf                     # split across awake devices
      kubectl get nodes -o wide                  # k3s view

  Pins published for workers: llama.cpp $LLAMA_REF, k3s ${K3S_VERSION:-unpinned}
SUMMARY
}

leave() {
  [[ $EUID -eq 0 ]] || die "run as root"
  log "tearing down the head (models in $MODELS_DIR are kept)"
  [[ -x /usr/local/bin/k3s-uninstall.sh ]] && run /usr/local/bin/k3s-uninstall.sh
  run systemctl disable --now clusterd.service cluster-agent.service cluster-mdns.service 2>/dev/null || true
  run rm -f /etc/systemd/system/clusterd.service /etc/systemd/system/cluster-agent.service /etc/systemd/system/cluster-mdns.service /etc/systemd/logind.conf.d/home-cluster.conf /usr/local/bin/cluster
  run sed -i "\|^$ROOT |d" /etc/exports; command -v exportfs >/dev/null && run exportfs -ra
  run rm -rf "$CONF_DIR" "$INSTALL_DIR" "$APP_DIR" "$JOIN_DIR" "$STATE_DIR" "$LOG_DIR"
  run systemctl daemon-reload
  log "left. $MODELS_DIR, tailscale and packages were kept."
}

main() {
  load_saved
  parse_args "$@"
  (( LEAVE )) && { leave; exit 0; }
  (( DRY_RUN )) && log "dry run: nothing below is executed"
  preflight
  install_packages
  setup_tailscale
  setup_share
  setup_k3s
  build_llama
  install_app
  publish_join
  configure_firewall
  keep_awake
  summary
}
main "$@"

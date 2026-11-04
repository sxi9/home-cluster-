#!/usr/bin/env bash
#
# worker.sh — join this Ubuntu machine to the home cluster as a worker.
#
# Every worker (laptop or phone chroot) runs this. It is idempotent: re-run it
# after a wipe, a config change, or to pick up a new llama.cpp build.
#
# What it does, in order:
#   1. preflight   root check, Ubuntu/Debian, arch, hostname, wired LAN iface
#   2. packages    curl git cmake build tools nfs-common openssh-server
#   3. tailscale   install + `tailscale up --ssh` (skippable)
#   4. nfs         automount head:/srv/cluster at /mnt/cluster (nofail)
#   5. defaults    read pinned versions from the share, if the head wrote them
#   6. llama.cpp   build rpc-server with GGML_RPC=ON into /opt/llama.cpp
#   7. systemd     install + enable rpc-server.service (bound to the LAN IP)
#   8. k3s         install the agent pointed at the head
#   9. host tweaks firewall rules, ignore laptop lid close
#
# Usage:
#   sudo ./worker.sh --head 192.168.1.10 [--token TOKEN | --token-file PATH]
#   sudo ./worker.sh --dry-run --head 192.168.1.10      # print the plan only
#   sudo ./worker.sh --leave                            # undo everything
#
# State this script leaves on the worker (and nothing else):
#   /etc/home-cluster/worker.env     config, sourced by the service and scripts
#   /etc/home-cluster/token          k3s join token (0600)
#   /etc/systemd/system/rpc-server.service
#   /opt/llama.cpp/                  rpc-server binary + source checkout
#   /etc/fstab line for the NFS share, k3s-agent (its own installer)
#
set -euo pipefail

# ----------------------------------------------------------------------------
# constants
# ----------------------------------------------------------------------------
CONF_DIR=/etc/home-cluster
ENV_FILE=$CONF_DIR/worker.env
TOKEN_FILE=$CONF_DIR/token
INSTALL_DIR=/opt/llama.cpp
SRC_DIR=$INSTALL_DIR/src
SERVICE_USER=cluster
SERVICE_HOME=/var/lib/home-cluster
UNIT_FILE=/etc/systemd/system/rpc-server.service
NFS_MOUNT=/mnt/cluster
NFS_EXPORT=/srv/cluster
LLAMA_REPO=https://github.com/ggml-org/llama.cpp
K3S_PORT=6443

# ----------------------------------------------------------------------------
# defaults (overridable by flags, env, or an existing worker.env)
# ----------------------------------------------------------------------------
HEAD=""                 # LAN IP or name of the head node (k3s, NFS, rpc traffic)
HEAD_SSH=""             # name to ssh to the head (Tailscale); defaults to HEAD
NODE_NAME=""            # hostname to use; defaults to current hostname
LAN_IFACE=""            # wired interface; auto-detected if empty
TOKEN="${CLUSTER_TOKEN:-}"
TOKEN_PATH=""
RPC_PORT=50052
RPC_RESERVE_MB=2048     # RAM kept back from rpc-server for the OS/k3s
RPC_THREADS=""          # defaults to nproc
RPC_CACHE=0             # 1 = rpc-server -c (caches tensors on local disk)
K3S_VERSION=""          # e.g. v1.31.4+k3s1; empty = installer default
LLAMA_REF="master"      # git ref of llama.cpp; head can pin it via the share
TS_AUTHKEY="${TS_AUTHKEY:-}"
DO_TAILSCALE=1
DO_NFS=1
DO_BUILD=1
DO_K3S=1
DO_LID=1
DRY_RUN=0
LEAVE=0

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------
log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# run: execute a command with side effects, or print it under --dry-run
run() {
  if (( DRY_RUN )); then
    printf '    + %s\n' "$*"
  else
    "$@"
  fi
}

# write_file PATH MODE  (content on stdin)
write_file() {
  local path=$1 mode=${2:-0644} content
  content=$(cat)
  if (( DRY_RUN )); then
    printf '    + write %s (mode %s):\n' "$path" "$mode"
    printf '%s\n' "$content" | sed 's/^/        | /'
    return
  fi
  install -d -m 0755 "$(dirname "$path")"
  printf '%s\n' "$content" > "$path.tmp"
  chmod "$mode" "$path.tmp"
  mv -f "$path.tmp" "$path"
}

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  cat <<USAGE

Options:
  --head HOST            LAN IP/name of the head node (required on first run)
  --head-ssh HOST        name used to ssh to the head (default: --head)
  --name NAME            set this machine's hostname / k3s node name
  --lan-iface IFACE      wired interface for model + k3s traffic (auto)
  --token TOKEN          k3s join token (or env CLUSTER_TOKEN)
  --token-file PATH      read the join token from a file
  --rpc-port N           rpc-server port (default $RPC_PORT)
  --rpc-reserve-mb N     RAM kept back from rpc-server (default $RPC_RESERVE_MB)
  --rpc-threads N        rpc-server threads (default: nproc)
  --rpc-cache            let rpc-server cache tensors on local disk
  --k3s-version VER      pin the k3s version (must match the head)
  --llama-ref REF        llama.cpp git ref (must match the head)
  --tailscale-authkey K  non-interactive 'tailscale up'
  --no-tailscale | --no-nfs | --no-build | --no-k3s | --no-lid-ignore
  --dry-run              print what would happen, change nothing
  --leave                remove k3s agent, service, mount and config
  -h, --help
USAGE
}

parse_args() {
  while (( $# )); do
    case $1 in
      --head)            HEAD=$2; shift 2 ;;
      --head-ssh)        HEAD_SSH=$2; shift 2 ;;
      --name)            NODE_NAME=$2; shift 2 ;;
      --lan-iface)       LAN_IFACE=$2; shift 2 ;;
      --token)           TOKEN=$2; shift 2 ;;
      --token-file)      TOKEN_PATH=$2; shift 2 ;;
      --rpc-port)        RPC_PORT=$2; shift 2 ;;
      --rpc-reserve-mb)  RPC_RESERVE_MB=$2; shift 2 ;;
      --rpc-threads)     RPC_THREADS=$2; shift 2 ;;
      --rpc-cache)       RPC_CACHE=1; shift ;;
      --k3s-version)     K3S_VERSION=$2; shift 2 ;;
      --llama-ref)       LLAMA_REF=$2; shift 2 ;;
      --tailscale-authkey) TS_AUTHKEY=$2; shift 2 ;;
      --no-tailscale)    DO_TAILSCALE=0; shift ;;
      --no-nfs)          DO_NFS=0; shift ;;
      --no-build)        DO_BUILD=0; shift ;;
      --no-k3s)          DO_K3S=0; shift ;;
      --no-lid-ignore)   DO_LID=0; shift ;;
      --dry-run)         DRY_RUN=1; shift ;;
      --leave)           LEAVE=1; shift ;;
      -h|--help)         usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
  done
}

# ----------------------------------------------------------------------------
# 1. preflight
# ----------------------------------------------------------------------------
preflight() {
  log "preflight"
  [[ $EUID -eq 0 ]] || die "run as root (sudo ./worker.sh ...)"
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
  command -v ip >/dev/null || die "iproute2 is missing (apt-get install iproute2)"
  # shellcheck disable=SC1091
  . /etc/os-release
  case ${ID:-}:${ID_LIKE:-} in
    *ubuntu*|*debian*) ;;
    *) die "this script expects Ubuntu/Debian, found ${PRETTY_NAME:-unknown}" ;;
  esac

  case $(uname -m) in
    x86_64)        ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac

  HAS_SYSTEMD=0
  [[ -d /run/systemd/system ]] && HAS_SYSTEMD=1
  (( HAS_SYSTEMD )) || warn "no systemd (chroot?) — service and k3s steps will be skipped"

  [[ -n $HEAD ]] || die "--head is required (LAN IP or name of the head node)"
  HEAD_SSH=${HEAD_SSH:-$HEAD}

  NODE_NAME=${NODE_NAME:-$(hostname -s)}
  case $NODE_NAME in
    localhost|ubuntu|debian|android|"")
      die "hostname '$NODE_NAME' is not unique enough for a cluster; pass --name" ;;
  esac
  set_hostname

  detect_lan
  MEM_TOTAL_MB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
  RPC_MEM_MB=$(( MEM_TOTAL_MB - RPC_RESERVE_MB ))
  (( RPC_MEM_MB > 512 )) || die "only ${MEM_TOTAL_MB} MB RAM; lower --rpc-reserve-mb"
  RPC_THREADS=${RPC_THREADS:-$(nproc)}

  cat <<INFO
    node name   : $NODE_NAME ($ARCH, ${MEM_TOTAL_MB} MB RAM, $(nproc) cpus)
    head        : $HEAD (ssh via $HEAD_SSH)
    lan         : $LAN_IFACE $LAN_IP
    rpc-server  : $LAN_IP:$RPC_PORT, ${RPC_MEM_MB} MB offered, $RPC_THREADS threads
    llama.cpp   : $LLAMA_REF
    k3s         : ${K3S_VERSION:-installer default}
INFO
}

# set_hostname: make the box answer to NODE_NAME (k3s and Tailscale use it).
set_hostname() {
  [[ $(hostname -s) == "$NODE_NAME" ]] && return 0
  log "hostname: $(hostname -s) -> $NODE_NAME"
  if command -v hostnamectl >/dev/null && (( HAS_SYSTEMD )); then
    run hostnamectl set-hostname "$NODE_NAME"
  else
    printf '%s\n' "$NODE_NAME" | write_file /etc/hostname 0644
    run hostname "$NODE_NAME"
  fi
  if grep -qs '^127\.0\.1\.1' /etc/hosts; then
    run sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NODE_NAME/" /etc/hosts
  else
    (( DRY_RUN )) && printf '    + append 127.0.1.1 %s to /etc/hosts\n' "$NODE_NAME" \
      || printf '127.0.1.1\t%s\n' "$NODE_NAME" >> /etc/hosts
  fi
}

# detect_lan: find the wired interface that carries the default route.
# Tailscale, docker, flannel and loopback are never candidates.
detect_lan() {
  if [[ -z $LAN_IFACE ]]; then
    local cand
    while read -r cand; do
      case $cand in
        tailscale*|docker*|cni*|flannel*|veth*|lo|br-*) continue ;;
      esac
      LAN_IFACE=$cand
      case $cand in en*|eth*) break ;; esac   # prefer wired, keep looking otherwise
    done < <(ip -o -4 route show default | awk '{print $5}')
  fi
  [[ -n $LAN_IFACE ]] || die "no default-route interface found; pass --lan-iface"
  case $LAN_IFACE in
    en*|eth*) ;;
    *) warn "$LAN_IFACE does not look wired; model traffic will be slow over wifi" ;;
  esac
  LAN_IP=$(ip -o -4 addr show dev "$LAN_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -n1)
  [[ -n $LAN_IP ]] || die "no IPv4 address on $LAN_IFACE (cable moved? pass --lan-iface)"
  LAN_CIDR=$(ip -o -4 addr show dev "$LAN_IFACE" | awk '{print $4}' | head -n1)
  LAN_SUBNET=$(python3 -c "import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)" "$LAN_CIDR" 2>/dev/null || echo "$LAN_CIDR")
}

# ----------------------------------------------------------------------------
# 2. packages
# ----------------------------------------------------------------------------
install_packages() {
  log "packages"
  local pkgs=(curl ca-certificates git cmake build-essential pkg-config
              nfs-common openssh-server python3 jq)
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update -qq
  run apt-get install -y -qq --no-install-recommends "${pkgs[@]}"
  if (( HAS_SYSTEMD )); then
    run systemctl enable --now ssh
  fi
}

# ----------------------------------------------------------------------------
# 3. tailscale
# ----------------------------------------------------------------------------
setup_tailscale() {
  (( DO_TAILSCALE )) || { log "tailscale: skipped"; return; }
  log "tailscale"
  if ! command -v tailscale >/dev/null; then
    run sh -c 'curl -fsSL https://tailscale.com/install.sh | sh'
  fi
  (( HAS_SYSTEMD )) && run systemctl enable --now tailscaled
  # --ssh lets the head reach workers without distributing ssh keys, and
  # --accept-dns gives every node a stable MagicDNS name.
  local args=(--ssh --accept-dns --hostname "$NODE_NAME")
  [[ -n $TS_AUTHKEY ]] && args+=(--authkey "$TS_AUTHKEY")
  if (( DRY_RUN )); then
    run tailscale up "${args[@]}"
  elif tailscale status >/dev/null 2>&1; then
    log "tailscale already up as $(tailscale status --self --json | jq -r .Self.DNSName)"
  else
    log "tailscale up — follow the login URL if one is printed"
    tailscale up "${args[@]}"
  fi
}

# ----------------------------------------------------------------------------
# 4. nfs share
# ----------------------------------------------------------------------------
setup_nfs() {
  (( DO_NFS )) || { log "nfs: skipped"; return; }
  log "nfs: $HEAD:$NFS_EXPORT -> $NFS_MOUNT"
  run install -d -m 0755 "$NFS_MOUNT"
  # nofail + automount: boot never blocks on the head being up, and the share
  # appears the first time something looks at it.
  local line="$HEAD:$NFS_EXPORT $NFS_MOUNT nfs4 _netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=600,soft,timeo=30 0 0"
  if grep -qs " $NFS_MOUNT " /etc/fstab; then
    run sed -i "\| $NFS_MOUNT |c\\$line" /etc/fstab
  else
    if (( DRY_RUN )); then printf '    + append to /etc/fstab: %s\n' "$line"
    else printf '%s\n' "$line" >> /etc/fstab; fi
  fi
  if (( HAS_SYSTEMD )); then
    run systemctl daemon-reload
    run systemctl restart "$(systemd-escape -p --suffix=automount "$NFS_MOUNT")" || true
  fi
  if (( ! DRY_RUN )) && ! timeout 15 ls "$NFS_MOUNT" >/dev/null 2>&1; then
    warn "share not reachable right now; it will mount when the head is up"
  fi
}

# ----------------------------------------------------------------------------
# 5. defaults published by the head
# ----------------------------------------------------------------------------
# head.sh writes $NFS_EXPORT/cluster.env with the versions it built against
# (LLAMA_REF, K3S_VERSION). The RPC protocol must match on both ends, so a
# worker always prefers the head's pins over its own defaults.
load_shared_defaults() {
  local f=$NFS_MOUNT/cluster.env
  (( DO_NFS )) && (( ! DRY_RUN )) || return 0
  if timeout 10 test -r "$f" 2>/dev/null; then
    log "using versions pinned by the head in $f"
    local ref ver
    ref=$(sed -n 's/^LLAMA_REF=//p' "$f" | tail -n1)
    ver=$(sed -n 's/^K3S_VERSION=//p' "$f" | tail -n1)
    [[ -n $ref ]] && LLAMA_REF=$ref
    [[ -n $ver ]] && K3S_VERSION=$ver
  fi
}

# ----------------------------------------------------------------------------
# 6. build rpc-server
# ----------------------------------------------------------------------------
build_rpc_server() {
  (( DO_BUILD )) || { log "build: skipped"; return; }
  log "llama.cpp rpc-server @ $LLAMA_REF"
  if [[ ! -d $SRC_DIR/.git ]]; then
    run git clone --quiet "$LLAMA_REPO" "$SRC_DIR"
  fi
  run git -C "$SRC_DIR" fetch --quiet --tags origin
  run git -C "$SRC_DIR" checkout --quiet --force "$LLAMA_REF"
  if [[ $LLAMA_REF == master ]]; then
    run git -C "$SRC_DIR" pull --quiet --ff-only
  fi
  local built_ref
  built_ref=$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
  if [[ -x $INSTALL_DIR/bin/rpc-server && -r $INSTALL_DIR/BUILT_REF ]] \
     && [[ $(cat "$INSTALL_DIR/BUILT_REF") == "$built_ref" ]]; then
    log "rpc-server already built from $built_ref"
    return
  fi
  # Only the rpc-server target: no CUDA, no curl, native CPU flags.
  run cmake -S "$SRC_DIR" -B "$SRC_DIR/build" \
      -DCMAKE_BUILD_TYPE=Release -DGGML_RPC=ON -DGGML_NATIVE=ON \
      -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
      -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=OFF
  run cmake --build "$SRC_DIR/build" --config Release -j "$(nproc)" --target rpc-server
  run install -d -m 0755 "$INSTALL_DIR/bin"
  run install -m 0755 "$SRC_DIR/build/bin/rpc-server" "$INSTALL_DIR/bin/rpc-server"
  printf '%s\n' "$built_ref" | write_file "$INSTALL_DIR/BUILT_REF"
}

# ----------------------------------------------------------------------------
# 7. config + systemd service
# ----------------------------------------------------------------------------
write_env() {
  log "config: $ENV_FILE"
  write_file "$ENV_FILE" 0644 <<ENV
# home-cluster worker settings — written by worker.sh, read by rpc-server.service
# and by the cluster tooling. Re-run worker.sh after editing.
HEAD=$HEAD
HEAD_SSH=$HEAD_SSH
NODE_NAME=$NODE_NAME
LAN_IFACE=$LAN_IFACE
LAN_IP=$LAN_IP
RPC_PORT=$RPC_PORT
RPC_RESERVE_MB=$RPC_RESERVE_MB
RPC_MEM_MB=$RPC_MEM_MB
RPC_THREADS=$RPC_THREADS
RPC_CACHE=$RPC_CACHE
RPC_EXTRA_ARGS=$( (( RPC_CACHE )) && echo "-c" )
K3S_VERSION=$K3S_VERSION
LLAMA_REF=$LLAMA_REF
NFS_MOUNT=$NFS_MOUNT
ENV
}

install_rpc_service() {
  (( HAS_SYSTEMD )) || { log "rpc-server service: skipped (no systemd)"; return; }
  log "rpc-server.service"
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    run useradd --system --home-dir "$SERVICE_HOME" --create-home \
        --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
  write_file "$UNIT_FILE" 0644 <<UNIT
[Unit]
Description=llama.cpp RPC worker (home-cluster)
Documentation=$LLAMA_REPO/tree/master/tools/rpc
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
EnvironmentFile=$ENV_FILE
Environment=HOME=$SERVICE_HOME
# rpc-server has no authentication: bind to the wired LAN address only.
ExecStart=$INSTALL_DIR/bin/rpc-server --host \${LAN_IP} --port \${RPC_PORT} --mem \${RPC_MEM_MB} --threads \${RPC_THREADS} \$RPC_EXTRA_ARGS
Restart=always
RestartSec=3
# Lose the model, not the box: the kernel kills this first under pressure.
OOMScoreAdjust=500
Nice=5
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$SERVICE_HOME
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
  run systemctl daemon-reload
  if [[ -x $INSTALL_DIR/bin/rpc-server ]] || (( DRY_RUN )); then
    run systemctl enable --now rpc-server.service
    run systemctl restart rpc-server.service
  else
    warn "rpc-server binary missing; unit installed but not started"
  fi
}

# ----------------------------------------------------------------------------
# 8. k3s agent
# ----------------------------------------------------------------------------
resolve_token() {
  if [[ -n $TOKEN_PATH ]]; then
    TOKEN=$(<"$TOKEN_PATH")
  elif [[ -z $TOKEN && -r $TOKEN_FILE ]]; then
    TOKEN=$(<"$TOKEN_FILE")
  fi
  if [[ -z $TOKEN ]]; then
    # Tailscale SSH makes this work with no keys: the head's node-token is the
    # one thing a wiped worker needs to rejoin.
    log "no token given; trying to fetch it from $HEAD_SSH over ssh"
    TOKEN=$(timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$HEAD_SSH" \
            cat /var/lib/rancher/k3s/server/node-token 2>/dev/null || true)
  fi
  if [[ -z $TOKEN && -t 0 ]]; then
    read -r -s -p "k3s join token (from the head: /var/lib/rancher/k3s/server/node-token): " TOKEN
    echo
  fi
  [[ -n $TOKEN ]] || die "no join token: pass --token, --token-file, or set CLUSTER_TOKEN"
  TOKEN=${TOKEN//[$'\r\n']/}
  if (( DRY_RUN )); then printf '    + write %s (mode 0600): ***\n' "$TOKEN_FILE"
  else printf '%s' "$TOKEN" | write_file "$TOKEN_FILE" 0600; fi
}

join_k3s() {
  (( DO_K3S )) || { log "k3s: skipped"; return; }
  (( HAS_SYSTEMD )) || { log "k3s: skipped (no systemd)"; return; }
  log "k3s agent -> https://$HEAD:$K3S_PORT"
  resolve_token
  local exec_args=(agent
    --node-name "$NODE_NAME"
    --node-ip "$LAN_IP"
    --flannel-iface "$LAN_IFACE"
    --node-label "home-cluster/role=worker"
    --node-label "home-cluster/arch=$ARCH"
    --node-label "home-cluster/ram-mb=$MEM_TOTAL_MB"
    --node-label "home-cluster/rpc-port=$RPC_PORT")
  if (( DRY_RUN )); then
    printf '    + curl -sfL https://get.k3s.io | K3S_URL=https://%s:%s K3S_TOKEN=*** %s sh -s - %s\n' \
      "$HEAD" "$K3S_PORT" "${K3S_VERSION:+INSTALL_K3S_VERSION=$K3S_VERSION}" "${exec_args[*]}"
    return
  fi
  if ! timeout 10 bash -c "</dev/tcp/$HEAD/$K3S_PORT" 2>/dev/null; then
    warn "cannot reach $HEAD:$K3S_PORT; installing anyway, the agent retries until the head is up"
  fi
  curl -sfL https://get.k3s.io | \
    K3S_URL="https://$HEAD:$K3S_PORT" \
    K3S_TOKEN="$TOKEN" \
    INSTALL_K3S_VERSION="$K3S_VERSION" \
    sh -s - "${exec_args[@]}"
}

# ----------------------------------------------------------------------------
# 9. host tweaks
# ----------------------------------------------------------------------------
configure_firewall() {
  command -v ufw >/dev/null || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  log "ufw: allowing cluster traffic from $LAN_SUBNET"
  run ufw allow in on "$LAN_IFACE" from "$LAN_SUBNET" to any port "$RPC_PORT" proto tcp comment 'home-cluster rpc-server'
  run ufw allow in on "$LAN_IFACE" from "$LAN_SUBNET" to any port 10250 proto tcp comment 'home-cluster kubelet'
  run ufw allow in on "$LAN_IFACE" from "$LAN_SUBNET" to any port 8472 proto udp comment 'home-cluster flannel'
  run ufw allow in on tailscale0 to any port 22 proto tcp comment 'home-cluster ssh'
}

keep_awake() {
  (( DO_LID )) || return 0
  (( HAS_SYSTEMD )) || return 0
  [[ -d /proc/acpi/button/lid ]] || return 0
  log "logind: ignore lid close so the laptop keeps serving"
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

# ----------------------------------------------------------------------------
# summary / leave
# ----------------------------------------------------------------------------
summary() {
  log "done"
  cat <<SUMMARY

  $NODE_NAME is a worker for head $HEAD.

  check it:
    systemctl status rpc-server            # should be active, listening on $LAN_IP:$RPC_PORT
    ss -ltnp | grep :$RPC_PORT
    systemctl status k3s-agent
    ls $NFS_MOUNT                           # the head's share
  from the head:
    kubectl get nodes -o wide              # $NODE_NAME should turn Ready

  re-run './worker.sh' with no flags after a reboot or wipe; settings live in $ENV_FILE.
SUMMARY
}

leave() {
  [[ $EUID -eq 0 ]] || die "run as root"
  log "leaving the cluster"
  [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]] && run /usr/local/bin/k3s-agent-uninstall.sh
  if [[ -d /run/systemd/system ]]; then
    run systemctl disable --now rpc-server.service 2>/dev/null || true
    run systemctl stop "$(systemd-escape -p --suffix=automount "$NFS_MOUNT")" 2>/dev/null || true
  fi
  run rm -f "$UNIT_FILE" /etc/systemd/logind.conf.d/home-cluster.conf
  run sed -i "\| $NFS_MOUNT |d" /etc/fstab
  run rm -rf "$CONF_DIR" "$INSTALL_DIR"
  [[ -d /run/systemd/system ]] && run systemctl daemon-reload
  log "left. tailscale, packages and the '$SERVICE_USER' user were kept."
}

# ----------------------------------------------------------------------------
# load_saved: settings from a previous run, so a re-run needs no flags.
# Precedence: flags > saved worker.env > built-in defaults.
load_saved() {
  [[ -r $ENV_FILE ]] || return 0
  log "loading saved settings from $ENV_FILE (flags override)"
  # shellcheck disable=SC1090
  . <(grep -E '^[A-Z_]+=' "$ENV_FILE")
  LAN_IP="" RPC_MEM_MB=""   # always recomputed
}

main() {
  load_saved
  parse_args "$@"
  if (( LEAVE )); then leave; exit 0; fi
  (( DRY_RUN )) && log "dry run: nothing below is executed"
  preflight
  install_packages
  setup_tailscale
  setup_nfs
  load_shared_defaults
  build_rpc_server
  write_env
  install_rpc_service
  join_k3s
  configure_firewall
  keep_awake
  summary
}

main "$@"

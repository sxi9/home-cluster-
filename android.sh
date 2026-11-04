#!/usr/bin/env bash
#
# android.sh — join a rooted Android phone (Termux) to the home cluster.
#
# Phones contribute RAM (and, on Snapdragon, the Adreno GPU) through
# llama.cpp's rpc-server, plus the node agent so the head sees them.
# Everything runs natively in Termux: no chroot is needed for that, which
# keeps the phone side small and fast. An Ubuntu chroot is optional
# (--chroot) and experimental; k3s does not run on stock Android kernels.
#
# What it does:
#   1. preflight   Termux check, root check (su), Wi-Fi/USB-ethernet address
#   2. packages    clang cmake git python iproute2 termux-services (+ OpenCL)
#   3. head        find the head's join service, take pins + settings
#   4. llama.cpp   build rpc-server (GGML_RPC=ON, Adreno OpenCL when present)
#   5. services    rpc-server + cluster-agent as termux-services (runit),
#                  started at boot by Termux:Boot, protected from the
#                  Android low-memory killer with root
#   6. root tweaks wake lock, battery-optimisation whitelist, Wi-Fi stays on
#
# Usage (in Termux, as the normal Termux user):
#   curl -fsSL http://HEAD:8787/android.sh | bash           # what head.sh prints
#   bash android.sh --gpu cpu                               # force CPU-only
#   bash android.sh --dry-run
#   bash android.sh --leave
#
# Needs the apps: Termux (F-Droid or GitHub build), Termux:Boot, and for
# off-home access the Tailscale app. Magisk/KernelSU root for the tweaks.
#
set -euo pipefail

JOIN_URL_DEFAULT=""     # filled in by the head when it serves this file
PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
CONF_DIR=$PREFIX/etc/home-cluster
ENV_FILE=$CONF_DIR/worker.env
INSTALL_DIR=$PREFIX/opt/llama.cpp
SRC_DIR=$INSTALL_DIR/src
APP_DIR=$PREFIX/opt/home-cluster
SV_DIR=$PREFIX/var/service
LLAMA_REPO=https://github.com/ggml-org/llama.cpp
AGENT_PORT=8788
RPC_PORT=50052
RPC_RESERVE_MB=2048     # Android itself needs headroom or it kills us
RPC_THREADS=""
GPU="${GPU:-auto}"      # auto | opencl | cpu   (auto: opencl on Adreno)
GPU_NAME=""
HEAD="" HEAD_SSH="" JOIN_URL="${JOIN_URL:-$JOIN_URL_DEFAULT}" NODE_NAME="" LLAMA_REF="master" LAN_IFACE=""
DO_BUILD=1 DO_CHROOT=0 DRY_RUN=0 LEAVE=0
declare -A FLAG_SET=()

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf '    + %s\n' "$*"; else "$@"; fi; }
suro() { if (( DRY_RUN )); then printf '    + su -c %q\n' "$*"; else su -c "$*" || warn "root step failed: $*"; fi; }
write_file() {
  local path=$1 mode=${2:-0644} content; content=$(cat)
  if (( DRY_RUN )); then printf '    + write %s (%s)\n' "$path" "$mode"; printf '%s\n' "$content" | sed 's/^/        | /'; return; fi
  mkdir -p "$(dirname "$path")"; printf '%s\n' "$content" > "$path.tmp"; chmod "$mode" "$path.tmp"; mv -f "$path.tmp" "$path"
}

usage() {
  sed -n '2,/^set -euo/p' "$0" 2>/dev/null | sed '$d' | sed 's/^# \{0,1\}//'
  cat <<USAGE
Options:
  --join URL         head's join service (default: baked in by the head, or --head)
  --head IP          head's LAN IP
  --name NAME        node name (default: model + wlan MAC suffix)
  --lan-iface IFACE  eth0 (USB ethernet) is preferred over wlan0 automatically
  --gpu auto|opencl|cpu
  --rpc-port N | --rpc-reserve-mb N | --rpc-threads N | --llama-ref REF
  --no-build | --chroot | --dry-run | --leave | -h
USAGE
}

parse_args() {
  while (( $# )); do
    case $1 in
      --join) JOIN_URL=$2; shift 2 ;;
      --head) HEAD=$2; FLAG_SET[HEAD]=1; shift 2 ;;
      --name) NODE_NAME=$2; shift 2 ;;
      --lan-iface) LAN_IFACE=$2; shift 2 ;;
      --gpu) GPU=$2; shift 2 ;;
      --rpc-port) RPC_PORT=$2; FLAG_SET[RPC_PORT]=1; shift 2 ;;
      --rpc-reserve-mb) RPC_RESERVE_MB=$2; shift 2 ;;
      --rpc-threads) RPC_THREADS=$2; shift 2 ;;
      --llama-ref) LLAMA_REF=$2; FLAG_SET[LLAMA_REF]=1; shift 2 ;;
      --no-build) DO_BUILD=0; shift ;;
      --chroot) DO_CHROOT=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --leave) LEAVE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option $1" ;;
    esac
  done
}

load_saved() {
  [[ -r $ENV_FILE ]] || return 0
  log "loading saved settings from $ENV_FILE (flags override)"
  # shellcheck disable=SC1090
  . <(grep -E '^[A-Z0-9_]+=' "$ENV_FILE")
  LAN_IP="" LINK_TYPE="" RPC_MEM_MB=""
}

# ----------------------------------------------------------------------------
preflight() {
  log "preflight"
  [[ $PREFIX == *com.termux* ]] || (( DRY_RUN )) || die "run this inside Termux"
  HAS_ROOT=0; command -v su >/dev/null && su -c true 2>/dev/null && HAS_ROOT=1
  (( HAS_ROOT )) || warn "no root: the phone will still work, but Android may kill rpc-server under memory pressure"
  command -v curl >/dev/null || run pkg install -y curl
  command -v ip >/dev/null || run pkg install -y iproute2
  detect_lan
  detect_gpu
  discover_head
  [[ -n $HEAD ]] || die "no head found; pass --head IP (phones cannot resolve .local names)"
  HEAD_SSH=${HEAD_SSH:-$HEAD}; JOIN_URL=${JOIN_URL:-http://$HEAD:8787}
  if [[ -z $NODE_NAME ]]; then
    local model mac; model=$(getprop ro.product.model 2>/dev/null | tr -cs '[:alnum:]' '-' | tr '[:upper:]' '[:lower:]' | sed 's/^-//;s/-$//')
    mac=$( (cat "/sys/class/net/${LAN_IFACE}/address" 2>/dev/null || true) | tr -d : | tail -c 5)
    NODE_NAME="${model:-phone}-${mac:-$RANDOM}"
  fi
  MEM_TOTAL_MB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
  RPC_MEM_MB=$(( MEM_TOTAL_MB - RPC_RESERVE_MB ))
  (( RPC_MEM_MB > 512 )) || die "only ${MEM_TOTAL_MB} MB RAM; lower --rpc-reserve-mb"
  RPC_THREADS=${RPC_THREADS:-$(nproc)}
  cat <<INFO
    node        : $NODE_NAME ($(uname -m), ${MEM_TOTAL_MB} MB RAM, $(nproc) cpus, root=$HAS_ROOT)
    head        : $HEAD via $JOIN_URL
    lan         : $LAN_IFACE $LAN_IP ($LINK_TYPE)
    gpu         : $GPU${GPU_NAME:+ ($GPU_NAME)}
    rpc-server  : $LAN_IP:$RPC_PORT, ${RPC_MEM_MB} MB offered, $RPC_THREADS threads
    llama.cpp   : $LLAMA_REF
INFO
}

detect_lan() {
  local c
  if [[ -z $LAN_IFACE ]]; then
    for c in eth0 usb0 rndis0 wlan0 wlan1; do
      if ip -o -4 addr show dev "$c" 2>/dev/null | grep -q inet; then LAN_IFACE=$c; break; fi
    done
  fi
  [[ -n $LAN_IFACE ]] || die "no network interface with an address (is Wi-Fi on?)"
  LAN_IP=$(ip -o -4 addr show dev "$LAN_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -n1)
  [[ -n $LAN_IP ]] || die "no IPv4 address on $LAN_IFACE"
  case $LAN_IFACE in wlan*) LINK_TYPE=wifi; warn "Wi-Fi link: works, but a USB-C ethernet adapter makes this phone much more useful" ;; *) LINK_TYPE=wired ;; esac
}

detect_gpu() {
  local soc; soc=$(getprop ro.soc.model 2>/dev/null || true)
  [[ -n $soc ]] || soc=$(getprop ro.board.platform 2>/dev/null || true)
  local has_cl=0; [[ -e /vendor/lib64/libOpenCL.so || -e /system/vendor/lib64/libOpenCL.so ]] && has_cl=1
  GPU_NAME=${soc:-}
  if [[ $GPU == auto ]]; then
    if (( has_cl )) && [[ $soc == *SM* || $soc == *sm* || $soc == *Snapdragon* || $soc == *msm* || $soc == *kalama* || $soc == *pineapple* || $soc == *taro* || $soc == *lahaina* ]]; then GPU=opencl; GPU_NAME="Adreno ($soc)"
    elif (( has_cl )); then GPU=opencl
    else GPU=cpu; fi
  fi
  case $GPU in
    cpu) ;;
    opencl) (( has_cl )) || die "--gpu opencl but no /vendor/lib64/libOpenCL.so on this phone; use --gpu cpu" ;;
    *) die "unknown --gpu $GPU (auto|opencl|cpu)" ;;
  esac
  return 0
}

discover_head() {
  local -a cands=(); local u tmp k v
  [[ -n $JOIN_URL ]] && cands+=("$JOIN_URL")
  [[ -n $HEAD ]] && cands+=("http://$HEAD:8787")
  (( ${#cands[@]} )) || return 0
  tmp=$(mktemp)
  for u in "${cands[@]}"; do
    if curl -fsS --max-time 5 "$u/cluster.env" -o "$tmp" 2>/dev/null; then
      JOIN_URL=$u; log "found head's join service at $u"
      while IFS='=' read -r k v; do
        case $k in HEAD|HEAD_SSH|RPC_PORT|LLAMA_REF) [[ -n ${FLAG_SET[$k]:-} ]] || printf -v "$k" '%s' "$v" ;; esac
      done < <(grep -E '^[A-Z0-9_]+=' "$tmp")
      [[ -n $HEAD ]] || HEAD=$(sed -E 's|^https?://([^:/]+).*|\1|' <<<"$u")
      break
    fi
  done
  rm -f "$tmp"
  # an explicit/baked URL names the head even when cluster.env is not published yet
  [[ -z $HEAD && -n $JOIN_URL ]] && HEAD=$(sed -E 's|^https?://([^:/]+).*|\1|' <<<"$JOIN_URL")
  return 0
}

# ----------------------------------------------------------------------------
install_packages() {
  log "packages"
  local pkgs=(git cmake clang make ninja python openssh termux-services termux-api iproute2 jq curl)
  [[ $GPU == opencl ]] && pkgs+=(opencl-headers opencl-clhpp ocl-icd opencl-vendor-driver)
  run pkg update -y
  run pkg install -y "${pkgs[@]}"
}

build_rpc_server() {
  (( DO_BUILD )) || { log "build: skipped"; return; }
  log "llama.cpp rpc-server @ $LLAMA_REF ($GPU) — this takes 10-30 minutes on a phone"
  [[ -d $SRC_DIR/.git ]] || run git clone --quiet "$LLAMA_REPO" "$SRC_DIR"
  run git -C "$SRC_DIR" fetch --quiet --tags origin
  run git -C "$SRC_DIR" checkout --quiet --force "$LLAMA_REF"
  [[ $LLAMA_REF == master ]] && run git -C "$SRC_DIR" pull --quiet --ff-only
  local built; built=$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
  if [[ -x $INSTALL_DIR/bin/rpc-server && $(cat "$INSTALL_DIR/BUILT_REF" 2>/dev/null) == "$built:$GPU" ]]; then
    log "already built"; return
  fi
  local -a flags=(-DGGML_RPC=ON -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
                  -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=OFF -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON
                  -DBUILD_SHARED_LIBS=OFF)
  # Adreno: llama.cpp's OpenCL backend, with the Adreno-tuned kernels.
  [[ $GPU == opencl ]] && flags+=(-DGGML_OPENCL=ON -DGGML_OPENCL_USE_ADRENO_KERNELS=ON -DGGML_OPENCL_EMBED_KERNELS=ON)
  run rm -rf "$SRC_DIR/build"
  run cmake -S "$SRC_DIR" -B "$SRC_DIR/build" -G Ninja "${flags[@]}"
  local target=rpc-server   # ggml-rpc-server on current llama.cpp
  cmake --build "$SRC_DIR/build" --target help 2>/dev/null | grep -q 'ggml-rpc-server' && target=ggml-rpc-server
  run cmake --build "$SRC_DIR/build" --target "$target"
  run mkdir -p "$INSTALL_DIR/bin"
  run cp -f "$SRC_DIR/build/bin/$target" "$INSTALL_DIR/bin/rpc-server"
  printf '%s:%s\n' "$built" "$GPU" | write_file "$INSTALL_DIR/BUILT_REF"
}

install_agent() {
  log "cluster-agent"
  local here src=""; here=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
  if [[ -n $here && -r $here/agent/cluster-agent.py ]]; then src=$here/agent/cluster-agent.py
  else src=$(mktemp); curl -fsS --max-time 10 "$JOIN_URL/cluster-agent.py" -o "$src" || { warn "could not fetch cluster-agent.py"; return 0; }; fi
  run mkdir -p "$APP_DIR"
  run cp -f "$src" "$APP_DIR/cluster-agent.py"
}

write_env() {
  log "config: $ENV_FILE"
  write_file "$ENV_FILE" 0644 <<ENV
# home-cluster phone settings — written by android.sh
ROLE=worker
OS=android
NODE_NAME=$NODE_NAME
HEAD=$HEAD
HEAD_SSH=$HEAD_SSH
JOIN_URL=$JOIN_URL
LAN_IFACE=$LAN_IFACE
LAN_IP=$LAN_IP
LINK_TYPE=$LINK_TYPE
RPC_PORT=$RPC_PORT
RPC_RESERVE_MB=$RPC_RESERVE_MB
RPC_MEM_MB=$RPC_MEM_MB
RPC_THREADS=$RPC_THREADS
GPU=$GPU
GPU_NAME=$GPU_NAME
AGENT_PORT=$AGENT_PORT
LLAMA_REF=$LLAMA_REF
ENV
}

install_services() {
  log "termux-services: rpc-server, cluster-agent"
  # rpc-server: re-reads worker.env on every (re)start so a new Wi-Fi address is picked up.
  write_file "$SV_DIR/rpc-server/run" 0755 <<RUN
#!/data/data/com.termux/files/usr/bin/sh
. $ENV_FILE
ip=\$(ip -o -4 addr show dev "\$LAN_IFACE" 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
[ -n "\$ip" ] || ip=0.0.0.0
exec $INSTALL_DIR/bin/rpc-server --host "\$ip" --port "\$RPC_PORT" --threads "\$RPC_THREADS" 2>&1
RUN
  write_file "$SV_DIR/rpc-server/log/run" 0755 <<RUN
#!/data/data/com.termux/files/usr/bin/sh
exec svlogd -tt $PREFIX/var/log/sv/rpc-server
RUN
  write_file "$SV_DIR/cluster-agent/run" 0755 <<RUN
#!/data/data/com.termux/files/usr/bin/sh
export CLUSTER_ENV=$ENV_FILE
exec python $APP_DIR/cluster-agent.py --bind-all 2>&1
RUN
  write_file "$SV_DIR/cluster-agent/log/run" 0755 <<RUN
#!/data/data/com.termux/files/usr/bin/sh
exec svlogd -tt $PREFIX/var/log/sv/cluster-agent
RUN
  run mkdir -p "$PREFIX/var/log/sv/rpc-server" "$PREFIX/var/log/sv/cluster-agent"
  # Termux:Boot runs everything in ~/.termux/boot at boot; sourcing the profile starts runsvdir.
  write_file "$HOME/.termux/boot/01-home-cluster.sh" 0755 <<BOOT
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
. $PREFIX/etc/profile
BOOT
  if (( DRY_RUN )); then run sv-enable rpc-server; run sv-enable cluster-agent; return; fi
  # start runsvdir now if the profile has not done it in this shell
  # shellcheck disable=SC1091
  pgrep -f runsvdir >/dev/null || { . "$PREFIX/etc/profile.d/start-services.sh" 2>/dev/null || true; sleep 2; }
  sv-enable rpc-server 2>/dev/null || true; sv-enable cluster-agent 2>/dev/null || true
  sv restart rpc-server 2>/dev/null || true; sv restart cluster-agent 2>/dev/null || true
  termux-wake-lock 2>/dev/null || true
}

# ssh into the phone from the head: Termux sshd on 8022, any username, key only
setup_ssh() {
  log "sshd on port 8022 for the head's controller key"
  local pub; pub=$(curl -fsS --max-time 5 "$JOIN_URL/head.pub" 2>/dev/null || true)
  if [[ $pub == ssh-* ]]; then
    if (( DRY_RUN )); then printf '    + append to ~/.ssh/authorized_keys: %s ...\n' "${pub%% *}"
    else
      mkdir -p "$HOME/.ssh"; chmod 0700 "$HOME/.ssh"; touch "$HOME/.ssh/authorized_keys"; chmod 0600 "$HOME/.ssh/authorized_keys"
      grep -qF "$pub" "$HOME/.ssh/authorized_keys" || printf '%s\n' "$pub" >> "$HOME/.ssh/authorized_keys"
    fi
  else
    warn "head.pub not published; 'cluster exec' will not reach this phone until android.sh is re-run"
  fi
  if (( DRY_RUN )); then run sv-enable sshd; else sv-enable sshd 2>/dev/null || true; fi
  return 0
}

root_tweaks() {
  (( HAS_ROOT )) || return 0
  log "root: keep Termux alive, keep Wi-Fi on, protect rpc-server from the low-memory killer"
  suro "dumpsys deviceidle whitelist +com.termux >/dev/null"
  suro "settings put global wifi_sleep_policy 2"
  suro "cmd appops set com.termux RUN_IN_BACKGROUND allow"
  if (( ! DRY_RUN )); then
    sleep 2
    local pid; pid=$(pgrep -f "$INSTALL_DIR/bin/rpc-server" | head -n1 || true)
    [[ -n $pid ]] && suro "echo -1000 > /proc/$pid/oom_score_adj"
  fi
  return 0
}

# Optional Ubuntu chroot (experimental). Gives a real Ubuntu shell on the phone
# for grouped services. k3s needs cgroup v2 + netfilter modules most phone
# kernels lack, so it is NOT started here; rpc-server and the agent already run
# natively above and do not need this.
setup_chroot() {
  (( DO_CHROOT )) || return 0
  (( HAS_ROOT )) || { warn "--chroot needs root"; return 0; }
  log "ubuntu chroot (experimental) at /data/local/ubuntu"
  local url=https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04-base-arm64.tar.gz
  local tgz=$HOME/ubuntu-base-arm64.tar.gz
  [[ -s $tgz ]] || run curl -fL --progress-bar -o "$tgz" "$url"
  suro "mkdir -p /data/local/ubuntu && tar -xzf $tgz -C /data/local/ubuntu --exclude=dev/* 2>/dev/null; true"
  suro "cp /etc/resolv.conf /data/local/ubuntu/etc/resolv.conf 2>/dev/null || printf 'nameserver 1.1.1.1\n' > /data/local/ubuntu/etc/resolv.conf"
  write_file "$PREFIX/bin/ubuntu-chroot" 0755 <<'CH'
#!/data/data/com.termux/files/usr/bin/sh
# enter the Ubuntu chroot on this phone (root). usage: ubuntu-chroot [command]
R=/data/local/ubuntu
su -c "
  mountpoint -q $R/proc || mount -t proc proc $R/proc
  mountpoint -q $R/sys  || mount -t sysfs sys $R/sys
  mountpoint -q $R/dev  || mount -o bind /dev $R/dev
  mountpoint -q $R/dev/pts || mount -t devpts devpts $R/dev/pts
  mkdir -p $R/mnt/sdcard; mountpoint -q $R/mnt/sdcard || mount -o bind /sdcard $R/mnt/sdcard
  HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin TERM=$TERM chroot $R ${*:-/bin/bash -l}
"
CH
  log "enter it with: ubuntu-chroot    (then apt-get update; apt-get install ...)"
}

summary() {
  log "done"
  cat <<SUMMARY

  $NODE_NAME is a phone worker for head $HEAD ($GPU backend).

  check it:
    sv status rpc-server cluster-agent
    tail $PREFIX/var/log/sv/rpc-server/current
    curl -s http://$LAN_IP:$AGENT_PORT/metrics | jq .
  on the head:  cluster nodes     (this phone should be awake, rpc up)

  Keep Termux:Boot installed so the services start after a reboot.
  Re-run 'bash android.sh' any time; settings live in $ENV_FILE.
SUMMARY
}

leave() {
  log "leaving"
  sv-disable rpc-server 2>/dev/null || true; sv-disable cluster-agent 2>/dev/null || true
  sv down rpc-server 2>/dev/null || true; sv down cluster-agent 2>/dev/null || true
  run rm -rf "$SV_DIR/rpc-server" "$SV_DIR/cluster-agent" "$CONF_DIR" "$INSTALL_DIR" "$APP_DIR" "$HOME/.termux/boot/01-home-cluster.sh"
  log "left (the ubuntu chroot, if any, was kept at /data/local/ubuntu)"
}

main() {
  load_saved
  parse_args "$@"
  (( LEAVE )) && { leave; exit 0; }
  (( DRY_RUN )) && log "dry run: nothing below is executed"
  preflight
  install_packages
  build_rpc_server
  install_agent
  write_env
  install_services
  setup_ssh
  root_tweaks
  setup_chroot
  summary
}
main "$@"

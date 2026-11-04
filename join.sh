#!/usr/bin/env bash
#
# join.sh — one entry point for every device:
#
#   sudo ./join.sh head          # this Ubuntu machine becomes the head
#   sudo ./join.sh worker [...]  # this Ubuntu machine joins as a worker
#   ./join.sh android [...]      # this Termux phone joins as a worker
#
# From a checkout it runs the sibling script. Piped from the head
# (curl -fsSL http://HEAD:8787/join.sh | bash -s worker) it fetches the
# right script from the head's join service first. Extra arguments are
# passed through (e.g. --gpu cuda, --dry-run, --leave).
#
set -euo pipefail
JOIN_URL_DEFAULT=""     # filled in by the head when it serves this file
JOIN_URL=${JOIN_URL:-$JOIN_URL_DEFAULT}
[[ -n $JOIN_URL ]] && export JOIN_URL     # the child script discovers the head from it

role=${1:-}; shift || true
case $role in head|worker|android) ;; *) sed -n '2,/^set -euo/p' "$0" 2>/dev/null | sed '$d;s/^# \{0,1\}//'; exit 1 ;; esac
script=$role.sh
here=""; [[ -f ${BASH_SOURCE[0]:-} ]] && here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ -n $here && -r $here/$script ]]; then
  src=$here/$script
elif [[ -n $JOIN_URL ]]; then
  src=$(mktemp); curl -fsSL "$JOIN_URL/$script" -o "$src"
elif [[ $role == head ]]; then
  src=$(mktemp); curl -fsSL "https://raw.githubusercontent.com/sxi9/home-cluster-/main/head.sh" -o "$src"
else
  echo "join.sh: no $script next to me and no head URL; run it from a checkout or via the head's join service" >&2; exit 1
fi

case $role in
  android) exec bash "$src" "$@" ;;
  *) if [[ $EUID -ne 0 ]]; then exec sudo -E bash "$src" "$@"; else exec bash "$src" "$@"; fi ;;
esac

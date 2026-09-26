#!/usr/bin/env bash
set -Eeuo pipefail

report_error() {
  local status=$?
  printf 'FAIL: line %s: %s (exit %s)\n' "$1" "$2" "$status" >&2
  exit "$status"
}
trap 'report_error "$LINENO" "$BASH_COMMAND"' ERR

[[ "$(uname -s)" == Linux ]] || { printf 'SKIP: Linux required\n'; exit 0; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'SKIP: root required\n'; exit 0; }
if ! command -v ip >/dev/null || ! command -v tc >/dev/null; then
  printf 'SKIP: iproute2 required\n'
  exit 0
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
task_tmp="$(mktemp -d /tmp/flowcraft-netns.XXXXXX)"
namespace="fc-$RANDOM-$$"
cleanup() {
  ip netns del "$namespace" >/dev/null 2>&1 || true
  rm -rf "$task_tmp"
}
trap cleanup EXIT

mkdir -p "$task_tmp/root/etc/sysctl.d" "$task_tmp/state"
cat >"$task_tmp/config.conf" <<'EOF'
ROLE=relay
IFACE=fcguest0
RTT_MS=100
PER_FLOW_MBPS=430
TOTAL_MBPS=900
QDISC_MODE=auto
EOF

ip netns add "$namespace"
ip link add fchost0 type veth peer name fcguest0
ip link set fcguest0 netns "$namespace"
ip link set fchost0 up
ip netns exec "$namespace" ip link set lo up
ip netns exec "$namespace" ip link set fcguest0 up
ip netns exec "$namespace" ip route add default dev fcguest0

run_flowcraft() {
  ip netns exec "$namespace" env \
    FLOWCRAFT_CONFIG_FILE="$task_tmp/config.conf" \
    FLOWCRAFT_STATE_DIR="$task_tmp/state" \
    FLOWCRAFT_LOCK_FILE="$task_tmp/lock" \
    FLOWCRAFT_ROOT_PREFIX="$task_tmp/root" \
    FLOWCRAFT_SERVICE_FILE="$task_tmp/flowcraft.service" \
    "$repo_root/bin/flowcraft" "$@"
}

run_flowcraft tc apply
run_flowcraft tc apply
ip netns exec "$namespace" tc qdisc show dev fcguest0 | grep -Eq '^qdisc htb .* root '
ip netns exec "$namespace" tc qdisc show dev fcguest0 | grep -Eq '^qdisc fq .* parent 1:10 '
ip netns exec "$namespace" tc class show dev fcguest0 | grep -Eq 'htb .*rate 900Mbit ceil 900Mbit'
run_flowcraft tc off
ip netns exec "$namespace" tc qdisc show dev fcguest0 | grep -Eq '^qdisc fq .* root '
printf 'PASS: idempotent HTB+fq network namespace integration\n'

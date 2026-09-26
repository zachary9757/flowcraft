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
ip link add fchost0 numtxqueues 2 numrxqueues 2 type veth \
  peer name fcguest0 numtxqueues 2 numrxqueues 2
ip link set fcguest0 netns "$namespace"
ip link set fchost0 up
ip netns exec "$namespace" ip link set lo up
ip netns exec "$namespace" ip link set fcguest0 up
ip netns exec "$namespace" ip route add default dev fcguest0

run_flowcraft() {
  local status trace="$task_tmp/flowcraft-trace"
  if ip netns exec "$namespace" env \
    FLOWCRAFT_CONFIG_FILE="$task_tmp/config.conf" \
    FLOWCRAFT_STATE_DIR="$task_tmp/state" \
    FLOWCRAFT_LOCK_FILE="$task_tmp/lock" \
    FLOWCRAFT_ROOT_PREFIX="$task_tmp/root" \
    FLOWCRAFT_SYSCTL_FILE="$task_tmp/90-flowcraft.conf" \
    FLOWCRAFT_SERVICE_FILE="$task_tmp/flowcraft.service" \
    bash -x "$repo_root/bin/flowcraft" "$@" 2>"$trace"; then
    rm -f "$trace"
    return 0
  else
    status=$?
    printf '%s\n' '--- flowcraft trace ---' >&2
    cat "$trace" >&2
    return "$status"
  fi
}

normalize_qdisc_output() {
  sed -E \
    -e 's/^(qdisc [^ ]+) [^ ]+ /\1 HANDLE /' \
    -e 's/ parent [[:xdigit:]]*:/ parent HANDLE:/' \
    -e 's/ refcnt [0-9]+ / /' \
    -e 's/[[:space:]]+$//'
}

ip netns exec "$namespace" tc qdisc replace dev fcguest0 root pfifo_fast
ip netns exec "$namespace" tc -d qdisc show dev fcguest0 |
  grep -F 'bands 3 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1' >/dev/null
run_flowcraft tc apply
run_flowcraft tc apply
ip netns exec "$namespace" tc qdisc show dev fcguest0 | grep -E '^qdisc htb .* root ' >/dev/null
ip netns exec "$namespace" tc qdisc show dev fcguest0 | grep -E '^qdisc fq .* parent 1:10 ' >/dev/null
ip netns exec "$namespace" tc class show dev fcguest0 | grep -E 'htb .*rate 900Mbit ceil 900Mbit' >/dev/null
run_flowcraft rollback
ip netns exec "$namespace" tc -d qdisc show dev fcguest0 |
  grep -E '^qdisc pfifo_fast .* root .*bands 3 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1$' >/dev/null
run_flowcraft tc apply
run_flowcraft tc off
ip netns exec "$namespace" tc qdisc show dev fcguest0 | grep -E '^qdisc fq .* root ' >/dev/null
run_flowcraft rollback

cat >"$task_tmp/config.conf" <<'EOF'
ROLE=relay
IFACE=fcguest0
RTT_MS=100
PER_FLOW_MBPS=430
TOTAL_MBPS=0
QDISC_MODE=auto
EOF
ip netns exec "$namespace" tc qdisc replace dev fcguest0 root fq
original_fq="$(ip netns exec "$namespace" tc -d qdisc show dev fcguest0 | normalize_qdisc_output)"
run_flowcraft tc apply
ip netns exec "$namespace" tc qdisc show dev fcguest0 |
  grep -E '^qdisc fq .* root .*maxrate 430Mbit' >/dev/null
run_flowcraft rollback
[[ "$(ip netns exec "$namespace" tc -d qdisc show dev fcguest0 | normalize_qdisc_output)" == "$original_fq" ]]

ip netns exec "$namespace" tc qdisc replace dev fcguest0 root mq
while IFS= read -r parent; do
  ip netns exec "$namespace" tc qdisc replace dev fcguest0 parent "$parent" fq
done < <(ip netns exec "$namespace" tc qdisc show dev fcguest0 |
  awk '$1 == "qdisc" && $0 ~ / parent / {for (i=1; i<=NF; i++) if ($i == "parent") print $(i+1)}')
original_mq="$(ip netns exec "$namespace" tc -d qdisc show dev fcguest0 | normalize_qdisc_output)"
run_flowcraft tc apply
ip netns exec "$namespace" tc qdisc show dev fcguest0 | grep -E '^qdisc mq .* root' >/dev/null
[[ "$(ip netns exec "$namespace" tc qdisc show dev fcguest0 | grep -Ec '^qdisc fq .* parent .*maxrate 430Mbit')" == 2 ]]
run_flowcraft rollback
[[ "$(ip netns exec "$namespace" tc -d qdisc show dev fcguest0 | normalize_qdisc_output)" == "$original_mq" ]]
printf 'PASS: available qdisc transactional integration scenarios\n'

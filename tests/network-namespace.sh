#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

((EUID == 0)) || {
  printf 'SKIP: network namespace test requires root\n'
  exit 0
}
command -v ip >/dev/null && command -v tc >/dev/null || {
  printf 'SKIP: iproute2 unavailable\n'
  exit 0
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_TMP="$(mktemp -d /tmp/flowcraft-netns.XXXXXX)"
namespace="flowcraft-test-$$"
trap 'ip netns del "$namespace" >/dev/null 2>&1 || true; rm -rf "$TASK_TMP"' EXIT

ip netns add "$namespace"
ip link add fchost0 type veth peer name fcguest0
ip link set fcguest0 netns "$namespace"
ip link set fchost0 up
ip netns exec "$namespace" ip link set lo up
ip netns exec "$namespace" ip link set fcguest0 up

mkdir -p "$TASK_TMP/etc/flowcraft"
cat >"$TASK_TMP/etc/flowcraft/config.conf" <<'EOF'
ROLE=relay
KERNEL_CHANNEL=skip
IFACE=fcguest0
RTT_MS=160
ORIGIN_RTT_MS=150
PER_FLOW_MBPS=430
TOTAL_MBPS=900
BURST_MODE=policer
IPV4_PRIORITY=off
RPS_MODE=off
INITCWND=0
SHAPER_MODE=auto
EXPERIMENTAL=off
TUNING_PROFILE=normal
EOF

ip netns exec "$namespace" env \
  FLOWCRAFT_VERSION=0.4.0 \
  FLOWCRAFT_ALLOW_NON_ROOT_TESTS=1 \
  FLOWCRAFT_ETC_DIR="$TASK_TMP/etc/flowcraft" \
  FLOWCRAFT_CONFIG_FILE="$TASK_TMP/etc/flowcraft/config.conf" \
  FLOWCRAFT_STATE_DIR="$TASK_TMP/state" \
  bash -c "source '$ROOT/lib/flowcraft/core.sh'; source '$ROOT/lib/flowcraft/tuning.sh'; fc_apply_shape"

ip netns exec "$namespace" tc qdisc show dev fcguest0 | grep -Eq '^qdisc (htb|tbf|fq) '
printf 'PASS: relay qdisc applied inside network namespace\n'

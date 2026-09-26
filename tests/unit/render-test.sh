#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for module in core config discover sysctl tc; do
  # shellcheck disable=SC1090
  source "$repo_root/lib/flowcraft/$module.sh"
done

task_tmp="$(mktemp -d /tmp/flowcraft-render.XXXXXX)"
trap 'rm -rf "$task_tmp"' EXIT
printf 'MemTotal:        4194304 kB\n' >"$task_tmp/meminfo"
printf 'reno cubic bbr\n' >"$task_tmp/cc"
FLOWCRAFT_MEMINFO="$task_tmp/meminfo"
FLOWCRAFT_CC_AVAILABLE="$task_tmp/cc"
FLOWCRAFT_ALLOW_MISSING_SYSCTL_TESTS=1
fc_config_defaults

output="$task_tmp/sysctl.conf"
fc_sysctl_render "$output"
grep -q '^net.ipv4.tcp_congestion_control = bbr$' "$output"
grep -q '^net.core.default_qdisc = fq$' "$output"
grep -q '^net.ipv4.tcp_rmem = 4096 131072 ' "$output"
[[ "$(grep -c '^net.ipv4.tcp_congestion_control' "$output")" == 1 ]]
printf 'PASS: deterministic sysctl rendering\n'

ROLE=relay TOTAL_MBPS=900 PER_FLOW_MBPS=430
plan="$(fc_tc_plan eth0)"
[[ "$plan" == *'root handle 1: htb'* ]]
[[ "$plan" == *'parent 1:10 handle 10: fq maxrate 430mbit'* ]]
printf 'PASS: relay renders HTB plus fq hierarchy\n'

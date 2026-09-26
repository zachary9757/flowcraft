#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for module in core config menu commands; do
  # shellcheck disable=SC1090
  source "$repo_root/lib/flowcraft/$module.sh"
done

task_tmp="$(mktemp -d /tmp/flowcraft-menu.XXXXXX)"
trap 'rm -rf "$task_tmp"' EXIT
FC_ETC_DIR="$task_tmp/etc"
FC_CONFIG_FILE="$FC_ETC_DIR/config.conf"
FC_STATE_DIR="$task_tmp/state"
FC_MANAGED_STATE="$FC_STATE_DIR/managed.state"
FC_SYSCTL_FILE="$task_tmp/90-flowcraft.conf"
FC_LOCK_FILE="$task_tmp/flowcraft.lock"
FLOWCRAFT_ALLOW_NON_ROOT_TESTS=1
fc_take_lock() { FC_LOCKED=1; }
mkdir -p "$FC_ETC_DIR" "$FC_STATE_DIR"
cat >"$FC_CONFIG_FILE" <<'EOF'
ROLE=relay
IFACE=eth0
RTT_MS=80
PER_FLOW_MBPS=430
TOTAL_MBPS=900
QDISC_MODE=auto
EOF

plan_marker="$task_tmp/plan"
apply_marker="$task_tmp/apply"
fc_plan() { touch "$plan_marker"; printf 'test plan\n'; }
fc_apply() { touch "$apply_marker"; }
fc_menu_colors
printf 'y\n' | fc_menu_apply_profile general General >/dev/null
[[ -e "$plan_marker" && -e "$apply_marker" ]] || {
  printf 'FAIL: menu preset did not call plan and apply\n' >&2
  exit 1
}
grep -Fxq 'ROLE=general' "$FC_CONFIG_FILE"
grep -Fxq 'TOTAL_MBPS=0' "$FC_CONFIG_FILE"
printf 'PASS: menu stages a validated preset and drives plan/apply\n'

cat >"$FC_CONFIG_FILE" <<'EOF'
ROLE=relay
IFACE=eth0
RTT_MS=80
PER_FLOW_MBPS=430
TOTAL_MBPS=900
QDISC_MODE=auto
EOF
rm -f "$apply_marker"
fc_apply() { touch "$apply_marker"; return 1; }
printf 'y\n' | fc_menu_apply_profile general General >/dev/null 2>&1 || true
[[ -e "$apply_marker" ]] || { printf 'FAIL: failed apply was not attempted\n' >&2; exit 1; }
grep -Fxq 'ROLE=relay' "$FC_CONFIG_FILE"
grep -Fxq 'TOTAL_MBPS=900' "$FC_CONFIG_FILE"
printf 'PASS: menu restores the previous config after apply failure\n'

menu_marker="$task_tmp/menu"
fc_menu() { touch "$menu_marker"; }
fc_main
[[ -e "$menu_marker" ]] || { printf 'FAIL: no-argument CLI did not open menu\n' >&2; exit 1; }
printf 'PASS: no-argument CLI dispatches to the menu\n'

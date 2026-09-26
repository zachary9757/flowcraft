#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for module in core config discover sysctl tc rollback; do
  # shellcheck disable=SC1090
  source "$repo_root/lib/flowcraft/$module.sh"
done

passes=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; passes=$((passes + 1)); }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; pass "$3"; }

assert_eq "$(fc_route_field dev 'default dev ppp0 scope link')" ppp0 'route parser handles no gateway'
assert_eq "$(fc_route_field dev 'default via 192.0.2.1 dev eth0 proto dhcp')" eth0 'route parser uses keywords'
if fc_route_has_multiple_nexthops 'default proto static nexthop via 192.0.2.1 dev eth0 weight 1 nexthop via 192.0.2.2 dev eth1 weight 1'; then
  pass 'single-line ECMP is detected'
else
  fail 'single-line ECMP was accepted'
fi
if ! (
  fc_default_route_count() { printf '1\n'; }
  fc_selected_default_routes() { printf 'default dev eth0\n'; }
  fc_assert_supported_route
); then fail 'single default route assertion returned failure'; fi
pass 'single default route assertion returns success'
assert_eq "$(fc_buffer_max relay 500 100 4096)" 14597152 'relay buffer uses two BDP plus headroom'
assert_eq "$(fc_buffer_max landing 1000 1 4096)" 33554432 'landing buffer is independent of RTT'

fc_config_defaults
ROLE=general TOTAL_MBPS=0 QDISC_MODE=auto
assert_eq "$(fc_tc_desired_kind)" fq 'general defaults to fq'
ROLE=relay TOTAL_MBPS=900
assert_eq "$(fc_tc_desired_kind)" htb 'aggregate shaping uses HTB'
QDISC_MODE=cake
assert_eq "$(fc_tc_desired_kind)" cake 'explicit CAKE is preserved'
QDISC_MODE=auto
if (QDISC_MODE=fq; TOTAL_MBPS=100; fc_config_validate_semantics >/dev/null 2>&1); then
  fail 'fq accepted an aggregate limit'
fi
pass 'fq rejects aggregate TOTAL_MBPS'

task_tmp="$(mktemp -d /tmp/flowcraft-test.XXXXXX)"
trap 'rm -rf "$task_tmp"' EXIT
FC_CONFIG_FILE="$task_tmp/config.conf"
marker="$task_tmp/executed"
cat >"$FC_CONFIG_FILE" <<EOF
ROLE=relay
IFACE=eth0
TOTAL_MBPS=900
EOF
fc_config_load
assert_eq "$ROLE" relay 'valid config is loaded'
assert_eq "$IFACE" eth0 'valid interface is loaded'
cat >"$FC_CONFIG_FILE" <<EOF
ROLE=relay
IFACE=\$(touch $marker)
TOTAL_MBPS=900
EOF
if (fc_config_load >/dev/null 2>&1); then fail 'invalid config was accepted'; fi
pass 'invalid configuration fails closed'
[[ ! -e "$marker" ]] || fail 'configuration was executed'
pass 'configuration is never executed'

printf 'ROLE=relay' >"$FC_CONFIG_FILE"
fc_config_load
assert_eq "$ROLE" relay 'unterminated final config line is parsed'
rm -f "$FC_CONFIG_FILE"
mkdir "$FC_CONFIG_FILE"
if (fc_config_load >/dev/null 2>&1); then fail 'non-regular config was accepted'; fi
pass 'non-regular configuration fails closed'
rmdir "$FC_CONFIG_FILE"
ln -s "$task_tmp/missing-config" "$FC_CONFIG_FILE"
if (fc_config_load >/dev/null 2>&1); then fail 'dangling config symlink was accepted'; fi
pass 'dangling configuration symlink fails closed'
rm -f "$FC_CONFIG_FILE"

atomic_move_marker="$task_tmp/atomic-move-called"
if (
  FC_DRY_RUN=0
  mkdir() { :; }
  chmod() { return 1; }
  mv() { touch "$atomic_move_marker"; }
  fc_atomic_replace "$task_tmp/source" "$task_tmp/target"
); then
  fail 'atomic replacement hid a permission failure'
fi
[[ ! -e "$atomic_move_marker" ]] || fail 'atomic replacement moved a source after chmod failed'
pass 'atomic replacement propagates preparation failures'

config_lock_marker="$task_tmp/config-lock-called"
FC_ETC_DIR="$task_tmp/default-etc"
FC_CONFIG_FILE="$FC_ETC_DIR/config.conf"
(
  fc_take_lock() { touch "$config_lock_marker"; }
  fc_atomic_replace() { rm -f "$1"; }
  fc_config_defaults
  fc_config_save_defaults
)
[[ -e "$config_lock_marker" ]] || fail 'default config write bypassed the global lock'
pass 'default config persistence takes the global lock'
FC_CONFIG_FILE="$task_tmp/config.conf"

FLOWCRAFT_ROOT_PREFIX="$task_tmp/root"
mkdir -p "$FLOWCRAFT_ROOT_PREFIX/etc/sysctl.d"
printf 'net.ipv4.tcp_congestion_control = cubic\n' >"$FLOWCRAFT_ROOT_PREFIX/etc/sysctl.d/80-other.conf"
[[ "$(fc_find_conflicts)" == *80-other.conf ]] || fail 'conflict not detected'
pass 'conflicting sysctl owner is detected'
mkdir -p "$FLOWCRAFT_ROOT_PREFIX/run/sysctl.d"
printf 'net.core.default_qdisc = fq\n' >"$FLOWCRAFT_ROOT_PREFIX/run/sysctl.d/70-runtime.conf"
[[ "$(fc_find_conflicts)" == *70-runtime.conf* ]] || fail 'runtime sysctl conflict not detected'
pass 'runtime sysctl owner is detected'

FC_STATE_DIR="$task_tmp/state"
FC_QDISC_SNAPSHOT="$FC_STATE_DIR/qdisc.snapshot"
FC_SYSCTL_SNAPSHOT="$FC_STATE_DIR/sysctl.snapshot"
FC_MANAGED_STATE="$FC_STATE_DIR/managed.state"
FC_SYSCTL_FILE="$task_tmp/90-flowcraft.conf"
FLOWCRAFT_PROC_ROOT="$task_tmp/proc"
mkdir -p "$FC_STATE_DIR"
mkdir -p "$FLOWCRAFT_PROC_ROOT/net/ipv4"
touch "$FLOWCRAFT_PROC_ROOT/net/ipv4/tcp_mtu_probing"
write_sysctl_snapshot() {
  local value="$1" checksum
  printf '# FlowCraft pre-apply snapshot v1\nnet.ipv4.tcp_mtu_probing=%s\n' "$value" >"$FC_SYSCTL_SNAPSHOT"
  checksum="$(fc_sysctl_snapshot_checksum "$FC_SYSCTL_SNAPSHOT")"
  printf '# CKSUM=%s\n' "$checksum" >>"$FC_SYSCTL_SNAPSHOT"
}
printf 'IFACE=eth0\nKIND=noqueue\n' >"$FC_QDISC_SNAPSHOT"
if (tc() { return 1; }; fc_tc_restore >/dev/null 2>&1); then
  fail 'qdisc restore accepted an unreadable post-state'
fi
pass 'qdisc restore fails when the resulting state cannot be verified'

printf 'KIND=noqueue\n' >"$FC_QDISC_SNAPSHOT"
if fc_tc_restore >/dev/null 2>&1; then
  fail 'qdisc restore accepted a truncated snapshot'
fi
pass 'qdisc restore rejects a snapshot without an interface'

tc_marker="$task_tmp/tc-called"
printf 'IFACE=eth0\nKIND=fq\n' >"$FC_QDISC_SNAPSHOT"
if (tc() { touch "$tc_marker"; return 0; }; fc_tc_restore >/dev/null 2>&1); then
  fail 'qdisc restore accepted an unsupported snapshot kind'
fi
[[ ! -e "$tc_marker" ]] || fail 'qdisc was changed before snapshot validation'
pass 'qdisc restore validates the kind before changing live state'

printf 'IFACE=eth0\n' >"$FC_QDISC_SNAPSHOT"
if (fc_tc_snapshot eth0 >/dev/null 2>&1); then
  fail 'qdisc snapshot accepted an existing truncated snapshot'
fi
pass 'existing qdisc snapshot is validated before reuse'

rm -f "$FC_SYSCTL_SNAPSHOT"
printf 'net.ipv4.tcp_mtu_probing = 1\n' >"$FC_SYSCTL_FILE"
if fc_sysctl_snapshot >/dev/null 2>&1; then
  fail 'existing managed sysctl file recreated a missing takeover snapshot'
fi
pass 'missing takeover snapshot fails closed for an existing sysctl owner'
rm -f "$FC_SYSCTL_FILE"

touch "$FLOWCRAFT_PROC_ROOT/net/ipv4/tcp_moderate_rcvbuf"
touch "$FLOWCRAFT_PROC_ROOT/net/ipv4/tcp_window_scaling"
if (
  sysctl() {
    [[ "$2" == net.ipv4.tcp_moderate_rcvbuf ]] && { printf '1\n'; return 0; }
    return 1
  }
  fc_sysctl_snapshot >/dev/null 2>&1
); then fail 'partial sysctl snapshot was accepted after a managed key read failed'; fi
[[ ! -e "$FC_SYSCTL_SNAPSHOT" ]] || fail 'failed sysctl snapshot left reusable recovery state'
pass 'sysctl snapshot fails closed when any managed key cannot be read'
rm -f "$FLOWCRAFT_PROC_ROOT/net/ipv4/tcp_moderate_rcvbuf" \
  "$FLOWCRAFT_PROC_ROOT/net/ipv4/tcp_window_scaling"

printf 'IFACE=eth0\nKIND=noqueue\n' >"$FC_QDISC_SNAPSHOT"
cat >"$FC_MANAGED_STATE" <<'EOF'
IFACE=eth0
QDISC=htb
ROLE=relay
PER_FLOW_MBPS=430
TOTAL_MBPS=900
QDISC_MODE=auto
EOF
restore_record="$task_tmp/restore-record"
(
  fc_root_qdisc() { printf 'htb\n'; }
  fc_tc_verify() { return 0; }
  fc_tc_transaction_begin eth0
  ROLE=general PER_FLOW_MBPS=500 TOTAL_MBPS=0 QDISC_MODE=fq
  fc_tc_apply_iface() { printf '%s|%s|%s\n' "$ROLE" "$TOTAL_MBPS" "$QDISC_MODE" >"$restore_record"; }
  fc_tc_abort
)
assert_eq "$(cat "$restore_record")" 'relay|900|auto' 'repeat qdisc failure restores previous managed policy'
[[ -e "$FC_QDISC_SNAPSHOT" && -e "$FC_MANAGED_STATE" ]] || fail 'repeat qdisc rollback removed takeover state'
pass 'repeat qdisc rollback preserves takeover snapshots'

if ! (
  fc_root_qdisc() { printf 'htb\n'; }
  ROLE=relay PER_FLOW_MBPS=430 TOTAL_MBPS=900 QDISC_MODE=auto
  tc() {
    if [[ "$1 $2" == 'qdisc show' ]]; then
      printf 'qdisc htb 1: root refcnt 2 default 0x10\nqdisc fq 10: parent 1:10 limit 10000p maxrate 430Mbit\n'
    else
      printf 'class htb 1:10 root rate 900Mbit ceil 900Mbit\n'
    fi
  }
  fc_tc_verify eth0
); then fail 'complete HTB+fq state was rejected'; fi
pass 'qdisc verification checks complete HTB+fq state'
if (
  fc_root_qdisc() { printf 'htb\n'; }
  ROLE=relay PER_FLOW_MBPS=430 TOTAL_MBPS=900 QDISC_MODE=auto
  tc() {
    if [[ "$1 $2" == 'qdisc show' ]]; then
      printf 'qdisc htb 1: root refcnt 2 default 0x10\nqdisc fq 10: parent 1:10 limit 10000p maxrate 430Mbit\n'
    else
      printf 'class htb 1:10 root rate 800Mbit ceil 800Mbit\n'
    fi
  }
  fc_tc_verify eth0
); then fail 'wrong HTB rate passed verification'; fi
pass 'qdisc verification rejects wrong HTB rate'

if ! (
  fc_root_qdisc() { printf 'cake\n'; }
  ROLE=general TOTAL_MBPS=900 QDISC_MODE=cake
  tc() { printf 'qdisc cake 1: root refcnt 2 bandwidth 900Mbit besteffort\n'; }
  fc_tc_verify eth0
); then fail 'CAKE besteffort state was rejected'; fi
pass 'qdisc verification accepts CAKE besteffort'
if (
  fc_root_qdisc() { printf 'cake\n'; }
  ROLE=general TOTAL_MBPS=900 QDISC_MODE=cake
  tc() { printf 'qdisc cake 1: root refcnt 2 bandwidth 900Mbit diffserv3\n'; }
  fc_tc_verify eth0
); then fail 'CAKE diffserv mode passed besteffort verification'; fi
pass 'qdisc verification rejects CAKE diffserv drift'

if (
  fc_root_qdisc() { printf 'htb\n'; }
  ROLE=general PER_FLOW_MBPS=500 TOTAL_MBPS=0 QDISC_MODE=fq
  tc() {
    if [[ "$1 $2" == 'qdisc show' ]]; then
      printf 'qdisc htb 1: root refcnt 2 default 0x10\nqdisc fq 10: parent 1:10 limit 10000p maxrate 430Mbit\n'
    else
      printf 'class htb 1:10 root rate 800Mbit ceil 800Mbit\nclass htb 1:20 parent 1: rate 900Mbit ceil 900Mbit\n'
    fi
  }
  fc_tc_transaction_begin eth0 >/dev/null 2>&1
); then fail 'qdisc transaction accepted drift hidden by another class'; fi
pass 'qdisc transaction rejects parameter drift before mutation'

FC_SYSCTL_FILE="$task_tmp/90-flowcraft.conf"
FC_SYSCTL_SNAPSHOT="$FC_STATE_DIR/sysctl.snapshot"
write_sysctl_snapshot 0
printf 'net.ipv4.tcp_mtu_probing = 1\n' >"$FC_SYSCTL_FILE"
(
  sysctl() {
    case "$1" in
      -n) printf '1\n' ;;
      -p) return 0 ;;
      *) return 0 ;;
    esac
  }
  fc_sysctl_transaction_begin
  printf 'net.ipv4.tcp_mtu_probing = 2\n' >"$FC_SYSCTL_FILE"
  fc_sysctl_transaction_restore
)
grep -Fxq 'net.ipv4.tcp_mtu_probing = 1' "$FC_SYSCTL_FILE" || fail 'previous sysctl file was not restored'
[[ -e "$FC_SYSCTL_SNAPSHOT" ]] || fail 'repeat sysctl rollback removed takeover snapshot'
pass 'repeat sysctl failure restores previous managed file'

if (
  write_sysctl_snapshot 0
  printf 'net.ipv4.tcp_mtu_probing = 1\n' >"$FC_SYSCTL_FILE"
  sysctl() { [[ "$1" == -n ]] && printf '1\n'; }
  cp() { return 1; }
  fc_sysctl_transaction_begin
); then fail 'sysctl transaction hid a backup copy failure'; fi
pass 'sysctl transaction propagates backup copy failures'

printf 'net.ipv4.tcp_mtu_probing = 1\n' >"$FC_SYSCTL_FILE"
FC_SYSCTL_TXN_WAS_MANAGED=1
FC_SYSCTL_TXN_BACKUP="$task_tmp/transaction-backup"
printf 'net.ipv4.tcp_mtu_probing = 0\n' >"$FC_SYSCTL_TXN_BACKUP"
if (cp() { return 1; }; fc_sysctl_transaction_restore); then
  fail 'sysctl transaction restore hid a copy failure'
fi
grep -Fxq 'net.ipv4.tcp_mtu_probing = 1' "$FC_SYSCTL_FILE" || fail 'failed restore replaced the managed sysctl file'
pass 'sysctl transaction restore preserves state on copy failure'
fc_sysctl_transaction_cleanup

sysctl_apply_marker="$task_tmp/sysctl-apply-called"
if (
  fc_sysctl_render() { printf 'net.ipv4.tcp_mtu_probing = 1\n' >"$1"; }
  fc_atomic_replace() { return 1; }
  sysctl() { touch "$sysctl_apply_marker"; }
  fc_sysctl_apply
); then fail 'sysctl apply hid an atomic replacement failure'; fi
[[ ! -e "$sysctl_apply_marker" ]] || fail 'sysctl apply loaded the old file after replacement failed'
pass 'sysctl apply propagates atomic replacement failures'

FC_SYSCTL_TXN_WAS_MANAGED=0
printf 'net.ipv4.tcp_mtu_probing = 1\n' >"$FC_SYSCTL_FILE"
if (
  rm() { return 1; }
  fc_has() { return 1; }
  fc_sysctl_restore() { :; }
  fc_sysctl_transaction_restore >/dev/null 2>&1
); then fail 'first sysctl transaction restore hid a delete failure'; fi
grep -Fxq 'net.ipv4.tcp_mtu_probing = 1' "$FC_SYSCTL_FILE" || fail 'delete failure unexpectedly changed the sysctl file'
pass 'first sysctl transaction restore propagates delete failures'

printf '# comments only\n' >"$FC_SYSCTL_FILE"
if (sysctl() { return 0; }; fc_sysctl_verify); then fail 'empty managed sysctl policy passed verification'; fi
pass 'sysctl verification rejects a policy without managed keys'

printf '# FlowCraft pre-apply snapshot v1\nnet.ipv4.tcp_mtu_probing=0\n' >"$FC_SYSCTL_SNAPSHOT"
if fc_sysctl_snapshot_validate >/dev/null 2>&1; then fail 'truncated sysctl snapshot passed validation'; fi
pass 'truncated sysctl snapshot fails closed'
write_sysctl_snapshot 0

off_marker="$task_tmp/tc-off-abort"
if (
  fc_need_root() { :; }
  fc_take_lock() { :; }
  fc_config_load() { ROLE=relay; IFACE=eth0; PER_FLOW_MBPS=430; TOTAL_MBPS=900; QDISC_MODE=auto; }
  fc_resolve_iface() { printf 'eth0\n'; }
  fc_assert_qdisc_takeover_safe() { :; }
  fc_tc_transaction_begin() { :; }
  fc_tc_snapshot() { :; }
  tc() { return 1; }
  fc_tc_abort() { touch "$off_marker"; }
  fc_tc_off >/dev/null 2>&1
); then
  fail 'tc off reported success after qdisc replace failed'
fi
[[ -e "$off_marker" ]] || fail 'tc off failure did not invoke rollback'
pass 'tc off failure invokes rollback'

rm -f "$FC_SYSCTL_FILE" "$FC_SYSCTL_SNAPSHOT"
printf 'IFACE=eth0\n' >"$FC_QDISC_SNAPSHOT"
cat >"$FC_MANAGED_STATE" <<'EOF'
IFACE=eth0
QDISC=fq
ROLE=general
PER_FLOW_MBPS=500
TOTAL_MBPS=0
QDISC_MODE=fq
EOF
service_marker="$task_tmp/systemctl-called"
if (
  fc_need_root() { :; }
  fc_take_lock() { :; }
  fc_has() { [[ "$1" == systemctl ]]; }
  systemctl() { touch "$service_marker"; }
  fc_rollback >/dev/null 2>&1
); then
  fail 'rollback accepted an invalid snapshot'
fi
[[ ! -e "$service_marker" ]] || fail 'rollback stopped the service before validating snapshots'
pass 'rollback validates snapshots before service changes'

write_sysctl_snapshot 0
printf 'net.ipv4.tcp_mtu_probing = 1\n' >"$FC_SYSCTL_FILE"
printf 'IFACE=eth0\nKIND=noqueue\n' >"$FC_QDISC_SNAPSHOT"
if (
  rm() { return 1; }
  fc_rollback_internal >/dev/null 2>&1
); then fail 'manual rollback hid a sysctl delete failure'; fi
[[ -e "$FC_SYSCTL_SNAPSHOT" ]] || fail 'manual rollback discarded the snapshot after delete failure'
pass 'manual rollback preserves recovery state on delete failure'
rm -f "$FC_SYSCTL_FILE" "$FC_SYSCTL_SNAPSHOT"

printf 'IFACE=eth0\nKIND=noqueue\n' >"$FC_QDISC_SNAPSHOT"
cat >"$FC_MANAGED_STATE" <<'EOF'
IFACE=eth0
QDISC=fq
ROLE=general
PER_FLOW_MBPS=500
TOTAL_MBPS=0
QDISC_MODE=fq
EOF
sysctl_marker="$task_tmp/sysctl-called"
(
  sysctl() { touch "$sysctl_marker"; }
  tc() { return 0; }
  fc_root_qdisc() { printf 'noqueue\n'; }
  fc_rollback_internal
)
[[ ! -e "$sysctl_marker" ]] || fail 'tc-only rollback reloaded unowned sysctl state'
pass 'tc-only rollback does not touch sysctl'

rm -f "$FC_QDISC_SNAPSHOT"
printf 'IFACE=eth0\nQDISC=fq\n' >"$FC_MANAGED_STATE"
if fc_rollback_internal >/dev/null 2>&1; then
  fail 'rollback accepted a missing qdisc snapshot'
fi
pass 'rollback refuses managed qdisc state without a snapshot'

printf '%s tests passed\n' "$passes"

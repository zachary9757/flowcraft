#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_TMP="$(mktemp -d /tmp/flowcraft-tests.XXXXXX)"
trap 'rm -rf "$TASK_TMP"' EXIT

export FLOWCRAFT_VERSION=0.3.0
export FLOWCRAFT_ALLOW_NON_ROOT_TESTS=1
export FLOWCRAFT_ETC_DIR="$TASK_TMP/etc/flowcraft"
export FLOWCRAFT_STATE_DIR="$TASK_TMP/state"
export FLOWCRAFT_SYSCTL_FILE="$TASK_TMP/etc/sysctl.d/99-flowcraft.conf"
export FLOWCRAFT_SERVICE_FILE="$TASK_TMP/etc/systemd/flowcraft.service"
export FLOWCRAFT_CONFIG_FILE="$FLOWCRAFT_ETC_DIR/config.conf"
export FLOWCRAFT_PROC_ROOT="$TASK_TMP/proc/sys"
export FLOWCRAFT_SYS_CLASS_NET="$TASK_TMP/sys/class/net"
export FLOWCRAFT_ROOT_PREFIX="$TASK_TMP/root"

# shellcheck source=../lib/flowcraft/core.sh
source "$ROOT/lib/flowcraft/core.sh"
# shellcheck source=../lib/flowcraft/tuning.sh
source "$ROOT/lib/flowcraft/tuning.sh"
# shellcheck source=../lib/flowcraft/fit.sh
source "$ROOT/lib/flowcraft/fit.sh"
# shellcheck source=../lib/flowcraft/kernel.sh
source "$ROOT/lib/flowcraft/kernel.sh"
# shellcheck source=../lib/flowcraft/commands.sh
source "$ROOT/lib/flowcraft/commands.sh"

passed=0
failed=0
check_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf 'PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'FAIL: %s (expected=%q actual=%q)\n' "$name" "$expected" "$actual" >&2
    failed=$((failed + 1))
  fi
}

check_true() {
  local name="$1"
  shift
  if ("$@"); then
    printf 'PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'FAIL: %s\n' "$name" >&2
    failed=$((failed + 1))
  fi
}

check_false() {
  local name="$1"
  shift
  if ("$@"); then
    printf 'FAIL: %s\n' "$name" >&2
    failed=$((failed + 1))
  else
    printf 'PASS: %s\n' "$name"
    passed=$((passed + 1))
  fi
}

check_eq '450M 160ms buffer with headroom' 20097152 "$(fc_tcp_max 450 160 2048)"
check_eq '950M 160ms buffer with headroom' 40097152 "$(fc_tcp_max 950 160 4096)"
check_eq 'small RAM cap' 8388608 "$(fc_tcp_max 1000 300 256)"
check_eq '2G RAM tcp_mem budget' '32768 65536 131072' "$(fc_tcp_mem_values 2048)"
check_eq '8G RAM tcp_mem budget' '131072 262144 524288' "$(fc_tcp_mem_values 8192)"
check_eq 'relay receive RTT' 160 "$(ROLE=relay RTT_MS=160 ORIGIN_RTT_MS=250 fc_recv_rtt)"
check_eq 'landing receive RTT' 250 "$(ROLE=landing RTT_MS=5 ORIGIN_RTT_MS=250 fc_recv_rtt)"
check_eq 'policer burst' 210 "$(fc_htb_burst_kb 430 policer)"
check_eq 'throughput burst' 525 "$(fc_htb_burst_kb 430 throughput)"
check_eq 'fit margin at 30M' 1 "$(fc_fit_margin 30)"
check_eq 'fit margin at 500M' 15 "$(fc_fit_margin 500)"
check_eq 'fit margin above 1G' 40 "$(fc_fit_margin 2500)"
check_eq 'fit loss uses bandwidth-relative packet estimate' 0.0322 "$(fc_fit_loss_pct 100 300 12)"
check_eq 'fit bounds expand above lossy goodput' '285 393 11' "$(fc_fit_scan_bounds 300 3 2500)"
check_true 'fit spike exceeds absolute threshold' fc_fit_is_spike 0.2 0 0.1
check_false 'fit stable baseline is not a spike' fc_fit_is_spike 0.3 0.1 0.1
fit_queue="$TASK_TMP/fit-queue"
fit_scan_result="$TASK_TMP/fit-scan-result"
printf '100 0 99\n110 10000 80\n110 10000 80\n110 10000 80\n' >"$fit_queue"
(
  fc_fit_apply_test_rate() { return 0; }
  fc_fit_measure() {
    sed -n '1p' "$fit_queue"
    tail -n +2 "$fit_queue" >"${fit_queue}.next"
    mv -f "${fit_queue}.next" "$fit_queue"
  }
  FC_FIT_LAST_OK=''
  FC_FIT_BROKE_AT=''
  FC_FIT_BASE_LOSS=''
  FC_FIT_SLOW_HITS=0
  FC_FIT_PEER_SLOW=0
  fc_fit_scan_range eth-test peer.test 5201 -4 12 0 0.1 100 110 10 2048 >/dev/null
  printf '%s %s\n' "$FC_FIT_LAST_OK" "$FC_FIT_BROKE_AT" >"$fit_scan_result"
)
check_eq 'fit scan keeps last clean rate and confirms 2-of-3 spike' '100 110' "$(<"$fit_scan_result")"
check_eq '1 CPU mask' 1 "$(fc_cpu_mask 1)"
check_eq '32 CPU mask' ffffffff "$(fc_cpu_mask 32)"
check_eq '33 CPU mask' 1,ffffffff "$(fc_cpu_mask 33)"
check_eq '64 CPU mask' ffffffff,ffffffff "$(fc_cpu_mask 64)"
check_eq '65 CPU mask' 1,ffffffff,ffffffff "$(fc_cpu_mask 65)"
check_true 'x86 kernel keeps IPv4 ESP available' grep -q '^CONFIG_INET_ESP=m$' "$ROOT/kernel/x86-64.config"
check_true 'x86 kernel keeps IPv6 ESP available' grep -q '^CONFIG_INET6_ESP=m$' "$ROOT/kernel/x86-64.config"
check_true 'x86 kernel keeps RxRPC available' grep -q '^CONFIG_AF_RXRPC=m$' "$ROOT/kernel/x86-64.config"
check_true 'x86 kernel keeps RXKAD available' grep -q '^CONFIG_RXKAD=y$' "$ROOT/kernel/x86-64.config"
check_true 'arm64 kernel keeps IPv4 ESP available' grep -q '^CONFIG_INET_ESP=m$' "$ROOT/kernel/arm64.config"
check_true 'arm64 kernel keeps IPv6 ESP available' grep -q '^CONFIG_INET6_ESP=m$' "$ROOT/kernel/arm64.config"
check_true 'arm64 kernel keeps RxRPC available' grep -q '^CONFIG_AF_RXRPC=m$' "$ROOT/kernel/arm64.config"
check_true 'arm64 kernel keeps RXKAD available' grep -q '^CONFIG_RXKAD=y$' "$ROOT/kernel/arm64.config"
check_true 'kernel image package is installable' fc_kernel_package_asset_allowed 'linux-image-7.1.8-flowcraft-bbrv3_7.1.8-1_amd64.deb'
check_true 'kernel headers package is installable' fc_kernel_package_asset_allowed 'linux-headers-7.1.8-flowcraft-bbrv3_7.1.8-1_amd64.deb'
check_false 'linux-libc-dev package is rejected' fc_kernel_package_asset_allowed 'linux-libc-dev_7.1.8-1_amd64.deb'
check_false 'kernel debug package is rejected' fc_kernel_package_asset_allowed 'linux-image-7.1.8-flowcraft-bbrv3-dbg_7.1.8-1_amd64.deb'
check_false 'package path traversal is rejected' fc_kernel_package_asset_allowed '../linux-image-7.1.8-flowcraft-bbrv3_7.1.8-1_amd64.deb'
kernel_dependency_log="$TASK_TMP/kernel-dependencies.log"
: >"$kernel_dependency_log"
if (
  dependencies_installed=0
  fc_has() {
    case "$1" in
      apt-get) return 0 ;;
      curl | jq | sha256sum) ((dependencies_installed == 1)) ;;
      *) command -v "$1" >/dev/null 2>&1 ;;
    esac
  }
  apt-get() {
    printf 'apt-get' >>"$kernel_dependency_log"
    printf ' %s' "$@" >>"$kernel_dependency_log"
    printf '\n' >>"$kernel_dependency_log"
    [[ "${1:-}" == install ]] && dependencies_installed=1
    return 0
  }
  fc_kernel_ensure_dependencies >/dev/null
); then
  check_true 'kernel dependencies run apt update' grep -q '^apt-get update$' "$kernel_dependency_log"
  check_true 'kernel dependencies install required packages' grep -q '^apt-get install -y curl jq coreutils ca-certificates$' "$kernel_dependency_log"
else
  check_true 'kernel dependency installation succeeds' false
fi
menu_output="$(fc_menu_render)"
check_true 'menu renders first-install action' grep -q '首次安装 / 角色向导' <<<"$menu_output"
check_true 'menu renders kernel management' grep -q 'BBRv3 内核管理' <<<"$menu_output"
check_true 'menu exposes port fit workflow' grep -q '端口拐点实测' <<<"$menu_output"
check_false 'menu omits generic bandwidth benchmark' grep -q '带宽测试' <<<"$menu_output"
check_true 'menu exposes integrated resume and diagnostics' grep -q 'resume / status / diagnose / security' <<<"$menu_output"
check_true 'menu explains IPv4 enablement condition' grep -q 'IPv6 绕路/握手异常时开启' <<<"$menu_output"
check_true 'menu explains RPS enablement condition' grep -q '单核 SoftIRQ 瓶颈时开启' <<<"$menu_output"
check_true 'menu reports unconfigured state' grep -q '配置=未配置' <<<"$menu_output"
usage_output="$(fc_usage)"
check_true 'usage exposes the ftcp command' grep -q '^  ftcp fit ' <<<"$usage_output"
check_false 'usage removes benchmark command' grep -q 'benchmark' <<<"$usage_output"
check_false 'usage does not expose the old flowcraft command' grep -q '^  flowcraft' <<<"$usage_output"
check_eq 'version uses the short command name' 'ftcp 0.3.0' "$(fc_main version)"
role_guide="$(fc_print_role_guide)"
check_true 'role guide includes 500M reference' grep -q '500M 家宽.*430.*450' <<<"$role_guide"
check_true 'role guide includes 1G and 2.5G references' grep -q '2.5G 端口.*2300' <<<"$role_guide"

mkdir -p "$FLOWCRAFT_ETC_DIR"
sentinel="$TASK_TMP/should-not-exist"
{
  printf 'ROLE=relay\n'
  printf 'RTT_MS=220\n'
  printf 'IFACE=$(touch %s)\n' "$sentinel"
  printf 'UNKNOWN_KEY=value\n'
} >"$FLOWCRAFT_CONFIG_FILE"
fc_load_config
check_eq 'valid config loaded' relay "$ROLE"
check_eq 'numeric config loaded' 220 "$RTT_MS"
check_eq 'invalid interface rejected' auto "$IFACE"
check_true 'config is never executed' test ! -e "$sentinel"

mkdir -p "$FLOWCRAFT_ROOT_PREFIX/etc/sysctl.d"
printf 'net.ipv4.tcp_congestion_control = bbr\n' >"$FLOWCRAFT_ROOT_PREFIX/etc/sysctl.d/legacy.conf"
check_true 'conflicting sysctl owner is detected' grep -q 'legacy.conf' < <(fc_find_conflicts)
rm -f "$FLOWCRAFT_ROOT_PREFIX/etc/sysctl.d/legacy.conf"
mkdir -p "$FLOWCRAFT_ROOT_PREFIX/etc/systemd/system"
: >"$FLOWCRAFT_ROOT_PREFIX/etc/systemd/system/tcpfit-qdisc.service"
check_true 'tcpfit qdisc owner is detected' grep -q 'tcpfit-qdisc.service' < <(fc_find_conflicts)
rm -f "$FLOWCRAFT_ROOT_PREFIX/etc/systemd/system/tcpfit-qdisc.service"
empty_conflicts="$(fc_find_conflicts | sort -u)"
check_eq 'empty conflict scan succeeds under pipefail' '' "$empty_conflicts"

while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  path="$(fc_sysctl_proc_path "$key")"
  mkdir -p "$(dirname "$path")"
  : >"$path"
done <<<"$FC_TUNED_KEYS"

mock_bin="$TASK_TMP/bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/sysctl" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == -qw ]]; then
  printf '%s\n' "${2:-}" >>"${FLOWCRAFT_SYSCTL_LOG:?}"
  exit 0
fi
if [[ "${1:-}" == -n ]]; then
  [[ "${2:-}" == net.ipv4.tcp_congestion_control ]] && printf 'cubic\n' || printf '0\n'
fi
exit 0
MOCK
cat >"$mock_bin/modprobe" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat >"$mock_bin/iperf3" <<'MOCK'
#!/usr/bin/env bash
printf '[  5]   0.00-10.00  sec   596 MBytes   500 Mbits/sec   12 sender\n'
printf '[  5]   0.00-10.00  sec   584 MBytes   490 Mbits/sec      receiver\n'
MOCK
cat >"$mock_bin/timeout" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == --foreground ]] && shift
shift
exec "$@"
MOCK
cat >"$mock_bin/tc" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FLOWCRAFT_TC_LOG:?}"
if [[ "$*" == "qdisc show dev "* ]]; then
  printf 'qdisc fq 0: root refcnt 2\n'
  exit 0
fi
if [[ "${FLOWCRAFT_TC_MODE:-ok}" == htb-fail && "$*" == *" htb "* ]]; then
  exit 1
fi
exit 0
MOCK
chmod +x "$mock_bin/sysctl" "$mock_bin/modprobe" "$mock_bin/iperf3" "$mock_bin/timeout" "$mock_bin/tc"
PATH="$mock_bin:$PATH"
export PATH
export FLOWCRAFT_SYSCTL_LOG="$TASK_TMP/sysctl.log"
export FLOWCRAFT_TC_LOG="$TASK_TMP/tc.log"
: >"$FLOWCRAFT_SYSCTL_LOG"
: >"$FLOWCRAFT_TC_LOG"

check_eq 'iperf3 sender receiver and retransmits are parsed as one sample' '500 12 490' "$(fc_fit_run_iperf peer.test 5201 10 1 -4)"

FC_DRY_RUN=1
dry_output="$(fc_write_sysctl_profile 2>&1)"
check_true 'dry-run renders sysctl profile' grep -q 'net.core.default_qdisc = fq' <<<"$dry_output"
check_true 'normal profile keeps learned TCP metrics' grep -q 'net.ipv4.tcp_no_metrics_save = 0' <<<"$dry_output"
check_true 'normal profile starts sockets at 1 MiB' grep -q 'net.core.rmem_default = 1048576' <<<"$dry_output"
check_true 'normal profile enables TCP Fast Open' grep -q 'net.ipv4.tcp_fastopen = 3' <<<"$dry_output"
check_true 'normal profile raises netdev processing budget' grep -q 'net.core.netdev_budget = 600' <<<"$dry_output"
check_false 'normal profile does not force tcp_notsent_lowat' grep -q 'net.ipv4.tcp_notsent_lowat' <<<"$dry_output"
check_true 'dry-run does not write sysctl target' test ! -e "$FLOWCRAFT_SYSCTL_FILE"

FC_DRY_RUN=0
mkdir -p "$FLOWCRAFT_STATE_DIR"
printf 'net.core.somaxconn=128\nnet.ipv4.tcp_fin_timeout=60\n' >"$FC_SYSCTL_SNAPSHOT"
fc_restore_sysctl_snapshot >/dev/null
check_true 'snapshot restores exact sysctl value' grep -q '^net.core.somaxconn=128$' "$FLOWCRAFT_SYSCTL_LOG"

fc_default_config
ROLE=relay
IFACE=eth-test
TOTAL_MBPS=900
PER_FLOW_MBPS=430
fc_save_config
export FLOWCRAFT_TC_MODE=htb-fail
fc_apply_shape >/dev/null
check_true 'HTB failure falls back to TBF' grep -q '^SHAPER_MODE=tbf$' "$FLOWCRAFT_CONFIG_FILE"
check_true 'fallback removes previous root qdisc' grep -q '^qdisc del dev eth-test root$' "$FLOWCRAFT_TC_LOG"
check_true 'TBF fallback retains fq maxrate leaf' grep -q 'qdisc add dev eth-test parent 1: handle 10: fq.*maxrate 430mbit' "$FLOWCRAFT_TC_LOG"

export FLOWCRAFT_TC_MODE=ok
fc_default_config
ROLE=general
IFACE=eth-test
fc_save_config
fc_fit_apply_result fitted 510 0 >/dev/null
check_true 'fit persists measured aggregate rate' grep -q '^TOTAL_MBPS=510$' "$FLOWCRAFT_CONFIG_FILE"
check_true 'general fit lifts single-flow ceiling with aggregate rate' grep -q '^PER_FLOW_MBPS=510$' "$FLOWCRAFT_CONFIG_FILE"
check_true 'fit persists HTB as the Flowcraft-owned shaper' grep -q '^SHAPER_MODE=htb$' "$FLOWCRAFT_CONFIG_FILE"
check_true 'fit apply uses HTB plus fq at the measured rate' grep -q 'qdisc add dev eth-test parent 1:10 handle 10: fq.*maxrate 510mbit' "$FLOWCRAFT_TC_LOG"
printf 'STAGE=complete\n' >"$FC_STAGE_FILE"
(
  fc_fit_measure() { printf '490 0 485\n'; }
  fc_fit_command --peer peer.test --nominal 500 --apply >/dev/null
)
check_true 'no-knee fit result is persisted' grep -q '^STATUS=no-knee$' "$FC_FIT_RESULT"
check_true 'applying no-knee result removes aggregate shaping' grep -q '^TOTAL_MBPS=0$' "$FLOWCRAFT_CONFIG_FILE"

fc_parse_install_options --non-interactive --total 2300 --role relay --kernel skip
check_eq 'CLI precedence is independent of option order' 2300 "$TOTAL_MBPS"
fc_parse_install_options --non-interactive --role landing --origin-rtt 220 --total 900 --kernel skip
check_eq 'landing defaults apply before explicit total' 900 "$TOTAL_MBPS"
check_eq 'landing role default RTT' 5 "$RTT_MS"

printf 'STAGE=pending-reboot\nEXPECTED_KERNEL=7.1.0-flowcraft-bbrv3\n' >"$FC_STAGE_FILE"
check_false 'ordinary apply is blocked while reboot is pending' fc_apply_all
before_lines="$(wc -l <"$FLOWCRAFT_SYSCTL_LOG")"
fc_service_apply >/dev/null 2>&1
after_lines="$(wc -l <"$FLOWCRAFT_SYSCTL_LOG")"
check_eq 'boot service skips an unverified kernel stage' "$before_lines" "$after_lines"

printf '\n%s passed, %s failed\n' "$passed" "$failed"
((failed == 0))

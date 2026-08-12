#!/usr/bin/env bash

FC_PROGRAM="flowcraft"
FC_REPOSITORY="${FLOWCRAFT_REPOSITORY:-zachary9757/flowcraft}"
FC_ETC_DIR="${FLOWCRAFT_ETC_DIR:-/etc/flowcraft}"
FC_STATE_DIR="${FLOWCRAFT_STATE_DIR:-/var/lib/flowcraft}"
FC_SYSCTL_FILE="${FLOWCRAFT_SYSCTL_FILE:-/etc/sysctl.d/99-flowcraft.conf}"
FC_SERVICE_FILE="${FLOWCRAFT_SERVICE_FILE:-/etc/systemd/system/flowcraft.service}"
FC_INSTALL_FILE="${FLOWCRAFT_INSTALL_FILE:-/usr/local/sbin/flowcraft}"
FC_COMMAND_FILE="${FLOWCRAFT_COMMAND_FILE:-/usr/local/bin/flowcraft}"
FC_INSTALL_LIB_DIR="${FLOWCRAFT_INSTALL_LIB_DIR:-/usr/local/lib/flowcraft}"
FC_CONFIG_FILE="${FLOWCRAFT_CONFIG_FILE:-$FC_ETC_DIR/config.conf}"
FC_LOCK_FILE="$FC_STATE_DIR/lock"
FC_STAGE_FILE="$FC_STATE_DIR/install-stage"
FC_SYSCTL_SNAPSHOT="$FC_STATE_DIR/sysctl.snapshot"
FC_QDISC_SNAPSHOT="$FC_STATE_DIR/qdisc.snapshot"
FC_GAI_BACKUP="$FC_STATE_DIR/gai.conf.before-flowcraft"
FC_GAI_ABSENT="$FC_STATE_DIR/gai.conf.was-absent"
FC_RPS_SNAPSHOT="$FC_STATE_DIR/rps.snapshot"
FC_ROUTE_SNAPSHOT="$FC_STATE_DIR/default-route.snapshot"
FC_BENCHMARK_FILE="${FLOWCRAFT_BENCHMARK_FILE:-$FC_STATE_DIR/benchmark-result}"
FC_DRY_RUN="${FLOWCRAFT_DRY_RUN:-0}"
FC_LOCKED=0

FC_RED='\033[0;31m'
FC_GREEN='\033[0;32m'
FC_YELLOW='\033[1;33m'
FC_BLUE='\033[0;34m'
FC_DIM='\033[2m'
FC_BOLD='\033[1m'
FC_RESET='\033[0m'
if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then
  FC_RED='' FC_GREEN='' FC_YELLOW='' FC_BLUE='' FC_DIM='' FC_BOLD='' FC_RESET=''
fi

fc_log() { printf '%b[OK]%b %s\n' "$FC_GREEN" "$FC_RESET" "$*"; }
fc_info() { printf '%b[INFO]%b %s\n' "$FC_BLUE" "$FC_RESET" "$*"; }
fc_warn() { printf '%b[WARN]%b %s\n' "$FC_YELLOW" "$FC_RESET" "$*" >&2; }
fc_die() {
  printf '%b[ERROR]%b %s\n' "$FC_RED" "$FC_RESET" "$*" >&2
  exit 1
}
fc_has() { command -v "$1" >/dev/null 2>&1; }
fc_is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }
fc_is_linux() { [[ "$(uname -s 2>/dev/null)" == Linux ]]; }

fc_need_root() {
  [[ "${FLOWCRAFT_ALLOW_NON_ROOT_TESTS:-0}" == 1 ]] && return 0
  ((${EUID:-$(id -u)} == 0)) || fc_die "此操作需要 root 权限，请使用 sudo。"
}

fc_take_lock() {
  ((FC_LOCKED == 1)) && return 0
  fc_has flock || return 0
  mkdir -p "$FC_STATE_DIR"
  exec 9>"$FC_LOCK_FILE"
  flock -w 10 9 || fc_die "另一个 Flowcraft 进程正在修改配置。"
  FC_LOCKED=1
}

fc_run() {
  if ((FC_DRY_RUN == 1)); then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

fc_atomic_replace() {
  local source="$1" target="$2" mode="${3:-0644}"
  if ((FC_DRY_RUN == 1)); then
    printf '[dry-run] install -m %q %q %q\n' "$mode" "$source" "$target"
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  chmod "$mode" "$source"
  mv -f "$source" "$target"
}

fc_default_config() {
  ROLE="general"
  KERNEL_CHANNEL="standard"
  IFACE="auto"
  RTT_MS=160
  ORIGIN_RTT_MS=150
  PER_FLOW_MBPS=430
  TOTAL_MBPS=0
  BURST_MODE="policer"
  IPV4_PRIORITY="off"
  RPS_MODE="off"
  INITCWND=32
  SHAPER_MODE="auto"
  EXPERIMENTAL="off"
  TUNING_PROFILE="normal"
}

fc_validate_config_value() {
  local key="$1" value="$2"
  case "$key" in
    ROLE) [[ "$value" =~ ^(general|relay|landing)$ ]] ;;
    KERNEL_CHANNEL) [[ "$value" =~ ^(standard|skip|max)$ ]] ;;
    IFACE) [[ "$value" == auto || "$value" =~ ^[a-zA-Z0-9_.:-]+$ ]] ;;
    RTT_MS | ORIGIN_RTT_MS) fc_is_uint "$value" && ((value >= 1 && value <= 3000)) ;;
    PER_FLOW_MBPS) fc_is_uint "$value" && ((value >= 10 && value <= 100000)) ;;
    TOTAL_MBPS) fc_is_uint "$value" && ((value == 0 || (value >= 10 && value <= 100000))) ;;
    BURST_MODE) [[ "$value" =~ ^(policer|throughput)$ ]] ;;
    IPV4_PRIORITY | EXPERIMENTAL) [[ "$value" =~ ^(on|off)$ ]] ;;
    RPS_MODE) [[ "$value" =~ ^(auto|off)$ ]] ;;
    INITCWND) fc_is_uint "$value" && ((value == 0 || (value >= 2 && value <= 64))) ;;
    SHAPER_MODE) [[ "$value" =~ ^(auto|fq|fq_codel|fq_pie|cake|htb|tbf)$ ]] ;;
    TUNING_PROFILE) [[ "$value" =~ ^(normal|extreme)$ ]] ;;
    *) return 1 ;;
  esac
}

fc_load_config() {
  fc_default_config
  [[ -r "$FC_CONFIG_FILE" ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    [[ -n "$key" && "$key" != \#* ]] || continue
    if fc_validate_config_value "$key" "$value"; then
      printf -v "$key" '%s' "$value"
    else
      fc_warn "忽略无效配置：${key}=${value}"
    fi
  done <"$FC_CONFIG_FILE"
}

fc_save_config() {
  local temp
  if ((FC_DRY_RUN == 1)); then
    fc_info "dry-run：不会写入 $FC_CONFIG_FILE"
    return 0
  fi
  mkdir -p "$FC_ETC_DIR"
  temp="$(mktemp "${FC_CONFIG_FILE}.XXXXXX")"
  {
    printf '# Flowcraft %s configuration; values are parsed, never sourced.\n' "$FLOWCRAFT_VERSION"
    printf 'ROLE=%s\n' "$ROLE"
    printf 'KERNEL_CHANNEL=%s\n' "$KERNEL_CHANNEL"
    printf 'IFACE=%s\n' "$IFACE"
    printf 'RTT_MS=%s\n' "$RTT_MS"
    printf 'ORIGIN_RTT_MS=%s\n' "$ORIGIN_RTT_MS"
    printf 'PER_FLOW_MBPS=%s\n' "$PER_FLOW_MBPS"
    printf 'TOTAL_MBPS=%s\n' "$TOTAL_MBPS"
    printf 'BURST_MODE=%s\n' "$BURST_MODE"
    printf 'IPV4_PRIORITY=%s\n' "$IPV4_PRIORITY"
    printf 'RPS_MODE=%s\n' "$RPS_MODE"
    printf 'INITCWND=%s\n' "$INITCWND"
    printf 'SHAPER_MODE=%s\n' "$SHAPER_MODE"
    printf 'EXPERIMENTAL=%s\n' "$EXPERIMENTAL"
    printf 'TUNING_PROFILE=%s\n' "$TUNING_PROFILE"
  } >"$temp"
  fc_atomic_replace "$temp" "$FC_CONFIG_FILE" 0600
}

fc_mem_mb() {
  awk '/^MemTotal:/ {printf "%d\n", $2 / 1024; found=1} END {if (!found) print 0}' /proc/meminfo 2>/dev/null || printf '0\n'
}

fc_cpu_count() {
  if fc_has nproc; then
    nproc
  elif [[ -r /proc/cpuinfo ]]; then
    awk '/^processor/ {n++} END {print n+0}' /proc/cpuinfo
  else
    printf '0\n'
  fi
}

fc_detect_iface() {
  local iface=''
  if fc_has ip; then
    iface="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
    [[ -n "$iface" ]] || iface="$(ip -o -6 route show to default 2>/dev/null | awk '{print $5; exit}')"
  fi
  printf '%s\n' "$iface"
}

fc_resolve_iface() {
  local iface="$IFACE"
  [[ "$iface" == auto ]] && iface="$(fc_detect_iface)"
  [[ -n "$iface" ]] || fc_die "无法识别默认出口网卡，请使用 --iface 指定。"
  printf '%s\n' "$iface"
}

fc_os_release_value() {
  local wanted="$1" key value
  [[ -r /etc/os-release ]] || return 0
  while IFS='=' read -r key value; do
    [[ "$key" == "$wanted" ]] || continue
    value="${value%\"}"
    value="${value#\"}"
    printf '%s\n' "$value"
    return 0
  done </etc/os-release
}

fc_cpu_mask() {
  local count="${1:-0}" groups group bits value result=''
  fc_is_uint "$count" && ((count > 0)) || return 1
  groups=$(((count + 31) / 32))
  for ((group = groups - 1; group >= 0; group--)); do
    bits=$((count - group * 32))
    ((bits > 32)) && bits=32
    if ((bits == 32)); then value=4294967295; else value=$(((1 << bits) - 1)); fi
    if [[ -n "$result" ]]; then
      result+=",$(printf '%08x' "$value")"
    else
      result+="$(printf '%x' "$value")"
    fi
  done
  printf '%s\n' "$result"
}

fc_find_conflicts() {
  local path root="${FLOWCRAFT_ROOT_PREFIX:-}"
  local candidates=(
    "$root/etc/sysctl.d/99-joeyblog.conf"
    "$root/etc/sysctl.d/10-bbr.conf"
    "$root/etc/sysctl.d/99-network-performance.conf"
    "$root/etc/sysctl.d/99-zz-netshape-manager.conf"
    "$root/etc/systemd/system/netshape-manager.service"
    "$root/etc/systemd/system/netshape.service"
    "$root/etc/systemd/system/tc-fq-maxrate.service"
    "$root/etc/systemd/system/netpace.service"
  )
  for path in "${candidates[@]}"; do [[ -e "$path" ]] && printf '%s\n' "$path"; done
  if [[ -d "$root/etc/sysctl.d" ]]; then
    while IFS= read -r path; do
      [[ "$path" == "$FC_SYSCTL_FILE" ]] && continue
      grep -Eq '^[[:space:]]*(net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control|net\.core\.[rw]mem_max|net\.ipv4\.tcp_[rw]mem)[[:space:]]*=' "$path" 2>/dev/null &&
        printf '%s\n' "$path"
    done < <(find "$root/etc/sysctl.d" -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null | sort)
  fi
}

fc_assert_no_conflicts() {
  local conflicts
  conflicts="$(fc_find_conflicts | sort -u)"
  [[ -z "$conflicts" ]] && return 0
  printf '%b发现会覆盖 Flowcraft 配置的现有文件：%b\n%s\n' "$FC_YELLOW" "$FC_RESET" "$conflicts" >&2
  fc_die "请先卸载旧网络调优工具或人工处理上述冲突。"
}

fc_version_ge() {
  local current="$1" required="$2"
  [[ "$(printf '%s\n' "$required" "$current" | sort -V | head -n 1)" == "$required" ]]
}

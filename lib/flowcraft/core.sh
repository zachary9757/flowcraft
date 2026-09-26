#!/usr/bin/env bash
# shellcheck disable=SC2034

FLOWCRAFT_VERSION=0.1.0
FC_PROGRAM=flowcraft
FC_ETC_DIR="${FLOWCRAFT_ETC_DIR:-/etc/flowcraft}"
FC_STATE_DIR="${FLOWCRAFT_STATE_DIR:-/var/lib/flowcraft}"
FC_CONFIG_FILE="${FLOWCRAFT_CONFIG_FILE:-$FC_ETC_DIR/config.conf}"
FC_SYSCTL_FILE="${FLOWCRAFT_SYSCTL_FILE:-/etc/sysctl.d/90-flowcraft.conf}"
FC_SERVICE_FILE="${FLOWCRAFT_SERVICE_FILE:-/etc/systemd/system/flowcraft.service}"
FC_INSTALL_BIN="${FLOWCRAFT_INSTALL_BIN:-/usr/local/sbin/flowcraft}"
FC_INSTALL_LIB="${FLOWCRAFT_INSTALL_LIB:-/usr/local/lib/flowcraft}"
FC_LOCK_FILE="${FLOWCRAFT_LOCK_FILE:-/run/lock/flowcraft.lock}"
FC_SYSCTL_SNAPSHOT="$FC_STATE_DIR/sysctl.snapshot"
FC_QDISC_SNAPSHOT="$FC_STATE_DIR/qdisc.snapshot"
FC_FIT_RESULT="$FC_STATE_DIR/fit-result"
FC_MANAGED_STATE="$FC_STATE_DIR/managed.state"
FC_DRY_RUN="${FLOWCRAFT_DRY_RUN:-0}"
FC_LOCKED=0

fc_log() { printf '[OK] %s\n' "$*"; }
fc_info() { printf '[INFO] %s\n' "$*"; }
fc_warn() { printf '[WARN] %s\n' "$*" >&2; }
fc_die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
fc_has() { command -v "$1" >/dev/null 2>&1; }
fc_is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

fc_need_root() {
  [[ ${FLOWCRAFT_ALLOW_NON_ROOT_TESTS:-0} == 1 ]] && return 0
  (( ${EUID:-$(id -u)} == 0 )) || fc_die '此操作需要 root 权限。'
}

fc_take_lock() {
  (( FC_LOCKED == 1 )) && return 0
  fc_has flock || fc_die '缺少 flock；请安装 util-linux。'
  mkdir -p "$(dirname "$FC_LOCK_FILE")"
  exec 9>"$FC_LOCK_FILE"
  flock -w 10 9 || fc_die '另一个 FlowCraft 进程正在修改网络状态。'
  FC_LOCKED=1
}

fc_atomic_replace() {
  local source="$1" target="$2" mode="${3:-0644}"
  if (( FC_DRY_RUN == 1 )); then
    printf '[dry-run] install -m %q %q %q\n' "$mode" "$source" "$target"
    rm -f "$source"
    return 0
  fi
  mkdir -p "$(dirname "$target")" || return 1
  chmod "$mode" "$source" || return 1
  mv -f "$source" "$target"
}

fc_run() {
  if (( FC_DRY_RUN == 1 )); then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

fc_normalize_ws() {
  tr -s '[:space:]' ' ' <<<"${1:-}" | sed 's/^ //; s/ $//'
}

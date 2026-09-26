#!/usr/bin/env bash
# shellcheck disable=SC2034

fc_menu_colors() {
  FC_MENU_RESET=''
  FC_MENU_BOLD=''
  FC_MENU_GREEN=''
  FC_MENU_RED=''
  FC_MENU_CYAN=''
  if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    FC_MENU_RESET=$'\033[0m'
    FC_MENU_BOLD=$'\033[1m'
    FC_MENU_GREEN=$'\033[32m'
    FC_MENU_RED=$'\033[31m'
    FC_MENU_CYAN=$'\033[36m'
  fi
}

fc_menu_managed_status() {
  local sysctl_owned=0 qdisc_owned=0
  [[ -e "$FC_SYSCTL_FILE" || -L "$FC_SYSCTL_FILE" ]] && sysctl_owned=1
  [[ -e "$FC_MANAGED_STATE" || -L "$FC_MANAGED_STATE" ]] && qdisc_owned=1
  if (( sysctl_owned == 1 && qdisc_owned == 1 )); then printf 'yes\n'
  elif (( sysctl_owned == 1 || qdisc_owned == 1 )); then printf 'partial\n'
  else printf 'no\n'; fi
}

fc_menu_iface_speed() {
  local iface="$1" speed_file speed
  [[ -n "$iface" ]] || { printf 'unknown\n'; return 0; }
  speed_file="${FLOWCRAFT_SYS_CLASS_NET:-/sys/class/net}/$iface/speed"
  speed="$(cat "$speed_file" 2>/dev/null || true)"
  if fc_is_uint "$speed" && (( speed > 0 )); then printf '%s Mbps\n' "$speed"
  else printf 'unknown\n'; fi
}

fc_menu_dashboard() {
  local iface cc qdisc bbr
  iface="$(fc_detect_iface)"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)"
  qdisc=unknown
  [[ -z "$iface" ]] || qdisc="$(fc_root_qdisc "$iface" || printf unknown)"
  if [[ "$cc" == bbr ]]; then bbr='active'; else bbr='inactive'; fi
  printf '%sFlowCraft %s%s\n' "$FC_MENU_BOLD" "$FLOWCRAFT_VERSION" "$FC_MENU_RESET"
  printf '  BBR: %-8s  qdisc: %-10s  Managed: %s\n' "$bbr" "${qdisc:-none}" "$(fc_menu_managed_status)"
  printf '  Interface: %-10s  Link: %s\n\n' "${iface:-unknown}" "$(fc_menu_iface_speed "$iface")"
}

fc_menu_restore_config() {
  local backup="$1" had_config="$2"
  if (( had_config == 1 )); then fc_atomic_replace "$backup" "$FC_CONFIG_FILE" 0600
  else rm -f "$backup" "$FC_CONFIG_FILE"; fi
}

fc_menu_read_total_rate() {
  local current="$1" value
  printf '总出口带宽 Mbps（0=不限速，回车沿用 %s）：' "$current" >&2
  IFS= read -r value || return 1
  [[ -n "$value" ]] || value="$current"
  fc_config_valid TOTAL_MBPS "$value" || {
    fc_warn '带宽必须为 0，或 10-100000 之间的整数。'
    return 1
  }
  printf '%s\n' "$value"
}

fc_menu_apply_profile() {
  local role="$1" label="$2" backup had_config=0 answer total
  fc_need_root
  fc_config_load || return 1
  [[ ! -L "$FC_CONFIG_FILE" ]] || {
    fc_warn '菜单拒绝改写符号链接配置文件。'
    return 1
  }
  fc_take_lock
  mkdir -p "$FC_ETC_DIR" || return 1
  backup="$(mktemp "$FC_ETC_DIR/.menu-config.XXXXXX")" || return 1
  if [[ -e "$FC_CONFIG_FILE" ]]; then
    if ! cp "$FC_CONFIG_FILE" "$backup" || ! chmod 0600 "$backup"; then
      rm -f "$backup"
      return 1
    fi
    had_config=1
  fi

  ROLE="$role"
  QDISC_MODE=auto
  if [[ "$role" == general ]]; then TOTAL_MBPS=0
  else
    if ! total="$(fc_menu_read_total_rate "$TOTAL_MBPS")"; then
      fc_menu_restore_config "$backup" "$had_config"
      return 1
    fi
    TOTAL_MBPS="$total"
  fi

  if ! fc_config_write; then
    fc_menu_restore_config "$backup" "$had_config"
    return 1
  fi
  printf '\n%s预设：%s%s\n' "$FC_MENU_CYAN" "$label" "$FC_MENU_RESET"
  if ! (fc_main plan); then
    fc_menu_restore_config "$backup" "$had_config"
    return 1
  fi
  printf '\n执行上述计划并调用 flowcraft apply？[y/N] '
  IFS= read -r answer || answer=''
  case "$answer" in y|Y|yes|YES) ;; *)
    fc_menu_restore_config "$backup" "$had_config"
    fc_info '已取消，原配置未改变。'
    return 0
  esac

  if (fc_main apply); then
    rm -f "$backup"
    printf '%s[OK] %s 已应用并验证通过。%s\n' "$FC_MENU_GREEN" "$label" "$FC_MENU_RESET"
    return 0
  fi
  if fc_menu_restore_config "$backup" "$had_config"; then
    printf '%s[ERROR] 应用失败；网络回滚由 apply 事务处理，原配置已恢复。%s\n' "$FC_MENU_RED" "$FC_MENU_RESET" >&2
  else
    printf '%s[ERROR] 应用失败，且原配置恢复失败；请立即检查 %s。%s\n' \
      "$FC_MENU_RED" "$FC_CONFIG_FILE" "$FC_MENU_RESET" >&2
  fi
  return 1
}

fc_menu_rollback() {
  local answer
  printf '确认调用 flowcraft rollback 恢复首次接管前状态？[y/N] '
  IFS= read -r answer || answer=''
  case "$answer" in y|Y|yes|YES) (fc_main rollback) ;;
    *) fc_info '已取消回滚。' ;;
  esac
}

fc_menu_uninstall() {
  local answer
  printf '确认完全卸载 FlowCraft？托管状态会先要求安全回滚。[y/N] '
  IFS= read -r answer || answer=''
  case "$answer" in
    y|Y|yes|YES) (fc_main uninstall) ;;
    *) fc_info '已取消卸载。'; return 1 ;;
  esac
}

fc_menu() {
  local choice
  fc_menu_colors
  while true; do
    printf '\n'
    fc_menu_dashboard
    printf '%s[1]%s 通用调优（General / BBR + FQ + 动态缓冲）\n' "$FC_MENU_CYAN" "$FC_MENU_RESET"
    printf '%s[2]%s 中继优化（Relay / 吞吐缓冲 + 可选总限速）\n' "$FC_MENU_CYAN" "$FC_MENU_RESET"
    printf '%s[3]%s 落地机优化（Landing / 保守缓冲 + 可选总限速）\n' "$FC_MENU_CYAN" "$FC_MENU_RESET"
    printf '%s[4]%s 查看执行计划（Plan / Dry-Run）\n' "$FC_MENU_CYAN" "$FC_MENU_RESET"
    printf '%s[5]%s 实时连接与丢包监控（Monitor）\n' "$FC_MENU_CYAN" "$FC_MENU_RESET"
    printf '%s[6]%s 回滚到首次接管前状态（Rollback）\n' "$FC_MENU_CYAN" "$FC_MENU_RESET"
    printf '%s[7]%s 安全回滚并完全卸载（Uninstall）\n' "$FC_MENU_CYAN" "$FC_MENU_RESET"
    printf '%s[0]%s 退出\n\n' "$FC_MENU_CYAN" "$FC_MENU_RESET"
    printf '请选择 [0-7]：'
    IFS= read -r choice || return 0
    case "$choice" in
      1) (fc_menu_apply_profile general 'General') || true ;;
      2) (fc_menu_apply_profile relay 'Relay') || true ;;
      3) (fc_menu_apply_profile landing 'Landing') || true ;;
      4) (fc_main plan) || true ;;
      5) (fc_main mon --watch 2) || true ;;
      6) fc_menu_rollback || true ;;
      7) if fc_menu_uninstall; then return 0; fi ;;
      0) return 0 ;;
      *) fc_warn '无效选项，请输入 0-7。' ;;
    esac
  done
}

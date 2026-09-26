#!/usr/bin/env bash
# shellcheck disable=SC2153

fc_plan() {
  fc_config_load
  local iface temp
  iface="$IFACE"
  [[ "$iface" == auto ]] && iface="$(fc_detect_iface)"
  temp="$(mktemp /tmp/flowcraft-plan.XXXXXX)"
  fc_sysctl_render "$temp"
  printf 'FlowCraft plan\n'
  printf '  role/interface: %s / %s\n' "$ROLE" "${iface:-unknown}"
  printf '  RTT/per-flow/total: %sms / %sMbps / %sMbps\n' "$RTT_MS" "$PER_FLOW_MBPS" "$TOTAL_MBPS"
  printf '  qdisc mode: %s -> %s\n\n' "$QDISC_MODE" "$(fc_tc_desired_kind)"
  printf 'sysctl:\n'
  sed 's/^/  /' "$temp"
  printf '\ntc:\n'
  if [[ -n "$iface" ]]; then fc_tc_plan "$iface" | sed 's/^/  /'; else printf '  unavailable: no default interface\n'; fi
  rm -f "$temp"
}

fc_apply_abort() {
  local tc_changed="${1:-0}" failed=0
  fc_sysctl_transaction_restore || failed=1
  if (( tc_changed == 1 )); then
    fc_tc_abort || failed=1
  elif (( FC_TC_TXN_WAS_MANAGED == 0 && failed == 0 )); then
    rm -f "$FC_QDISC_SNAPSHOT"
  fi
  if (( failed == 0 )); then
    fc_sysctl_transaction_cleanup
    fc_tc_transaction_cleanup
  fi
  (( failed == 0 ))
}

fc_apply() {
  fc_need_root
  fc_take_lock
  fc_config_load
  [[ "$(uname -s)" == Linux ]] || fc_die 'apply 只支持 Linux。'
  if ! fc_has ip || ! fc_has tc || ! fc_has sysctl || ! fc_has cksum; then
    fc_die '缺少 iproute2、procps 或 cksum。'
  fi
  fc_assert_supported_route
  fc_assert_no_conflicts
  local iface
  iface="$(fc_resolve_iface)"
  fc_assert_qdisc_takeover_safe "$iface"
  fc_tc_transaction_begin "$iface" || fc_die '无法建立 qdisc 事务基线。'
  fc_sysctl_snapshot
  fc_tc_snapshot "$iface"
  fc_sysctl_transaction_begin || fc_die '无法建立 sysctl 事务基线。'
  if ! fc_sysctl_apply; then
    fc_apply_abort 0 || fc_die 'sysctl 应用失败且回滚不完整；快照已保留。'
    fc_die 'sysctl 应用失败，已执行回滚。'
  fi
  if ! fc_tc_apply_iface "$iface"; then
    fc_warn 'qdisc 应用失败，开始回滚本次变更。'
    fc_apply_abort 1 || fc_die '应用失败且回滚不完整；快照已保留。'
    fc_die '应用失败，已执行回滚。'
  fi
  if ! fc_sysctl_verify; then
    fc_apply_abort 1 || fc_die 'sysctl 验证失败且回滚不完整；快照已保留。'
    fc_die 'sysctl 运行态验证失败，已回滚。'
  fi
  if ! fc_tc_verify "$iface"; then
    fc_apply_abort 1 || fc_die 'qdisc 验证失败且回滚不完整；快照已保留。'
    fc_die 'qdisc 运行态验证失败，已回滚。'
  fi
  if ! fc_managed_state_write "$iface"; then
    fc_apply_abort 1 || fc_die '状态写入失败且回滚不完整；快照已保留。'
    fc_die '托管状态写入失败，已回滚。'
  fi
  fc_sysctl_transaction_cleanup
  fc_tc_transaction_cleanup
  if [[ -f "$FC_SERVICE_FILE" ]] && fc_has systemctl; then
    systemctl enable flowcraft.service >/dev/null 2>&1 || fc_warn '无法启用 flowcraft.service。'
  fi
  fc_log '配置已应用并通过运行态验证。'
}

fc_status() {
  fc_config_load
  local iface
  iface="$(fc_detect_iface)"
  printf 'FlowCraft status\n'
  printf '  version:    %s\n' "$FLOWCRAFT_VERSION"
  printf '  role:       %s\n' "$ROLE"
  printf '  kernel:     %s\n' "$(uname -r)"
  printf '  interface:  %s\n' "${iface:-unknown}"
  printf '  congestion: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)"
  printf '  root qdisc: %s\n' "$([[ -n "$iface" ]] && fc_root_qdisc "$iface" || printf unknown)"
  if [[ -r "$FC_SYSCTL_FILE" ]] && fc_sysctl_verify; then printf '  sysctl:     managed, verified\n'
  elif [[ -r "$FC_SYSCTL_FILE" ]]; then printf '  sysctl:     managed, drifted\n'
  else printf '  sysctl:     not managed\n'; fi
}

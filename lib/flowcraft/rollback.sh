#!/usr/bin/env bash

fc_rollback_validate() {
  local sysctl_file_exists=0 sysctl_snapshot_exists=0 managed_state_exists=0 qdisc_snapshot_exists=0
  [[ -e "$FC_SYSCTL_FILE" || -L "$FC_SYSCTL_FILE" ]] && sysctl_file_exists=1
  [[ -e "$FC_SYSCTL_SNAPSHOT" || -L "$FC_SYSCTL_SNAPSHOT" ]] && sysctl_snapshot_exists=1
  [[ -e "$FC_MANAGED_STATE" || -L "$FC_MANAGED_STATE" ]] && managed_state_exists=1
  [[ -e "$FC_QDISC_SNAPSHOT" || -L "$FC_QDISC_SNAPSHOT" ]] && qdisc_snapshot_exists=1
  if (( sysctl_file_exists == 1 && sysctl_snapshot_exists == 0 )); then
    fc_warn 'sysctl 已托管但快照缺失；拒绝删除持久配置。'
    return 1
  fi
  if (( managed_state_exists == 1 && qdisc_snapshot_exists == 0 )); then
    fc_warn 'qdisc 已托管但快照缺失；拒绝执行不完整回滚。'
    return 1
  fi
  if (( sysctl_file_exists == 1 || sysctl_snapshot_exists == 1 )); then
    fc_sysctl_snapshot_validate || return 1
  fi
  if (( managed_state_exists == 1 )); then
    fc_managed_state_load || return 1
    fc_tc_snapshot_validate "$FC_MANAGED_IFACE" || return 1
  elif (( qdisc_snapshot_exists == 1 )); then
    fc_tc_snapshot_validate || return 1
  fi
}

fc_rollback_internal() {
  local failed=0 sysctl_owned=0
  fc_rollback_validate || return 1
  if [[ -e "$FC_SYSCTL_FILE" || -e "$FC_SYSCTL_SNAPSHOT" ]]; then
    sysctl_owned=1
    if ! rm -f "$FC_SYSCTL_FILE"; then
      fc_warn '无法删除 FlowCraft sysctl 配置；拒绝继续回滚。'
      return 1
    fi
    if fc_has sysctl; then sysctl --system >/dev/null 2>&1 || failed=1; fi
    fc_sysctl_restore || failed=1
  fi
  fc_tc_restore || failed=1
  if (( failed == 0 )); then
    rm -f "$FC_MANAGED_STATE" "$FC_QDISC_SNAPSHOT" || failed=1
    if (( sysctl_owned == 1 )); then rm -f "$FC_SYSCTL_SNAPSHOT" || failed=1; fi
  fi
  return "$failed"
}

fc_rollback() {
  fc_need_root
  fc_take_lock
  fc_rollback_validate || fc_die '回滚前校验失败；未修改服务或网络状态。'
  if fc_has systemctl; then systemctl disable --now flowcraft.service >/dev/null 2>&1 || true; fi
  fc_rollback_internal || fc_die '回滚不完整；快照已保留，请检查警告后重试。'
  fc_log '已恢复首次接管前的 sysctl 和已验证 qdisc 快照。'
}

#!/usr/bin/env bash

fc_rollback_validate() {
  if [[ -e "$FC_SYSCTL_FILE" && ! -r "$FC_SYSCTL_SNAPSHOT" ]]; then
    fc_warn 'sysctl 已托管但快照缺失；拒绝删除持久配置。'
    return 1
  fi
  if [[ -e "$FC_MANAGED_STATE" && ! -r "$FC_QDISC_SNAPSHOT" ]]; then
    fc_warn 'qdisc 已托管但快照缺失；拒绝执行不完整回滚。'
    return 1
  fi
  if [[ -e "$FC_SYSCTL_FILE" || -e "$FC_SYSCTL_SNAPSHOT" ]]; then
    fc_sysctl_snapshot_validate || return 1
  fi
  if [[ -e "$FC_MANAGED_STATE" ]]; then
    fc_managed_state_load || return 1
    fc_tc_snapshot_validate "$FC_MANAGED_IFACE" || return 1
  elif [[ -e "$FC_QDISC_SNAPSHOT" ]]; then
    fc_tc_snapshot_validate || return 1
  fi
}

fc_rollback_internal() {
  local failed=0 sysctl_owned=0
  fc_rollback_validate || return 1
  if [[ -e "$FC_SYSCTL_FILE" || -e "$FC_SYSCTL_SNAPSHOT" ]]; then
    sysctl_owned=1
    rm -f "$FC_SYSCTL_FILE"
    if fc_has sysctl; then sysctl --system >/dev/null 2>&1 || failed=1; fi
    fc_sysctl_restore || failed=1
  fi
  fc_tc_restore || failed=1
  if (( failed == 0 )); then
    rm -f "$FC_MANAGED_STATE" "$FC_QDISC_SNAPSHOT"
    (( sysctl_owned == 0 )) || rm -f "$FC_SYSCTL_SNAPSHOT"
  fi
  return "$failed"
}

fc_rollback() {
  fc_need_root
  fc_take_lock
  fc_rollback_validate || fc_die '回滚前校验失败；未修改服务或网络状态。'
  if fc_has systemctl; then systemctl disable --now flowcraft.service >/dev/null 2>&1 || true; fi
  fc_rollback_internal || fc_die '回滚不完整；快照已保留，请检查警告后重试。'
  fc_log '已恢复首次接管前的 sysctl 和简单 qdisc 快照。'
}

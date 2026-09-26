#!/usr/bin/env bash

FC_TC_TXN_WAS_MANAGED=0
FC_TC_TXN_IFACE=''
FC_TC_TXN_ROLE=''
FC_TC_TXN_PER_FLOW_MBPS=''
FC_TC_TXN_TOTAL_MBPS=''
FC_TC_TXN_QDISC_MODE=''

fc_tc_desired_kind() {
  case "$QDISC_MODE" in
    cake) printf 'cake\n' ;;
    htb) printf 'htb\n' ;;
    fq) printf 'fq\n' ;;
    auto) if (( TOTAL_MBPS > 0 )); then printf 'htb\n'; else printf 'fq\n'; fi ;;
  esac
}

fc_tc_plan() {
  local iface="$1" kind
  kind="$(fc_tc_desired_kind)"
  case "$kind" in
    cake) printf 'tc qdisc replace dev %q root cake bandwidth %smbit besteffort\n' "$iface" "$TOTAL_MBPS" ;;
    htb)
      printf 'tc qdisc replace dev %q root handle 1: htb default 10\n' "$iface"
      printf 'tc class replace dev %q parent 1: classid 1:10 htb rate %smbit ceil %smbit\n' "$iface" "$TOTAL_MBPS" "$TOTAL_MBPS"
      if [[ "$ROLE" == relay ]]; then
        printf 'tc qdisc replace dev %q parent 1:10 handle 10: fq maxrate %smbit\n' "$iface" "$PER_FLOW_MBPS"
      else
        printf 'tc qdisc replace dev %q parent 1:10 handle 10: fq\n' "$iface"
      fi
      ;;
    fq)
      if [[ "$ROLE" == relay ]]; then
        printf 'tc qdisc replace dev %q root fq maxrate %smbit\n' "$iface" "$PER_FLOW_MBPS"
      else
        printf 'tc qdisc replace dev %q root fq\n' "$iface"
      fi
      ;;
  esac
}

fc_tc_snapshot() {
  local iface="$1" kind temp
  if [[ -e "$FC_QDISC_SNAPSHOT" ]]; then
    fc_tc_snapshot_validate "$iface" || fc_die 'qdisc 快照无效，拒绝修改运行态。'
    return 0
  fi
  kind="$(fc_root_qdisc "$iface")"
  mkdir -p "$FC_STATE_DIR"
  temp="$(mktemp "$FC_STATE_DIR/.qdisc-snapshot.XXXXXX")"
  {
    printf 'IFACE=%s\n' "$iface"
    printf 'KIND=%s\n' "${kind:-none}"
  } >"$temp"
  fc_atomic_replace "$temp" "$FC_QDISC_SNAPSHOT" 0600
  fc_tc_snapshot_validate "$iface"
}

fc_tc_snapshot_validate() {
  local expected_iface="${1:-}" iface='' kind='' key value
  local iface_seen=0 kind_seen=0 invalid=0
  [[ -f "$FC_QDISC_SNAPSHOT" && -r "$FC_QDISC_SNAPSHOT" ]] || {
    fc_warn 'qdisc 快照不可读或不是普通文件。'
    return 1
  }
  while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
    case "$key" in
      IFACE)
        (( iface_seen == 0 )) || invalid=1
        iface="$value"
        iface_seen=1
        ;;
      KIND)
        (( kind_seen == 0 )) || invalid=1
        kind="$value"
        kind_seen=1
        ;;
      *) invalid=1 ;;
    esac
  done <"$FC_QDISC_SNAPSHOT"
  if (( invalid == 1 || iface_seen == 0 || kind_seen == 0 )) || [[ -z "$iface" ]]; then
    fc_warn 'qdisc 快照不完整或格式无效。'
    return 1
  fi
  [[ -z "$expected_iface" || "$iface" == "$expected_iface" ]] || {
    fc_warn "qdisc 快照属于 $iface，不能用于 $expected_iface。"
    return 1
  }
  case "$kind" in
    none|noqueue) return 0 ;;
    *) fc_warn "快照包含不可恢复的 qdisc：$kind"; return 1 ;;
  esac
}

fc_tc_restore() {
  local iface kind actual
  if [[ ! -e "$FC_QDISC_SNAPSHOT" ]]; then
    [[ -e "$FC_MANAGED_STATE" ]] && { fc_warn 'qdisc 已托管但快照缺失。'; return 1; }
    fc_warn '没有 qdisc 快照。'
    return 0
  fi
  fc_tc_snapshot_validate || return 1
  iface="$(awk -F= '$1 == "IFACE" {print $2}' "$FC_QDISC_SNAPSHOT")"
  kind="$(awk -F= '$1 == "KIND" {print $2}' "$FC_QDISC_SNAPSHOT")"
  tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
  actual="$(fc_root_qdisc "$iface")" || { fc_warn '无法读取 qdisc 恢复结果。'; return 1; }
  case "${actual:-none}" in none|noqueue) return 0 ;; esac
  fc_warn "qdisc 未恢复：期望 ${kind}，实际 ${actual}"
  return 1
}

fc_tc_abort() {
  local current_role="$ROLE" current_per_flow="$PER_FLOW_MBPS"
  local current_total="$TOTAL_MBPS" current_mode="$QDISC_MODE"
  if (( FC_TC_TXN_WAS_MANAGED == 1 )); then
    ROLE="$FC_TC_TXN_ROLE"
    PER_FLOW_MBPS="$FC_TC_TXN_PER_FLOW_MBPS"
    TOTAL_MBPS="$FC_TC_TXN_TOTAL_MBPS"
    QDISC_MODE="$FC_TC_TXN_QDISC_MODE"
    if fc_tc_apply_iface "$FC_TC_TXN_IFACE" && fc_tc_verify "$FC_TC_TXN_IFACE"; then
      ROLE="$current_role"
      PER_FLOW_MBPS="$current_per_flow"
      TOTAL_MBPS="$current_total"
      QDISC_MODE="$current_mode"
      return 0
    fi
    ROLE="$current_role"
    PER_FLOW_MBPS="$current_per_flow"
    TOTAL_MBPS="$current_total"
    QDISC_MODE="$current_mode"
    return 1
  fi
  if fc_tc_restore; then
    rm -f "$FC_QDISC_SNAPSHOT" "$FC_MANAGED_STATE"
    return 0
  fi
  return 1
}

fc_tc_apply_iface() {
  local iface="$1" kind
  kind="$(fc_tc_desired_kind)"
  tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
  case "$kind" in
    cake)
      (( TOTAL_MBPS > 0 )) || { fc_warn 'CAKE 需要 TOTAL_MBPS。'; return 1; }
      tc qdisc add dev "$iface" root cake bandwidth "${TOTAL_MBPS}mbit" besteffort
      ;;
    htb)
      tc qdisc add dev "$iface" root handle 1: htb default 10 || return 1
      tc class add dev "$iface" parent 1: classid 1:10 htb rate "${TOTAL_MBPS}mbit" ceil "${TOTAL_MBPS}mbit" || return 1
      if [[ "$ROLE" == relay ]]; then
        tc qdisc add dev "$iface" parent 1:10 handle 10: fq maxrate "${PER_FLOW_MBPS}mbit"
      else
        tc qdisc add dev "$iface" parent 1:10 handle 10: fq
      fi
      ;;
    fq)
      if [[ "$ROLE" == relay ]]; then tc qdisc add dev "$iface" root fq maxrate "${PER_FLOW_MBPS}mbit"
      else tc qdisc add dev "$iface" root fq
      fi
      ;;
  esac
}

fc_tc_apply() {
  fc_need_root
  fc_take_lock
  fc_config_load
  fc_assert_supported_route
  local iface
  iface="$(fc_resolve_iface)"
  fc_assert_qdisc_takeover_safe "$iface"
  fc_tc_transaction_begin "$iface" || fc_die '无法建立 qdisc 事务基线。'
  fc_tc_snapshot "$iface"
  if ! fc_tc_apply_iface "$iface"; then
    fc_tc_abort || fc_die 'qdisc 应用失败且恢复不完整；快照已保留。'
    fc_die 'qdisc 应用失败，已恢复快照。'
  fi
  if ! fc_tc_verify "$iface"; then
    fc_tc_abort || fc_die 'qdisc 验证失败且恢复不完整；快照已保留。'
    fc_die 'qdisc 应用后验证失败，已恢复快照。'
  fi
  if ! fc_managed_state_write "$iface"; then
    fc_tc_abort || fc_die '托管状态写入失败且恢复不完整；快照已保留。'
    fc_die '托管状态写入失败，已恢复 qdisc 快照。'
  fi
  fc_tc_transaction_cleanup
  fc_log "已应用 $iface 的 $(fc_tc_desired_kind) 队列。"
}

fc_managed_state_write() {
  local iface="$1" temp
  mkdir -p "$FC_STATE_DIR"
  temp="$(mktemp "$FC_STATE_DIR/.managed.XXXXXX")"
  {
    printf 'IFACE=%s\n' "$iface"
    printf 'QDISC=%s\n' "$(fc_tc_desired_kind)"
    printf 'ROLE=%s\n' "$ROLE"
    printf 'PER_FLOW_MBPS=%s\n' "$PER_FLOW_MBPS"
    printf 'TOTAL_MBPS=%s\n' "$TOTAL_MBPS"
    printf 'QDISC_MODE=%s\n' "$QDISC_MODE"
  } >"$temp"
  fc_atomic_replace "$temp" "$FC_MANAGED_STATE" 0600
}

fc_managed_state_load() {
  local key value expected
  local iface='' qdisc='' role='' per_flow='' total='' mode=''
  local seen='|' invalid=0
  [[ -f "$FC_MANAGED_STATE" && -r "$FC_MANAGED_STATE" ]] || {
    fc_warn '托管状态不可读或不是普通文件。'
    return 1
  }
  while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
    [[ "$seen" != *"|$key|"* ]] || invalid=1
    seen+="$key|"
    case "$key" in
      IFACE) iface="$value" ;;
      QDISC) qdisc="$value" ;;
      ROLE) role="$value" ;;
      PER_FLOW_MBPS) per_flow="$value" ;;
      TOTAL_MBPS) total="$value" ;;
      QDISC_MODE) mode="$value" ;;
      *) invalid=1 ;;
    esac
  done <"$FC_MANAGED_STATE"
  if (( invalid == 1 )) || ! fc_config_valid IFACE "$iface" || [[ "$iface" == auto ]] ||
    ! fc_config_valid ROLE "$role" || ! fc_config_valid PER_FLOW_MBPS "$per_flow" ||
    ! fc_config_valid TOTAL_MBPS "$total" || ! fc_config_valid QDISC_MODE "$mode"; then
    fc_warn '托管状态格式或取值无效。'
    return 1
  fi
  case "$mode" in
    cake) expected=cake ;;
    htb) expected=htb ;;
    fq) expected=fq ;;
    auto) if (( total > 0 )); then expected=htb; else expected=fq; fi ;;
  esac
  if { [[ "$mode" =~ ^(cake|htb)$ ]] && (( total == 0 )); } ||
    { [[ "$mode" == fq ]] && (( total > 0 )); }; then
    fc_warn '托管状态中的 qdisc 模式与总带宽不一致。'
    return 1
  fi
  [[ "$qdisc" == "$expected" ]] || {
    fc_warn '托管状态中的 qdisc 与配置字段不一致。'
    return 1
  }
  FC_MANAGED_IFACE="$iface"
  FC_MANAGED_QDISC="$qdisc"
  FC_MANAGED_ROLE="$role"
  FC_MANAGED_PER_FLOW_MBPS="$per_flow"
  FC_MANAGED_TOTAL_MBPS="$total"
  FC_MANAGED_QDISC_MODE="$mode"
}

fc_tc_transaction_begin() {
  local iface="$1" actual current_role="$ROLE" current_per_flow="$PER_FLOW_MBPS"
  local current_total="$TOTAL_MBPS" current_mode="$QDISC_MODE"
  FC_TC_TXN_WAS_MANAGED=0
  if [[ -e "$FC_MANAGED_STATE" ]]; then
    fc_managed_state_load || return 1
    actual="$(fc_root_qdisc "$iface")"
    [[ "$FC_MANAGED_IFACE" == "$iface" && "$FC_MANAGED_QDISC" == "$actual" ]] || {
      fc_warn '当前 qdisc 与托管状态不一致，拒绝开始事务。'
      return 1
    }
    ROLE="$FC_MANAGED_ROLE"
    PER_FLOW_MBPS="$FC_MANAGED_PER_FLOW_MBPS"
    TOTAL_MBPS="$FC_MANAGED_TOTAL_MBPS"
    QDISC_MODE="$FC_MANAGED_QDISC_MODE"
    if ! fc_tc_verify "$iface"; then
      ROLE="$current_role"
      PER_FLOW_MBPS="$current_per_flow"
      TOTAL_MBPS="$current_total"
      QDISC_MODE="$current_mode"
      fc_warn '当前 qdisc 参数已偏离托管状态，拒绝开始事务。'
      return 1
    fi
    ROLE="$current_role"
    PER_FLOW_MBPS="$current_per_flow"
    TOTAL_MBPS="$current_total"
    QDISC_MODE="$current_mode"
    FC_TC_TXN_IFACE="$FC_MANAGED_IFACE"
    FC_TC_TXN_ROLE="$FC_MANAGED_ROLE"
    FC_TC_TXN_PER_FLOW_MBPS="$FC_MANAGED_PER_FLOW_MBPS"
    FC_TC_TXN_TOTAL_MBPS="$FC_MANAGED_TOTAL_MBPS"
    FC_TC_TXN_QDISC_MODE="$FC_MANAGED_QDISC_MODE"
    FC_TC_TXN_WAS_MANAGED=1
  fi
}

fc_tc_transaction_cleanup() {
  FC_TC_TXN_WAS_MANAGED=0
  FC_TC_TXN_IFACE=''
  FC_TC_TXN_ROLE=''
  FC_TC_TXN_PER_FLOW_MBPS=''
  FC_TC_TXN_TOTAL_MBPS=''
  FC_TC_TXN_QDISC_MODE=''
}

fc_tc_rate_matches() {
  local output="$1" label="$2" mbps="$3"
  grep -Eq "${label}[[:space:]]+${mbps}Mbit([[:space:]]|$)" <<<"$output" && return 0
  (( mbps % 1000 == 0 )) && grep -Eq "${label}[[:space:]]+$((mbps / 1000))Gbit([[:space:]]|$)" <<<"$output"
}

fc_tc_verify() {
  local iface="$1" expected actual qdiscs classes root_line leaf_line class_line
  expected="$(fc_tc_desired_kind)"
  actual="$(fc_root_qdisc "$iface")"
  [[ "$actual" == "$expected" ]] || return 1
  qdiscs="$(tc qdisc show dev "$iface" 2>/dev/null)" || return 1
  case "$expected" in
    cake)
      root_line="$(awk '$1 == "qdisc" && $2 == "cake" && $0 ~ / root / {print; exit}' <<<"$qdiscs")"
      [[ -n "$root_line" ]] && fc_tc_rate_matches "$root_line" bandwidth "$TOTAL_MBPS"
      ;;
    htb)
      root_line="$(awk '$1 == "qdisc" && $2 == "htb" && $0 ~ / root / {print; exit}' <<<"$qdiscs")"
      leaf_line="$(awk '$1 == "qdisc" && $2 == "fq" && $0 ~ / parent 1:10 / {print; exit}' <<<"$qdiscs")"
      classes="$(tc class show dev "$iface" 2>/dev/null)" || return 1
      class_line="$(awk '$1 == "class" && $2 == "htb" && $3 == "1:10" {print; exit}' <<<"$classes")"
      [[ -n "$root_line" ]] || return 1
      [[ "$root_line" == *'default 0x10'* || "$root_line" == *'default 10'* ]] || return 1
      [[ -n "$class_line" ]] || return 1
      fc_tc_rate_matches "$class_line" rate "$TOTAL_MBPS" || return 1
      fc_tc_rate_matches "$class_line" ceil "$TOTAL_MBPS" || return 1
      [[ -n "$leaf_line" ]] || return 1
      if [[ "$ROLE" == relay ]]; then fc_tc_rate_matches "$leaf_line" maxrate "$PER_FLOW_MBPS"
      else [[ "$leaf_line" != *' maxrate '* ]]; fi
      ;;
    fq)
      root_line="$(awk '$1 == "qdisc" && $2 == "fq" && $0 ~ / root / {print; exit}' <<<"$qdiscs")"
      [[ -n "$root_line" ]] || return 1
      if [[ "$ROLE" == relay ]]; then fc_tc_rate_matches "$root_line" maxrate "$PER_FLOW_MBPS"
      else [[ "$root_line" != *' maxrate '* ]]; fi
      ;;
  esac
}

fc_tc_status() {
  fc_config_load
  local iface
  iface="$(fc_detect_iface)"
  [[ -n "$iface" ]] || fc_die '没有默认出口接口。'
  tc -s qdisc show dev "$iface"
  tc -s class show dev "$iface" 2>/dev/null || true
}

fc_tc_off() {
  fc_need_root
  fc_take_lock
  fc_config_load
  local iface
  iface="$(fc_resolve_iface)"
  fc_assert_qdisc_takeover_safe "$iface"
  fc_tc_transaction_begin "$iface" || fc_die '无法建立 qdisc 事务基线。'
  fc_tc_snapshot "$iface"
  if ! tc qdisc replace dev "$iface" root fq; then
    fc_tc_abort || fc_die 'qdisc 关闭失败且恢复不完整；快照已保留。'
    fc_die 'qdisc 关闭失败，已恢复事务前状态。'
  fi
  QDISC_MODE=fq
  TOTAL_MBPS=0
  ROLE=general
  if ! fc_tc_verify "$iface"; then
    fc_tc_abort || fc_die 'qdisc 关闭后验证失败且恢复不完整；快照已保留。'
    fc_die 'qdisc 关闭后验证失败，已恢复事务前状态。'
  fi
  if ! fc_managed_state_write "$iface"; then
    fc_tc_abort || fc_die '托管状态写入失败且恢复不完整；快照已保留。'
    fc_die '托管状态写入失败，已恢复 qdisc 快照。'
  fi
  fc_tc_transaction_cleanup
  fc_log "已临时移除人为整形，$iface 保留 fq；下次 apply 或重启会按配置恢复。"
}

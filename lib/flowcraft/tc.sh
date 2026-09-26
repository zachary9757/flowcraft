#!/usr/bin/env bash

FC_TC_TXN_WAS_MANAGED=0
FC_TC_TXN_IFACE=''
FC_TC_TXN_ROLE=''
FC_TC_TXN_PER_FLOW_MBPS=''
FC_TC_TXN_TOTAL_MBPS=''
FC_TC_TXN_QDISC_MODE=''
FC_PFIFO_FAST_BANDS=3
FC_PFIFO_FAST_PRIOMAP='1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1'

fc_pfifo_fast_fingerprint() {
  local iface="$1" output line bands priomap priority index=4
  local -a fields priorities
  output="$(tc -d qdisc show dev "$iface" 2>/dev/null)" || return 1
  line="$(awk '$1 == "qdisc" && $2 == "pfifo_fast" && $0 ~ / root / {print; exit}' <<<"$output")"
  [[ -n "$line" ]] || return 1
  read -r -a fields <<<"$line"
  (( ${#fields[@]} >= 23 )) || return 1
  [[ "${fields[0]}" == qdisc && "${fields[1]}" == pfifo_fast &&
    "${fields[2]}" =~ ^[[:xdigit:]]+:$ && "${fields[3]}" == root ]] || return 1
  if [[ "${fields[$index]}" == refcnt ]]; then
    fc_is_uint "${fields[$((index + 1))]:-}" || return 1
    index=$((index + 2))
  fi
  [[ "${fields[$index]:-}" == bands ]] || return 1
  bands="${fields[$((index + 1))]:-}"
  index=$((index + 2))
  [[ "${fields[$index]:-}" == priomap ]] || return 1
  index=$((index + 1))
  (( ${#fields[@]} == index + 16 )) || return 1
  priorities=("${fields[@]:$index:16}")
  priomap="${priorities[*]}"
  fc_is_uint "$bands" || return 1
  for priority in "${priorities[@]}"; do
    fc_is_uint "$priority" || return 1
    (( priority < bands )) || return 1
  done
  printf '%s|%s\n' "$bands" "$priomap"
}

fc_pfifo_fast_is_standard() {
  [[ "$(fc_pfifo_fast_fingerprint "$1")" == "$FC_PFIFO_FAST_BANDS|$FC_PFIFO_FAST_PRIOMAP" ]]
}

fc_fq_line_fingerprint() {
  local line="$1" index=4 token
  local -a fields options
  read -r -a fields <<<"$line"
  (( ${#fields[@]} > 4 )) || return 1
  [[ "${fields[0]}" == qdisc && "${fields[1]}" == fq &&
    "${fields[2]}" =~ ^[[:xdigit:]]+:$ ]] || return 1
  case "${fields[3]}" in
    root) ;;
    parent)
      [[ "${fields[4]:-}" =~ ^[[:xdigit:]]*:[[:xdigit:]]+$ ]] || return 1
      index=5
      ;;
    *) return 1 ;;
  esac
  if [[ "${fields[$index]:-}" == refcnt ]]; then
    fc_is_uint "${fields[$((index + 1))]:-}" || return 1
    index=$((index + 2))
  fi
  (( ${#fields[@]} > index )) || return 1
  options=("${fields[@]:$index}")
  for token in "${options[@]}"; do
    [[ "$token" =~ ^[[:alnum:]_.:/-]+$ ]] || return 1
  done
  printf '%s\n' "${options[*]}"
}

fc_fq_fingerprint() {
  local iface="$1" wanted="${2:-root}" output line
  output="$(tc -d qdisc show dev "$iface" 2>/dev/null)" || return 1
  case "$wanted" in
    root) line="$(awk '$1 == "qdisc" && $2 == "fq" && $0 ~ / root / {print; exit}' <<<"$output")" ;;
    *) line="$(awk -v parent="$wanted" '$1 == "qdisc" && $2 == "fq" && $4 == "parent" && $5 == parent {print; exit}' <<<"$output")" ;;
  esac
  [[ -n "$line" ]] || return 1
  fc_fq_line_fingerprint "$line"
}

fc_fq_default_fingerprint() {
  local iface="$1" probe="fcq${BASHPID:-$$}" mtu fingerprint='' created=0
  [[ ${#probe} -le 15 ]] || probe="fcq$$"
  [[ ! -e "/sys/class/net/$probe" ]] || return 1
  mtu="$(cat "/sys/class/net/$iface/mtu" 2>/dev/null)" || return 1
  fc_is_uint "$mtu" || return 1
  if ip link add "$probe" type dummy >/dev/null 2>&1; then
    created=1
  else
    return 1
  fi
  if ! ip link set dev "$probe" mtu "$mtu" >/dev/null 2>&1 ||
    ! tc qdisc replace dev "$probe" root fq >/dev/null 2>&1 ||
    ! fingerprint="$(fc_fq_fingerprint "$probe")"; then
    (( created == 0 )) || ip link del "$probe" >/dev/null 2>&1 || true
    return 1
  fi
  ip link del "$probe" >/dev/null 2>&1 || return 1
  printf '%s\n' "$fingerprint"
}

fc_fq_is_standard() {
  local iface="$1" actual expected qdisc_count
  actual="$(fc_fq_fingerprint "$iface")" || return 1
  expected="$(fc_fq_default_fingerprint "$iface")" || return 1
  qdisc_count="$(tc qdisc show dev "$iface" 2>/dev/null |
    awk '$1 == "qdisc" {count++} END {print count+0}')" || return 1
  [[ "$qdisc_count" == 1 && "$actual" == "$expected" ]]
}

fc_mq_fingerprint() {
  local iface="$1" output line raw_parent parent fingerprint='' current root_count=0 leaf_count=0
  local parents=''
  output="$(tc -d qdisc show dev "$iface" 2>/dev/null)" || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "$line" in
      'qdisc mq '*root*)
        root_count=$((root_count + 1))
        [[ "$line" =~ ^qdisc[[:space:]]+mq[[:space:]]+[[:xdigit:]]+:[[:space:]]+root([[:space:]]+refcnt[[:space:]]+[0-9]+)?[[:space:]]*$ ]] || return 1
        ;;
      'qdisc fq '*parent*)
        raw_parent="$(awk '{for (i=1; i<=NF; i++) if ($i == "parent") {print $(i+1); exit}}' <<<"$line")"
        [[ "$raw_parent" =~ ^[[:xdigit:]]*:[[:xdigit:]]+$ ]] || return 1
        parent=":${raw_parent##*:}"
        [[ " $parents " != *" $parent "* ]] || return 1
        current="$(fc_fq_line_fingerprint "$line")" || return 1
        if [[ -z "$fingerprint" ]]; then fingerprint="$current"
        elif [[ "$current" != "$fingerprint" ]]; then return 1
        fi
        parents+="${parents:+ }$parent"
        leaf_count=$((leaf_count + 1))
        ;;
      qdisc*) return 1 ;;
    esac
  done <<<"$output"
  (( root_count == 1 && leaf_count > 0 )) || return 1
  printf '%s|%s\n' "$parents" "$fingerprint"
}

fc_mq_is_standard() {
  local iface="$1" fingerprint parents expected
  fingerprint="$(fc_mq_fingerprint "$iface")" || return 1
  parents="${fingerprint%%|*}"
  fc_mq_parents_available "$iface" "$parents" || return 1
  expected="$(fc_fq_default_fingerprint "$iface")" || return 1
  [[ "${fingerprint#*|}" == "$expected" ]]
}

fc_mq_leaf_parents() {
  local iface="$1" output line raw_parent parent parents='' normalized=''
  output="$(tc qdisc show dev "$iface" 2>/dev/null)" || return 1
  while IFS= read -r line; do
    [[ "$line" == qdisc* && "$line" == *' parent '* ]] || continue
    raw_parent="$(awk '{for (i=1; i<=NF; i++) if ($i == "parent") {print $(i+1); exit}}' <<<"$line")"
    [[ "$raw_parent" =~ ^[[:xdigit:]]*:[[:xdigit:]]+$ ]] || return 1
    parent=":${raw_parent##*:}"
    [[ " $normalized " != *" $parent "* ]] || return 1
    parents+="${parents:+ }$raw_parent"
    normalized+="${normalized:+ }$parent"
  done <<<"$output"
  fc_mq_parents_available "$iface" "$normalized" || return 1
  printf '%s\n' "$parents"
}

fc_mq_parents_available() {
  local iface="$1" parents="$2" queue count=0 parent minor index
  for queue in "/sys/class/net/$iface/queues"/tx-*; do
    [[ -e "$queue" ]] && count=$((count + 1))
  done
  (( count > 0 )) || return 1
  for parent in $parents; do
    minor="${parent##*:}"
    [[ "$parent" =~ ^:[[:xdigit:]]+$ ]] || return 1
    (( 16#$minor >= 1 && 16#$minor <= count )) || return 1
  done
  for ((index = 1; index <= count; index++)); do
    printf -v parent ':%x' "$index"
    [[ " $parents " == *" $parent "* ]] || return 1
  done
}

fc_mq_parent_sets_equal() {
  local expected="$1" actual="$2" parent expected_count=0 actual_count=0
  for parent in $expected; do
    expected_count=$((expected_count + 1))
    [[ " $actual " == *" $parent "* ]] || return 1
  done
  for parent in $actual; do actual_count=$((actual_count + 1)); done
  (( expected_count == actual_count ))
}

fc_tc_snapshot_value() {
  local key="$1"
  awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$FC_QDISC_SNAPSHOT"
}

fc_tc_origin_kind() {
  [[ -f "$FC_QDISC_SNAPSHOT" ]] || return 1
  fc_tc_snapshot_value KIND
}

fc_tc_uses_mq_topology() {
  [[ "$(fc_tc_desired_kind)" == fq && "$(fc_tc_origin_kind 2>/dev/null || true)" == mq ]]
}

fc_tc_desired_kind() {
  case "$QDISC_MODE" in
    cake) printf 'cake\n' ;;
    htb) printf 'htb\n' ;;
    fq) printf 'fq\n' ;;
    auto) if (( TOTAL_MBPS > 0 )); then printf 'htb\n'; else printf 'fq\n'; fi ;;
  esac
}

fc_tc_plan() {
  local iface="$1" kind root parents parent
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
      root="$(fc_root_qdisc "$iface" 2>/dev/null || true)"
      if [[ "$root" == mq ]]; then
        parents="$(fc_mq_leaf_parents "$iface" 2>/dev/null || true)"
        for parent in $parents; do
          if [[ "$ROLE" == relay ]]; then
            printf 'tc qdisc replace dev %q parent %q fq maxrate %smbit\n' "$iface" "$parent" "$PER_FLOW_MBPS"
          else
            printf 'tc qdisc replace dev %q parent %q fq\n' "$iface" "$parent"
          fi
        done
      elif [[ "$ROLE" == relay ]]; then
        printf 'tc qdisc replace dev %q root fq maxrate %smbit\n' "$iface" "$PER_FLOW_MBPS"
      else
        printf 'tc qdisc replace dev %q root fq\n' "$iface"
      fi
      ;;
  esac
}

fc_tc_snapshot() {
  local iface="$1" kind temp fingerprint='' bands='' priomap='' parents=''
  if [[ -e "$FC_QDISC_SNAPSHOT" || -L "$FC_QDISC_SNAPSHOT" ]]; then
    fc_tc_snapshot_validate "$iface" || fc_die 'qdisc 快照无效，拒绝修改运行态。'
    return 0
  fi
  kind="$(fc_root_qdisc "$iface")" || return 1
  if [[ "$kind" == pfifo_fast ]]; then
    fingerprint="$(fc_pfifo_fast_fingerprint "$iface")" || return 1
    [[ "$fingerprint" == "$FC_PFIFO_FAST_BANDS|$FC_PFIFO_FAST_PRIOMAP" ]] || return 1
    bands="${fingerprint%%|*}"
    priomap="${fingerprint#*|}"
  elif [[ "$kind" == fq ]]; then
    fingerprint="$(fc_fq_fingerprint "$iface")" || return 1
    [[ "$fingerprint" == "$(fc_fq_default_fingerprint "$iface")" ]] || return 1
  elif [[ "$kind" == mq ]]; then
    fingerprint="$(fc_mq_fingerprint "$iface")" || return 1
    parents="${fingerprint%%|*}"
    fingerprint="${fingerprint#*|}"
    fc_mq_parents_available "$iface" "$parents" || return 1
    [[ "$fingerprint" == "$(fc_fq_default_fingerprint "$iface")" ]] || return 1
  fi
  mkdir -p "$FC_STATE_DIR"
  temp="$(mktemp "$FC_STATE_DIR/.qdisc-snapshot.XXXXXX")"
  {
    printf 'IFACE=%s\n' "$iface"
    printf 'KIND=%s\n' "${kind:-none}"
    if [[ "$kind" == pfifo_fast ]]; then
      printf 'BANDS=%s\n' "$bands"
      printf 'PRIOMAP=%s\n' "$priomap"
    elif [[ "$kind" == fq ]]; then
      printf 'FQ_FINGERPRINT=%s\n' "$fingerprint"
    elif [[ "$kind" == mq ]]; then
      printf 'MQ_PARENTS=%s\n' "$parents"
      printf 'FQ_FINGERPRINT=%s\n' "$fingerprint"
    fi
  } >"$temp"
  fc_atomic_replace "$temp" "$FC_QDISC_SNAPSHOT" 0600
  fc_tc_snapshot_validate "$iface"
}

fc_tc_snapshot_validate() {
  local expected_iface="${1:-}" iface='' kind='' bands='' priomap='' fq_fingerprint='' mq_parents='' key value parent
  local iface_seen=0 kind_seen=0 bands_seen=0 priomap_seen=0 fingerprint_seen=0 parents_seen=0 invalid=0
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
      BANDS)
        (( bands_seen == 0 )) || invalid=1
        bands="$value"
        bands_seen=1
        ;;
      PRIOMAP)
        (( priomap_seen == 0 )) || invalid=1
        priomap="$value"
        priomap_seen=1
        ;;
      FQ_FINGERPRINT)
        (( fingerprint_seen == 0 )) || invalid=1
        fq_fingerprint="$value"
        fingerprint_seen=1
        ;;
      MQ_PARENTS)
        (( parents_seen == 0 )) || invalid=1
        mq_parents="$value"
        parents_seen=1
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
    none|noqueue)
      (( bands_seen == 0 && priomap_seen == 0 && fingerprint_seen == 0 && parents_seen == 0 )) || {
        fc_warn '简单 qdisc 快照包含多余参数。'
        return 1
      }
      return 0
      ;;
    pfifo_fast)
      if (( bands_seen != 1 || priomap_seen != 1 || fingerprint_seen != 0 || parents_seen != 0 )) ||
        [[ "$bands" != "$FC_PFIFO_FAST_BANDS" || "$priomap" != "$FC_PFIFO_FAST_PRIOMAP" ]]; then
        fc_warn 'pfifo_fast 快照缺少标准且可重放的参数指纹。'
        return 1
      fi
      return 0
      ;;
    fq)
      if (( fingerprint_seen != 1 || bands_seen != 0 || priomap_seen != 0 || parents_seen != 0 )) ||
        [[ -z "$fq_fingerprint" || "$fq_fingerprint" == *$'\n'* ||
          ! "$fq_fingerprint" =~ ^[[:alnum:]_.:/\ -]+$ ]]; then
        fc_warn 'fq 快照缺少安全且可验证的默认参数指纹。'
        return 1
      fi
      return 0
      ;;
    mq)
      if (( fingerprint_seen != 1 || parents_seen != 1 || bands_seen != 0 || priomap_seen != 0 )) ||
        [[ -z "$fq_fingerprint" || ! "$fq_fingerprint" =~ ^[[:alnum:]_.:/\ -]+$ || -z "$mq_parents" ]]; then
        fc_warn 'mq 快照缺少父队列或默认 fq 指纹。'
        return 1
      fi
      local seen_parents=' '
      for parent in $mq_parents; do
        [[ "$parent" =~ ^[[:xdigit:]]*:[[:xdigit:]]+$ && "$seen_parents" != *" $parent "* ]] || {
          fc_warn 'mq 快照包含无效或重复父队列。'
          return 1
        }
        seen_parents+="$parent "
      done
      return 0
      ;;
    *) fc_warn "快照包含不可恢复的 qdisc：$kind"; return 1 ;;
  esac
}

fc_tc_restore() {
  local iface kind actual bands priomap fingerprint expected parents leaf_parents
  if [[ ! -e "$FC_QDISC_SNAPSHOT" ]]; then
    [[ -e "$FC_MANAGED_STATE" ]] && { fc_warn 'qdisc 已托管但快照缺失。'; return 1; }
    fc_warn '没有 qdisc 快照。'
    return 0
  fi
  fc_tc_snapshot_validate || return 1
  iface="$(awk -F= '$1 == "IFACE" {print $2}' "$FC_QDISC_SNAPSHOT")"
  kind="$(awk -F= '$1 == "KIND" {print $2}' "$FC_QDISC_SNAPSHOT")"
  case "$kind" in
    none|noqueue)
      tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
      actual="$(fc_root_qdisc "$iface")" || { fc_warn '无法读取 qdisc 恢复结果。'; return 1; }
      case "${actual:-none}" in none|noqueue) return 0 ;; esac
      ;;
    pfifo_fast)
      bands="$(awk -F= '$1 == "BANDS" {print $2}' "$FC_QDISC_SNAPSHOT")"
      priomap="$(awk -F= '$1 == "PRIOMAP" {sub(/^[^=]*=/, ""); print}' "$FC_QDISC_SNAPSHOT")"
      tc qdisc replace dev "$iface" root pfifo_fast || {
        fc_warn '无法重建 pfifo_fast qdisc。'
        return 1
      }
      fingerprint="$(fc_pfifo_fast_fingerprint "$iface")" || {
        fc_warn '无法读取 pfifo_fast 恢复结果。'
        return 1
      }
      [[ "$fingerprint" == "$bands|$priomap" ]] && return 0
      actual="${fingerprint:-unknown}"
      ;;
    fq)
      expected="$(fc_tc_snapshot_value FQ_FINGERPRINT)"
      [[ "$expected" == "$(fc_fq_default_fingerprint "$iface")" ]] || {
        fc_warn '当前内核无法按快照重建默认 fq；拒绝修改 qdisc。'
        return 1
      }
      tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
      tc qdisc replace dev "$iface" root fq || {
        fc_warn '无法重建默认 fq qdisc。'
        return 1
      }
      fingerprint="$(fc_fq_fingerprint "$iface")" || {
        fc_warn '无法读取 fq 恢复结果。'
        return 1
      }
      [[ "$fingerprint" == "$expected" ]] && return 0
      actual="${fingerprint:-unknown}"
      ;;
    mq)
      parents="$(fc_tc_snapshot_value MQ_PARENTS)"
      expected="$parents|$(fc_tc_snapshot_value FQ_FINGERPRINT)"
      fc_mq_parents_available "$iface" "$parents" || {
        fc_warn '当前网卡 TX queue 无法覆盖 mq 快照中的父队列。'
        return 1
      }
      [[ "${expected#*|}" == "$(fc_fq_default_fingerprint "$iface")" ]] || {
        fc_warn '当前内核无法按快照重建 mq 的默认 fq 叶子；拒绝修改 qdisc。'
        return 1
      }
      tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
      tc qdisc replace dev "$iface" root mq || {
        fc_warn '无法重建 mq root qdisc。'
        return 1
      }
      leaf_parents="$(fc_mq_leaf_parents "$iface")" || {
        fc_warn '无法读取重建后的 mq 叶子。'
        return 1
      }
      for parent in $leaf_parents; do
        tc qdisc replace dev "$iface" parent "$parent" fq || {
          fc_warn '无法重建 mq 的默认 fq 叶子。'
          return 1
        }
      done
      fingerprint="$(fc_mq_fingerprint "$iface")" || {
        fc_warn '无法读取 mq 恢复结果。'
        return 1
      }
      if fc_mq_parent_sets_equal "$parents" "${fingerprint%%|*}" &&
        [[ "${fingerprint#*|}" == "${expected#*|}" ]]; then
        return 0
      fi
      actual="${fingerprint:-unknown}"
      ;;
  esac
  fc_warn "qdisc 未恢复：期望 ${kind}，实际 ${actual:-unknown}"
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
    return
  fi
  return 1
}

fc_tc_apply_iface() {
  local iface="$1" kind parents parent
  kind="$(fc_tc_desired_kind)"
  if [[ "$kind" == fq ]] && fc_tc_uses_mq_topology; then
    parents="$(fc_tc_snapshot_value MQ_PARENTS)"
    fc_mq_parents_available "$iface" "$parents" || return 1
    tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
    tc qdisc replace dev "$iface" root mq || return 1
    parents="$(fc_mq_leaf_parents "$iface")" || return 1
    for parent in $parents; do
      if [[ "$ROLE" == relay ]]; then
        tc qdisc replace dev "$iface" parent "$parent" fq maxrate "${PER_FLOW_MBPS}mbit" || return 1
      else
        tc qdisc replace dev "$iface" parent "$parent" fq || return 1
      fi
    done
    return 0
  fi
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
  local iface="$1" temp actual
  actual="$(fc_root_qdisc "$iface")" || return 1
  mkdir -p "$FC_STATE_DIR"
  temp="$(mktemp "$FC_STATE_DIR/.managed.XXXXXX")"
  {
    printf 'IFACE=%s\n' "$iface"
    printf 'QDISC=%s\n' "$actual"
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
  if [[ "$qdisc" == mq && "$expected" == fq ]]; then
    [[ "$(fc_tc_origin_kind 2>/dev/null || true)" == mq ]] || {
      fc_warn '托管状态声明 mq，但首次接管快照不匹配。'
      return 1
    }
  elif [[ "$qdisc" != "$expected" ]]; then
    fc_warn '托管状态中的 qdisc 与配置字段不一致。'
    return 1
  fi
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
  if [[ -e "$FC_MANAGED_STATE" || -L "$FC_MANAGED_STATE" ]]; then
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
  local iface="$1" expected actual qdiscs classes root_line leaf_line class_line parents parent line seen='' root_count=0
  expected="$(fc_tc_desired_kind)"
  actual="$(fc_root_qdisc "$iface")"
  if [[ "$expected" == fq ]] && fc_tc_uses_mq_topology; then
    [[ "$actual" == mq ]] || return 1
  else
    [[ "$actual" == "$expected" ]] || return 1
  fi
  qdiscs="$(tc qdisc show dev "$iface" 2>/dev/null)" || return 1
  case "$expected" in
    cake)
      root_line="$(awk '$1 == "qdisc" && $2 == "cake" && $0 ~ / root / {print; exit}' <<<"$qdiscs")"
      [[ -n "$root_line" && "$root_line" == *' besteffort'* ]] &&
        fc_tc_rate_matches "$root_line" bandwidth "$TOTAL_MBPS"
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
      if fc_tc_uses_mq_topology; then
        parents="$(fc_tc_snapshot_value MQ_PARENTS)"
        while IFS= read -r line; do
          [[ -n "$line" ]] || continue
          if [[ "$line" =~ ^qdisc[[:space:]]+mq[[:space:]]+[^[:space:]]+[[:space:]]+root([[:space:]]|$) ]]; then
            root_count=$((root_count + 1))
          elif [[ "$line" =~ ^qdisc[[:space:]]+fq[[:space:]]+[^[:space:]]+[[:space:]]+parent[[:space:]]+([^[:space:]]+) ]]; then
            leaf_line="$line"
            parent=":${BASH_REMATCH[1]##*:}"
            [[ " $parents " == *" $parent "* && " $seen " != *" $parent "* ]] || return 1
            if [[ "$ROLE" == relay ]]; then fc_tc_rate_matches "$leaf_line" maxrate "$PER_FLOW_MBPS" || return 1
            elif [[ "$leaf_line" == *' maxrate '* ]]; then return 1
            fi
            seen+="${seen:+ }$parent"
          else
            return 1
          fi
        done <<<"$qdiscs"
        fc_mq_parent_sets_equal "$parents" "$seen" || return 1
        (( root_count == 1 )) || return 1
        return 0
      fi
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
  QDISC_MODE=fq
  TOTAL_MBPS=0
  ROLE=general
  if ! fc_tc_apply_iface "$iface"; then
    fc_tc_abort || fc_die 'qdisc 关闭失败且恢复不完整；快照已保留。'
    fc_die 'qdisc 关闭失败，已恢复事务前状态。'
  fi
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

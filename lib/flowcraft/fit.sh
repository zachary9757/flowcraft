#!/usr/bin/env bash

# Policer measurement adapted from MIT-licensed Kylin010/tcpfit. Flowcraft remains the only
# persistent sysctl, qdisc, service, configuration, and rollback owner.

FC_FIT_PEER_POOL="${FC_FIT_PEER_POOL:-
speedtest.hkg12.hk.leaseweb.net|香港|Leaseweb
speedtest.sin1.sg.leaseweb.net|新加坡|Leaseweb
sgp.proof.ovh.net|新加坡|OVH
speedtest.syd12.au.leaseweb.net|悉尼|Leaseweb
speedtest.tyo11.jp.leaseweb.net|东京|Leaseweb
speedtest.fra1.de.leaseweb.net|法兰克福|Leaseweb
speedtest.ams2.nl.leaseweb.net|阿姆斯特丹|Leaseweb
ams.speedtest.clouvider.net|阿姆斯特丹|Clouvider
speedtest.lon12.uk.leaseweb.net|伦敦|Leaseweb
lon.speedtest.clouvider.net|伦敦|Clouvider
speedtest.lax12.us.leaseweb.net|洛杉矶|Leaseweb
speedtest.sfo12.us.leaseweb.net|旧金山|Leaseweb
speedtest.sea11.us.leaseweb.net|西雅图|Leaseweb
speedtest.dal13.us.leaseweb.net|达拉斯|Leaseweb
speedtest.chi11.us.leaseweb.net|芝加哥|Leaseweb
speedtest.nyc1.us.leaseweb.net|纽约|Leaseweb
speedtest.mia11.us.leaseweb.net|迈阿密|Leaseweb
speedtest.mtl2.ca.leaseweb.net|蒙特利尔|Leaseweb
}"
FC_FIT_PORT_POOL="${FC_FIT_PORT_POOL:-5201 5202 5203 5204 5205 5206 5207 5208 5209 5210 5200}"
FC_FIT_PROBE_PORTS="${FC_FIT_PROBE_PORTS:-5201 5202 5203 5200}"
FC_FIT_PEER_IDEAL_RTT="${FC_FIT_PEER_IDEAL_RTT:-50}"
FC_FIT_PEER_MAX_RTT="${FC_FIT_PEER_MAX_RTT:-100}"
FC_FIT_PING_CONCURRENCY="${FC_FIT_PING_CONCURRENCY:-6}"

fc_fit_port_order() {
  local preferred="$1" candidate
  local -a candidates=()
  IFS=' ' read -r -a candidates <<<"$FC_FIT_PORT_POOL"
  printf '%s\n' "$preferred"
  for candidate in "${candidates[@]}"; do
    [[ "$candidate" == "$preferred" ]] || printf '%s\n' "$candidate"
  done
}

fc_fit_ping_rtt() {
  local peer="$1" family="$2"
  LC_ALL=C ping "$family" -c 2 -q -W 2 "$peer" 2>/dev/null |
    awk -F/ '/rtt|round-trip/ {printf "%.0f\n", $5; exit}'
}

fc_fit_probe_tcp_port() {
  local peer="$1" port="$2"
  local -a timeout_args=()
  timeout --foreground 1 true >/dev/null 2>&1 && timeout_args+=(--foreground)
  timeout "${timeout_args[@]}" 4 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$peer" "$port" \
    >/dev/null 2>&1
}

fc_fit_probe_peer_port() {
  local peer="$1" candidate
  local -a candidates=()
  IFS=' ' read -r -a candidates <<<"$FC_FIT_PROBE_PORTS"
  for candidate in "${candidates[@]}"; do
    if fc_fit_probe_tcp_port "$peer" "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

fc_fit_probe_iperf() {
  local peer="$1" port="$2" family="$3"
  local -a timeout_args=()
  timeout --foreground 1 true >/dev/null 2>&1 && timeout_args+=(--foreground)
  LC_ALL=C timeout "${timeout_args[@]}" 15 \
    iperf3 "$family" -c "$peer" -p "$port" -n 1M -P 1 >/dev/null 2>&1
}

fc_fit_find_working_port() {
  local peer="$1" family="$2" first candidate
  first="$(fc_fit_probe_peer_port "$peer" || true)"
  [[ -n "$first" ]] || return 1
  while IFS= read -r candidate; do
    if fc_fit_probe_iperf "$peer" "$candidate" "$family"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(fc_fit_port_order "$first")
  return 1
}

fc_fit_auto_peer() {
  local family="$1" temp_dir sorted='' candidate name provider rtt port file
  local excluded="${2:-}"
  local running=0 index=0 concurrency="$FC_FIT_PING_CONCURRENCY"
  local ideal="$FC_FIT_PEER_IDEAL_RTT" maximum="$FC_FIT_PEER_MAX_RTT"
  fc_has ping || {
    fc_warn '本机缺少 ping，无法自动选择对端。请安装 iputils-ping，或使用 --peer 指定。' >&2
    return 1
  }
  fc_is_uint "$concurrency" && ((concurrency >= 1 && concurrency <= 18)) || concurrency=6
  fc_is_uint "$ideal" && ((ideal >= 1)) || ideal=50
  fc_is_uint "$maximum" && ((maximum >= ideal)) || maximum=100
  temp_dir="$(mktemp -d /tmp/flowcraft-peer.XXXXXX)"
  fc_info '正在按 RTT 筛选公共 iperf3 对端，并验证空闲端口…' >&2
  while IFS='|' read -r candidate name provider; do
    [[ -n "$candidate" ]] || continue
    index=$((index + 1))
    (
      rtt="$(fc_fit_ping_rtt "$candidate" "$family" || true)"
      if [[ "$rtt" =~ ^[0-9]+$ ]]; then
        printf '%s|%s|%s|%s\n' "$rtt" "$candidate" "$name" "$provider" >"$temp_dir/$index"
      fi
      exit 0
    ) &
    running=$((running + 1))
    if ((running >= concurrency)); then
      wait || true
      running=0
    fi
  done <<<"$FC_FIT_PEER_POOL"
  wait || true
  for file in "$temp_dir"/*; do
    [[ -f "$file" ]] && sorted+="$(<"$file")"$'\n'
  done
  rm -rf -- "$temp_dir"
  [[ -n "$sorted" ]] || {
    fc_warn '公共节点均未返回 RTT；请检查 DNS、ICMP 或使用 --peer 指定。' >&2
    return 1
  }
  while IFS='|' read -r rtt candidate name provider; do
    [[ -n "$candidate" ]] || continue
    [[ "$excluded" == *"|${candidate}|"* ]] && continue
    if ((rtt > maximum)); then
      printf '[SKIP] %s (%s/%s) RTT %sms，超过 %sms 上限。\n' "$candidate" "$name" "$provider" "$rtt" "$maximum" >&2
      continue
    fi
    printf '[INFO] 验证 %s (%s/%s)，RTT %sms…\n' "$candidate" "$name" "$provider" "$rtt" >&2
    port="$(fc_fit_find_working_port "$candidate" "$family" || true)"
    [[ -n "$port" ]] || {
      printf '[SKIP] 节点端口不可用或当前占线。\n' >&2
      continue
    }
    if ((rtt > ideal)); then
      fc_warn "最近可用对端 RTT ${rtt}ms，高于理想值 ${ideal}ms；拐点结果可能偏保守。" >&2
    fi
    printf '%s|%s|%s|%s|%s\n' "$candidate" "$port" "$rtt" "$name" "$provider"
    return 0
  done < <(printf '%s' "$sorted" | sort -t '|' -k1,1n)
  fc_warn "未找到 ${maximum}ms 内且可实际运行 iperf3 的公共节点；请稍后重试或使用 --peer。" >&2
  return 1
}

fc_fit_margin() {
  local bandwidth="$1"
  if ((bandwidth <= 30)); then
    printf '1\n'
  elif ((bandwidth <= 60)); then
    printf '2\n'
  elif ((bandwidth <= 100)); then
    printf '5\n'
  elif ((bandwidth <= 300)); then
    printf '10\n'
  elif ((bandwidth <= 600)); then
    printf '15\n'
  elif ((bandwidth <= 1000)); then
    printf '25\n'
  else
    printf '40\n'
  fi
}

fc_fit_loss_pct() {
  local retransmits="$1" sender_mbps="$2" duration="$3"
  awk -v retransmits="$retransmits" -v rate="$sender_mbps" -v seconds="$duration" 'BEGIN {
    packets=rate*1000000*seconds/8/1448
    if (packets<1) packets=1
    printf "%.4f\n", retransmits*100/packets
  }'
}

fc_fit_default_ceiling() {
  local nominal="$1" ceiling
  ceiling=$((nominal * 125 / 100))
  ((ceiling > nominal)) || ceiling="$nominal"
  printf '%s\n' "$ceiling"
}

fc_fit_health_rate() {
  local nominal="$1" rate
  rate=$((nominal * 20 / 100))
  ((rate >= 1)) || rate=1
  ((rate <= 200)) || rate=200
  printf '%s\n' "$rate"
}

fc_fit_coarse_points() {
  local nominal="$1" ceiling="$2" discover="$3" percent rate last=0 next
  local -a percentages=(50 70 85 100 110 125)
  for percent in "${percentages[@]}"; do
    rate=$((nominal * percent / 100))
    ((rate >= 1)) || rate=1
    ((rate <= ceiling)) || rate="$ceiling"
    if ((rate > last)); then
      printf '%s\n' "$rate"
      last="$rate"
    fi
    ((last < ceiling)) || return 0
  done
  ((discover == 1)) || return 0
  while ((last < ceiling)); do
    next=$((last * 3 / 2))
    ((next > last)) || next=$((last + 1))
    ((next <= ceiling)) || next="$ceiling"
    printf '%s\n' "$next"
    last="$next"
  done
}

fc_fit_is_spike() {
  local loss="$1" baseline="${2:-0}" threshold="${3:-0.1}"
  awk -v loss="$loss" -v baseline="$baseline" -v threshold="$threshold" 'BEGIN {
    needed=threshold
    if (baseline>0 && baseline*5>needed) needed=baseline*5
    if (needed>1) needed=1
    exit !(loss>needed)
  }'
}

fc_fit_is_efficiency_knee() {
  local goodput="$1" rate="$2" previous_goodput="$3" previous_rate="$4"
  local health_goodput="$5" health_rate="$6"
  [[ -n "$goodput" && -n "$previous_goodput" && -n "$health_goodput" ]] || return 1
  awk -v goodput="$goodput" -v rate="$rate" \
    -v previous_goodput="$previous_goodput" -v previous_rate="$previous_rate" \
    -v health_goodput="$health_goodput" -v health_rate="$health_rate" 'BEGIN {
    if (rate<=previous_rate || health_rate<=0 || rate<=0) exit 1
    efficiency=goodput/rate
    health_efficiency=health_goodput/health_rate
    marginal_gain=(goodput-previous_goodput)/(rate-previous_rate)
    exit !(efficiency<health_efficiency*0.90 && marginal_gain<0.50)
  }'
}

fc_fit_goodput() {
  local result="$1" value
  value="$(awk '{print $3}' <<<"$result")"
  [[ -n "$value" ]] || value="$(awk '{print $1}' <<<"$result")"
  printf '%s\n' "$value"
}

fc_fit_run_iperf() {
  local peer="$1" port="$2" duration="$3" parallel="$4" family="$5"
  local temp pattern sender_line receiver_line sender retransmits receiver=''
  local -a timeout_args=()
  temp="$(mktemp /tmp/flowcraft-iperf.XXXXXX)"
  timeout --foreground 1 true >/dev/null 2>&1 && timeout_args+=(--foreground)
  if ! LC_ALL=C timeout "${timeout_args[@]}" $((duration + 25)) \
    iperf3 "$family" -c "$peer" -p "$port" -t "$duration" -P "$parallel" -f m >"$temp" 2>&1; then
    rm -f "$temp"
    return 1
  fi
  if ((parallel > 1)); then pattern='SUM.*sender'; else pattern='sender'; fi
  sender_line="$(grep -E "$pattern" "$temp" | tail -n 1 || true)"
  if ((parallel > 1)); then pattern='SUM.*receiver'; else pattern='receiver'; fi
  receiver_line="$(grep -E "$pattern" "$temp" | tail -n 1 || true)"
  rm -f "$temp"
  [[ -n "$sender_line" ]] || return 1
  sender="$(awk '{print $(NF-3)}' <<<"$sender_line")"
  retransmits="$(awk '{print $(NF-1)}' <<<"$sender_line")"
  [[ -n "$receiver_line" ]] && receiver="$(awk '{print $(NF-2)}' <<<"$receiver_line")"
  [[ "$sender" =~ ^[0-9]+([.][0-9]+)?$ && "$retransmits" =~ ^[0-9]+$ ]] || return 1
  [[ -z "$receiver" || "$receiver" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  if [[ -n "$receiver" ]]; then
    printf '%s %s %s\n' "$sender" "$retransmits" "$receiver"
  else
    printf '%s %s\n' "$sender" "$retransmits"
  fi
}

fc_fit_measure() {
  local peer="$1" port="$2" duration="$3" parallel="$4" family="$5" result='' attempt
  for attempt in 1 2 3; do
    printf '[INFO] iperf3 %ss x %s stream(s), attempt %s/3\n' "$duration" "$parallel" "$attempt" >&2
    result="$(fc_fit_run_iperf "$peer" "$port" "$duration" "$parallel" "$family" || true)"
    [[ -n "$result" ]] && {
      printf '%s\n' "$result"
      return 0
    }
    ((attempt < 3)) && sleep 8
  done
  return 1
}

fc_fit_apply_test_rate() {
  local iface="$1" rate="$2" mem="$3" error burst
  error="$(mktemp /tmp/flowcraft-fit-tc.XXXXXX)"
  burst="$(fc_htb_burst_kb "$rate" policer)"
  if fc_try_htb "$iface" "$rate" "$rate" "$burst" "$mem" "$error"; then
    rm -f "$error"
    return 0
  fi
  fc_warn "测试整形 ${rate} Mbps 应用失败：$(tail -n 1 "$error")"
  rm -f "$error"
  return 1
}

FC_FIT_LAST_OK=''
FC_FIT_LAST_GOODPUT=''
FC_FIT_BROKE_AT=''
FC_FIT_BREAK_REASON=''
FC_FIT_BASE_LOSS=''
FC_FIT_SLOW_HITS=0
FC_FIT_PEER_SLOW=0
FC_FIT_HEALTH_STATUS=''
FC_FIT_HEALTH_RATE=''
FC_FIT_HEALTH_GOODPUT=''
FC_FIT_HEALTH_LOSS=''

fc_fit_validate_path() {
  local iface="$1" peer="$2" port="$3" family="$4" duration="$5" nominal="$6" mem="$7"
  local result sender retransmits
  FC_FIT_HEALTH_RATE="$(fc_fit_health_rate "$nominal")"
  FC_FIT_HEALTH_STATUS='measurement-failed'
  FC_FIT_HEALTH_GOODPUT=''
  FC_FIT_HEALTH_LOSS=''
  if ! fc_fit_apply_test_rate "$iface" "$FC_FIT_HEALTH_RATE" "$mem"; then
    FC_FIT_HEALTH_STATUS='shaper-failed'
    return 1
  fi
  result="$(fc_fit_measure "$peer" "$port" "$duration" 1 "$family" || true)"
  [[ -n "$result" ]] || return 1
  sender="$(awk '{print $1}' <<<"$result")"
  retransmits="$(awk '{print $2}' <<<"$result")"
  FC_FIT_HEALTH_GOODPUT="$(fc_fit_goodput "$result")"
  FC_FIT_HEALTH_LOSS="$(fc_fit_loss_pct "$retransmits" "$sender" "$duration")"
  if awk -v loss="$FC_FIT_HEALTH_LOSS" 'BEGIN {exit !(loss>0.05)}'; then
    FC_FIT_HEALTH_STATUS='dirty-path'
    return 1
  fi
  if awk -v goodput="$FC_FIT_HEALTH_GOODPUT" -v rate="$FC_FIT_HEALTH_RATE" \
    'BEGIN {exit !(goodput<rate*0.7)}'; then
    FC_FIT_HEALTH_STATUS='peer-too-slow'
    return 1
  fi
  FC_FIT_HEALTH_STATUS=clean
  FC_FIT_BASE_LOSS="$FC_FIT_HEALTH_LOSS"
  return 0
}

fc_fit_scan_range() {
  local iface="$1" peer="$2" port="$3" family="$4" duration="$5" gap="$6" threshold="$7"
  local low="$8" high="$9" step="${10}" mem="${11}" ceiling="${12}"
  local rate result sender retransmits goodput loss hits recheck clean_result
  local -a points=()
  if ((low < 1 || high < low || high > ceiling)); then
    fc_warn "拒绝越过测试上限：范围 ${low}-${high} Mbps / ceiling ${ceiling} Mbps。"
    return 1
  fi
  for ((rate = low; rate <= high; rate += step)); do points+=("$rate"); done
  [[ "${points[$((${#points[@]} - 1))]}" == "$high" ]] || points+=("$high")
  for rate in "${points[@]}"; do
    fc_fit_apply_test_rate "$iface" "$rate" "$mem" || return 1
    result="$(fc_fit_measure "$peer" "$port" "$duration" 1 "$family" || true)"
    if [[ -z "$result" ]]; then
      printf '  %-10s %12s %9s %8s  %s\n' "$rate" - - - 'peer busy, skipped'
      continue
    fi
    sender="$(awk '{print $1}' <<<"$result")"
    retransmits="$(awk '{print $2}' <<<"$result")"
    goodput="$(fc_fit_goodput "$result")"
    loss="$(fc_fit_loss_pct "$retransmits" "$sender" "$duration")"
    if [[ -z "$FC_FIT_BASE_LOSS" ]] && awk -v loss="$loss" -v threshold="$threshold" 'BEGIN {exit !(loss<=threshold)}'; then
      FC_FIT_BASE_LOSS="$loss"
    fi
    if fc_fit_is_spike "$loss" "${FC_FIT_BASE_LOSS:-0}" "$threshold"; then
      hits=1
      clean_result=''
      for recheck in 2 3; do
        sleep "$gap"
        result="$(fc_fit_measure "$peer" "$port" "$duration" 1 "$family" || true)"
        [[ -n "$result" ]] || continue
        sender="$(awk '{print $1}' <<<"$result")"
        retransmits="$(awk '{print $2}' <<<"$result")"
        goodput="$(fc_fit_goodput "$result")"
        loss="$(fc_fit_loss_pct "$retransmits" "$sender" "$duration")"
        printf '  %-10s %12s %9s %8s  %s\n' "${rate} (#${recheck})" "$goodput" "$retransmits" "$loss" recheck
        if fc_fit_is_spike "$loss" "${FC_FIT_BASE_LOSS:-0}" "$threshold"; then
          hits=$((hits + 1))
        else
          clean_result="$result"
          [[ -n "$FC_FIT_BASE_LOSS" ]] || FC_FIT_BASE_LOSS="$loss"
        fi
      done
      if ((hits >= 2)); then
        printf '  %-10s %12s %9s %8s  loss spike (%s/3)\n' "$rate" "$goodput" "$retransmits" "$loss" "$hits"
        FC_FIT_BROKE_AT="$rate"
        FC_FIT_BREAK_REASON='loss-spike'
        return 0
      fi
      [[ -n "$clean_result" ]] || continue
      result="$clean_result"
      sender="$(awk '{print $1}' <<<"$result")"
      retransmits="$(awk '{print $2}' <<<"$result")"
      goodput="$(fc_fit_goodput "$result")"
      loss="$(fc_fit_loss_pct "$retransmits" "$sender" "$duration")"
    fi
    if fc_fit_is_efficiency_knee "$goodput" "$rate" "$FC_FIT_LAST_GOODPUT" "$FC_FIT_LAST_OK" \
      "$FC_FIT_HEALTH_GOODPUT" "$FC_FIT_HEALTH_RATE"; then
      hits=1
      clean_result=''
      for recheck in 2 3; do
        sleep "$gap"
        result="$(fc_fit_measure "$peer" "$port" "$duration" 1 "$family" || true)"
        [[ -n "$result" ]] || continue
        sender="$(awk '{print $1}' <<<"$result")"
        retransmits="$(awk '{print $2}' <<<"$result")"
        goodput="$(fc_fit_goodput "$result")"
        loss="$(fc_fit_loss_pct "$retransmits" "$sender" "$duration")"
        printf '  %-10s %12s %9s %8s  %s\n' "${rate} (#${recheck})" "$goodput" "$retransmits" "$loss" recheck
        if fc_fit_is_efficiency_knee "$goodput" "$rate" "$FC_FIT_LAST_GOODPUT" "$FC_FIT_LAST_OK" \
          "$FC_FIT_HEALTH_GOODPUT" "$FC_FIT_HEALTH_RATE"; then
          hits=$((hits + 1))
        else
          clean_result="$result"
        fi
      done
      if ((hits >= 2)); then
        printf '  %-10s %12s %9s %8s  efficiency knee (%s/3)\n' "$rate" "$goodput" "$retransmits" "$loss" "$hits"
        FC_FIT_BROKE_AT="$rate"
        FC_FIT_BREAK_REASON='efficiency-drop'
        return 0
      fi
      [[ -n "$clean_result" ]] || continue
      result="$clean_result"
      sender="$(awk '{print $1}' <<<"$result")"
      retransmits="$(awk '{print $2}' <<<"$result")"
      goodput="$(fc_fit_goodput "$result")"
      loss="$(fc_fit_loss_pct "$retransmits" "$sender" "$duration")"
    fi
    if awk -v goodput="$goodput" -v rate="$rate" -v loss="$loss" -v threshold="$threshold" \
      'BEGIN {exit !(goodput<rate*0.7 && loss<=threshold)}'; then
      FC_FIT_SLOW_HITS=$((FC_FIT_SLOW_HITS + 1))
      printf '  %-10s %12s %9s %8s  peer below target\n' "$rate" "$goodput" "$retransmits" "$loss"
      if ((FC_FIT_SLOW_HITS >= 3)); then
        FC_FIT_PEER_SLOW=1
        return 0
      fi
      sleep "$gap"
      continue
    else
      FC_FIT_SLOW_HITS=0
      printf '  %-10s %12s %9s %8s  ok\n' "$rate" "$goodput" "$retransmits" "$loss"
    fi
    FC_FIT_LAST_OK="$rate"
    FC_FIT_LAST_GOODPUT="$goodput"
    sleep "$gap"
  done
}

fc_fit_store_result() {
  ((FC_DRY_RUN == 0)) || return 0
  local temp
  mkdir -p "$FC_STATE_DIR"
  temp="$(mktemp "${FC_FIT_RESULT}.XXXXXX")"
  printf '%s\n' "$@" >"$temp"
  chmod 0600 "$temp"
  mv -f "$temp" "$FC_FIT_RESULT"
}

fc_fit_summary() {
  [[ -r "$FC_FIT_RESULT" ]] || {
    printf '尚未执行\n'
    return 0
  }
  local status recommendation knee
  status="$(awk -F= '$1=="STATUS" {print $2; exit}' "$FC_FIT_RESULT")"
  recommendation="$(awk -F= '$1=="RECOMMEND_MBPS" {print $2; exit}' "$FC_FIT_RESULT")"
  knee="$(awk -F= '$1=="KNEE_MBPS" {print $2; exit}' "$FC_FIT_RESULT")"
  if [[ "$status" == fitted ]]; then
    printf '拐点 %s / 建议 %s Mbps\n' "${knee:-?}" "${recommendation:-?}"
  else
    printf '%s\n' "${status:-unknown}"
  fi
}

fc_fit_apply_result() {
  local status="$1" recommendation="${2:-}" lift_per_flow="$3"
  fc_load_config
  case "$status" in
    fitted)
      TOTAL_MBPS="$recommendation"
      BURST_MODE=policer
      SHAPER_MODE=htb
      if [[ "$ROLE" == general ]]; then
        PER_FLOW_MBPS="$recommendation"
      elif [[ "$ROLE" == relay && "$lift_per_flow" == 1 ]]; then
        PER_FLOW_MBPS="$recommendation"
      fi
      ;;
    *) return 0 ;;
  esac
  fc_save_config
  fc_apply_all
}

fc_fit_restore_managed_qdisc() {
  trap - EXIT INT TERM HUP
  if ! fc_apply_shape >/dev/null 2>&1; then
    fc_warn '无法按 Flowcraft 配置恢复出口 qdisc；请立即运行 ftcp apply。'
    return 1
  fi
}

fc_fit_command() {
  local peer='' nominal='' port=5201 family=-4 duration=12 gap=3 ceiling='' threshold=0.1
  local apply=0 lift_per_flow=0 port_explicit=0 peer_auto=0 discover=0 ceiling_explicit=0
  local legacy_cap=0 argument selected_peer='' peer_rtt='' peer_name='' peer_provider=''
  while (($#)); do
    argument="$1"
    case "$argument" in
      --peer)
        [[ $# -ge 2 ]] || fc_die '--peer 缺少值'
        peer="$2"
        shift 2
        ;;
      --nominal)
        [[ $# -ge 2 ]] || fc_die '--nominal 缺少值'
        nominal="$2"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || fc_die '--port 缺少值'
        port="$2"
        port_explicit=1
        shift 2
        ;;
      --duration)
        [[ $# -ge 2 ]] || fc_die '--duration 缺少值'
        duration="$2"
        shift 2
        ;;
      --gap)
        [[ $# -ge 2 ]] || fc_die '--gap 缺少值'
        gap="$2"
        shift 2
        ;;
      --ceiling)
        [[ $# -ge 2 ]] || fc_die '--ceiling 缺少值'
        ceiling="$2"
        ceiling_explicit=1
        shift 2
        ;;
      --cap)
        [[ $# -ge 2 ]] || fc_die '--cap 缺少值'
        ceiling="$2"
        ceiling_explicit=1
        discover=1
        legacy_cap=1
        shift 2
        ;;
      --loss-threshold)
        [[ $# -ge 2 ]] || fc_die '--loss-threshold 缺少值'
        threshold="$2"
        shift 2
        ;;
      -4 | -6)
        family="$1"
        shift
        ;;
      --apply)
        apply=1
        shift
        ;;
      --discover)
        discover=1
        shift
        ;;
      --lift-per-flow)
        lift_per_flow=1
        shift
        ;;
      *) fc_die "未知 fit 参数：$argument" ;;
    esac
  done
  [[ -r "$FC_CONFIG_FILE" ]] || fc_die '请先完成 Flowcraft 安装，再运行 fit。'
  [[ -n "$peer" || "$port_explicit" == 0 ]] || fc_die '--port 只能与 --peer 一起使用。'
  [[ -z "$peer" || "$peer" =~ ^[a-zA-Z0-9_.:%-]+$ ]] || fc_die 'peer 格式无效。'
  fc_is_uint "$nominal" && ((nominal >= 1 && nominal <= 100000)) || fc_die '--nominal 必须是 1-100000 的整数 Mbps。'
  fc_is_uint "$port" && ((port >= 1 && port <= 65535)) || fc_die '--port 必须是 1-65535 的整数。'
  fc_is_uint "$duration" && ((duration >= 1 && duration <= 600)) || fc_die '--duration 必须是 1-600 秒。'
  fc_is_uint "$gap" && ((gap <= 60)) || fc_die '--gap 必须是 0-60 秒。'
  if ((discover == 1)); then
    ((ceiling_explicit == 1)) || fc_die '--discover 必须同时指定 --ceiling MBPS。'
  else
    ((ceiling_explicit == 0)) || fc_die '--ceiling 必须与 --discover 一起使用。'
    ceiling="$(fc_fit_default_ceiling "$nominal")"
  fi
  fc_is_uint "$ceiling" && ((ceiling >= nominal && ceiling <= 100000)) ||
    fc_die '--ceiling 必须是不小于 nominal 且不超过 100000 的整数 Mbps。'
  if [[ -z "$peer" ]] && ((ceiling > 2500)); then
    fc_die '公共节点模式最多测试到 2500 Mbps；更高速率请使用 --peer 指定独享对端。'
  fi
  [[ "$threshold" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
    awk -v value="$threshold" 'BEGIN {exit !(value>0 && value<=10)}' ||
    fc_die '--loss-threshold 必须大于 0 且不超过 10%。'
  ((lift_per_flow == 0 || apply == 1)) || fc_die '--lift-per-flow 必须与 --apply 一起使用。'

  fc_need_root
  fc_take_lock
  fc_assert_no_conflicts
  fc_has iperf3 || fc_die 'fit 需要 iperf3；请先通过系统包管理器安装。'
  fc_has timeout && fc_has tc || fc_die 'fit 需要 timeout 和 tc。'
  ((legacy_cap == 0)) || fc_warn '--cap 已兼容映射为 --discover --ceiling；后续请使用新参数。'
  fc_load_config
  [[ "$(fc_read_stage_value STAGE)" == complete ]] || fc_die 'Flowcraft 安装尚未完成；请先运行 ftcp resume。'
  [[ -n "$peer" ]] || peer_auto=1
  local iface mem rate status recommendation='' knee='' margin coarse_broke coarse_reason fine fine_start fine_end
  local peer_attempts=0 excluded='' health_error=''
  local -a endpoint_fields=()
  iface="$(fc_resolve_iface)"
  mem="$(fc_mem_mb)"
  ((mem > 0)) || mem=1024
  ((FC_DRY_RUN == 1)) || rm -f "$FC_FIT_RESULT"

  trap 'fc_fit_restore_managed_qdisc || true' EXIT
  trap 'fc_warn "fit 被中断，正在恢复 Flowcraft qdisc"; fc_fit_restore_managed_qdisc || true; exit 130' INT TERM HUP

  while true; do
    if [[ -z "$peer" ]]; then
      selected_peer="$(fc_fit_auto_peer "$family" "$excluded" || true)"
      [[ -n "$selected_peer" ]] || fc_die '自动选择测速对端失败；请稍后重试或使用 --peer 指定。'
      IFS='|' read -r peer port peer_rtt peer_name peer_provider <<<"$selected_peer"
      [[ "$peer" =~ ^[a-zA-Z0-9_.:%-]+$ ]] || fc_die '自动选择返回了无效 peer。'
      fc_is_uint "$port" && ((port >= 1 && port <= 65535)) || fc_die '自动选择返回了无效端口。'
      fc_info "已选择 ${peer}:${port}（${peer_name}/${peer_provider}，RTT ${peer_rtt}ms）。"
    fi
    peer_attempts=$((peer_attempts + 1))
    endpoint_fields=("PEER=$peer" "PEER_PORT=$port" "PEER_AUTO=$peer_auto")
    if ((peer_auto == 1)); then
      endpoint_fields+=("PEER_RTT_MS=$peer_rtt" "PEER_NAME=$peer_name" "PEER_PROVIDER=$peer_provider")
    fi
    fc_info "开始有界端口拟合：${peer}:${port} / 标称 ${nominal} Mbps / ceiling ${ceiling} Mbps / ${family#-}"
    FC_FIT_BASE_LOSS=''
    if ! fc_fit_validate_path "$iface" "$peer" "$port" "$family" "$duration" "$nominal" "$mem"; then
      health_error="$FC_FIT_HEALTH_STATUS"
      fc_warn "对端健康检查未通过：${health_error}（${FC_FIT_HEALTH_RATE} Mbps / goodput ${FC_FIT_HEALTH_GOODPUT:--} / loss ${FC_FIT_HEALTH_LOSS:--}%）。"
      if [[ "$health_error" != shaper-failed ]] && ((peer_auto == 1 && peer_attempts < 3)); then
        excluded+="|${peer}|"
        peer=''
        fc_warn '自动换下一个公共节点重新验证。'
        continue
      fi
      fc_fit_restore_managed_qdisc || fc_die '恢复出口 qdisc 失败。'
      fc_fit_store_result "STATUS=$health_error" "HEALTH_RATE_MBPS=$FC_FIT_HEALTH_RATE" \
        "HEALTH_GOODPUT_MBPS=$FC_FIT_HEALTH_GOODPUT" "HEALTH_LOSS_PCT=$FC_FIT_HEALTH_LOSS" \
        "${endpoint_fields[@]}" "NOMINAL_MBPS=$nominal" "CEILING_MBPS=$ceiling"
      fc_warn '路径或对端不适合拟合；未修改持久配置。'
      return 0
    fi

    printf '  %-10s %12s %9s %8s  %s\n' Rate Goodput Retrans Loss% Verdict
    printf '  %-10s %12s %9s %8s  %s\n' "$FC_FIT_HEALTH_RATE" "$FC_FIT_HEALTH_GOODPUT" - "$FC_FIT_HEALTH_LOSS" health
    FC_FIT_LAST_OK="$FC_FIT_HEALTH_RATE"
    FC_FIT_LAST_GOODPUT="$FC_FIT_HEALTH_GOODPUT"
    FC_FIT_BROKE_AT=''
    FC_FIT_BREAK_REASON=''
    FC_FIT_SLOW_HITS=0
    FC_FIT_PEER_SLOW=0
    while IFS= read -r rate; do
      [[ "$rate" == "$FC_FIT_HEALTH_RATE" ]] && continue
      fc_fit_scan_range "$iface" "$peer" "$port" "$family" "$duration" "$gap" "$threshold" \
        "$rate" "$rate" 1 "$mem" "$ceiling" || {
        fc_fit_restore_managed_qdisc || true
        fc_die '扫描期间无法应用有界测试 qdisc。'
      }
      [[ -z "$FC_FIT_BROKE_AT" ]] || break
      ((FC_FIT_PEER_SLOW == 0)) || break
    done < <(fc_fit_coarse_points "$nominal" "$ceiling" "$discover")
    if ((FC_FIT_PEER_SLOW == 1 && peer_auto == 1 && peer_attempts < 3)); then
      excluded+="|${peer}|"
      peer=''
      fc_warn '当前公共节点在高档位连续达不到目标，自动换节点重新扫描。'
      continue
    fi
    break
  done

  if ((FC_FIT_PEER_SLOW == 1)); then
    status='peer-too-slow'
    fc_fit_restore_managed_qdisc || fc_die '恢复出口 qdisc 失败。'
    fc_fit_store_result "STATUS=$status" "SCANNED_TO_MBPS=$FC_FIT_LAST_OK" \
      "LAST_GOODPUT_MBPS=$FC_FIT_LAST_GOODPUT" \
      "${endpoint_fields[@]}" "NOMINAL_MBPS=$nominal" "CEILING_MBPS=$ceiling"
    fc_warn '测速对端连续三档达不到目标速率；未修改持久配置。'
    return 0
  fi
  if [[ -z "$FC_FIT_BROKE_AT" ]]; then
    status='clean-through-envelope'
    fc_fit_restore_managed_qdisc || fc_die '恢复出口 qdisc 失败。'
    fc_fit_store_result "STATUS=$status" "SCANNED_TO_MBPS=$FC_FIT_LAST_OK" \
      "LAST_GOODPUT_MBPS=$FC_FIT_LAST_GOODPUT" "HEALTH_LOSS_PCT=$FC_FIT_HEALTH_LOSS" "${endpoint_fields[@]}" \
      "NOMINAL_MBPS=$nominal" "CEILING_MBPS=$ceiling" "DISCOVER=$discover"
    fc_log "测试到 ${FC_FIT_LAST_OK} Mbps 仍保持干净，真实拐点高于本次测试范围。"
    ((apply == 0)) || fc_warn '没有找到可信拐点，因此忽略 --apply 并保留现有配置。'
    return 0
  fi

  coarse_broke="$FC_FIT_BROKE_AT"
  coarse_reason="$FC_FIT_BREAK_REASON"
  fine=$((nominal * 2 / 100))
  ((fine >= 1)) || fine=1
  fine_start=$((FC_FIT_LAST_OK + fine))
  fine_end=$((coarse_broke - fine))
  if ((fine_start <= fine_end)); then
    fc_info "拐点位于 ${FC_FIT_LAST_OK}-${coarse_broke} Mbps，以 ${fine} Mbps 步长细扫。"
    FC_FIT_BROKE_AT=''
    FC_FIT_BREAK_REASON=''
    fc_fit_scan_range "$iface" "$peer" "$port" "$family" "$duration" "$gap" "$threshold" \
      "$fine_start" "$fine_end" "$fine" "$mem" "$ceiling" || {
      fc_fit_restore_managed_qdisc || true
      fc_die '细扫期间无法应用有界测试 qdisc。'
    }
    if [[ -z "$FC_FIT_BROKE_AT" ]]; then
      FC_FIT_BROKE_AT="$coarse_broke"
      FC_FIT_BREAK_REASON="$coarse_reason"
    fi
  fi
  knee="$FC_FIT_LAST_OK"
  margin="$(fc_fit_margin "$knee")"
  recommendation=$((knee - margin))
  ((recommendation >= 1)) || recommendation="$knee"
  status=fitted
  fc_fit_restore_managed_qdisc || fc_die '恢复出口 qdisc 失败。'
  fc_fit_store_result 'STATUS=fitted' "KNEE_MBPS=$knee" "MARGIN_MBPS=$margin" "RECOMMEND_MBPS=$recommendation" \
    "BREAK_REASON=$FC_FIT_BREAK_REASON" "LAST_GOODPUT_MBPS=$FC_FIT_LAST_GOODPUT" \
    "${endpoint_fields[@]}" "NOMINAL_MBPS=$nominal" "CEILING_MBPS=$ceiling" \
    "DISCOVER=$discover" "LOSS_THRESHOLD_PCT=$threshold"
  fc_log "实测干净上限 ${knee} Mbps，触发 ${FC_FIT_BREAK_REASON}，安全余量 ${margin} Mbps，建议整形 ${recommendation} Mbps。"
  if ((apply == 1)); then
    fc_fit_apply_result "$status" "$recommendation" "$lift_per_flow"
    fc_log '拟合结果已写入 Flowcraft 配置并应用。'
  else
    fc_info "只保存测量结果；应用时重跑并加 --apply。结果：$FC_FIT_RESULT"
  fi
}

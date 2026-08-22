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

fc_fit_find_working_port() {
  local peer="$1" family="$2" first candidate
  first="$(fc_fit_probe_peer_port "$peer" || true)"
  [[ -n "$first" ]] || return 1
  while IFS= read -r candidate; do
    if fc_fit_run_iperf "$peer" "$candidate" 3 1 "$family" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(fc_fit_port_order "$first")
  return 1
}

fc_fit_auto_peer() {
  local family="$1" temp_dir sorted='' candidate name provider rtt port file
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

fc_fit_scan_bounds() {
  local goodput="$1" loss="$2" cap="$3"
  awk -v goodput="$goodput" -v loss="$loss" -v cap="$cap" 'BEGIN {
    low=int(goodput*0.95)
    if (low<1) low=1
    factor=1.25+(loss/100)*2
    if (factor>2.5) factor=2.5
    high=int(goodput*factor)
    if (high>cap) high=cap
    if (high<=low) high=low+2
    step=int((high-low)/10+0.5)
    if (step<1) step=1
    printf "%d %d %d\n", low, high, step
  }'
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
FC_FIT_BROKE_AT=''
FC_FIT_BASE_LOSS=''
FC_FIT_SLOW_HITS=0
FC_FIT_PEER_SLOW=0

fc_fit_scan_range() {
  local iface="$1" peer="$2" port="$3" family="$4" duration="$5" gap="$6" threshold="$7"
  local low="$8" high="$9" step="${10}" mem="${11}"
  local rate result sender retransmits goodput loss hits recheck clean_result
  local -a points=()
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
    else
      FC_FIT_SLOW_HITS=0
      printf '  %-10s %12s %9s %8s  ok\n' "$rate" "$goodput" "$retransmits" "$loss"
    fi
    FC_FIT_LAST_OK="$rate"
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
    no-knee)
      TOTAL_MBPS=0
      [[ "$ROLE" == general || "$ROLE" == landing ]] && SHAPER_MODE=fq
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
  local peer='' nominal='' port=5201 family=-4 duration=12 gap=3 cap=2500 threshold=0.1
  local apply=0 lift_per_flow=0 port_explicit=0 peer_auto=0 argument
  local selected_peer='' peer_rtt='' peer_name='' peer_provider=''
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
      --cap)
        [[ $# -ge 2 ]] || fc_die '--cap 缺少值'
        cap="$2"
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
  fc_is_uint "$cap" && ((cap >= 100 && cap <= 100000)) || fc_die '--cap 必须是 100-100000 Mbps。'
  [[ "$threshold" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
    awk -v value="$threshold" 'BEGIN {exit !(value>0 && value<=10)}' ||
    fc_die '--loss-threshold 必须大于 0 且不超过 10%。'
  ((lift_per_flow == 0 || apply == 1)) || fc_die '--lift-per-flow 必须与 --apply 一起使用。'

  fc_need_root
  fc_take_lock
  fc_assert_no_conflicts
  fc_has iperf3 || fc_die 'fit 需要 iperf3；请先通过系统包管理器安装。'
  fc_has timeout && fc_has tc || fc_die 'fit 需要 timeout 和 tc。'
  fc_load_config
  [[ "$(fc_read_stage_value STAGE)" == complete ]] || fc_die 'Flowcraft 安装尚未完成；请先运行 ftcp resume。'
  if [[ -z "$peer" ]]; then
    selected_peer="$(fc_fit_auto_peer "$family" || true)"
    [[ -n "$selected_peer" ]] || fc_die '自动选择测速对端失败；请稍后重试或使用 --peer 指定。'
    IFS='|' read -r peer port peer_rtt peer_name peer_provider <<<"$selected_peer"
    [[ "$peer" =~ ^[a-zA-Z0-9_.:%-]+$ ]] || fc_die '自动选择返回了无效 peer。'
    fc_is_uint "$port" && ((port >= 1 && port <= 65535)) || fc_die '自动选择返回了无效端口。'
    peer_auto=1
    fc_info "已选择 ${peer}:${port}（${peer_name}/${peer_provider}，RTT ${peer_rtt}ms）。"
  fi
  local iface mem result sender retransmits goodput loss best_result best_goodput _sample aggregate
  local bounds low high step status recommendation='' knee='' margin coarse_broke fine control attempts
  local -a endpoint_fields=("PEER=$peer" "PEER_PORT=$port" "PEER_AUTO=$peer_auto")
  if ((peer_auto == 1)); then
    endpoint_fields+=("PEER_RTT_MS=$peer_rtt" "PEER_NAME=$peer_name" "PEER_PROVIDER=$peer_provider")
  fi
  iface="$(fc_resolve_iface)"
  mem="$(fc_mem_mb)"
  ((mem > 0)) || mem=1024
  ((FC_DRY_RUN == 1)) || rm -f "$FC_FIT_RESULT"

  fc_info "开始端口拟合：${peer}:${port} / 标称 ${nominal} Mbps / ${family#-}"
  trap 'fc_fit_restore_managed_qdisc || true' EXIT
  trap 'fc_warn "fit 被中断，正在恢复 Flowcraft qdisc"; fc_fit_restore_managed_qdisc || true; exit 130' INT TERM HUP
  fc_restore_fq "$iface" || fc_die '无法临时切换到 fq。'
  result="$(fc_fit_measure "$peer" "$port" "$duration" 1 "$family" || true)"
  [[ -n "$result" ]] || {
    fc_fit_restore_managed_qdisc || true
    fc_die '未整形基线测试失败，请检查对端、端口和防火墙。'
  }
  sender="$(awk '{print $1}' <<<"$result")"
  retransmits="$(awk '{print $2}' <<<"$result")"
  goodput="$(fc_fit_goodput "$result")"
  loss="$(fc_fit_loss_pct "$retransmits" "$sender" "$duration")"

  if ((nominal <= cap)) && awk -v goodput="$goodput" -v nominal="$nominal" 'BEGIN {exit !(goodput<nominal*0.7)}'; then
    best_result="$result"
    best_goodput="$goodput"
    fc_info "单流仅达到标称值的 70% 以下，再取两次样本中的最高完整结果。"
    for _sample in 2 3; do
      sleep "$gap"
      result="$(fc_fit_measure "$peer" "$port" "$duration" 1 "$family" || true)"
      [[ -n "$result" ]] || continue
      goodput="$(fc_fit_goodput "$result")"
      if awk -v current="$goodput" -v best="$best_goodput" 'BEGIN {exit !(current>best)}'; then
        best_result="$result"
        best_goodput="$goodput"
      fi
    done
    result="$best_result"
    goodput="$best_goodput"
    sender="$(awk '{print $1}' <<<"$result")"
    retransmits="$(awk '{print $2}' <<<"$result")"
    loss="$(fc_fit_loss_pct "$retransmits" "$sender" "$duration")"
  fi

  if ((nominal > cap)) && awk -v goodput="$goodput" -v cap="$cap" -v loss="$loss" -v threshold="$threshold" \
    'BEGIN {exit !(goodput<=cap && loss>threshold)}'; then
    fc_info '高带宽单流结果不确定，增加一次 8 流聚合确认。'
    aggregate="$(fc_fit_measure "$peer" "$port" "$duration" 8 "$family" || true)"
    if [[ -n "$aggregate" ]] && awk -v goodput="$(fc_fit_goodput "$aggregate")" -v cap="$cap" 'BEGIN {exit !(goodput>cap)}'; then
      goodput="$(fc_fit_goodput "$aggregate")"
    fi
  fi

  if awk -v goodput="$goodput" -v cap="$cap" 'BEGIN {exit !(goodput>cap)}'; then
    status=above-cap
    fc_fit_restore_managed_qdisc || fc_die '恢复出口 qdisc 失败。'
    fc_fit_store_result 'STATUS=above-cap' "UNSHAPED_MBPS=$goodput" "CAP_MBPS=$cap" \
      "${endpoint_fields[@]}" "NOMINAL_MBPS=$nominal"
    fc_warn "未整形吞吐 ${goodput} Mbps 超过扫描上限 ${cap} Mbps；未修改持久配置。"
    return 0
  fi
  if awk -v loss="$loss" -v threshold="$threshold" 'BEGIN {exit !(loss<=threshold)}'; then
    status=no-knee
    fc_fit_restore_managed_qdisc || fc_die '恢复出口 qdisc 失败。'
    fc_fit_store_result 'STATUS=no-knee' "UNSHAPED_MBPS=$goodput" "LOSS_PCT=$loss" \
      "${endpoint_fields[@]}" "NOMINAL_MBPS=$nominal"
    fc_info "未整形丢包 ${loss}%，未发现 policer。"
    ((apply == 0)) || fc_fit_apply_result "$status" '' "$lift_per_flow"
    return 0
  fi

  bounds="$(fc_fit_scan_bounds "$goodput" "$loss" "$cap")"
  IFS=' ' read -r low high step <<<"$bounds"
  fc_info "检测到 policer 迹象：未整形 ${goodput} Mbps / 丢包 ${loss}%；扫描 ${low}-${high} Mbps。"
  sleep 15
  printf '  %-10s %12s %9s %8s  %s\n' Rate Goodput Retrans Loss% Verdict
  FC_FIT_LAST_OK=''
  FC_FIT_BROKE_AT=''
  FC_FIT_BASE_LOSS=''
  FC_FIT_SLOW_HITS=0
  FC_FIT_PEER_SLOW=0
  fc_fit_scan_range "$iface" "$peer" "$port" "$family" "$duration" "$gap" "$threshold" "$low" "$high" "$step" "$mem" || {
    fc_fit_restore_managed_qdisc || true
    fc_die '扫描期间无法应用测试 qdisc。'
  }
  if ((FC_FIT_PEER_SLOW == 1)); then
    fc_fit_restore_managed_qdisc || true
    fc_die '测速对端连续三档达不到目标速率，结果无效。'
  fi

  if [[ -z "$FC_FIT_LAST_OK" && -n "$FC_FIT_BROKE_AT" ]]; then
    coarse_broke="$FC_FIT_BROKE_AT"
    control="$coarse_broke"
    attempts=0
    while ((attempts < 3)) && [[ -z "$FC_FIT_LAST_OK" ]]; do
      attempts=$((attempts + 1))
      control=$((control * 3 / 4))
      ((control >= 1)) || control=1
      FC_FIT_BROKE_AT=''
      FC_FIT_BASE_LOSS=''
      fc_info "首档已经丢包，向下检查 ${control} Mbps 控制点。"
      fc_fit_scan_range "$iface" "$peer" "$port" "$family" "$duration" "$gap" "$threshold" "$control" "$control" 1 "$mem"
    done
    [[ -n "$FC_FIT_LAST_OK" ]] && FC_FIT_BROKE_AT="$coarse_broke"
  fi
  [[ -n "$FC_FIT_LAST_OK" ]] || {
    fc_fit_restore_managed_qdisc || true
    fc_die '没有测到可用的干净档位；未修改持久配置。'
  }
  if [[ -z "$FC_FIT_BROKE_AT" ]]; then
    status=out-of-range
    fc_fit_restore_managed_qdisc || fc_die '恢复出口 qdisc 失败。'
    fc_fit_store_result 'STATUS=out-of-range' "SCANNED_TO_MBPS=$high" "UNSHAPED_LOSS_PCT=$loss" \
      "${endpoint_fields[@]}" "NOMINAL_MBPS=$nominal"
    fc_warn "扫描到 ${high} Mbps 仍未定位拐点；未修改持久配置。"
    return 0
  fi

  coarse_broke="$FC_FIT_BROKE_AT"
  if ((coarse_broke - FC_FIT_LAST_OK > 1)); then
    fine=$((step / 4))
    ((fine >= 1)) || fine=1
    if ((FC_FIT_LAST_OK + fine <= coarse_broke - fine)); then
      fc_info "拐点位于 ${FC_FIT_LAST_OK}-${coarse_broke} Mbps，以 ${fine} Mbps 步长细扫。"
      FC_FIT_BROKE_AT=''
      fc_fit_scan_range "$iface" "$peer" "$port" "$family" "$duration" "$gap" "$threshold" \
        "$((FC_FIT_LAST_OK + fine))" "$((coarse_broke - fine))" "$fine" "$mem"
      [[ -n "$FC_FIT_BROKE_AT" ]] || FC_FIT_BROKE_AT="$coarse_broke"
    fi
  fi
  knee="$FC_FIT_LAST_OK"
  margin="$(fc_fit_margin "$nominal")"
  recommendation=$((knee - margin))
  ((recommendation >= 1)) || recommendation="$knee"
  status=fitted
  fc_fit_restore_managed_qdisc || fc_die '恢复出口 qdisc 失败。'
  fc_fit_store_result 'STATUS=fitted' "KNEE_MBPS=$knee" "MARGIN_MBPS=$margin" "RECOMMEND_MBPS=$recommendation" \
    "${endpoint_fields[@]}" "NOMINAL_MBPS=$nominal" "LOSS_THRESHOLD_PCT=$threshold"
  fc_log "实测干净上限 ${knee} Mbps，安全余量 ${margin} Mbps，建议整形 ${recommendation} Mbps。"
  if ((apply == 1)); then
    fc_fit_apply_result "$status" "$recommendation" "$lift_per_flow"
    fc_log '拟合结果已写入 Flowcraft 配置并应用。'
  else
    fc_info "只保存测量结果；应用时重跑并加 --apply。结果：$FC_FIT_RESULT"
  fi
}

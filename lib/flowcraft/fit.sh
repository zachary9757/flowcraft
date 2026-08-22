#!/usr/bin/env bash

# Policer measurement adapted from tcpfit, Copyright (c) 2026 Kylin010.
# Flowcraft remains the only persistent sysctl, qdisc, service, configuration, and rollback owner.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

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

fc_fit_health_rate() {
  local nominal="$1" rate
  rate=$((nominal * 40 / 100))
  ((rate >= 1)) || rate=1
  printf '%s\n' "$rate"
}

fc_fit_scan_bounds() {
  local goodput="$1" loss="$2" cap="$3"
  awk -v goodput="$goodput" -v loss="$loss" -v cap="$cap" 'BEGIN {
    low=int(goodput*0.95)
    if (low<1) low=1
    factor=1.25+loss/100*2
    if (factor>2.5) factor=2.5
    high=int(goodput*factor)
    if (high>cap) high=cap
    if (high<=low) high=low+2
    if (high>cap) high=cap
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
  local peer="$1" port="$2" duration="$3" parallel="$4" family="$5"
  local result='' attempt candidate
  for attempt in 1 2 3; do
    while IFS= read -r candidate; do
      printf '[INFO] iperf3 %ss x %s stream(s), %s:%s, attempt %s/3\n' \
        "$duration" "$parallel" "$peer" "$candidate" "$attempt" >&2
      result="$(fc_fit_run_iperf "$peer" "$candidate" "$duration" "$parallel" "$family" || true)"
      [[ -n "$result" ]] && {
        printf '%s\n' "$result"
        return 0
      }
    done < <(fc_fit_port_order "$port")
    ((attempt < 3)) && sleep 8
  done
  return 1
}

fc_fit_apply_unshaped_fq() {
  local iface="$1" error
  error="$(mktemp /tmp/flowcraft-fit-fq.XXXXXX)"
  tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
  if tc qdisc add dev "$iface" root fq 2>"$error"; then
    rm -f "$error"
    return 0
  fi
  fc_warn "不限速 fq 测试队列应用失败：$(tail -n 1 "$error")"
  rm -f "$error"
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
FC_FIT_SPIKE_MIN_LOSS=''
FC_FIT_SLOW_HITS=0
FC_FIT_PEER_SLOW=0
FC_FIT_HEALTH_STATUS=''
FC_FIT_HEALTH_RATE=''
FC_FIT_HEALTH_GOODPUT=''
FC_FIT_HEALTH_LOSS=''

fc_fit_validate_path() {
  local iface="$1" peer="$2" port="$3" family="$4" nominal="$5" mem="$6"
  local result sender retransmits
  FC_FIT_HEALTH_RATE="$(fc_fit_health_rate "$nominal")"
  FC_FIT_HEALTH_STATUS='measurement-failed'
  FC_FIT_HEALTH_GOODPUT=''
  FC_FIT_HEALTH_LOSS=''
  if ! fc_fit_apply_test_rate "$iface" "$FC_FIT_HEALTH_RATE" "$mem"; then
    FC_FIT_HEALTH_STATUS='shaper-failed'
    return 1
  fi
  result="$(fc_fit_measure "$peer" "$port" 8 2 "$family" || true)"
  [[ -n "$result" ]] || return 1
  sender="$(awk '{print $1}' <<<"$result")"
  retransmits="$(awk '{print $2}' <<<"$result")"
  FC_FIT_HEALTH_GOODPUT="$(fc_fit_goodput "$result")"
  FC_FIT_HEALTH_LOSS="$(fc_fit_loss_pct "$retransmits" "$sender" 8)"
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
  local low="$8" high="$9" step="${10}" mem="${11}" cap="${12}" parallel="${13:-1}"
  local rate result sender retransmits goodput loss hits recheck clean_result verdict previous_goodput=0
  local spike_goodput spike_retransmits spike_loss min_loss
  local -a points=()
  if ((low < 1 || high < low || high > cap)); then
    fc_warn "拒绝越过测试上限：范围 ${low}-${high} Mbps / cap ${cap} Mbps。"
    return 1
  fi
  for ((rate = low; rate <= high; rate += step)); do points+=("$rate"); done
  [[ "${points[$((${#points[@]} - 1))]}" == "$high" ]] || points+=("$high")
  for rate in "${points[@]}"; do
    fc_fit_apply_test_rate "$iface" "$rate" "$mem" || return 1
    result="$(fc_fit_measure "$peer" "$port" "$duration" "$parallel" "$family" || true)"
    if [[ -z "$result" ]]; then
      printf '  %-10s %12s %9s %8s  %s\n' "$rate" - - - 'peer busy, skipped'
      continue
    fi
    sender="$(awk '{print $1}' <<<"$result")"
    retransmits="$(awk '{print $2}' <<<"$result")"
    goodput="$(fc_fit_goodput "$result")"
    loss="$(fc_fit_loss_pct "$retransmits" "$sender" "$duration")"
    verdict=ok
    if [[ -z "$FC_FIT_BASE_LOSS" ]] && awk -v loss="$loss" -v threshold="$threshold" 'BEGIN {exit !(loss<=threshold)}'; then
      FC_FIT_BASE_LOSS="$loss"
    fi
    if fc_fit_is_spike "$loss" "${FC_FIT_BASE_LOSS:-0}" "$threshold"; then
      hits=1
      clean_result=''
      min_loss="$loss"
      spike_goodput="$goodput"
      spike_retransmits="$retransmits"
      spike_loss="$loss"
      for recheck in 2 3; do
        sleep "$gap"
        result="$(fc_fit_measure "$peer" "$port" "$duration" "$parallel" "$family" || true)"
        [[ -n "$result" ]] || continue
        sender="$(awk '{print $1}' <<<"$result")"
        retransmits="$(awk '{print $2}' <<<"$result")"
        goodput="$(fc_fit_goodput "$result")"
        loss="$(fc_fit_loss_pct "$retransmits" "$sender" "$duration")"
        printf '  %-10s %12s %9s %8s  %s\n' "${rate} (#${recheck})" "$goodput" "$retransmits" "$loss" recheck
        if awk -v current="$loss" -v minimum="$min_loss" 'BEGIN {exit !(current<minimum)}'; then
          min_loss="$loss"
        fi
        if fc_fit_is_spike "$loss" "${FC_FIT_BASE_LOSS:-0}" "$threshold"; then
          hits=$((hits + 1))
          spike_goodput="$goodput"
          spike_retransmits="$retransmits"
          spike_loss="$loss"
        else
          clean_result="$result"
          [[ -n "$FC_FIT_BASE_LOSS" ]] || FC_FIT_BASE_LOSS="$loss"
        fi
      done
      if ((hits >= 2)); then
        FC_FIT_SPIKE_MIN_LOSS="$min_loss"
        printf '  %-10s %12s %9s %8s  loss spike (%s/3)\n' \
          "$rate" "$spike_goodput" "$spike_retransmits" "$spike_loss" "$hits"
        FC_FIT_BROKE_AT="$rate"
        FC_FIT_BREAK_REASON='loss-spike'
        return 0
      fi
      if [[ -z "$clean_result" ]]; then
        printf '  %-10s %12s %9s %8s  transient (1/3), no clean recheck\n' \
          "$rate" "$goodput" "$retransmits" "$loss"
        sleep "$gap"
        continue
      fi
      result="$clean_result"
      sender="$(awk '{print $1}' <<<"$result")"
      retransmits="$(awk '{print $2}' <<<"$result")"
      goodput="$(fc_fit_goodput "$result")"
      loss="$(fc_fit_loss_pct "$retransmits" "$sender" "$duration")"
      verdict='transient (1/3), clean recheck used'
    fi
    if awk -v goodput="$goodput" -v rate="$rate" -v loss="$loss" -v threshold="$threshold" \
      'BEGIN {exit !(goodput<rate*0.7 && loss<=threshold)}'; then
      FC_FIT_SLOW_HITS=$((FC_FIT_SLOW_HITS + 1))
      printf '  %-10s %12s %9s %8s  peer below target\n' "$rate" "$goodput" "$retransmits" "$loss"
      if ((FC_FIT_SLOW_HITS >= 3)); then
        FC_FIT_PEER_SLOW=1
        return 0
      fi
      FC_FIT_LAST_OK="$rate"
      FC_FIT_LAST_GOODPUT="$goodput"
      previous_goodput="$goodput"
      sleep "$gap"
      continue
    else
      FC_FIT_SLOW_HITS=0
    fi
    if [[ "$verdict" == ok ]] && awk -v current="$goodput" -v previous="$previous_goodput" \
      'BEGIN {exit !(previous>0 && current<previous*1.01)}'; then
      verdict='no further gain'
    fi
    printf '  %-10s %12s %9s %8s  %s\n' "$rate" "$goodput" "$retransmits" "$loss" "$verdict"
    FC_FIT_LAST_OK="$rate"
    FC_FIT_LAST_GOODPUT="$goodput"
    previous_goodput="$goodput"
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

fc_fit_result_value() {
  local key="$1"
  [[ -r "$FC_FIT_RESULT" ]] || return 1
  awk -F= -v key="$key" '$1==key {print $2; found=1; exit} END {exit !found}' "$FC_FIT_RESULT"
}

fc_fit_recommendation() {
  local status recommendation
  status="$(fc_fit_result_value STATUS || true)"
  [[ "$status" == fitted ]] || return 1
  recommendation="$(fc_fit_result_value RECOMMEND_MBPS || true)"
  fc_is_uint "$recommendation" && ((recommendation >= 1 && recommendation <= 100000)) || return 1
  printf '%s\n' "$recommendation"
}

fc_fit_summary() {
  [[ -r "$FC_FIT_RESULT" ]] || {
    printf '尚未执行\n'
    return 0
  }
  local status recommendation knee cap unshaped current_total current_per_flow
  status="$(fc_fit_result_value STATUS || true)"
  recommendation="$(fc_fit_result_value RECOMMEND_MBPS || true)"
  knee="$(fc_fit_result_value KNEE_MBPS || true)"
  cap="$(fc_fit_result_value CAP_MBPS || true)"
  unshaped="$(fc_fit_result_value UNSHAPED_MBPS || true)"
  current_total="$(fc_fit_result_value CURRENT_TOTAL_MBPS || true)"
  current_per_flow="$(fc_fit_result_value CURRENT_PER_FLOW_MBPS || true)"
  case "$status" in
    fitted) printf '拐点 %s / 建议 %s Mbps\n' "${knee:-?}" "${recommendation:-?}" ;;
    above-cap)
      printf '链路能力 %s Mbps > 测试上限 %s Mbps / 保留整形 %s/%s Mbps\n' \
        "${unshaped:-?}" "${cap:-?}" "${current_per_flow:-?}" "${current_total:-?}"
      ;;
    *) printf '%s\n' "${status:-unknown}" ;;
  esac
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
  if ! fc_apply_shape >/dev/null 2>&1; then
    fc_warn '无法按 Flowcraft 配置恢复出口 qdisc；请立即运行 ftcp apply。'
    return 1
  fi
}

fc_fit_finish_restore() {
  fc_fit_restore_managed_qdisc || return 1
  trap - EXIT INT TERM HUP
}

fc_fit_command() {
  local peer='' nominal='' port=5201 family=-4 duration=12 gap=3 cap=2500 threshold=0.1
  local low='' high='' step='' parallel=1 refine=1 apply=0 lift_per_flow=0 margin=''
  local port_explicit=0 peer_auto=0 compatibility_mode=0 argument
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
      --duration | --dur)
        [[ $# -ge 2 ]] || fc_die "$argument 缺少值"
        duration="$2"
        shift 2
        ;;
      --gap)
        [[ $# -ge 2 ]] || fc_die '--gap 缺少值'
        gap="$2"
        shift 2
        ;;
      --ceiling | --cap)
        [[ $# -ge 2 ]] || fc_die "$argument 缺少值"
        cap="$2"
        shift 2
        ;;
      --from)
        [[ $# -ge 2 ]] || fc_die '--from 缺少值'
        low="$2"
        shift 2
        ;;
      --to)
        [[ $# -ge 2 ]] || fc_die '--to 缺少值'
        high="$2"
        shift 2
        ;;
      --step)
        [[ $# -ge 2 ]] || fc_die '--step 缺少值'
        step="$2"
        shift 2
        ;;
      --parallel)
        [[ $# -ge 2 ]] || fc_die '--parallel 缺少值'
        parallel="$2"
        shift 2
        ;;
      --no-refine)
        refine=0
        shift
        ;;
      --loss-threshold | --retrans-threshold)
        [[ $# -ge 2 ]] || fc_die "$argument 缺少值"
        threshold="$2"
        shift 2
        ;;
      --margin)
        [[ $# -ge 2 ]] || fc_die '--margin 缺少值'
        margin="$2"
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
        compatibility_mode=1
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
  fc_is_uint "$parallel" && ((parallel >= 1 && parallel <= 128)) || fc_die '--parallel 必须是 1-128 的整数。'
  fc_is_uint "$cap" && ((cap >= 100 && cap <= 100000)) || fc_die '--cap 必须是 100-100000 的整数 Mbps。'
  [[ -z "$margin" ]] || { fc_is_uint "$margin" && ((margin >= 1 && margin <= 100000)); } ||
    fc_die '--margin 必须是 1-100000 的整数 Mbps。'
  if [[ -n "$low" || -n "$high" ]]; then
    [[ -n "$low" && -n "$high" ]] || fc_die '--from 与 --to 必须同时提供。'
    fc_is_uint "$low" && fc_is_uint "$high" && ((low >= 1 && high >= low && high <= cap)) ||
      fc_die '手工扫描范围无效，必须满足 1 <= from <= to <= cap。'
    if [[ -z "$step" ]]; then
      step=$(((high - low + 5) / 10))
      ((step >= 1)) || step=1
    fi
  fi
  [[ -z "$step" ]] || { fc_is_uint "$step" && ((step >= 1 && step <= 100000)); } ||
    fc_die '--step 必须是 1-100000 的整数。'
  if [[ -z "$peer" ]] && ((cap > 2500)); then
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
  ((compatibility_mode == 0)) || fc_warn '--discover 已不再需要；tcpfit sweep 会根据不限速结果自动推导扫描区间。'
  fc_load_config
  [[ "$(fc_read_stage_value STAGE)" == complete ]] || fc_die 'Flowcraft 安装尚未完成；请先运行 ftcp resume。'
  [[ -n "$peer" ]] || peer_auto=1
  local iface mem status recommendation='' knee='' coarse_broke fine fine_start fine_end
  local peer_attempts=0 excluded='' health_error=''
  local unshaped_result='' unshaped_sender='' unshaped_retransmits='' unshaped_receiver=''
  local unshaped_goodput='' unshaped_effective='' unshaped_loss='' cap_streams=1
  local user_range=0 bounds='' derived_step='' prescan_gap="${FC_FIT_PRE_SCAN_GAP:-15}"
  local -a endpoint_fields=()
  [[ -z "$low" ]] || user_range=1
  fc_is_uint "$prescan_gap" && ((prescan_gap <= 60)) || prescan_gap=15
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
    fc_info "开始 tcpfit sweep：${peer}:${port} / 标称 ${nominal} Mbps / cap ${cap} Mbps / ${family#-}"
    FC_FIT_BASE_LOSS=''
    if ! fc_fit_validate_path "$iface" "$peer" "$port" "$family" "$nominal" "$mem"; then
      health_error="$FC_FIT_HEALTH_STATUS"
      fc_warn "对端健康检查未通过：${health_error}（${FC_FIT_HEALTH_RATE} Mbps / goodput ${FC_FIT_HEALTH_GOODPUT:--} / loss ${FC_FIT_HEALTH_LOSS:--}%）。"
      if [[ "$health_error" != shaper-failed ]] && ((peer_auto == 1 && peer_attempts < 3)); then
        excluded+="|${peer}|"
        peer=''
        fc_fit_restore_managed_qdisc || fc_die '恢复出口 qdisc 失败。'
        fc_warn '自动换下一个公共节点重新验证。'
        continue
      fi
      fc_fit_restore_managed_qdisc || fc_die '恢复出口 qdisc 失败。'
      fc_fit_store_result "STATUS=$health_error" "HEALTH_RATE_MBPS=$FC_FIT_HEALTH_RATE" \
        "HEALTH_GOODPUT_MBPS=$FC_FIT_HEALTH_GOODPUT" "HEALTH_LOSS_PCT=$FC_FIT_HEALTH_LOSS" \
        "${endpoint_fields[@]}" "NOMINAL_MBPS=$nominal" "CAP_MBPS=$cap"
      fc_warn '路径或对端不适合拟合；未修改持久配置。'
      return 0
    fi
    printf '  %-10s %12s %9s %8s  %s\n' Rate Goodput Retrans Loss% Verdict
    printf '  %-10s %12s %9s %8s  %s\n' "$FC_FIT_HEALTH_RATE" "$FC_FIT_HEALTH_GOODPUT" - "$FC_FIT_HEALTH_LOSS" health

    if ((user_range == 0)); then
      fc_info "不限速 fq 单流探测：${duration}s / cap ${cap} Mbps"
      fc_fit_apply_unshaped_fq "$iface" || fc_die '无法应用不限速 fq 测试队列。'
      unshaped_result="$(fc_fit_measure "$peer" "$port" "$duration" 1 "$family" || true)"
      fc_fit_restore_managed_qdisc || fc_die '恢复出口 qdisc 失败。'
      if [[ -z "$unshaped_result" ]]; then
        if ((peer_auto == 1 && peer_attempts < 3)); then
          excluded+="|${peer}|"
          peer=''
          fc_warn '不限速探测失败，自动更换公共节点。'
          continue
        fi
        fc_fit_store_result 'STATUS=measurement-failed' "${endpoint_fields[@]}" \
          "NOMINAL_MBPS=$nominal" "CAP_MBPS=$cap"
        fc_warn '不限速探测失败；未修改持久配置。'
        return 0
      fi
      unshaped_sender="$(awk '{print $1}' <<<"$unshaped_result")"
      unshaped_retransmits="$(awk '{print $2}' <<<"$unshaped_result")"
      unshaped_receiver="$(awk '{print $3}' <<<"$unshaped_result")"
      unshaped_goodput="$(fc_fit_goodput "$unshaped_result")"
      unshaped_loss="$(fc_fit_loss_pct "$unshaped_retransmits" "$unshaped_sender" "$duration")"
      if ((nominal <= cap)) && awk -v goodput="$unshaped_goodput" -v nominal="$nominal" \
        'BEGIN {exit !(goodput<nominal*0.7)}'; then
        local best_result="$unshaped_result" best_goodput="$unshaped_goodput" sample result_goodput
        local result sender retransmits loss
        fc_info "单流仅送达 ${unshaped_goodput} Mbps（低于标称值 70%）；再取两次样本并采用最佳整组结果。"
        fc_fit_apply_unshaped_fq "$iface" || fc_die '无法应用不限速 fq 测试队列。'
        printf '  %-10s %12s %9s %8s  %s\n' 'none (#1)' "$unshaped_goodput" \
          "$unshaped_retransmits" "$unshaped_loss" sample
        for sample in 2 3; do
          sleep "$gap"
          result="$(fc_fit_measure "$peer" "$port" "$duration" 1 "$family" || true)"
          if [[ -z "$result" ]]; then
            printf '  %-10s %12s %9s %8s  %s\n' "none (#${sample})" - - - 'peer busy, skipped'
            continue
          fi
          sender="$(awk '{print $1}' <<<"$result")"
          retransmits="$(awk '{print $2}' <<<"$result")"
          result_goodput="$(fc_fit_goodput "$result")"
          loss="$(fc_fit_loss_pct "$retransmits" "$sender" "$duration")"
          printf '  %-10s %12s %9s %8s  %s\n' "none (#${sample})" "$result_goodput" \
            "$retransmits" "$loss" sample
          if awk -v current="$result_goodput" -v best="$best_goodput" 'BEGIN {exit !(current>best)}'; then
            best_result="$result"
            best_goodput="$result_goodput"
          fi
        done
        unshaped_result="$best_result"
        unshaped_sender="$(awk '{print $1}' <<<"$unshaped_result")"
        unshaped_retransmits="$(awk '{print $2}' <<<"$unshaped_result")"
        unshaped_receiver="$(awk '{print $3}' <<<"$unshaped_result")"
        unshaped_goodput="$(fc_fit_goodput "$unshaped_result")"
        unshaped_loss="$(fc_fit_loss_pct "$unshaped_retransmits" "$unshaped_sender" "$duration")"
        fc_fit_restore_managed_qdisc || fc_die '恢复出口 qdisc 失败。'
        fc_info "采用最佳单流样本：${unshaped_goodput} Mbps。"
      fi
      printf '  %-10s %12s %9s %8s  %s\n' none "$unshaped_goodput" "$unshaped_retransmits" "$unshaped_loss" baseline
      if ((nominal > cap)) && awk -v goodput="$unshaped_goodput" -v cap="$cap" -v loss="$unshaped_loss" \
        -v threshold="$threshold" 'BEGIN {exit !(goodput<=cap && loss>threshold)}'; then
        local aggregate_result aggregate_sender aggregate_retransmits aggregate_goodput aggregate_loss
        fc_info "标称 ${nominal} Mbps 高于 cap，单流结果无法定性；用 8 流聚合探测反证。"
        fc_fit_apply_unshaped_fq "$iface" || fc_die '无法应用不限速 fq 测试队列。'
        aggregate_result="$(fc_fit_measure "$peer" "$port" "$duration" 8 "$family" || true)"
        fc_fit_restore_managed_qdisc || fc_die '恢复出口 qdisc 失败。'
        if [[ -n "$aggregate_result" ]]; then
          aggregate_sender="$(awk '{print $1}' <<<"$aggregate_result")"
          aggregate_retransmits="$(awk '{print $2}' <<<"$aggregate_result")"
          aggregate_goodput="$(fc_fit_goodput "$aggregate_result")"
          aggregate_loss="$(fc_fit_loss_pct "$aggregate_retransmits" "$aggregate_sender" "$duration")"
          printf '  %-10s %12s %9s %8s  %s\n' 'none (8x)' "$aggregate_goodput" \
            "$aggregate_retransmits" "$aggregate_loss" aggregate
          if awk -v goodput="$aggregate_goodput" -v cap="$cap" 'BEGIN {exit !(goodput>cap)}'; then
            unshaped_goodput="$aggregate_goodput"
            cap_streams=8
          fi
        fi
      fi
      if awk -v goodput="$unshaped_goodput" -v cap="$cap" 'BEGIN {exit !(goodput>cap)}'; then
        fc_fit_finish_restore || fc_die '恢复出口 qdisc 失败。'
        fc_fit_store_result 'STATUS=above-cap' "UNSHAPED_MBPS=$unshaped_goodput" \
          "UNSHAPED_LOSS_PCT=$unshaped_loss" "${endpoint_fields[@]}" \
          "NOMINAL_MBPS=$nominal" "CAP_MBPS=$cap" "CAP_STREAMS=$cap_streams" \
          "CURRENT_PER_FLOW_MBPS=$PER_FLOW_MBPS" "CURRENT_TOTAL_MBPS=$TOTAL_MBPS" \
          'CONFIG_UNCHANGED=1'
        if ((peer_auto == 1)); then
          fc_log "链路 ${cap_streams} 流能力至少 ${unshaped_goodput} Mbps，高于 ${cap} Mbps 公共安全测试范围。"
          fc_info "当前 ${PER_FLOW_MBPS}/${TOTAL_MBPS} Mbps 是 Flowcraft 整形策略，不是本次测得的物理拐点；已完整保留。"
          fc_info '如需寻找更高拐点，请指定自有/独享 iperf3 对端并在菜单设置更高扫描上限。'
        else
          fc_log "链路 ${cap_streams} 流能力至少 ${unshaped_goodput} Mbps，高于本次 ${cap} Mbps 测试上限。"
          fc_info "未在指定范围内找到可应用的 policer 拐点；已保留 ${PER_FLOW_MBPS}/${TOTAL_MBPS} Mbps 整形配置。"
        fi
        if awk -v loss="$unshaped_loss" -v threshold="$threshold" 'BEGIN {exit !(loss>threshold)}'; then
          fc_info "${unshaped_loss}% 丢包发生在 ${unshaped_goodput} Mbps 高速样本，不能据此推导 ${cap} Mbps 以内的 policer 拐点。"
        fi
        return 0
      fi
      if ! awk -v loss="$unshaped_loss" -v threshold="$threshold" 'BEGIN {exit !(loss>threshold)}'; then
        fc_fit_finish_restore || fc_die '恢复出口 qdisc 失败。'
        fc_fit_store_result 'STATUS=no-knee' "UNSHAPED_MBPS=$unshaped_goodput" \
          "UNSHAPED_LOSS_PCT=$unshaped_loss" "${endpoint_fields[@]}" \
          "NOMINAL_MBPS=$nominal" "CAP_MBPS=$cap"
        fc_log "不限速单流送达 ${unshaped_goodput} Mbps，丢包 ${unshaped_loss}%；未检测到 policer，不应用整形。"
        return 0
      fi
      unshaped_effective="$unshaped_receiver"
      [[ -n "$unshaped_effective" ]] || unshaped_effective="$(awk -v sender="$unshaped_sender" -v loss="$unshaped_loss" 'BEGIN {
        value=sender*(1-loss/100); if (value<1) value=1; printf "%.1f", value
      }')"
      bounds="$(fc_fit_scan_bounds "$unshaped_effective" "$unshaped_loss" "$cap")"
      IFS=' ' read -r low high derived_step <<<"$bounds"
      [[ -n "$step" ]] || step="$derived_step"
      fc_info "不限速存在高丢包；按送达量自动扫描 ${low}-${high} Mbps，步长 ${step} Mbps。"
      ((prescan_gap == 0)) || {
        fc_info "首档扫描前静置 ${prescan_gap}s。"
        sleep "$prescan_gap"
      }
    fi
    break
  done

  FC_FIT_LAST_OK=''
  FC_FIT_LAST_GOODPUT=''
  FC_FIT_BROKE_AT=''
  FC_FIT_BREAK_REASON=''
  FC_FIT_BASE_LOSS=''
  FC_FIT_SPIKE_MIN_LOSS=''
  FC_FIT_SLOW_HITS=0
  FC_FIT_PEER_SLOW=0
  fc_info "扫描 ${low}-${high} Mbps，步长 ${step} Mbps，丢包阈值 ${threshold}%。"
  printf '  %-10s %12s %9s %8s  %s\n' Rate Goodput Retrans Loss% Verdict
  fc_fit_scan_range "$iface" "$peer" "$port" "$family" "$duration" "$gap" "$threshold" \
    "$low" "$high" "$step" "$mem" "$cap" "$parallel" || {
    fc_fit_finish_restore || true
    fc_die '扫描期间无法应用测试 qdisc。'
  }

  if ((user_range == 0)) && [[ -z "$FC_FIT_LAST_OK" && -n "$FC_FIT_BROKE_AT" ]]; then
    local known_broke="$FC_FIT_BROKE_AT" known_loss="$FC_FIT_SPIKE_MIN_LOSS"
    local control control_loss control_attempts=0
    while ((control_attempts < 3)) && [[ -z "$FC_FIT_LAST_OK" ]]; do
      control_attempts=$((control_attempts + 1))
      control=$((known_broke * 3 / 4))
      ((control >= 1)) || control=1
      ((control < known_broke)) || break
      fc_info "首档持续丢包；向下测试 ${control} Mbps 控制点。"
      FC_FIT_LAST_OK=''
      FC_FIT_BROKE_AT=''
      FC_FIT_BASE_LOSS=''
      FC_FIT_SPIKE_MIN_LOSS=''
      fc_fit_scan_range "$iface" "$peer" "$port" "$family" "$duration" "$gap" "$threshold" \
        "$control" "$control" 1 "$mem" "$cap" "$parallel" || {
        fc_fit_finish_restore || true
        fc_die '控制点测试失败。'
      }
      if [[ -n "$FC_FIT_LAST_OK" ]]; then
        FC_FIT_BROKE_AT="$known_broke"
        FC_FIT_BREAK_REASON='loss-spike'
        break
      fi
      control_loss="$FC_FIT_SPIKE_MIN_LOSS"
      if [[ -n "$control_loss" && -n "$known_loss" ]] &&
        awk -v a="$control_loss" -v b="$known_loss" 'BEGIN {
          difference=a-b; if (difference<0) difference=-difference
          exit !(a<=0.5 && b<=0.5 && difference<=0.1)
        }'; then
        FC_FIT_BASE_LOSS="$(awk -v a="$control_loss" -v b="$known_loss" 'BEGIN {print (a<b?a:b)}')"
        FC_FIT_LAST_OK="$control"
        FC_FIT_BROKE_AT=''
        fc_info "确认稳定路径底噪 ${FC_FIT_BASE_LOSS}%；从原首档继续扫描。"
        fc_fit_scan_range "$iface" "$peer" "$port" "$family" "$duration" "$gap" "$threshold" \
          "$known_broke" "$high" "$step" "$mem" "$cap" "$parallel" || {
          fc_fit_finish_restore || true
          fc_die '底噪控制扫描失败。'
        }
        break
      fi
      [[ -n "$control_loss" ]] || break
      known_broke="$control"
      known_loss="$control_loss"
    done
  fi

  if ((FC_FIT_PEER_SLOW == 1)); then
    status='peer-too-slow'
    fc_fit_finish_restore || fc_die '恢复出口 qdisc 失败。'
    fc_fit_store_result "STATUS=$status" "SCANNED_TO_MBPS=$FC_FIT_LAST_OK" \
      "LAST_GOODPUT_MBPS=$FC_FIT_LAST_GOODPUT" \
      "${endpoint_fields[@]}" "NOMINAL_MBPS=$nominal" "CAP_MBPS=$cap"
    fc_warn '测速对端连续三档达不到目标速率；未修改持久配置。'
    return 0
  fi

  if ((refine == 1)) && [[ -n "$FC_FIT_LAST_OK" && -n "$FC_FIT_BROKE_AT" ]] &&
    ((FC_FIT_BROKE_AT - FC_FIT_LAST_OK > 1)); then
    coarse_broke="$FC_FIT_BROKE_AT"
    fine=$((step / 4))
    ((fine >= 1)) || fine=1
    ((fine * 2 < coarse_broke - FC_FIT_LAST_OK)) || fine=1
    fine_start=$((FC_FIT_LAST_OK + fine))
    fine_end=$((coarse_broke - fine))
    fc_info "拐点位于 ${FC_FIT_LAST_OK}-${coarse_broke} Mbps，以 ${fine} Mbps 步长细扫。"
    FC_FIT_BROKE_AT=''
    FC_FIT_BREAK_REASON=''
    fc_fit_scan_range "$iface" "$peer" "$port" "$family" "$duration" "$gap" "$threshold" \
      "$fine_start" "$fine_end" "$fine" "$mem" "$cap" "$parallel" || {
      fc_fit_finish_restore || true
      fc_die '细扫期间无法应用测试 qdisc。'
    }
    if [[ -z "$FC_FIT_BROKE_AT" ]]; then
      FC_FIT_BROKE_AT="$coarse_broke"
      FC_FIT_BREAK_REASON='loss-spike'
    fi
  fi

  fc_fit_finish_restore || fc_die '恢复出口 qdisc 失败。'
  if [[ -z "$FC_FIT_LAST_OK" ]]; then
    fc_fit_store_result 'STATUS=measurement-failed' "${endpoint_fields[@]}" \
      "NOMINAL_MBPS=$nominal" "CAP_MBPS=$cap"
    fc_warn '没有测得可用干净档位；未修改持久配置。'
    return 0
  fi
  if [[ -z "$FC_FIT_BROKE_AT" ]]; then
    status=no-knee
    ((user_range == 1)) || status=out-of-range
    fc_fit_store_result "STATUS=$status" "SCANNED_TO_MBPS=$FC_FIT_LAST_OK" \
      "LAST_GOODPUT_MBPS=$FC_FIT_LAST_GOODPUT" "UNSHAPED_MBPS=$unshaped_goodput" \
      "UNSHAPED_LOSS_PCT=$unshaped_loss" "${endpoint_fields[@]}" \
      "NOMINAL_MBPS=$nominal" "CAP_MBPS=$cap"
    fc_warn "扫到 ${FC_FIT_LAST_OK} Mbps 仍未出现丢包跳变；不应用整形。"
    return 0
  fi
  knee="$FC_FIT_LAST_OK"
  [[ -n "$margin" ]] || margin="$(fc_fit_margin "$knee")"
  recommendation=$((knee - margin))
  ((recommendation >= 1)) || recommendation="$knee"
  status=fitted
  fc_fit_store_result 'STATUS=fitted' "KNEE_MBPS=$knee" "MARGIN_MBPS=$margin" "RECOMMEND_MBPS=$recommendation" \
    "BREAK_REASON=$FC_FIT_BREAK_REASON" "LAST_GOODPUT_MBPS=$FC_FIT_LAST_GOODPUT" \
    "UNSHAPED_MBPS=$unshaped_goodput" "UNSHAPED_LOSS_PCT=$unshaped_loss" \
    "${endpoint_fields[@]}" "NOMINAL_MBPS=$nominal" "CAP_MBPS=$cap" \
    "SCAN_FROM_MBPS=$low" "SCAN_TO_MBPS=$high" "SCAN_STEP_MBPS=$step" \
    "LOSS_THRESHOLD_PCT=$threshold"
  fc_log "实测干净上限 ${knee} Mbps，触发 ${FC_FIT_BREAK_REASON}，安全余量 ${margin} Mbps，建议整形 ${recommendation} Mbps。"
  if ((apply == 1)); then
    fc_fit_apply_result "$status" "$recommendation" "$lift_per_flow"
    fc_log '拟合结果已写入 Flowcraft 配置并应用。'
  else
    fc_info "只保存测量结果；应用时重跑并加 --apply。结果：$FC_FIT_RESULT"
  fi
}

#!/usr/bin/env bash

fc_fit_probe() {
  fc_need_root
  local peer='' port=5201 duration=8 temp parsed result_temp
  while (($#)); do
    case "$1" in
      --peer) [[ $# -ge 2 ]] || fc_die '--peer 缺少值。'; peer="$2"; shift 2 ;;
      --port) [[ $# -ge 2 ]] || fc_die '--port 缺少值。'; port="$2"; shift 2 ;;
      --duration) [[ $# -ge 2 ]] || fc_die '--duration 缺少值。'; duration="$2"; shift 2 ;;
      *) fc_die "未知 fit 参数：$1" ;;
    esac
  done
  [[ "$peer" =~ ^[a-zA-Z0-9_.:%-]+$ ]] || fc_die '必须提供有效 --peer。'
  if ! fc_is_uint "$port" || (( port < 1 || port > 65535 )); then fc_die '端口必须是 1-65535。'; fi
  if ! fc_is_uint "$duration" || (( duration < 3 || duration > 60 )); then fc_die '时长必须是 3-60 秒。'; fi
  fc_has iperf3 || fc_die 'fit probe 需要 iperf3。'
  fc_has python3 || fc_die 'fit probe 需要 Python 3 标准库解析 iperf3 JSON。'
  fc_take_lock
  temp="$(mktemp /tmp/flowcraft-iperf.XXXXXX)"
  if ! iperf3 -4 -c "$peer" -p "$port" -t "$duration" -P 1 -J >"$temp"; then
    rm -f "$temp"
    fc_die 'iperf3 测量失败；未修改网络配置。'
  fi
  parsed="$(python3 - "$temp" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    data = json.load(source)
end = data.get("end", {})
sent = end.get("sum_sent", {})
received = end.get("sum_received", {})
mbps = float(received.get("bits_per_second", 0)) / 1_000_000
retransmits = int(sent.get("retransmits", 0))
seconds = float(received.get("seconds", 0))
print(f"GOODPUT_MBPS={mbps:.2f}")
print(f"RETRANSMITS={retransmits}")
print(f"SECONDS={seconds:.2f}")
PY
)"
  rm -f "$temp"
  mkdir -p "$FC_STATE_DIR"
  result_temp="$(mktemp "$FC_STATE_DIR/.fit-result.XXXXXX")"
  {
    printf 'STATUS=probe\nPEER=%s\nPORT=%s\n' "$peer" "$port"
    printf '%s\n' "$parsed"
    printf 'MEASURED_AT=%s\n' "$(date -u +%FT%TZ)"
    printf 'IFACE=%s\n' "$(fc_detect_iface)"
  } >"$result_temp"
  fc_atomic_replace "$result_temp" "$FC_FIT_RESULT" 0600
  printf 'FlowCraft fit probe\n  %s\n' "${parsed//$'\n'/$'\n  '}"
  fc_info 'probe 只记录测量结果，不会自动修改 sysctl 或 qdisc。'
}

#!/usr/bin/env bash

fc_mon_once() {
  local iface
  iface="$(fc_detect_iface)"
  printf 'FlowCraft monitor  %s\n' "$(date '+%F %T')"
  printf '  interface: %s\n' "${iface:-unknown}"
  if fc_has nstat; then
    nstat -az 2>/dev/null | awk '$1 ~ /^(TcpRetransSegs|TcpExtTCPTimeouts|TcpExtListenDrops|IpOutDiscards)$/ {printf "  %-24s %s\n", $1, $2}'
  else
    awk '/^Tcp:/ {if (++n == 2) printf "  TcpOutSegs/ Retrans: %s / %s\n", $12, $13}' /proc/net/snmp 2>/dev/null || true
  fi
  if [[ -n "$iface" ]] && fc_has tc; then
    tc -s qdisc show dev "$iface" 2>/dev/null | sed 's/^/  /'
  fi
}

fc_mon() {
  local interval=''
  if [[ ${1:-} == --watch ]]; then interval="${2:-2}"; fi
  if [[ -z "$interval" ]]; then fc_mon_once; return 0; fi
  if ! fc_is_uint "$interval" || (( interval < 1 || interval > 60 )); then fc_die 'watch 间隔必须是 1-60 秒。'; fi
  while true; do
    fc_mon_once
    sleep "$interval"
  done
}

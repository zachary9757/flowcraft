#!/usr/bin/env bash

fc_route_field() {
  local wanted="$1" route="${2:-}" previous='' token
  local IFS=$' \t\n'
  [[ -n "$route" ]] || route="$(ip -4 route show default 2>/dev/null | head -n 1)"
  for token in $route; do
    [[ "$previous" == "$wanted" ]] && { printf '%s\n' "$token"; return 0; }
    previous="$token"
  done
  return 1
}

fc_default_route_count() {
  fc_has ip || { printf '0\n'; return 0; }
  local routes
  routes="$(ip -4 route show default 2>/dev/null || true)"
  [[ -n "$routes" ]] || routes="$(ip -6 route show default 2>/dev/null || true)"
  awk 'NF {n++} END {print n+0}' <<<"$routes"
}

fc_route_has_multiple_nexthops() {
  local route="$1" count
  count="$(awk '{for (i=1; i<=NF; i++) if ($i == "nexthop") n++} END {print n+0}' <<<"$route")"
  (( count > 1 ))
}

fc_selected_default_routes() {
  local routes
  fc_has ip || return 0
  routes="$(ip -4 route show default 2>/dev/null || true)"
  [[ -n "$routes" ]] || routes="$(ip -6 route show default 2>/dev/null || true)"
  printf '%s\n' "$routes"
}

fc_detect_iface() {
  local iface
  iface="$(fc_route_field dev 2>/dev/null || true)"
  if [[ -z "$iface" ]]; then
    iface="$(fc_route_field dev "$(ip -6 route show default 2>/dev/null | head -n 1)" || true)"
  fi
  printf '%s\n' "$iface"
}

fc_resolve_iface() {
  local iface="${IFACE:-auto}"
  [[ "$iface" == auto ]] && iface="$(fc_detect_iface)"
  [[ -n "$iface" ]] || fc_die '无法确定默认出口接口。'
  [[ -d "/sys/class/net/$iface" || ${FLOWCRAFT_ALLOW_FAKE_IFACE:-0} == 1 ]] || fc_die "接口不存在：$iface"
  printf '%s\n' "$iface"
}

fc_root_qdisc() {
  local iface="$1" output
  output="$(tc qdisc show dev "$iface" 2>/dev/null)" || return 1
  awk '$1 == "qdisc" && $0 ~ / root / {print $2; exit}' <<<"$output"
}

fc_managed_sysctl_pattern() {
  printf '%s' 'net\.core\.(default_qdisc|rmem_max|wmem_max|somaxconn|netdev_max_backlog)|net\.ipv4\.(tcp_congestion_control|tcp_rmem|tcp_wmem|tcp_moderate_rcvbuf|tcp_window_scaling|tcp_slow_start_after_idle|tcp_mtu_probing|tcp_fastopen)'
}

fc_find_conflicts() {
  local root="${FLOWCRAFT_ROOT_PREFIX:-}" path pattern directory
  pattern="$(fc_managed_sysctl_pattern)"
  path="$root/etc/sysctl.conf"
  if [[ -r "$path" ]] && grep -Eq "^[[:space:]]*(${pattern})[[:space:]]*=" "$path" 2>/dev/null; then
    printf '%s\n' "$path"
  fi
  for directory in /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d; do
    [[ -d "$root$directory" ]] || continue
    while IFS= read -r path; do
      [[ "$path" == "$root$FC_SYSCTL_FILE" || "$path" == "$FC_SYSCTL_FILE" ]] && continue
      grep -Eq "^[[:space:]]*(${pattern})[[:space:]]*=" "$path" 2>/dev/null && printf '%s\n' "$path"
    done < <(find -L "$root$directory" -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null | sort)
  done
  return 0
}

fc_assert_supported_route() {
  local count routes
  count="$(fc_default_route_count)"
  (( count == 1 )) || fc_die "需要唯一默认路由，当前检测到 ${count} 条。"
  routes="$(fc_selected_default_routes)"
  if fc_route_has_multiple_nexthops "$routes"; then
    fc_die '默认路由包含多个 nexthop，拒绝自动选择出口接口。'
  fi
  return 0
}

fc_assert_no_conflicts() {
  local conflicts
  conflicts="$(fc_find_conflicts)"
  [[ -z "$conflicts" ]] || fc_die "发现其他 sysctl owner：${conflicts//$'\n'/, }"
}

fc_assert_qdisc_takeover_safe() {
  local iface="$1" kind owner_iface='' managed_kind=''
  kind="$(fc_root_qdisc "$iface")"
  if [[ -e "$FC_MANAGED_STATE" ]]; then
    fc_managed_state_load || fc_die '托管状态无效，拒绝接管 qdisc。'
    owner_iface="$FC_MANAGED_IFACE"
    managed_kind="$FC_MANAGED_QDISC"
    if [[ "$owner_iface" == "$iface" && "$kind" == "$managed_kind" ]]; then
      return 0
    fi
    fc_die '当前 qdisc 与托管状态不一致，拒绝覆盖。'
  fi
  case "${kind:-none}" in
    none|noqueue) ;;
    *) fc_die "拒绝接管复杂 root qdisc：$kind" ;;
  esac
}

fc_inspect() {
  fc_config_load
  local iface cc qdisc conflicts route_count
  iface="$(fc_detect_iface)"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)"
  qdisc=unknown
  [[ -z "$iface" ]] || qdisc="$(fc_root_qdisc "$iface" || printf unknown)"
  conflicts="$(fc_find_conflicts)"
  route_count="$(fc_default_route_count 2>/dev/null || printf 0)"
  if [[ ${1:-} == --json ]]; then
    printf '{"kernel":"%s","iface":"%s","route_count":%s,"cc":"%s","qdisc":"%s","conflicts":%s}\n' \
      "$(uname -r)" "$iface" "$route_count" "$cc" "${qdisc:-none}" "$([[ -n "$conflicts" ]] && printf true || printf false)"
    return 0
  fi
  printf 'FlowCraft inspect\n'
  printf '  kernel:       %s\n' "$(uname -r)"
  printf '  interface:    %s\n' "${iface:-unknown}"
  printf '  default route:%s\n' " $route_count"
  printf '  cc/qdisc:     %s / %s\n' "$cc" "${qdisc:-none}"
  printf '  BBR module:   %s\n' "$( (modinfo tcp_bbr 2>/dev/null || true) | awk '/^version:/ {print $2; found=1} END {if (!found) print "not-versioned"}')"
  if [[ -n "$conflicts" ]]; then
    printf '  conflicts:\n    %s\n' "${conflicts//$'\n'/$'\n    '}"
  else
    printf '  conflicts:    none\n'
  fi
}

#!/usr/bin/env bash

FC_TUNED_KEYS='vm.swappiness
vm.min_free_kbytes
kernel.panic
net.core.default_qdisc
net.ipv4.tcp_congestion_control
net.core.somaxconn
net.core.netdev_max_backlog
net.core.netdev_budget
net.core.netdev_budget_usecs
net.core.rmem_default
net.core.wmem_default
net.core.rmem_max
net.core.wmem_max
net.core.optmem_max
net.core.rps_sock_flow_entries
net.ipv4.tcp_max_syn_backlog
net.ipv4.tcp_syncookies
net.ipv4.tcp_window_scaling
net.ipv4.tcp_sack
net.ipv4.tcp_dsack
net.ipv4.tcp_timestamps
net.ipv4.tcp_no_metrics_save
net.ipv4.tcp_moderate_rcvbuf
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
net.ipv4.tcp_mem
net.ipv4.tcp_adv_win_scale
net.ipv4.tcp_notsent_lowat
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_ecn
net.ipv4.tcp_frto
net.ipv4.tcp_fastopen
net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_tw_reuse
net.ipv4.tcp_fin_timeout
net.ipv4.tcp_keepalive_time
net.ipv4.tcp_keepalive_intvl
net.ipv4.tcp_keepalive_probes
net.ipv4.udp_rmem_min
net.ipv4.udp_wmem_min
net.ipv4.ip_local_port_range
net.ipv4.tcp_max_tw_buckets
fs.file-max
net.netfilter.nf_conntrack_max'

fc_sysctl_proc_path() {
  local root="${FLOWCRAFT_PROC_ROOT:-/proc/sys}"
  printf '%s/%s\n' "$root" "$(printf '%s' "$1" | tr '.' '/')"
}

fc_tcp_mem_values() {
  local mem="$1"
  awk -v m="$mem" 'BEGIN {
    pages=m*1024/4
    low=int(pages/16); pressure=int(pages/8); high=int(pages/4)
    if (low<4096) low=4096
    if (pressure<8192) pressure=8192
    if (high<16384) high=16384
    printf "%d %d %d\n", low, pressure, high
  }'
}

fc_buffer_cap() {
  local mem="$1" cap
  cap=$((mem * 32768))
  ((cap > 268435456)) && cap=268435456
  printf '%s\n' "$cap"
}

fc_tcp_max() {
  local rate="$1" rtt="$2" mem="$3" target cap
  target=$((rate * rtt * 125 * 2 + 2097152))
  cap="$(fc_buffer_cap "$mem")"
  ((target > cap)) && target="$cap"
  ((target < 4194304)) && target=4194304
  printf '%s\n' "$target"
}

fc_recv_rtt() {
  if [[ "$ROLE" == landing ]] && ((ORIGIN_RTT_MS > RTT_MS)); then
    printf '%s\n' "$ORIGIN_RTT_MS"
  else
    printf '%s\n' "$RTT_MS"
  fi
}

fc_htb_burst_kb() {
  local rate="$1" mode="${2:-policer}" burst
  if [[ "$mode" == throughput ]]; then
    burst=$(((rate * 1250 + 1023) / 1024))
    ((burst < 64)) && burst=64
    ((burst > 2048)) && burst=2048
  else
    burst=$(((rate * 500 + 1023) / 1024))
    ((burst < 32)) && burst=32
  fi
  printf '%s\n' "$burst"
}

fc_fq_limits() {
  local mem="$1"
  if ((mem < 1024)); then printf '10240 2048\n'; else printf '40960 8192\n'; fi
}

fc_choose_cc() {
  local available=''
  fc_has modprobe && modprobe tcp_bbr >/dev/null 2>&1 || true
  [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] &&
    available="$(</proc/sys/net/ipv4/tcp_available_congestion_control)"
  if [[ " $available " == *' bbr '* ]]; then
    printf 'bbr\n'
  elif [[ " $available " == *' cubic '* ]]; then
    printf 'cubic\n'
  else
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'cubic\n'
  fi
}

fc_append_sysctl() {
  local file="$1" key="$2" value="$3"
  if [[ -e "$(fc_sysctl_proc_path "$key")" ]]; then
    printf '%s = %s\n' "$key" "$value" >>"$file"
  else
    fc_warn "当前内核不支持 ${key}，已跳过。"
  fi
}

fc_take_sysctl_snapshot() {
  [[ -e "$FC_SYSCTL_SNAPSHOT" ]] && return 0
  ((FC_DRY_RUN == 0)) || return 0
  local key value
  mkdir -p "$FC_STATE_DIR"
  {
    printf '# Flowcraft pre-tune sysctl snapshot\n'
    while IFS= read -r key; do
      [[ -n "$key" && -e "$(fc_sysctl_proc_path "$key")" ]] || continue
      value="$(sysctl -n "$key" 2>/dev/null)" || continue
      printf '%s=%s\n' "$key" "$value"
    done <<<"$FC_TUNED_KEYS"
  } >"$FC_SYSCTL_SNAPSHOT"
  chmod 0600 "$FC_SYSCTL_SNAPSHOT"
}

fc_restore_sysctl_snapshot() {
  local key value restored=0
  [[ -r "$FC_SYSCTL_SNAPSHOT" ]] || {
    fc_warn "找不到 sysctl 快照。"
    return 0
  }
  while IFS='=' read -r key value; do
    [[ -n "$key" && "$key" != \#* && -n "$value" ]] || continue
    fc_run sysctl -qw "$key=$value" >/dev/null 2>&1 && restored=$((restored + 1)) || true
  done <"$FC_SYSCTL_SNAPSHOT"
  fc_log "已恢复 ${restored} 项安装前 sysctl。"
}

fc_write_sysctl_profile() {
  fc_need_root
  fc_take_lock
  fc_load_config
  fc_take_sysctl_snapshot
  if [[ "$TUNING_PROFILE" == extreme ]]; then
    fc_write_extreme_sysctl_profile
    return 0
  fi
  local mem recv_rtt reference_rate rmax wmax backlog min_free tcp_mem
  local somax syn_backlog port_range tw_buckets file_max conntrack cc temp
  mem="$(fc_mem_mb)"
  ((mem > 0)) || mem=1024
  recv_rtt="$(fc_recv_rtt)"
  reference_rate="$PER_FLOW_MBPS"
  [[ "$ROLE" == landing && "$TOTAL_MBPS" -gt 0 ]] && reference_rate="$TOTAL_MBPS"
  if [[ "$ROLE" == general ]]; then
    if ((TOTAL_MBPS > 0)); then reference_rate="$TOTAL_MBPS"; else reference_rate=1000; fi
  fi
  rmax="$(fc_tcp_max "$reference_rate" "$recv_rtt" "$mem")"
  wmax="$(fc_tcp_max "$reference_rate" "$RTT_MS" "$mem")"
  tcp_mem="$(fc_tcp_mem_values "$mem")"
  if ((mem < 1024)); then
    backlog=4096
    min_free=32768
  else
    backlog=16384
    min_free=65536
  fi
  case "$ROLE" in
    landing)
      somax=8192
      syn_backlog=8192
      port_range='10240 65535'
      if ((mem < 1024)); then
        tw_buckets=65536
        file_max=262144
        conntrack=131072
      else
        tw_buckets=262144
        file_max=1048576
        conntrack=524288
      fi
      ;;
    relay)
      somax=2048
      syn_backlog=2048
      port_range='32768 60999'
      tw_buckets=32768
      file_max=262144
      conntrack=65536
      ;;
    *)
      somax=4096
      syn_backlog=4096
      port_range='32768 60999'
      tw_buckets=65536
      file_max=524288
      conntrack=131072
      ;;
  esac
  cc="$(fc_choose_cc)"
  temp="$(mktemp /tmp/flowcraft-sysctl.XXXXXX)"
  {
    printf '# Generated by Flowcraft %s; do not hand edit.\n' "$FLOWCRAFT_VERSION"
    printf '# role=%s rate=%s total=%s rtt=%s recv-rtt=%s ram=%s\n\n' \
      "$ROLE" "$PER_FLOW_MBPS" "$TOTAL_MBPS" "$RTT_MS" "$recv_rtt" "$mem"
  } >"$temp"
  fc_append_sysctl "$temp" vm.swappiness 10
  fc_append_sysctl "$temp" vm.min_free_kbytes "$min_free"
  fc_append_sysctl "$temp" kernel.panic 10
  fc_append_sysctl "$temp" net.core.default_qdisc fq
  fc_append_sysctl "$temp" net.ipv4.tcp_congestion_control "$cc"
  fc_append_sysctl "$temp" net.core.somaxconn "$somax"
  fc_append_sysctl "$temp" net.core.netdev_max_backlog "$backlog"
  fc_append_sysctl "$temp" net.core.netdev_budget 600
  fc_append_sysctl "$temp" net.core.netdev_budget_usecs 4000
  fc_append_sysctl "$temp" net.ipv4.tcp_max_syn_backlog "$syn_backlog"
  fc_append_sysctl "$temp" net.ipv4.tcp_syncookies 1
  fc_append_sysctl "$temp" net.ipv4.tcp_window_scaling 1
  fc_append_sysctl "$temp" net.ipv4.tcp_sack 1
  fc_append_sysctl "$temp" net.ipv4.tcp_dsack 1
  fc_append_sysctl "$temp" net.ipv4.tcp_timestamps 1
  fc_append_sysctl "$temp" net.ipv4.tcp_no_metrics_save 0
  fc_append_sysctl "$temp" net.ipv4.tcp_moderate_rcvbuf 1
  fc_append_sysctl "$temp" net.core.rmem_default 1048576
  fc_append_sysctl "$temp" net.core.wmem_default 1048576
  fc_append_sysctl "$temp" net.core.rmem_max "$rmax"
  fc_append_sysctl "$temp" net.core.wmem_max "$wmax"
  fc_append_sysctl "$temp" net.core.optmem_max 4194304
  fc_append_sysctl "$temp" net.ipv4.tcp_rmem "4096 1048576 $rmax"
  fc_append_sysctl "$temp" net.ipv4.tcp_wmem "4096 1048576 $wmax"
  fc_append_sysctl "$temp" net.ipv4.tcp_mem "$tcp_mem"
  fc_append_sysctl "$temp" net.ipv4.tcp_adv_win_scale 1
  fc_append_sysctl "$temp" net.ipv4.tcp_mtu_probing 1
  fc_append_sysctl "$temp" net.ipv4.tcp_ecn 0
  fc_append_sysctl "$temp" net.ipv4.tcp_frto 0
  fc_append_sysctl "$temp" net.ipv4.tcp_fastopen 3
  fc_append_sysctl "$temp" net.ipv4.tcp_slow_start_after_idle 0
  fc_append_sysctl "$temp" net.ipv4.tcp_tw_reuse 1
  fc_append_sysctl "$temp" net.ipv4.tcp_fin_timeout 15
  fc_append_sysctl "$temp" net.ipv4.tcp_keepalive_time 600
  fc_append_sysctl "$temp" net.ipv4.tcp_keepalive_intvl 60
  fc_append_sysctl "$temp" net.ipv4.tcp_keepalive_probes 5
  fc_append_sysctl "$temp" net.ipv4.udp_rmem_min 16384
  fc_append_sysctl "$temp" net.ipv4.udp_wmem_min 16384
  fc_append_sysctl "$temp" net.ipv4.ip_local_port_range "$port_range"
  fc_append_sysctl "$temp" net.ipv4.tcp_max_tw_buckets "$tw_buckets"
  fc_append_sysctl "$temp" fs.file-max "$file_max"
  fc_append_sysctl "$temp" net.netfilter.nf_conntrack_max "$conntrack"

  if ((FC_DRY_RUN == 1)); then
    printf '\n将写入 %s：\n' "$FC_SYSCTL_FILE"
    sed 's/^/  /' "$temp"
    rm -f "$temp"
    return 0
  fi
  fc_atomic_replace "$temp" "$FC_SYSCTL_FILE" 0644
  sysctl -p "$FC_SYSCTL_FILE" >/dev/null || fc_die "sysctl 应用失败，配置保留在 ${FC_SYSCTL_FILE}。"
  fc_log "已应用 ${ROLE} 角色 TCP 配置，拥塞控制 ${cc}。"
}

fc_write_extreme_sysctl_profile() {
  local mem cc temp
  mem="$(fc_mem_mb)"
  ((mem >= 4096)) || fc_die "极限吞吐 profile 至少需要 4 GiB RAM。"
  cc="$(fc_choose_cc)"
  [[ "$cc" == bbr ]] || fc_die "极限吞吐 profile 需要内核提供 BBR。"
  temp="$(mktemp /tmp/flowcraft-extreme.XXXXXX)"
  printf '# Flowcraft EXPERIMENTAL max-throughput profile\n' >"$temp"
  fc_append_sysctl "$temp" net.core.default_qdisc fq
  fc_append_sysctl "$temp" net.ipv4.tcp_congestion_control bbr
  fc_append_sysctl "$temp" net.core.rmem_max 1073741824
  fc_append_sysctl "$temp" net.core.wmem_max 1073741824
  fc_append_sysctl "$temp" net.core.optmem_max 1073741824
  fc_append_sysctl "$temp" net.core.netdev_max_backlog 1000000
  fc_append_sysctl "$temp" net.core.somaxconn 65535
  fc_append_sysctl "$temp" net.ipv4.tcp_wmem '4096 1048576 1073741824'
  fc_append_sysctl "$temp" net.ipv4.tcp_rmem '4096 1048576 1073741824'
  fc_append_sysctl "$temp" net.ipv4.tcp_notsent_lowat 4294967295
  fc_append_sysctl "$temp" net.ipv4.tcp_no_metrics_save 1
  fc_append_sysctl "$temp" net.ipv4.tcp_mtu_probing 1
  fc_append_sysctl "$temp" net.ipv4.tcp_fastopen 3
  fc_append_sysctl "$temp" net.ipv4.tcp_ecn 0
  fc_append_sysctl "$temp" net.ipv4.tcp_slow_start_after_idle 0
  if ((FC_DRY_RUN == 1)); then
    printf '\n将写入实验配置 %s：\n' "$FC_SYSCTL_FILE"
    sed 's/^/  /' "$temp"
    rm -f "$temp"
    return 0
  fi
  fc_atomic_replace "$temp" "$FC_SYSCTL_FILE" 0644
  sysctl -p "$FC_SYSCTL_FILE" >/dev/null || fc_die "极限 profile 应用失败。"
  fc_warn "已启用极限吞吐 profile；它会增加内存、重传、抖动和排队延迟。"
}

fc_record_qdisc() {
  local iface="$1" kind
  [[ -e "$FC_QDISC_SNAPSHOT" || "$FC_DRY_RUN" == 1 ]] && return 0
  kind="$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1 {print $2; exit}')"
  mkdir -p "$FC_STATE_DIR"
  printf 'IFACE=%s\nKIND=%s\n' "$iface" "${kind:-unknown}" >"$FC_QDISC_SNAPSHOT"
  chmod 0600 "$FC_QDISC_SNAPSHOT"
}

fc_restore_qdisc() {
  [[ -r "$FC_QDISC_SNAPSHOT" ]] || return 0
  local iface='' kind='' key value
  while IFS='=' read -r key value; do
    case "$key" in IFACE) iface="$value" ;; KIND) kind="$value" ;; esac
  done <"$FC_QDISC_SNAPSHOT"
  [[ -n "$iface" && -n "$kind" ]] || return 0
  case "$kind" in
    mq | noqueue | unknown) fc_run tc qdisc del dev "$iface" root >/dev/null 2>&1 || true ;;
    *) fc_run tc qdisc replace dev "$iface" root "$kind" >/dev/null 2>&1 || true ;;
  esac
  fc_log "已尝试恢复 $iface 的原 root qdisc：${kind}。"
}

fc_restore_fq() {
  local iface="$1"
  tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
  tc qdisc replace dev "$iface" root fq 2>/dev/null ||
    tc qdisc replace dev "$iface" root fq_codel
}

fc_add_fq_leaf() {
  local iface="$1" parent="$2" handle="$3" maxrate="${4:-}" mem="$5" error="$6"
  local limits limit flow_limit args=(fq)
  limits="$(fc_fq_limits "$mem")"
  limit="${limits%% *}"
  flow_limit="${limits##* }"
  args+=(limit "$limit" flow_limit "$flow_limit")
  [[ -n "$maxrate" ]] && args+=(maxrate "${maxrate}mbit")
  tc qdisc add dev "$iface" parent "$parent" handle "$handle" "${args[@]}" 2>>"$error" ||
    {
      args=(fq)
      [[ -n "$maxrate" ]] && args+=(maxrate "${maxrate}mbit")
      tc qdisc add dev "$iface" parent "$parent" handle "$handle" "${args[@]}" 2>>"$error"
    }
}

fc_try_htb() {
  local iface="$1" total="$2" perflow="$3" burst="$4" mem="$5" error="$6"
  tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
  tc qdisc add dev "$iface" root handle 1: htb default 10 2>"$error" || return 1
  tc class add dev "$iface" parent 1: classid 1:10 htb rate "${total}mbit" ceil "${total}mbit" burst "${burst}kb" cburst "${burst}kb" quantum 1514 2>>"$error" || return 1
  fc_add_fq_leaf "$iface" 1:10 10: "$perflow" "$mem" "$error"
}

fc_try_tbf() {
  local iface="$1" total="$2" perflow="$3" burst="$4" mem="$5" error="$6"
  tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
  tc qdisc add dev "$iface" root handle 1: tbf rate "${total}mbit" burst "${burst}kb" latency 50ms 2>"$error" || return 1
  fc_add_fq_leaf "$iface" 1: 10: "$perflow" "$mem" "$error"
}

fc_try_fq_maxrate() {
  local iface="$1" rate="$2" mem="$3" error="$4" limits limit flow_limit
  limits="$(fc_fq_limits "$mem")"
  limit="${limits%% *}"
  flow_limit="${limits##* }"
  tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
  tc qdisc add dev "$iface" root fq limit "$limit" flow_limit "$flow_limit" maxrate "${rate}mbit" 2>"$error" ||
    tc qdisc add dev "$iface" root fq maxrate "${rate}mbit" 2>>"$error"
}

fc_try_total() {
  local iface="$1" total="$2" burst="$3" mem="$4" error="$5"
  tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
  if tc qdisc add dev "$iface" root cake bandwidth "${total}mbit" besteffort dual-dsthost 2>"$error"; then
    SHAPER_MODE=cake
    return 0
  fi
  if fc_try_htb "$iface" "$total" '' "$burst" "$mem" "$error"; then
    SHAPER_MODE=htb
    return 0
  fi
  if fc_try_tbf "$iface" "$total" '' "$burst" "$mem" "$error"; then
    SHAPER_MODE=tbf
    return 0
  fi
  return 1
}

fc_apply_shape() {
  fc_need_root
  fc_take_lock
  fc_load_config
  fc_has tc || fc_die "缺少 tc，请安装 iproute2。"
  local iface mem burst error detail
  iface="$(fc_resolve_iface)"
  mem="$(fc_mem_mb)"
  ((mem > 0)) || mem=1024
  fc_record_qdisc "$iface"
  if ((FC_DRY_RUN == 1)); then
    printf '队列计划：role=%s iface=%s per-flow=%s total=%s burst=%s\n' "$ROLE" "$iface" "$PER_FLOW_MBPS" "$TOTAL_MBPS" "$BURST_MODE"
    return 0
  fi
  fc_has modprobe && {
    modprobe sch_fq sch_htb sch_tbf >/dev/null 2>&1 || true
    modprobe sch_cake >/dev/null 2>&1 || true
  }
  error="$(mktemp /tmp/flowcraft-tc.XXXXXX)"
  if [[ "$ROLE" == general ]]; then
    if ((TOTAL_MBPS > 0)) && [[ "$SHAPER_MODE" == htb ]]; then
      burst="$(fc_htb_burst_kb "$TOTAL_MBPS" "$BURST_MODE")"
      if fc_try_htb "$iface" "$TOTAL_MBPS" "$TOTAL_MBPS" "$burst" "$mem" "$error"; then
        SHAPER_MODE=htb
      else
        detail="$(tail -n 1 "$error")"
        fc_restore_fq "$iface"
        rm -f "$error"
        fc_die "实测总出口整形不可用，已恢复 fq：$detail"
      fi
    elif [[ "$SHAPER_MODE" =~ ^(fq_codel|fq_pie|cake)$ ]]; then
      tc qdisc replace dev "$iface" root "$SHAPER_MODE" 2>"$error" || {
        detail="$(tail -n 1 "$error")"
        rm -f "$error"
        fc_die "qdisc ${SHAPER_MODE} 不可用：$detail"
      }
    else
      fc_restore_fq "$iface"
      SHAPER_MODE=fq
    fi
  elif [[ "$ROLE" == relay ]]; then
    if ((TOTAL_MBPS > 0)); then
      burst="$(fc_htb_burst_kb "$TOTAL_MBPS" "$BURST_MODE")"
      if fc_try_htb "$iface" "$TOTAL_MBPS" "$PER_FLOW_MBPS" "$burst" "$mem" "$error"; then
        SHAPER_MODE=htb
      elif fc_try_tbf "$iface" "$TOTAL_MBPS" "$PER_FLOW_MBPS" "$burst" "$mem" "$error"; then
        SHAPER_MODE=tbf
      elif fc_try_fq_maxrate "$iface" "$PER_FLOW_MBPS" "$mem" "$error"; then
        SHAPER_MODE=fq
        fc_warn "总出口限速不可用，仅保留单连接上限。"
      else
        detail="$(tail -n 1 "$error")"
        fc_restore_fq "$iface"
        rm -f "$error"
        fc_die "限速队列不可用，已恢复 fq：$detail"
      fi
    elif fc_try_fq_maxrate "$iface" "$PER_FLOW_MBPS" "$mem" "$error"; then
      SHAPER_MODE=fq
    else
      detail="$(tail -n 1 "$error")"
      fc_restore_fq "$iface"
      rm -f "$error"
      fc_die "单连接限速不可用，已恢复 fq：$detail"
    fi
  elif ((TOTAL_MBPS > 0)); then
    burst="$(fc_htb_burst_kb "$TOTAL_MBPS" "$BURST_MODE")"
    if [[ "$SHAPER_MODE" == htb ]]; then
      fc_try_htb "$iface" "$TOTAL_MBPS" "$TOTAL_MBPS" "$burst" "$mem" "$error" && SHAPER_MODE=htb
    else
      fc_try_total "$iface" "$TOTAL_MBPS" "$burst" "$mem" "$error"
    fi ||
      {
        detail="$(tail -n 1 "$error")"
        fc_restore_fq "$iface"
        rm -f "$error"
        fc_die "总出口限速不可用，已恢复 fq：$detail"
      }
  else
    fc_restore_fq "$iface"
    SHAPER_MODE=fq
  fi
  rm -f "$error"
  fc_save_config
  fc_log "出口队列已应用：$iface / ${SHAPER_MODE}。"
}

fc_apply_initcwnd() {
  ((INITCWND > 0)) || return 0
  fc_has ip || return 0
  local iface="$1" route words
  route="$(ip -4 route show default 2>/dev/null | head -n 1)"
  [[ -n "$route" ]] || return 0
  if [[ ! -e "$FC_ROUTE_SNAPSHOT" && "$FC_DRY_RUN" == 0 ]]; then
    printf '%s\n' "$route" >"$FC_ROUTE_SNAPSHOT"
  fi
  route="$(printf '%s\n' "$route" | sed -E 's/ initcwnd [0-9]+//g; s/ initrwnd [0-9]+//g')"
  read -r -a words <<<"$route"
  fc_run ip route replace "${words[@]}" initcwnd "$INITCWND" initrwnd "$INITCWND" >/dev/null 2>&1 ||
    fc_warn "当前平台不支持修改 initcwnd/initrwnd。"
  : "$iface"
}

fc_restore_route() {
  [[ -r "$FC_ROUTE_SNAPSHOT" ]] || return 0
  fc_has ip || return 0
  local route words
  route="$(<"$FC_ROUTE_SNAPSHOT")"
  read -r -a words <<<"$route"
  fc_run ip route replace "${words[@]}" >/dev/null 2>&1 || fc_warn "默认路由恢复失败。"
}

fc_apply_ipv4_priority() {
  local gai="${FLOWCRAFT_GAI_FILE:-/etc/gai.conf}"
  if [[ "$IPV4_PRIORITY" == on ]]; then
    if [[ ! -e "$FC_GAI_BACKUP" && ! -e "$FC_GAI_ABSENT" && "$FC_DRY_RUN" == 0 ]]; then
      mkdir -p "$FC_STATE_DIR"
      if [[ -e "$gai" ]]; then cp -p "$gai" "$FC_GAI_BACKUP"; else : >"$FC_GAI_ABSENT"; fi
    fi
    if ((FC_DRY_RUN == 1)); then
      fc_info "dry-run：将启用 IPv4 地址选择优先级。"
      return 0
    fi
    mkdir -p "$(dirname "$gai")"
    touch "$gai"
    grep -Fqx 'precedence ::ffff:0:0/96  100' "$gai" || printf 'precedence ::ffff:0:0/96  100\n' >>"$gai"
  else
    fc_restore_ipv4_priority
  fi
}

fc_restore_ipv4_priority() {
  local gai="${FLOWCRAFT_GAI_FILE:-/etc/gai.conf}"
  if [[ -e "$FC_GAI_BACKUP" ]]; then
    fc_run cp -p "$FC_GAI_BACKUP" "$gai"
  elif [[ -e "$FC_GAI_ABSENT" ]]; then
    fc_run rm -f "$gai"
  else
    ((FC_DRY_RUN == 1)) || sed -i '/^precedence ::ffff:0:0\/96  100$/d' "$gai" 2>/dev/null || true
  fi
}

fc_take_rps_snapshot() {
  [[ -e "$FC_RPS_SNAPSHOT" || "$FC_DRY_RUN" == 1 ]] && return 0
  local root="${FLOWCRAFT_SYS_CLASS_NET:-/sys/class/net}" file
  mkdir -p "$FC_STATE_DIR"
  {
    printf '# path=value\n'
    for file in "$root"/*/queues/rx-*/rps_cpus "$root"/*/queues/rx-*/rps_flow_cnt; do
      [[ -r "$file" ]] && printf '%s=%s\n' "$file" "$(<"$file")"
    done
    printf 'sysctl:net.core.rps_sock_flow_entries=%s\n' "$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null || printf 0)"
  } >"$FC_RPS_SNAPSHOT"
  chmod 0600 "$FC_RPS_SNAPSHOT"
}

fc_apply_rps() {
  [[ "$RPS_MODE" == auto ]] || {
    fc_restore_rps
    return 0
  }
  fc_take_rps_snapshot
  local root="${FLOWCRAFT_SYS_CLASS_NET:-/sys/class/net}" iface file mask queues=0
  mask="$(fc_cpu_mask "$(fc_cpu_count)")"
  for iface in "$root"/*; do
    [[ -d "$iface/queues" ]] || continue
    case "$(basename "$iface")" in lo | docker* | veth* | br-* | tun* | wg*) continue ;; esac
    for file in "$iface"/queues/rx-*/rps_cpus; do
      [[ -e "$file" ]] || continue
      queues=$((queues + 1))
      if ((FC_DRY_RUN == 1)); then printf '[dry-run] %s <- %s\n' "$file" "$mask"; else printf '%s\n' "$mask" >"$file" || true; fi
    done
    for file in "$iface"/queues/rx-*/rps_flow_cnt; do
      [[ -e "$file" ]] || continue
      if ((FC_DRY_RUN == 1)); then printf '[dry-run] %s <- 4096\n' "$file"; else printf '4096\n' >"$file" || true; fi
    done
  done
  ((queues > 0)) && fc_run sysctl -qw net.core.rps_sock_flow_entries=$((queues * 4096)) >/dev/null 2>&1 || true
}

fc_restore_rps() {
  [[ -r "$FC_RPS_SNAPSHOT" ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    [[ -n "$key" && "$key" != \#* ]] || continue
    if [[ "$key" == sysctl:* ]]; then
      fc_run sysctl -qw "${key#sysctl:}=$value" >/dev/null 2>&1 || true
    elif [[ -e "$key" ]]; then
      if ((FC_DRY_RUN == 1)); then printf '[dry-run] %s <- %s\n' "$key" "$value"; else printf '%s\n' "$value" >"$key" || true; fi
    fi
  done <"$FC_RPS_SNAPSHOT"
}

fc_apply_all() {
  if [[ -r "$FC_STAGE_FILE" ]] && grep -q '^STAGE=pending-reboot$' "$FC_STAGE_FILE"; then
    fc_die "内核正在等待重启验证；请先重启并运行 ftcp resume。"
  fi
  fc_write_sysctl_profile
  fc_apply_shape
  fc_load_config
  fc_apply_initcwnd "$(fc_resolve_iface)"
  fc_apply_ipv4_priority
  fc_apply_rps
}

fc_rollback_all() {
  fc_need_root
  fc_take_lock
  fc_restore_qdisc
  if ((FC_DRY_RUN == 0)); then
    rm -f "$FC_SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || true
  fi
  fc_restore_sysctl_snapshot
  fc_restore_route
  fc_restore_ipv4_priority
  fc_restore_rps
  fc_log "Flowcraft 网络变更已按快照回滚。"
}

fc_status() {
  fc_load_config
  local iface cc qdisc root_qdisc kernel bbr_version retrans='unknown'
  iface="$IFACE"
  [[ "$iface" == auto ]] && iface="$(fc_detect_iface)"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf unknown)"
  if fc_has tc && [[ -n "$iface" ]]; then
    root_qdisc="$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1 {print $2; exit}' || true)"
  else
    root_qdisc=unknown
  fi
  kernel="$(uname -r 2>/dev/null || printf unknown)"
  bbr_version="$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/ {print $2; exit}' || true)"
  if fc_has nstat; then
    retrans="$(nstat -asz 2>/dev/null | awk '$1=="TcpOutSegs"{s=$2}$1=="TcpRetransSegs"{r=$2}END{if(s>0)printf "%.3f%%",r*100/s;else print "n/a"}')"
  fi
  printf '%bFlowcraft %s%b\n' "$FC_BOLD" "$FLOWCRAFT_VERSION" "$FC_RESET"
  printf '  role:              %s\n' "$ROLE"
  printf '  kernel:            %s\n' "$kernel"
  printf '  bbr module:        %s\n' "${bbr_version:-not-v3}"
  printf '  congestion:        %s\n' "$cc"
  printf '  default qdisc:     %s\n' "$qdisc"
  printf '  interface/root:    %s / %s\n' "${iface:-unknown}" "${root_qdisc:-unknown}"
  printf '  per-flow / total:  %s / %s Mbps\n' "$PER_FLOW_MBPS" "$TOTAL_MBPS"
  printf '  port fit:          %s\n' "$(fc_fit_summary)"
  printf '  retrans since boot:%s\n' "$retrans"
  printf '  IPv4 priority/RPS: %s / %s\n' "$IPV4_PRIORITY" "$RPS_MODE"
}

fc_diagnose() {
  fc_status
  local conflicts
  conflicts="$(fc_find_conflicts | sort -u)"
  printf '\n冲突检查：\n'
  if [[ -n "$conflicts" ]]; then printf '%s\n' "$conflicts" | sed 's/^/  - /'; else printf '  未发现已知冲突。\n'; fi
  printf '\n能力：\n'
  printf '  tc=%s ip=%s systemd=%s bbr=%s\n' "$(fc_has tc && printf yes || printf no)" "$(fc_has ip && printf yes || printf no)" "$(fc_has systemctl && printf yes || printf no)" "$(grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && printf yes || printf no)"
}

#!/usr/bin/env bash

FC_INSTALL_YES=0
FC_NON_INTERACTIVE=0

fc_json_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "$value"
}

fc_inspect() {
  local json=0
  [[ "${1:-}" == --json ]] && json=1
  local os version iface conflicts cc qdisc bbr systemd arch
  os="$(fc_os_release_value ID)"
  version="$(fc_os_release_value VERSION_ID)"
  iface="$(fc_detect_iface)"
  conflicts="$(fc_find_conflicts | sort -u)"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf unknown)"
  bbr="$(fc_bbr_version || true)"
  arch="$(uname -m 2>/dev/null || printf unknown)"
  fc_has systemctl && systemd=yes || systemd=no
  if ((json == 1)); then
    printf '{\n'
    printf '  "os": "%s",\n' "$(fc_json_escape "${os:-unknown} ${version:-}")"
    printf '  "arch": "%s",\n' "$(fc_json_escape "$arch")"
    printf '  "kernel": "%s",\n' "$(fc_json_escape "$(uname -r 2>/dev/null || printf unknown)")"
    printf '  "memory_mb": %s,\n' "$(fc_mem_mb)"
    printf '  "cpus": %s,\n' "$(fc_cpu_count)"
    printf '  "systemd": "%s",\n' "$systemd"
    printf '  "interface": "%s",\n' "$(fc_json_escape "${iface:-unknown}")"
    printf '  "congestion_control": "%s",\n' "$(fc_json_escape "$cc")"
    printf '  "default_qdisc": "%s",\n' "$(fc_json_escape "$qdisc")"
    printf '  "bbr_version": "%s",\n' "$(fc_json_escape "${bbr:-none}")"
    printf '  "conflicts": "%s"\n' "$(fc_json_escape "$conflicts")"
    printf '}\n'
    return 0
  fi
  printf '%bFlowcraft 环境体检%b\n' "$FC_BOLD" "$FC_RESET"
  printf '  系统：       %s %s / %s\n' "${os:-unknown}" "${version:-}" "$arch"
  printf '  内核：       %s / BBR module %s\n' "$(uname -r 2>/dev/null || printf unknown)" "${bbr:-none}"
  printf '  CPU/内存：   %s vCPU / %s MiB\n' "$(fc_cpu_count)" "$(fc_mem_mb)"
  printf '  systemd：    %s\n' "$systemd"
  printf '  出口网卡：   %s\n' "${iface:-unknown}"
  printf '  CC/qdisc：   %s / %s\n' "$cc" "$qdisc"
  if [[ -n "$conflicts" ]]; then printf '  冲突：\n%s\n' "$(printf '%s\n' "$conflicts" | sed 's/^/    - /')"; else printf '  冲突：       未发现\n'; fi
}

fc_set_role_defaults() {
  TUNING_PROFILE=normal
  case "$ROLE" in
    general)
      RTT_MS=160
      PER_FLOW_MBPS=1000
      TOTAL_MBPS=0
      BURST_MODE=throughput
      SHAPER_MODE=fq
      ;;
    relay)
      RTT_MS=160
      PER_FLOW_MBPS=430
      TOTAL_MBPS=0
      BURST_MODE=policer
      SHAPER_MODE=auto
      ;;
    landing)
      PER_FLOW_MBPS=1000
      TOTAL_MBPS=0
      RTT_MS=5
      BURST_MODE=throughput
      SHAPER_MODE=auto
      ;;
  esac
}

fc_set_role_total() {
  local total="$1" source="${2:-manual}"
  TOTAL_MBPS="$total"
  ((TOTAL_MBPS > 0)) || return 0
  if [[ "$source" == fitted ]]; then
    BURST_MODE=policer
    SHAPER_MODE=htb
  elif [[ "$ROLE" == general ]]; then
    SHAPER_MODE=htb
  fi
  [[ "$ROLE" != general ]] || PER_FLOW_MBPS="$TOTAL_MBPS"
}

fc_print_role_guide() {
  printf '\n角色与常用参考：\n'
  printf '  1) general  通用 VPS：BBR + fq，不设置单连接或整机限速\n'
  printf '  2) relay    跨境中转/观看机：按客户端家宽限制单连接\n'
  printf '              500M 家宽 -> 430 稳定 / 450 速度优先 Mbps\n'
  printf '                1G 家宽 -> 850 稳定 / 900 速度优先 Mbps\n'
  printf '              VPS 1G 端口 -> 整机 900；2.5G 端口 -> 整机 2300；0 不限\n'
  printf '  3) landing  同区域落地：不限单连接，整机出口可填 900 / 2300 / 0\n'
  printf '              接收缓冲按源站到落地机的回源 RTT 计算\n'
}

fc_interactive_wizard() {
  [[ -t 0 ]] || fc_die "无终端时请使用 --non-interactive 和完整参数。"
  local answer
  fc_print_role_guide
  read -r -p '角色 [1]: ' answer
  case "${answer:-1}" in 1) ROLE=general ;; 2) ROLE=relay ;; 3) ROLE=landing ;; *) fc_die "无效角色。" ;; esac
  fc_set_role_defaults
  printf '\n内核选择：\n  1) Flowcraft BBRv3 标准版\n  2) 跳过内核安装，使用系统内核\n  3) BBRv3 Max 实验版\n'
  read -r -p '内核 [1]: ' answer
  case "${answer:-1}" in
    1) KERNEL_CHANNEL=standard ;;
    2) KERNEL_CHANNEL=skip ;;
    3)
      KERNEL_CHANNEL=max
      EXPERIMENTAL=on
      read -r -p 'Max 会增加重传、延迟和内存风险，输入 MAX 确认: ' answer
      [[ "$answer" == MAX ]] || fc_die "已取消 Max 内核。"
      ;;
    *) fc_die "无效内核选项。" ;;
  esac
  if [[ "$ROLE" == relay ]]; then
    read -r -p "业务 RTT 毫秒 [$RTT_MS]: " answer
    RTT_MS="${answer:-$RTT_MS}"
    read -r -p "单连接上限 Mbps [$PER_FLOW_MBPS]: " answer
    PER_FLOW_MBPS="${answer:-$PER_FLOW_MBPS}"
    read -r -p "整机总出口 Mbps，0 不限 [$TOTAL_MBPS]: " answer
    TOTAL_MBPS="${answer:-$TOTAL_MBPS}"
  elif [[ "$ROLE" == landing ]]; then
    read -r -p "回源 RTT 毫秒 [$ORIGIN_RTT_MS]: " answer
    ORIGIN_RTT_MS="${answer:-$ORIGIN_RTT_MS}"
    read -r -p "整机总出口 Mbps，0 不限 [$TOTAL_MBPS]: " answer
    TOTAL_MBPS="${answer:-$TOTAL_MBPS}"
  fi
  printf '\nIPv4 优先：仅在 IPv6 绕路、握手慢或连接不稳定时建议开启。\n'
  read -r -p '启用 IPv4 优先？[y/N]: ' answer
  [[ "$answer" =~ ^[Yy]$ ]] && IPV4_PRIORITY=on
  printf 'RPS/RFS：仅在多核高吞吐且单核 SoftIRQ 成为瓶颈时建议开启。\n'
  read -r -p '启用 RPS/RFS？[y/N]: ' answer
  [[ "$answer" =~ ^[Yy]$ ]] && RPS_MODE=auto
}

fc_parse_install_options() {
  fc_load_config
  FC_INSTALL_YES=0
  FC_NON_INTERACTIVE=0
  local arguments=("$@") index requested_role
  # Resolve role defaults before the normal parse so command-line precedence
  # does not depend on whether --role appears before or after --total/--rtt.
  for ((index = 0; index < ${#arguments[@]}; index++)); do
    if [[ "${arguments[$index]}" == --role ]]; then
      ((index + 1 < ${#arguments[@]})) || fc_die "--role 缺少值"
      requested_role="${arguments[$((index + 1))]}"
      fc_validate_config_value ROLE "$requested_role" || fc_die "无效 --role"
      ROLE="$requested_role"
      fc_set_role_defaults
      break
    fi
  done
  while (($#)); do
    case "$1" in
      --non-interactive)
        FC_NON_INTERACTIVE=1
        shift
        ;;
      --yes)
        FC_INSTALL_YES=1
        shift
        ;;
      --experimental)
        EXPERIMENTAL=on
        shift
        ;;
      --role)
        [[ $# -ge 2 ]] || fc_die "--role 缺少值"
        ROLE="$2"
        fc_validate_config_value ROLE "$ROLE" || fc_die "无效 --role"
        shift 2
        ;;
      --kernel)
        [[ $# -ge 2 ]] || fc_die "--kernel 缺少值"
        KERNEL_CHANNEL="$2"
        shift 2
        ;;
      --iface)
        [[ $# -ge 2 ]] || fc_die "--iface 缺少值"
        IFACE="$2"
        shift 2
        ;;
      --rtt)
        [[ $# -ge 2 ]] || fc_die "--rtt 缺少值"
        RTT_MS="$2"
        shift 2
        ;;
      --origin-rtt)
        [[ $# -ge 2 ]] || fc_die "--origin-rtt 缺少值"
        ORIGIN_RTT_MS="$2"
        shift 2
        ;;
      --per-flow)
        [[ $# -ge 2 ]] || fc_die "--per-flow 缺少值"
        PER_FLOW_MBPS="$2"
        shift 2
        ;;
      --total)
        [[ $# -ge 2 ]] || fc_die "--total 缺少值"
        TOTAL_MBPS="$2"
        shift 2
        ;;
      --burst)
        [[ $# -ge 2 ]] || fc_die "--burst 缺少值"
        BURST_MODE="$2"
        shift 2
        ;;
      --ipv4-priority)
        [[ $# -ge 2 ]] || fc_die "--ipv4-priority 缺少值"
        IPV4_PRIORITY="$2"
        shift 2
        ;;
      --rps)
        [[ $# -ge 2 ]] || fc_die "--rps 缺少值"
        RPS_MODE="$2"
        shift 2
        ;;
      --initcwnd)
        [[ $# -ge 2 ]] || fc_die "--initcwnd 缺少值"
        INITCWND="$2"
        shift 2
        ;;
      --dry-run)
        FC_DRY_RUN=1
        shift
        ;;
      *) fc_die "未知安装参数：$1" ;;
    esac
  done
  if ((FC_NON_INTERACTIVE == 0)); then fc_interactive_wizard; fi
  local key
  for key in ROLE KERNEL_CHANNEL IFACE RTT_MS ORIGIN_RTT_MS PER_FLOW_MBPS TOTAL_MBPS BURST_MODE IPV4_PRIORITY RPS_MODE INITCWND EXPERIMENTAL SHAPER_MODE TUNING_PROFILE; do
    fc_validate_config_value "$key" "${!key}" || fc_die "无效参数：${key}=${!key}"
  done
  [[ "$KERNEL_CHANNEL" != max || "$EXPERIMENTAL" == on ]] || fc_die "--kernel max 必须配合 --experimental。"
}

fc_experimental_command() {
  local profile="${1:-}" confirm="${2:-}"
  [[ "$profile" == max-throughput ]] || fc_die "支持：experimental max-throughput --yes"
  [[ "$confirm" == --yes ]] || fc_die "极限 profile 必须显式提供 --yes。"
  fc_need_root
  fc_load_config
  EXPERIMENTAL=on
  TUNING_PROFILE=extreme
  ROLE=general
  SHAPER_MODE=fq
  TOTAL_MBPS=0
  fc_save_config
  fc_apply_all
}

fc_show_plan() {
  local iface="${IFACE}" cc
  [[ "$iface" == auto ]] && iface="$(fc_detect_iface)"
  cc="$(fc_choose_cc)"
  printf '%bFlowcraft 变更计划%b\n' "$FC_BOLD" "$FC_RESET"
  printf '  role:              %s\n' "$ROLE"
  printf '  kernel:            %s%s\n' "$KERNEL_CHANNEL" "$([[ "$KERNEL_CHANNEL" == max ]] && printf ' (experimental)' || true)"
  printf '  interface:         %s\n' "${iface:-auto/unknown}"
  printf '  congestion:        %s（安装 BBRv3 后为 bbr）\n' "$cc"
  printf '  RTT/origin RTT:    %s / %s ms\n' "$RTT_MS" "$ORIGIN_RTT_MS"
  printf '  per-flow/total:    %s / %s Mbps\n' "$PER_FLOW_MBPS" "$TOTAL_MBPS"
  printf '  burst:             %s\n' "$BURST_MODE"
  printf '  IPv4 priority/RPS: %s / %s\n' "$IPV4_PRIORITY" "$RPS_MODE"
  printf '  writes:            %s, %s, %s\n' "$FC_CONFIG_FILE" "$FC_SYSCTL_FILE" "$FC_SERVICE_FILE"
  if [[ "$KERNEL_CHANNEL" != skip ]]; then printf '  stages:            install kernel -> manual reboot -> ftcp resume\n'; fi
}

fc_install_program() {
  local source_root
  source_root="$(cd "$FLOWCRAFT_LIB_DIR/../.." && pwd)"
  if [[ ! "$source_root/bin/ftcp" -ef "$FC_INSTALL_FILE" ]]; then
    fc_run install -d -m 0755 "$FC_INSTALL_LIB_DIR" "$(dirname "$FC_INSTALL_FILE")" "$(dirname "$FC_COMMAND_FILE")"
    fc_run install -m 0755 "$source_root/bin/ftcp" "$FC_INSTALL_FILE"
    fc_run install -m 0644 "$source_root"/lib/flowcraft/*.sh "$FC_INSTALL_LIB_DIR/"
  fi
  fc_run ln -sfn "$FC_INSTALL_FILE" "$FC_COMMAND_FILE"
  if [[ "$FC_LEGACY_INSTALL_FILE" != "$FC_INSTALL_FILE" ]]; then
    fc_run rm -f "$FC_LEGACY_INSTALL_FILE"
  fi
  if [[ "$FC_LEGACY_COMMAND_FILE" != "$FC_COMMAND_FILE" ]]; then
    fc_run rm -f "$FC_LEGACY_COMMAND_FILE"
  fi
  fc_run rm -f "$FC_LEGACY_BENCHMARK_FILE"
}

fc_write_service() {
  local temp
  temp="$(mktemp /tmp/flowcraft-service.XXXXXX)"
  {
    printf '[Unit]\nDescription=Flowcraft network tuning and egress shaping\nAfter=network-online.target\nWants=network-online.target\n\n'
    printf '[Service]\nType=oneshot\nExecStart=%s service-apply\nRemainAfterExit=yes\n\n' "$FC_INSTALL_FILE"
    printf '[Install]\nWantedBy=multi-user.target\n'
  } >"$temp"
  fc_atomic_replace "$temp" "$FC_SERVICE_FILE" 0644
  if ((FC_DRY_RUN == 0)); then
    systemctl daemon-reload
    systemctl enable flowcraft.service >/dev/null
  fi
}

fc_install() {
  fc_parse_install_options "$@"
  fc_need_root
  fc_is_linux || fc_die "Flowcraft 运行态只支持 Linux。"
  fc_has systemctl || fc_die "首版需要 systemd。"
  fc_has ip && fc_has tc && fc_has sysctl || fc_die "缺少 iproute2 或 procps。"
  fc_assert_no_conflicts
  fc_show_plan
  if ((FC_INSTALL_YES == 0 && FC_DRY_RUN == 0)); then
    local answer
    read -r -p '确认应用上述计划？[y/N]: ' answer
    [[ "$answer" =~ ^[Yy]$ ]] || fc_die "已取消。"
    FC_INSTALL_YES=1
  fi
  fc_take_lock
  fc_install_program
  fc_save_config
  fc_write_service
  if [[ "$KERNEL_CHANNEL" != skip ]]; then
    fc_kernel_install "$KERNEL_CHANNEL" "$FC_INSTALL_YES"
    return 0
  fi
  fc_apply_all
  ((FC_DRY_RUN == 1)) || fc_write_stage complete
  fc_log "Flowcraft 安装和调优完成。"
}

fc_resume() {
  fc_need_root
  fc_load_config
  local stage
  stage="$(fc_read_stage_value STAGE)"
  [[ "$stage" =~ ^(pending-reboot|applying)$ ]] || fc_die "没有等待恢复的内核安装阶段。"
  fc_kernel_verify_pending
  fc_write_stage applying "$(uname -r)"
  fc_apply_all
  fc_write_stage complete "$(uname -r)"
  fc_log "内核已验证，Flowcraft 调优阶段完成。"
}

fc_service_apply() {
  local stage
  stage="$(fc_read_stage_value STAGE)"
  if [[ "$stage" != complete ]]; then
    fc_warn "安装阶段为 ${stage:-missing}，开机服务不会应用网络变更；请运行 ftcp resume。"
    return 0
  fi
  fc_apply_all
}

fc_profile() {
  local role="${1:-}" preserved_total fitted total_source=manual
  fc_validate_config_value ROLE "$role" || fc_die "角色必须是 general、relay 或 landing。"
  fc_need_root
  fc_load_config
  preserved_total="$TOTAL_MBPS"
  fitted="$(fc_fit_recommendation || true)"
  if [[ -n "$fitted" ]]; then
    preserved_total="$fitted"
    total_source=fitted
  fi
  ROLE="$role"
  fc_set_role_defaults
  fc_set_role_total "$preserved_total" "$total_source"
  fc_save_config
  fc_apply_all
}

fc_network_command() {
  [[ "${1:-}" == ipv4-priority ]] || fc_die "支持：network ipv4-priority on|off"
  local mode="${2:-}"
  [[ "$mode" =~ ^(on|off)$ ]] || fc_die "状态必须是 on 或 off。"
  fc_need_root
  fc_load_config
  IPV4_PRIORITY="$mode"
  fc_save_config
  fc_apply_ipv4_priority
}

fc_nic_command() {
  [[ "${1:-}" == rps ]] || fc_die "支持：nic rps auto|off"
  local mode="${2:-}"
  [[ "$mode" =~ ^(auto|off)$ ]] || fc_die "状态必须是 auto 或 off。"
  fc_need_root
  fc_load_config
  RPS_MODE="$mode"
  fc_save_config
  fc_apply_rps
}

fc_qdisc_command() {
  local mode="${1:-}"
  [[ "$mode" =~ ^(fq|fq_codel|fq_pie|cake)$ ]] || fc_die "qdisc 必须是 fq、fq_codel、fq_pie 或 cake。"
  fc_need_root
  fc_load_config
  [[ "$ROLE" == general ]] || fc_die "手动 qdisc 只允许用于 general 角色，避免覆盖限速树。"
  SHAPER_MODE="$mode"
  TOTAL_MBPS=0
  fc_save_config
  fc_apply_shape
}

fc_kernel_command() {
  local action="${1:-status}"
  fc_load_config
  case "$action" in
    status) fc_kernel_status ;;
    install)
      shift
      local channel=standard yes=0 argument
      for argument in "$@"; do
        case "$argument" in
          standard | max) channel="$argument" ;;
          --yes) yes=1 ;;
          --experimental) EXPERIMENTAL=on ;;
          *) fc_die "未知内核安装参数：$argument" ;;
        esac
      done
      fc_kernel_install "$channel" "$yes"
      ;;
    rollback) fc_kernel_rollback ;;
    *) fc_die "支持：kernel install standard --yes、kernel install max --experimental --yes、status、rollback" ;;
  esac
}

fc_uninstall() {
  fc_need_root
  fc_rollback_all
  systemctl disable --now flowcraft.service >/dev/null 2>&1 || true
  rm -f "$FC_SERVICE_FILE" "$FC_CONFIG_FILE"
  [[ -L "$FC_COMMAND_FILE" && "$(readlink "$FC_COMMAND_FILE")" == "$FC_INSTALL_FILE" ]] && rm -f "$FC_COMMAND_FILE"
  rm -f "$FC_INSTALL_FILE" "$FC_LEGACY_INSTALL_FILE" "$FC_LEGACY_COMMAND_FILE"
  rm -rf "$FC_INSTALL_LIB_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$FC_STATE_DIR"
  fc_log "Flowcraft 已卸载；Flowcraft 内核包保留，需从旧内核启动后单独 rollback。"
}

fc_bootstrap() {
  fc_need_root
  fc_is_linux || fc_die "Flowcraft 只支持 Linux。"
  fc_install_program
  fc_log "Flowcraft 命令已安装：${FC_COMMAND_FILE}"
  if [[ "${FLOWCRAFT_NO_MENU:-0}" == 1 ]]; then return 0; fi
  [[ -t 0 && -t 1 ]] || {
    fc_info "运行 ftcp menu 进入交互式面板。"
    return 0
  }
  exec "$FC_COMMAND_FILE" menu
}

fc_menu_badge() {
  case "${1:-}" in
    on | auto | active | enabled) printf '%b已启用%b' "$FC_GREEN" "$FC_RESET" ;;
    complete) printf '%b已完成%b' "$FC_GREEN" "$FC_RESET" ;;
    off | disabled | inactive) printf '%b未启用%b' "$FC_DIM" "$FC_RESET" ;;
    missing) printf '%b未配置%b' "$FC_DIM" "$FC_RESET" ;;
    pending-reboot | applying) printf '%b%s%b' "$FC_YELLOW" "$1" "$FC_RESET" ;;
    *) printf '%s' "${1:-unknown}" ;;
  esac
}

fc_menu_next_action() {
  local configured="$1" stage="$2" fit_status="${3:-}"
  if [[ "$configured" != 1 ]]; then
    printf '[1] 首次安装：选择角色、内核和业务参数'
  elif [[ "$stage" =~ ^(pending-reboot|applying)$ ]]; then
    printf '重启系统后进入 [7] 执行 resume 并验证 BBRv3'
  elif [[ "$stage" != complete ]]; then
    printf '[1] 重新完成安装阶段'
  else
    case "$fit_status" in
      '') printf '[8] 拟合物理总出口拐点' ;;
      dirty-path | peer-too-slow | measurement-failed | shaper-failed)
        printf '[8] 更换或指定对端后重试，再用 [7] 复核'
        ;;
      fitted) printf '[7] 用 status / diagnose 复核实测配置' ;;
      *) printf '[7] 复核当前配置；线路或套餐变化时才重跑 [8]' ;;
    esac
  fi
}

fc_menu_render() {
  fc_load_config
  local configured=未配置 configured_state=0 stage=missing iface cc qdisc bbr fit fit_status next_action
  if [[ -r "$FC_CONFIG_FILE" ]]; then
    configured=已配置
    configured_state=1
  fi
  stage="$(fc_read_stage_value STAGE)"
  [[ -n "$stage" ]] || stage=missing
  iface="$IFACE"
  [[ "$iface" == auto ]] && iface="$(fc_detect_iface)"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf unknown)"
  bbr="$(fc_bbr_version || true)"
  fit="$(fc_fit_summary)"
  fit_status="$(fc_fit_result_value STATUS || true)"
  next_action="$(fc_menu_next_action "$configured_state" "$stage" "$fit_status")"

  printf '%b================================================================%b\n' "$FC_YELLOW" "$FC_RESET"
  printf '              %bFlowcraft VPS 网络调优与 BBRv3 面板%b\n' "$FC_BOLD" "$FC_RESET"
  printf '%b================================================================%b\n' "$FC_YELLOW" "$FC_RESET"
  printf '  调优流程：\n'
  printf '    [1] 角色/内核/基础调优 -> [重启] -> [7] resume 验证\n'
  printf '    [8] 物理总出口拟合      -> [7] status / diagnose 复核\n'
  printf '    角色管业务策略；relay 单流不等于 VPS 物理总出口。\n'
  printf '  下一步：%s\n' "$next_action"
  printf '%b----------------------------------------------------------------%b\n' "$FC_YELLOW" "$FC_RESET"
  printf '  1. 首次安装：角色 / 内核 / 基础调优\n'
  printf '  2. 角色与业务策略         -> RTT / 单流 / 复用拟合总出口\n'
  printf '  3. BBRv3 内核管理           -> 状态 / 标准版 / Max / 回滚\n'
  printf '  4. IPv4 优先解析            -> [%s] IPv6 绕路/握手异常时开启\n' "$(fc_menu_badge "$IPV4_PRIORITY")"
  printf '  5. RPS/RFS 多队列均衡       -> [%s] 多核高吞吐/单核 SoftIRQ 瓶颈时开启\n' "$(fc_menu_badge "$RPS_MODE")"
  printf '  6. 出口队列管理             -> fq / fq_codel / fq_pie / cake\n'
  printf '  7. 安装续作与状态复核       -> resume / status / diagnose / security\n'
  printf '  8. 物理总出口拐点实测     -> %s\n' "$fit"
  printf '  9. 回滚全部网络配置\n'
  printf ' 10. 卸载 Flowcraft\n'
  printf '  0. 退出\n'
  printf '%b----------------------------------------------------------------%b\n' "$FC_YELLOW" "$FC_RESET"
  printf ' 当前：配置=%s | 阶段=%s | 角色=%s | 内核=%s\n' "$configured" "$(fc_menu_badge "$stage")" "$ROLE" "$(uname -r 2>/dev/null || printf unknown)"
  printf '       BBR=%s | 算法=%s | qdisc=%s | 网卡=%s\n' "${bbr:-非 v3}" "$cc" "$qdisc" "${iface:-unknown}"
  printf '%b================================================================%b\n' "$FC_YELLOW" "$FC_RESET"
}

fc_menu_pause() {
  local ignored
  read -r -p '按 Enter 返回主菜单...' ignored
}

fc_menu_require_config() {
  [[ -r "$FC_CONFIG_FILE" ]] || {
    fc_warn "尚未完成首次安装，请先选择 1。"
    return 1
  }
}

fc_menu_run() {
  if ("$@"); then
    printf '\n'
  else
    fc_warn "操作失败，请查看上方错误。"
  fi
  fc_menu_pause
}

fc_menu_role() {
  fc_menu_require_config || return 1
  fc_load_config
  local answer previous_total fitted total_default total_source=manual
  previous_total="$TOTAL_MBPS"
  fitted="$(fc_fit_recommendation || true)"
  fc_print_role_guide
  read -r -p "角色 [当前 $ROLE]: " answer
  case "$answer" in
    1) ROLE=general ;;
    2) ROLE=relay ;;
    3) ROLE=landing ;;
    *)
      fc_warn "无效角色。"
      return 1
      ;;
  esac
  fc_set_role_defaults
  if [[ "$ROLE" == relay ]]; then
    read -r -p "业务 RTT 毫秒 [$RTT_MS]: " answer
    RTT_MS="${answer:-$RTT_MS}"
    printf '单连接上限是客户端/业务策略，不等同于 VPS 物理总出口。\n'
    read -r -p "单连接上限 Mbps [$PER_FLOW_MBPS]: " answer
    PER_FLOW_MBPS="${answer:-$PER_FLOW_MBPS}"
  elif [[ "$ROLE" == landing ]]; then
    read -r -p "回源 RTT 毫秒 [$ORIGIN_RTT_MS]: " answer
    ORIGIN_RTT_MS="${answer:-$ORIGIN_RTT_MS}"
  fi
  total_default="$previous_total"
  if [[ -n "$fitted" ]]; then
    total_default="$fitted"
    total_source=fitted
    printf '检测到最近可信拟合建议：总出口 %s Mbps。\n' "$fitted"
  fi
  read -r -p "整机总出口 Mbps；输入 r 先不限速并稍后重测 [$total_default]: " answer
  if [[ "$answer" =~ ^[Rr]$ ]]; then
    total_default=0
    total_source=manual
    fc_info '本次先不设置总出口；角色应用完成后请运行菜单 8 重新拟合。'
  else
    [[ -z "$answer" ]] || total_source=manual
    total_default="${answer:-$total_default}"
  fi
  fc_validate_config_value TOTAL_MBPS "$total_default" || fc_die "总出口速率无效。"
  fc_set_role_total "$total_default" "$total_source"
  fc_validate_config_value RTT_MS "$RTT_MS" || fc_die "RTT 参数无效。"
  fc_validate_config_value ORIGIN_RTT_MS "$ORIGIN_RTT_MS" || fc_die "回源 RTT 参数无效。"
  fc_validate_config_value PER_FLOW_MBPS "$PER_FLOW_MBPS" || fc_die "单连接速率无效。"
  fc_save_config
  fc_apply_all
  fc_log "已切换到 ${ROLE} 角色。"
}

fc_menu_kernel() {
  local answer confirm
  printf '1) 查看内核状态\n2) 安装 BBRv3 标准版\n3) 安装 BBRv3 Max 实验版\n4) 回滚 Flowcraft 内核包\n'
  read -r -p '选择 [1-4]: ' answer
  case "$answer" in
    1) fc_kernel_command status ;;
    2)
      fc_menu_require_config || return 1
      read -r -p '安装内核但不自动重启，输入 YES 确认: ' confirm
      [[ "$confirm" == YES ]] || {
        fc_warn "已取消。"
        return 0
      }
      fc_kernel_command install standard --yes
      ;;
    3)
      fc_menu_require_config || return 1
      read -r -p 'Max 风险较高，输入 MAX 确认: ' confirm
      [[ "$confirm" == MAX ]] || {
        fc_warn "已取消。"
        return 0
      }
      fc_kernel_command install max --experimental --yes
      ;;
    4)
      fc_menu_require_config || return 1
      read -r -p '必须已从旧内核启动，输入 ROLLBACK 确认: ' confirm
      [[ "$confirm" == ROLLBACK ]] || {
        fc_warn "已取消。"
        return 0
      }
      fc_kernel_command rollback
      ;;
    *)
      fc_warn "无效选项。"
      return 1
      ;;
  esac
}

fc_menu_toggle() {
  local feature="$1" answer
  fc_menu_require_config || return 1
  case "$feature" in
    ipv4) printf '仅在 IPv6 绕路、握手慢或连接不稳定时建议开启；会完整备份并可恢复 gai.conf。\n' ;;
    rps) printf '仅在多核高吞吐且单核 SoftIRQ 成为瓶颈时建议开启；普通 1-2 核 VPS 保持关闭。\n' ;;
  esac
  printf '1) 开启\n2) 关闭\n'
  read -r -p '选择 [1-2]: ' answer
  case "$feature:$answer" in
    ipv4:1) fc_network_command ipv4-priority on ;;
    ipv4:2) fc_network_command ipv4-priority off ;;
    rps:1) fc_nic_command rps auto ;;
    rps:2) fc_nic_command rps off ;;
    *)
      fc_warn "无效选项。"
      return 1
      ;;
  esac
}

fc_menu_qdisc() {
  fc_menu_require_config || return 1
  local answer mode
  printf '1) fq\n2) fq_codel\n3) fq_pie\n4) cake\n'
  read -r -p '选择 [1-4]: ' answer
  case "$answer" in 1) mode=fq ;; 2) mode=fq_codel ;; 3) mode=fq_pie ;; 4) mode=cake ;; *)
    fc_warn "无效选项。"
    return 1
    ;;
  esac
  fc_qdisc_command "$mode"
}

fc_menu_operations() {
  local answer stage
  stage="$(fc_read_stage_value STAGE)"
  [[ -n "$stage" ]] || stage=missing
  printf '当前阶段：%s\n' "$(fc_menu_badge "$stage")"
  printf '1) resume   重启后验证 BBRv3 并完成网络调优\n'
  printf '2) status   查看内核、BBR、qdisc、速率和重传状态\n'
  printf '3) diagnose 查看状态、配置冲突和系统能力\n'
  printf '4) security 只读检查 AEAD / Dirty Frag 风险面\n'
  read -r -p '选择 [1-4]: ' answer
  case "$answer" in
    1) fc_resume ;;
    2) fc_status ;;
    3) fc_diagnose ;;
    4) fc_security_audit ;;
    *)
      fc_warn "无效选项。"
      return 1
      ;;
  esac
}

fc_menu_fit() {
  fc_menu_require_config || return 1
  fc_load_config
  local peer nominal cap answer
  printf '可指定靠近本机、带宽高于本机端口的 iperf3 服务端。\n'
  printf '直接回车会从公共节点中按 RTT 和实际可用端口自动选择。\n'
  printf '当前 Flowcraft 整形：单流 %s Mbps / 总出口 %s Mbps。\n' "$PER_FLOW_MBPS" "$TOTAL_MBPS"
  read -r -p '对端 IP / 域名 [自动]: ' peer
  nominal="$TOTAL_MBPS"
  ((nominal > 0)) || nominal="$PER_FLOW_MBPS"
  read -r -p "拟合参考带宽 Mbps（用于健康检查与安全余量）[$nominal]: " answer
  nominal="${answer:-$nominal}"
  fc_is_uint "$nominal" || {
    fc_warn '拟合参考带宽必须是整数 Mbps。'
    return 1
  }
  local -a args=(--nominal "$nominal")
  if [[ -n "$peer" ]]; then
    args+=(--peer "$peer")
    cap=$((nominal * 2))
    ((cap >= 2500)) || cap=2500
    read -r -p "最高扫描速率 Mbps [$cap]: " answer
    cap="${answer:-$cap}"
    fc_is_uint "$cap" && ((cap >= nominal)) || {
      fc_warn '最高扫描速率必须是不小于拟合参考带宽的整数 Mbps。'
      return 1
    }
    if ((cap > 2500)); then
      printf '高带宽扫描会产生大量流量，仅应对自有或独享 iperf3 对端使用。\n'
      read -r -p "确认最高测试 ${cap} Mbps？[y/N]: " answer
      [[ "$answer" =~ ^[Yy]$ ]] || {
        fc_warn '已取消高带宽扫描。'
        return 0
      }
    fi
    args+=(--cap "$cap")
  else
    printf '自动公共模式固定最高 2500 Mbps；若链路更快，只确认能力超出范围并保留现有配置。\n'
  fi
  printf '将按 tcpfit sweep 逻辑先做不限速 fq 单流探测；仅在高丢包时动态扫描。\n'
  printf '只有找到 2/3 可复现丢包拐点才会应用。\n'
  read -r -p '找到可信丢包拐点后自动应用推荐值？[y/N]: ' answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    args+=(--apply)
    if [[ "$ROLE" == relay ]]; then
      read -r -p "同时把单流上限同步为实测推荐值？当前 ${PER_FLOW_MBPS} Mbps [y/N]: " answer
      [[ "$answer" =~ ^[Yy]$ ]] && args+=(--lift-per-flow)
    fi
  fi
  fc_fit_command "${args[@]}"
}

fc_menu_rollback() {
  local confirm
  fc_menu_require_config || return 1
  read -r -p '恢复首次安装前的网络快照，输入 ROLLBACK 确认: ' confirm
  [[ "$confirm" == ROLLBACK ]] || {
    fc_warn "已取消。"
    return 0
  }
  fc_rollback_all
}

fc_menu_uninstall() {
  local confirm
  read -r -p '回滚网络并卸载 Flowcraft，输入 UNINSTALL 确认: ' confirm
  [[ "$confirm" == UNINSTALL ]] || {
    fc_warn "已取消。"
    return 0
  }
  fc_uninstall
}

fc_menu() {
  [[ -t 0 && -t 1 ]] || fc_die "交互式菜单需要终端；自动化请使用 ftcp install --non-interactive。"
  fc_need_root
  local choice
  while true; do
    fc_has clear && clear || true
    fc_menu_render
    read -r -p '请选择 [0-10]: ' choice
    case "$choice" in
      1) fc_menu_run fc_install ;;
      2) fc_menu_run fc_menu_role ;;
      3) fc_menu_run fc_menu_kernel ;;
      4) fc_menu_run fc_menu_toggle ipv4 ;;
      5) fc_menu_run fc_menu_toggle rps ;;
      6) fc_menu_run fc_menu_qdisc ;;
      7) fc_menu_run fc_menu_operations ;;
      8) fc_menu_run fc_menu_fit ;;
      9) fc_menu_run fc_menu_rollback ;;
      10)
        fc_menu_uninstall
        return 0
        ;;
      0) return 0 ;;
      *)
        fc_warn "无效选项。"
        fc_menu_pause
        ;;
    esac
  done
}

fc_usage() {
  cat <<'EOF'
Flowcraft - BBRv3、TCP 调优、监控与出口整形

  ftcp                          打开交互式菜单
  ftcp menu                     打开交互式菜单
  ftcp inspect [--json]          只读环境体检
  ftcp plan [install options]    预览安装与调优计划
  ftcp install [options]         安装；默认进入角色向导
  ftcp resume                    重启后继续安装
  ftcp apply                     重应用持久化配置
  ftcp status                    查看运行状态
  ftcp diagnose                  查看状态和冲突
  ftcp profile general|relay|landing
  ftcp kernel install|status|rollback
  ftcp network ipv4-priority on|off
  ftcp nic rps auto|off
  ftcp qdisc fq|fq_codel|fq_pie|cake
  ftcp security audit            只读内核风险面审计
  ftcp fit [--peer HOST [--port PORT]] --nominal MBPS [--cap MBPS]
           [--from MBPS --to MBPS [--step MBPS]] [--apply] [--lift-per-flow]
                                      tcpfit sweep 实测 policer 丢包拐点
  ftcp experimental max-throughput --yes
  ftcp rollback                  恢复安装前网络状态
  ftcp uninstall                 回滚并卸载程序

无人值守安装参数：
  --non-interactive --role ROLE --kernel standard|skip|max --iface NAME
  --rtt MS --origin-rtt MS --per-flow MBPS --total MBPS
  --burst policer|throughput --ipv4-priority on|off --rps auto|off
  --experimental --yes
EOF
}

fc_main() {
  local command="${1:-}"
  if [[ -z "$command" ]]; then
    if [[ -t 0 && -t 1 ]]; then fc_menu; else fc_usage; fi
    return 0
  fi
  [[ $# -gt 0 ]] && shift || true
  case "$command" in
    bootstrap) fc_bootstrap ;;
    menu) fc_menu ;;
    inspect) fc_inspect "$@" ;;
    plan)
      FC_DRY_RUN=1
      FC_NON_INTERACTIVE=1
      fc_parse_install_options --non-interactive "$@"
      fc_show_plan
      ;;
    install) fc_install "$@" ;;
    resume) fc_resume ;;
    apply) fc_apply_all ;;
    service-apply) fc_service_apply ;;
    status) fc_status ;;
    diagnose) fc_diagnose ;;
    profile) fc_profile "$@" ;;
    kernel) fc_kernel_command "$@" ;;
    network) fc_network_command "$@" ;;
    nic) fc_nic_command "$@" ;;
    qdisc) fc_qdisc_command "$@" ;;
    security) [[ "${1:-}" == audit ]] && fc_security_audit || fc_die "支持：security audit" ;;
    fit) fc_fit_command "$@" ;;
    experimental) fc_experimental_command "$@" ;;
    rollback) fc_rollback_all ;;
    uninstall) fc_uninstall ;;
    version | --version) printf 'ftcp %s\n' "$FLOWCRAFT_VERSION" ;;
    help | -h | --help) fc_usage ;;
    *) fc_die "未知命令：${command}（使用 ftcp help）" ;;
  esac
}

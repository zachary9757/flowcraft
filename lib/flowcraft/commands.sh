#!/usr/bin/env bash

fc_usage() {
  cat <<'EOF'
Usage: flowcraft [COMMAND]

  (no command)                             open the interactive menu
  inspect [--json]                         read-only system inspection
  plan                                     render changes without applying
  apply                                    apply and verify managed state
  status                                   show managed state and drift
  mon [--watch SECONDS]                    read-only counters and qdisc stats
  bbr status                               show BBR capability
  tc status|apply|off                      manage the selected egress qdisc
  fit probe --peer HOST [options]          explicit iperf3 measurement
  rollback                                 restore the pre-apply snapshot
  uninstall                                rollback if needed and remove FlowCraft
  version
EOF
}

fc_uninstall() {
  local installer="$FC_INSTALL_LIB/install.sh" repo_installer
  if [[ ! -f "$installer" || ! -r "$installer" || -L "$installer" ]]; then
    repo_installer="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/install.sh"
    installer="$repo_installer"
  fi
  [[ -f "$installer" && -r "$installer" && ! -L "$installer" ]] ||
    fc_die '未找到可信的 FlowCraft 卸载脚本；请重新下载 install.sh 并运行 --uninstall。'
  bash "$installer" --uninstall
}

fc_main() {
  if (( $# == 0 )); then
    fc_menu
    return
  fi
  local command="$1"
  shift
  case "$command" in
    help|-h|--help) fc_usage ;;
    version|-V|--version) printf 'flowcraft %s\n' "$FLOWCRAFT_VERSION" ;;
    inspect) fc_inspect "$@" ;;
    plan) (($# == 0)) || fc_die 'plan 不接受参数。'; fc_plan ;;
    apply) (($# == 0)) || fc_die 'apply 不接受参数。'; fc_apply ;;
    status) (($# == 0)) || fc_die 'status 不接受参数。'; fc_status ;;
    mon) fc_mon "$@" ;;
    bbr)
      [[ ${1:-} == status && $# == 1 ]] || fc_die '支持：bbr status'
      fc_bbr_status
      ;;
    tc)
      case "${1:-}" in
        status) fc_tc_status ;;
        apply) fc_tc_apply ;;
        off) fc_tc_off ;;
        *) fc_die '支持：tc status|apply|off' ;;
      esac
      ;;
    fit)
      [[ ${1:-} == probe ]] || fc_die '首版支持：fit probe --peer HOST'
      shift
      fc_fit_probe "$@"
      ;;
    rollback) (($# == 0)) || fc_die 'rollback 不接受参数。'; fc_rollback ;;
    uninstall) (($# == 0)) || fc_die 'uninstall 不接受参数。'; fc_uninstall ;;
    *) fc_die "未知命令：$command" ;;
  esac
}

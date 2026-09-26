#!/usr/bin/env bash
set -Eeuo pipefail

repository='zachary9757/flowcraft'
source_ref='main'
install_bin='/usr/local/sbin/flowcraft'
install_lib='/usr/local/lib/flowcraft'
config_dir='/etc/flowcraft'
state_dir='/var/lib/flowcraft'
sysctl_file='/etc/sysctl.d/90-flowcraft.conf'
service_file='/etc/systemd/system/flowcraft.service'

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

require_root_linux() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die '请使用 root 运行（例如 curl ... | sudo bash）。'
  [[ "$(uname -s)" == Linux ]] || die 'FlowCraft 只安装到 Linux。'
}

require_bash() {
  (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) ||
    die '需要 Bash 4.4 或更高版本。'
}

require_commands() {
  local command missing=0
  for command in "$@"; do
    if ! command -v "$command" >/dev/null 2>&1; then
      printf '[ERROR] 缺少依赖：%s\n' "$command" >&2
      missing=1
    fi
  done
  (( missing == 0 )) || die '请安装 iproute2、procps 和 util-linux 后重试。'
}

source_tree_valid() {
  local root="$1"
  [[ -f "$root/bin/flowcraft" && -d "$root/lib/flowcraft" &&
    -f "$root/config/flowcraft.conf.example" &&
    -f "$root/packaging/systemd/flowcraft.service" ]]
}

download_source() {
  local work_dir archive source_dir archive_url
  require_commands curl tar mktemp
  work_dir="$(mktemp -d /tmp/flowcraft-install.XXXXXX)" || die '无法创建临时目录。'
  archive="$work_dir/flowcraft.tar.gz"
  source_dir="$work_dir/source"
  archive_url="https://github.com/${repository}/archive/refs/heads/${source_ref}.tar.gz"
  mkdir -p "$source_dir"
  info "正在下载 FlowCraft ${source_ref} 源码..." >&2
  if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --retry 3 --output "$archive" "$archive_url" ||
    ! tar -xzf "$archive" --strip-components=1 -C "$source_dir" ||
    ! source_tree_valid "$source_dir"; then
    rm -rf -- "$work_dir"
    die '下载包无效或不完整，安装已停止。'
  fi
  printf '%s\n' "$source_dir"
}

has_managed_state() {
  [[ -e "$sysctl_file" || -L "$sysctl_file" ||
    -e "$state_dir/sysctl.snapshot" || -L "$state_dir/sysctl.snapshot" ||
    -e "$state_dir/qdisc.snapshot" || -L "$state_dir/qdisc.snapshot" ||
    -e "$state_dir/managed.state" || -L "$state_dir/managed.state" ]]
}

assert_upgrade_safe() {
  local source_root="$1" desired_version installed_version
  desired_version="$(awk -F= '$1 == "FLOWCRAFT_VERSION" {print $2; exit}' \
    "$source_root/lib/flowcraft/core.sh")"
  [[ "$desired_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die '下载源码缺少有效版本，拒绝安装。'
  if [[ -x "$install_bin" ]]; then
    has_managed_state &&
      die '当前系统处于托管状态；请先用现有程序 rollback 并卸载，再安装新构建。'
    installed_version="$("$install_bin" version 2>/dev/null || true)"
    [[ "$installed_version" == "flowcraft $desired_version" ]] || {
      die "检测到其他版本：${installed_version:-unknown}。请先用原版本 rollback 并卸载。"
    }
  elif [[ -e "$config_dir/config.conf" || -L "$config_dir/config.conf" ]] || has_managed_state; then
    die '检测到 FlowCraft 配置或状态但程序缺失；为保护恢复材料，拒绝覆盖。'
  fi
}

confirm_from_tty() {
  local prompt="$1" default="${2:-no}" answer
  [[ -r /dev/tty ]] || return 1
  printf '%s' "$prompt" >/dev/tty
  IFS= read -r answer </dev/tty || answer=''
  if [[ "$default" == yes && -z "$answer" ]]; then return 0; fi
  [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}

uninstall_flowcraft() {
  require_root_linux
  require_bash
  if has_managed_state; then
    [[ -x "$install_bin" ]] ||
      die '检测到托管状态但程序缺失；为保护回滚材料，拒绝卸载。'
    printf '[WARN] 检测到 FlowCraft 托管状态，必须先执行 flowcraft rollback。\n' >&2
    if ! confirm_from_tty '现在回滚网络并继续卸载？[y/N] '; then
      die '已取消。请先运行 flowcraft rollback，确认成功后重试。'
    fi
    "$install_bin" rollback || die '回滚失败；安装文件和恢复材料均已保留。'
    has_managed_state && die '回滚后仍有托管材料；拒绝继续删除。'
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now flowcraft.service >/dev/null 2>&1 || true
  fi
  rm -f -- "$service_file" "$install_bin" /usr/local/bin/flowcraft /usr/local/bin/ftcp
  rm -rf -- "$install_lib" "$config_dir" "$state_dir"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl reset-failed >/dev/null 2>&1 || true
  fi
  printf '[OK] FlowCraft 已完全卸载。\n'
}

install_flowcraft() {
  local script_path="${BASH_SOURCE[0]:-}" script_root='' source_root='' download_root=''
  require_root_linux
  require_bash
  require_commands systemctl install ip tc sysctl flock cksum cmp
  if [[ -n "$script_path" && "$script_path" != /dev/stdin && -f "$script_path" ]]; then
    script_root="$(cd "$(dirname "$script_path")" 2>/dev/null && pwd || true)"
  fi
  if [[ -n "$script_root" ]] && source_tree_valid "$script_root"; then
    source_root="$script_root"
  else
    source_root="$(download_source)"
    download_root="$(dirname "$source_root")"
  fi
  assert_upgrade_safe "$source_root"

  install -d -m 0755 "$install_lib" "$config_dir" "$state_dir"
  install -m 0755 "$source_root/bin/flowcraft" "$install_bin"
  ln -sfn "$install_bin" /usr/local/bin/flowcraft
  ln -sfn "$install_bin" /usr/local/bin/ftcp
  install -m 0644 "$source_root"/lib/flowcraft/*.sh "$install_lib/"
  install -m 0755 "$source_root/install.sh" "$install_lib/install.sh"
  install -m 0644 "$source_root/packaging/systemd/flowcraft.service" "$service_file"
  if [[ ! -e "$config_dir/config.conf" && ! -L "$config_dir/config.conf" ]]; then
    install -m 0600 "$source_root/config/flowcraft.conf.example" "$config_dir/config.conf"
  fi
  systemctl daemon-reload
  [[ -z "$download_root" ]] || rm -rf -- "$download_root"
  printf '[OK] FlowCraft 已安装。安装过程未修改网络运行态。\n'
  printf '[INFO] 可先运行 flowcraft inspect 和 flowcraft plan。\n'

  if [[ ${FLOWCRAFT_NO_PROMPT:-0} != 1 ]]; then
    if confirm_from_tty '是否立即运行 flowcraft 进入优化面板？[Y/n] ' yes; then
      /usr/local/bin/flowcraft </dev/tty
    else
      printf '[INFO] 稍后运行 sudo flowcraft 即可进入面板。\n'
    fi
  fi
}

case "${1:-}" in
  --uninstall) (($# == 1)) || die '--uninstall 不接受其他参数。'; uninstall_flowcraft ;;
  '') install_flowcraft ;;
  *) die "未知参数：$1" ;;
esac

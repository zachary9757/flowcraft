#!/usr/bin/env bash
set -Eeuo pipefail

release='v0.1.0'
release_commit='f1ec1453cfebf0e881ad0695fe6f9b50d5ad9183'
repository='zachary9757/flowcraft'

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  printf '[ERROR] 请通过 sudo 运行一键安装脚本。\n' >&2
  exit 1
}
[[ "$(uname -s)" == Linux ]] || {
  printf '[ERROR] FlowCraft 只支持 Linux。\n' >&2
  exit 1
}

for command in curl tar mktemp; do
  command -v "$command" >/dev/null 2>&1 || {
    printf '[ERROR] 缺少依赖：%s\n' "$command" >&2
    exit 1
  }
done

if [[ -x /usr/local/sbin/flowcraft ]]; then
  installed_version="$(/usr/local/sbin/flowcraft version 2>/dev/null || true)"
  [[ "$installed_version" == 'flowcraft 0.1.0' ]] || {
    printf '[ERROR] 检测到其他版本：%s\n' "${installed_version:-unknown}" >&2
    printf '[ERROR] 请先使用原版本 rollback 并移走旧配置与状态，再安装 v0.1.0。\n' >&2
    exit 1
  }
elif [[ -e /etc/flowcraft/config.conf || -e /var/lib/flowcraft/sysctl.snapshot ||
  -e /var/lib/flowcraft/qdisc.snapshot || -e /var/lib/flowcraft/managed.state ]]; then
  printf '[ERROR] 检测到 FlowCraft 配置或状态，但没有可验证的 v0.1.0 程序。\n' >&2
  printf '[ERROR] 为避免覆盖旧版恢复材料，一键安装已停止。\n' >&2
  exit 1
fi

temp_root=/tmp
work_dir="$(mktemp -d "$temp_root/flowcraft-install.XXXXXX")"
cleanup() {
  [[ -n "$work_dir" && -d "$work_dir" && "$work_dir" == "$temp_root"/flowcraft-install.* ]] || return 0
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

archive="$work_dir/flowcraft.tar.gz"
source_dir="$work_dir/source"
archive_url="https://github.com/${repository}/archive/${release_commit}.tar.gz"
mkdir -p "$source_dir"

printf '[INFO] 正在下载 FlowCraft %s...\n' "$release"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --retry 3 --output "$archive" "$archive_url"
tar -xzf "$archive" --strip-components=1 -C "$source_dir"

[[ -f "$source_dir/install.sh" && -f "$source_dir/bin/flowcraft" && -d "$source_dir/lib/flowcraft" ]] || {
  printf '[ERROR] 下载包结构无效，拒绝安装。\n' >&2
  exit 1
}

bash "$source_dir/install.sh"

flowcraft_bin=/usr/local/sbin/flowcraft
[[ -x "$flowcraft_bin" ]] || {
  printf '[ERROR] 安装后未找到 flowcraft。\n' >&2
  exit 1
}

checks_failed=0
printf '\n[INFO] 只读检查：flowcraft inspect\n'
"$flowcraft_bin" inspect || checks_failed=1
printf '\n[INFO] 只读计划：flowcraft plan\n'
"$flowcraft_bin" plan || checks_failed=1

printf '\n[OK] FlowCraft %s 已安装。脚本未执行 apply，也未修改网络运行态。\n' "$release"
printf '[INFO] 确认计划后，可手动运行：sudo flowcraft apply\n'
(( checks_failed == 0 )) || {
  printf '[WARN] 安装已完成，但只读检查未全部通过；请先处理上方问题。\n' >&2
  exit 1
}

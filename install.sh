#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf '[ERROR] 请使用 root 运行。\n' >&2; exit 1; }
[[ "$(uname -s)" == Linux ]] || { printf '[ERROR] FlowCraft 只安装到 Linux。\n' >&2; exit 1; }
command -v systemctl >/dev/null 2>&1 || { printf '[ERROR] 当前版本需要 systemd。\n' >&2; exit 1; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -d -m 0755 /usr/local/lib/flowcraft /etc/flowcraft /var/lib/flowcraft
install -m 0755 "$root/bin/flowcraft" /usr/local/sbin/flowcraft
ln -sfn /usr/local/sbin/flowcraft /usr/local/bin/flowcraft
ln -sfn /usr/local/sbin/flowcraft /usr/local/bin/ftcp
install -m 0644 "$root"/lib/flowcraft/*.sh /usr/local/lib/flowcraft/
install -m 0644 "$root/packaging/systemd/flowcraft.service" /etc/systemd/system/flowcraft.service
if [[ ! -e /etc/flowcraft/config.conf ]]; then
  install -m 0600 "$root/config/flowcraft.conf.example" /etc/flowcraft/config.conf
fi
systemctl daemon-reload
printf '[OK] FlowCraft 已安装，但尚未修改网络。先运行 flowcraft inspect 和 flowcraft plan。\n'

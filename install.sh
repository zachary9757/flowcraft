#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

FLOWCRAFT_REPOSITORY="${FLOWCRAFT_REPOSITORY:-zachary9757/flowcraft}"

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

[[ "$(uname -s 2>/dev/null)" == Linux ]] || die "Flowcraft 只支持 Linux。"
if [[ "${FLOWCRAFT_ALLOW_NON_ROOT_TESTS:-0}" != 1 ]]; then
  ((EUID == 0)) || die "请切换到 root 后重新运行安装命令。"
fi
command -v curl >/dev/null 2>&1 || die "缺少 curl。"
command -v tar >/dev/null 2>&1 || die "缺少 tar。"

workdir="$(mktemp -d /tmp/flowcraft-bootstrap.XXXXXX)"
trap 'rm -rf "$workdir"' EXIT
archive="$workdir/flowcraft.tar.gz"
source_dir="$workdir/source"
mkdir -p "$source_dir"

printf '[INFO] 正在下载 Flowcraft main...\n'
curl -fsSL --retry 3 \
  "https://github.com/${FLOWCRAFT_REPOSITORY}/archive/refs/heads/main.tar.gz" \
  -o "$archive"
tar -xzf "$archive" -C "$source_dir" --strip-components=1
[[ -x "$source_dir/bin/ftcp" && -r "$source_dir/lib/flowcraft/commands.sh" ]] || die "下载内容不完整。"

FLOWCRAFT_REPOSITORY="$FLOWCRAFT_REPOSITORY" \
  bash "$source_dir/bin/ftcp" bootstrap

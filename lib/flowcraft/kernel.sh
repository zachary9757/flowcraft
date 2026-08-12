#!/usr/bin/env bash

fc_kernel_arch() {
  case "$(uname -m)" in
    x86_64) printf 'x86_64\n' ;;
    aarch64 | arm64) printf 'arm64\n' ;;
    *) return 1 ;;
  esac
}

fc_kernel_supported_system() {
  local id version
  id="$(fc_os_release_value ID)"
  version="$(fc_os_release_value VERSION_ID)"
  case "$id" in
    debian) fc_version_ge "${version:-0}" 12 ;;
    ubuntu) fc_version_ge "${version:-0}" 24.04 ;;
    *) return 1 ;;
  esac
}

fc_bbr_version() {
  modinfo tcp_bbr 2>/dev/null | awk '/^version:/ {print $2; exit}'
}

fc_kernel_api_get() {
  local url="$1" token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [[ -n "$token" ]]; then
    curl -fsSL -H "Authorization: Bearer $token" -H 'Accept: application/vnd.github+json' "$url"
  else
    curl -fsSL -H 'Accept: application/vnd.github+json' "$url"
  fi
}

fc_kernel_latest_release() {
  local channel="$1" arch suffix regex
  arch="$(fc_kernel_arch)" || fc_die "BBRv3 内核只支持 x86_64 和 arm64。"
  [[ "$channel" == max ]] && suffix='-max' || suffix=''
  regex="^${arch}-[0-9]+\\.[0-9]+\\.[0-9]+${suffix}$"
  fc_has jq || fc_die "安装内核需要 jq。"
  fc_kernel_api_get "https://api.github.com/repos/${FC_REPOSITORY}/releases?per_page=100" |
    jq -c --arg regex "$regex" '[.[] | select(.draft == false) | select(.tag_name | test($regex))] | sort_by(.published_at) | last // empty'
}

fc_kernel_preflight() {
  fc_need_root
  fc_is_linux || fc_die "内核安装只支持 Linux。"
  fc_kernel_arch >/dev/null || fc_die "当前 CPU 架构不支持 Flowcraft 内核。"
  fc_kernel_supported_system || fc_die "Flowcraft 内核仅支持 Debian 12+ 和 Ubuntu 24.04+。当前系统仍可使用 --kernel skip。"
  fc_has dpkg && fc_has apt-get || fc_die "缺少 dpkg/apt-get。"
  fc_has curl && fc_has jq && fc_has sha256sum || fc_die "缺少 curl、jq 或 sha256sum。"
  local free_kb
  free_kb="$(df -Pk /boot 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ -n "$free_kb" ]] || free_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
  ((${free_kb:-0} >= 524288)) || fc_die "/boot 可用空间不足 512 MiB。"
  if ! fc_has update-grub && [[ ! -d /boot/loader/entries ]]; then
    fc_warn "未检测到 GRUB 或 systemd-boot 条目；安装后必须通过 VPS 控制台确认启动项。"
  fi
}

fc_kernel_package_asset_allowed() {
  local name="$1"
  [[ "$name" == "${name##*/}" ]] || return 1
  case "$name" in
    linux-image-*.deb | linux-headers-*.deb)
      [[ "$name" != *-dbg* && "$name" != *-dbgsym* ]]
      ;;
    *) return 1 ;;
  esac
}

fc_kernel_download_release() {
  local channel="$1" destination="$2" release tag checksum_url url name expected actual
  release="$(fc_kernel_latest_release "$channel")"
  [[ -n "$release" ]] || fc_die "Flowcraft Releases 中没有适用于当前架构的 ${channel} 内核。"
  tag="$(jq -r '.tag_name' <<<"$release")"
  checksum_url="$(jq -r '.assets[] | select(.name == "SHA256SUMS") | .browser_download_url' <<<"$release" | head -n 1)"
  [[ -n "$checksum_url" && "$checksum_url" != null ]] || fc_die "Release ${tag} 缺少 SHA256SUMS。"
  mkdir -p "$destination"
  curl -fL --retry 3 "$checksum_url" -o "$destination/SHA256SUMS"
  while IFS=$'\t' read -r name url; do
    [[ -n "$name" && -n "$url" ]] || continue
    fc_kernel_package_asset_allowed "$name" || continue
    curl -fL --retry 3 "$url" -o "$destination/$name"
  done < <(jq -r '.assets[] | select(.name | endswith(".deb")) | [.name,.browser_download_url] | @tsv' <<<"$release")
  compgen -G "$destination/linux-image-*.deb" >/dev/null || fc_die "Release ${tag} 没有可安装的内核镜像。"
  while IFS= read -r -d '' package; do
    name="${package##*/}"
    expected="$(awk -v name="$name" '$2 == name || $2 == "*" name {print $1; exit}' "$destination/SHA256SUMS")"
    [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || fc_die "SHA256SUMS 缺少 ${name}。"
    actual="$(sha256sum "$package" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || fc_die "${name} 校验失败。"
  done < <(find "$destination" -maxdepth 1 -type f \( -name 'linux-image-*.deb' -o -name 'linux-headers-*.deb' \) -print0)
  printf '%s\n' "$tag"
}

fc_write_stage() {
  local stage="$1" expected="${2:-}"
  mkdir -p "$FC_STATE_DIR"
  {
    printf 'STAGE=%s\n' "$stage"
    [[ -n "$expected" ]] && printf 'EXPECTED_KERNEL=%s\n' "$expected"
  } >"$FC_STAGE_FILE"
  chmod 0600 "$FC_STAGE_FILE"
}

fc_read_stage_value() {
  local wanted="$1" key value
  [[ -r "$FC_STAGE_FILE" ]] || return 0
  while IFS='=' read -r key value; do [[ "$key" == "$wanted" ]] && {
    printf '%s\n' "$value"
    return 0
  }; done <"$FC_STAGE_FILE"
}

fc_kernel_install() {
  local channel="${1:-standard}" confirmed="${2:-0}" temp tag version expected debs=()
  [[ "$channel" =~ ^(standard|max)$ ]] || fc_die "内核通道只能是 standard 或 max。"
  if [[ "$channel" == max && "$EXPERIMENTAL" != on ]]; then
    fc_die "Max 内核必须同时启用 --experimental。"
  fi
  fc_kernel_preflight
  ((confirmed == 1)) || fc_die "内核安装需要显式确认；交互安装或 --yes 才会继续。"
  temp="$(mktemp -d /tmp/flowcraft-kernel.XXXXXX)"
  tag="$(fc_kernel_download_release "$channel" "$temp")"
  version="${tag#x86_64-}"
  version="${version#arm64-}"
  version="${version%-max}"
  if [[ "$channel" == max ]]; then expected="${version}-flowcraft-bbrv3-max"; else expected="${version}-flowcraft-bbrv3"; fi
  while IFS= read -r -d '' deb; do debs+=("$deb"); done < <(find "$temp" -maxdepth 1 -type f \( -name 'linux-image-*.deb' -o -name 'linux-headers-*.deb' \) -print0)
  for deb in "${debs[@]}"; do dpkg-deb -I "$deb" >/dev/null || fc_die "无效 Debian 包：$deb"; done
  dpkg -i "${debs[@]}" || apt-get install -f -y
  fc_has update-grub && update-grub
  fc_write_stage pending-reboot "$expected"
  rm -rf "$temp"
  fc_log "已安装 ${tag}，并保留当前与旧内核。"
  fc_warn "现在请自行重启；重启成功后运行：sudo flowcraft resume"
}

fc_kernel_verify_pending() {
  local expected current version
  expected="$(fc_read_stage_value EXPECTED_KERNEL)"
  current="$(uname -r)"
  version="$(fc_bbr_version)"
  [[ -n "$expected" ]] || return 0
  [[ "$current" == "$expected" ]] || fc_die "当前内核为 ${current}，仍未进入待验证内核 ${expected}。"
  [[ "$version" == 3 ]] || fc_die "当前 tcp_bbr 模块版本不是 3。"
}

fc_kernel_status() {
  local stage expected
  stage="$(fc_read_stage_value STAGE)"
  expected="$(fc_read_stage_value EXPECTED_KERNEL)"
  printf 'running=%s\n' "$(uname -r)"
  printf 'bbr_version=%s\n' "$(fc_bbr_version || true)"
  printf 'stage=%s\n' "${stage:-none}"
  printf 'expected=%s\n' "${expected:-none}"
  if fc_has dpkg; then dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^linux-/ && $2 ~ /flowcraft-bbrv3/ {print "package=" $2}'; fi
}

fc_kernel_rollback() {
  fc_need_root
  local running packages
  running="$(uname -r)"
  [[ "$running" != *flowcraft-bbrv3* ]] || fc_die "不能卸载正在运行的 Flowcraft 内核。请先从旧内核启动，再执行 rollback。"
  packages="$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^linux-/ && $2 ~ /flowcraft-bbrv3/ {print $2}')"
  [[ -n "$packages" ]] || {
    fc_info "没有已安装的 Flowcraft 内核包。"
    return 0
  }
  # Package names originate from dpkg and are intentionally word-split here.
  local IFS=$' \n\t'
  # shellcheck disable=SC2086
  apt-get remove --purge -y $packages
  fc_has update-grub && update-grub
  rm -f "$FC_STAGE_FILE"
  fc_log "已卸载非运行中的 Flowcraft 内核包。"
}

fc_security_audit() {
  local boot_config aead='unknown'
  boot_config="/boot/config-$(uname -r)"
  if [[ -r "$boot_config" ]]; then
    grep -Fqx '# CONFIG_CRYPTO_USER_API_AEAD is not set' "$boot_config" && aead=disabled || aead=enabled
  elif [[ -r /proc/config.gz ]] && fc_has gzip; then
    gzip -dc /proc/config.gz 2>/dev/null | grep -Fqx '# CONFIG_CRYPTO_USER_API_AEAD is not set' && aead=disabled || aead=enabled
  fi
  printf 'CONFIG_CRYPTO_USER_API_AEAD=%s\n' "$aead"
  for module in esp4 esp6 rxrpc; do
    if lsmod 2>/dev/null | awk '{print $1}' | grep -Fqx "$module"; then printf '%s=loaded\n' "$module"; else printf '%s=not-loaded\n' "$module"; fi
  done
  printf 'audit_only=true\n'
}

fc_benchmark_client() {
  if fc_has speedtest-cli; then
    printf 'speedtest-cli\n'
  elif fc_has speedtest; then
    printf 'speedtest\n'
  else
    return 1
  fi
}

fc_install_benchmark_client() {
  fc_need_root
  fc_has apt-get || fc_die "当前系统未找到 apt-get，请手动安装 speedtest 或 speedtest-cli。"
  fc_info "正在从系统软件源安装 speedtest-cli；不会删除或替换已有测速工具。"
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y speedtest-cli
}

fc_benchmark_metric() {
  local metric="$1"
  awk -v metric="$metric" '
    {
      lower = tolower($0)
      matched = 0
      if (metric == "ping" && lower ~ /^[[:space:]]*(ping|latency):/) matched = 1
      if (metric == "download" && lower ~ /^[[:space:]]*download:/) matched = 1
      if (metric == "upload" && lower ~ /^[[:space:]]*upload:/) matched = 1
      if (matched) {
        value = $0
        sub(/^[^:]*:[[:space:]]*/, "", value)
        sub(/[^0-9.].*$/, "", value)
        if (value ~ /^[0-9]+([.][0-9]+)?$/) {
          printf "%.2f\n", value
          exit
        }
      }
    }
  '
}

fc_save_benchmark_result() {
  local client="$1" output="$2" ping download upload temp
  ping="$(printf '%s\n' "$output" | fc_benchmark_metric ping)"
  download="$(printf '%s\n' "$output" | fc_benchmark_metric download)"
  upload="$(printf '%s\n' "$output" | fc_benchmark_metric upload)"
  if [[ -z "$download" || -z "$upload" ]]; then
    fc_warn "测速已完成，但无法识别下载/上传结果，面板不会保存本次数据。"
    return 0
  fi
  [[ -n "$ping" ]] || ping=unknown
  mkdir -p "$FC_STATE_DIR"
  temp="$(mktemp "${FC_BENCHMARK_FILE}.XXXXXX")"
  {
    printf 'TESTED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'CLIENT=%s\n' "$client"
    printf 'PING_MS=%s\n' "$ping"
    printf 'DOWNLOAD_MBPS=%s\n' "$download"
    printf 'UPLOAD_MBPS=%s\n' "$upload"
  } >"$temp"
  fc_atomic_replace "$temp" "$FC_BENCHMARK_FILE" 0600
}

fc_benchmark_summary() {
  if [[ ! -r "$FC_BENCHMARK_FILE" ]]; then
    printf '尚未测速（建议先选 8）'
    return 0
  fi
  local key value tested_at='' ping='' download='' upload=''
  while IFS='=' read -r key value; do
    case "$key" in
      TESTED_AT) [[ "$value" =~ ^[0-9TZ:-]+$ ]] && tested_at="$value" ;;
      PING_MS) [[ "$value" == unknown || "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && ping="$value" ;;
      DOWNLOAD_MBPS) [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && download="$value" ;;
      UPLOAD_MBPS) [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && upload="$value" ;;
    esac
  done <"$FC_BENCHMARK_FILE"
  if [[ -z "$download" || -z "$upload" ]]; then
    printf '测速记录不可用，请重新选择 8'
    return 0
  fi
  printf '下载 %s / 上传 %s Mbps' "$download" "$upload"
  [[ -n "$ping" && "$ping" != unknown ]] && printf ' | Ping %s ms' "$ping"
  [[ -n "$tested_at" ]] && printf ' | %s' "$tested_at"
}

fc_benchmark() {
  local mode="${1:-}" client answer output
  fc_need_root
  client="$(fc_benchmark_client || true)"
  if [[ -z "$client" ]]; then
    case "$mode" in
      --install) fc_install_benchmark_client ;;
      --prompt-install)
        [[ -t 0 ]] || fc_die "未找到测速客户端。请运行：flowcraft benchmark --install"
        read -r -p '未找到测速客户端，是否从系统软件源安装 speedtest-cli？[y/N]: ' answer
        [[ "$answer" =~ ^[Yy]$ ]] || {
          fc_warn "已取消测速客户端安装。"
          return 0
        }
        fc_install_benchmark_client
        ;;
      *) fc_die "未找到测速客户端。运行 flowcraft benchmark --install，或从菜单中确认安装。" ;;
    esac
    client="$(fc_benchmark_client || true)"
    [[ -n "$client" ]] || fc_die "speedtest-cli 安装后仍不可用。"
  fi
  fc_info "测速仅用于带宽参考，不会用测速节点延迟替代业务 RTT。"
  case "$client" in
    speedtest-cli) output="$(LC_ALL=C speedtest-cli --secure)" ;;
    speedtest) output="$(LC_ALL=C speedtest --accept-license --accept-gdpr)" ;;
  esac
  printf '%s\n' "$output"
  fc_save_benchmark_result "$client" "$output"
}

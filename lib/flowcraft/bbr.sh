#!/usr/bin/env bash

fc_bbr_status() {
  local available active version
  available="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
  active="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)"
  version="$( (modinfo tcp_bbr 2>/dev/null || true) | awk '/^version:/ {print $2; exit}')"
  printf 'BBR status\n'
  printf '  kernel:    %s\n' "$(uname -r)"
  printf '  available: %s\n' "${available:-unknown}"
  printf '  active:    %s\n' "$active"
  printf '  module:    %s\n' "${version:-present without version metadata or unavailable}"
  if [[ "$version" == 3 ]]; then printf '  BBRv3:     verified\n'; else printf '  BBRv3:     not verified\n'; fi
}

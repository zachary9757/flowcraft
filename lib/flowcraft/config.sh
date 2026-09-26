#!/usr/bin/env bash

fc_config_defaults() {
  ROLE=general
  IFACE=auto
  RTT_MS=100
  PER_FLOW_MBPS=500
  TOTAL_MBPS=0
  QDISC_MODE=auto
}

fc_config_valid() {
  local key="$1" value="$2"
  case "$key" in
    ROLE) [[ "$value" =~ ^(general|relay|landing)$ ]] ;;
    IFACE) [[ "$value" == auto || "$value" =~ ^[a-zA-Z0-9_.:-]+$ ]] ;;
    RTT_MS) fc_is_uint "$value" && (( value >= 1 && value <= 3000 )) ;;
    PER_FLOW_MBPS) fc_is_uint "$value" && (( value >= 1 && value <= 100000 )) ;;
    TOTAL_MBPS) fc_is_uint "$value" && (( value == 0 || (value >= 10 && value <= 100000) )) ;;
    QDISC_MODE) [[ "$value" =~ ^(auto|fq|htb|cake)$ ]] ;;
    *) return 1 ;;
  esac
}

fc_config_load() {
  fc_config_defaults
  [[ -e "$FC_CONFIG_FILE" || -L "$FC_CONFIG_FILE" ]] || return 0
  [[ -f "$FC_CONFIG_FILE" && -r "$FC_CONFIG_FILE" ]] || {
    fc_warn "配置文件不可读或不是普通文件：$FC_CONFIG_FILE"
    return 1
  }
  local key value invalid=0
  while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
    [[ -n "$key" && "$key" != \#* ]] || continue
    if fc_config_valid "$key" "$value"; then
      printf -v "$key" '%s' "$value"
    else
      fc_warn "无效配置：${key}=${value}"
      invalid=1
    fi
  done <"$FC_CONFIG_FILE"
  (( invalid == 0 )) || return 1
  fc_config_validate_semantics
}

fc_config_validate_semantics() {
  if [[ "$QDISC_MODE" =~ ^(htb|cake)$ ]] && (( TOTAL_MBPS == 0 )); then
    fc_die "QDISC_MODE=${QDISC_MODE} 需要非零 TOTAL_MBPS。"
  fi
  if [[ "$QDISC_MODE" == fq ]] && (( TOTAL_MBPS > 0 )); then
    fc_die 'fq 只能限制单流，不能实现 TOTAL_MBPS；请使用 auto、htb 或 cake。'
  fi
}

fc_config_save_defaults() {
  fc_take_lock
  [[ -e "$FC_CONFIG_FILE" ]] && return 0
  local temp
  mkdir -p "$FC_ETC_DIR"
  temp="$(mktemp "$FC_ETC_DIR/.config.XXXXXX")"
  {
    printf '# FlowCraft declarative configuration\n'
    printf 'ROLE=%s\n' "$ROLE"
    printf 'IFACE=%s\n' "$IFACE"
    printf 'RTT_MS=%s\n' "$RTT_MS"
    printf 'PER_FLOW_MBPS=%s\n' "$PER_FLOW_MBPS"
    printf 'TOTAL_MBPS=%s\n' "$TOTAL_MBPS"
    printf 'QDISC_MODE=%s\n' "$QDISC_MODE"
  } >"$temp"
  fc_atomic_replace "$temp" "$FC_CONFIG_FILE" 0600
}

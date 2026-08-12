#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_TMP="$(mktemp -d /tmp/flowcraft-install.XXXXXX)"
trap 'rm -rf "$TASK_TMP"' EXIT
mock_bin="$TASK_TMP/bin"
mkdir -p "$mock_bin"

cat >"$mock_bin/uname" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf 'Linux\n' ;;
  -m) printf 'x86_64\n' ;;
  -r) printf '6.8.0-test\n' ;;
  *) printf 'Linux\n' ;;
esac
MOCK
cat >"$mock_bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FLOWCRAFT_SYSTEMCTL_LOG:?}"
exit 0
MOCK
cat >"$mock_bin/ip" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FLOWCRAFT_IP_LOG:?}"
if [[ "$*" == *"route show"* || "$*" == *"route show to default"* ]]; then
  printf 'default via 192.0.2.1 dev eth-test proto static\n'
fi
exit 0
MOCK
cat >"$mock_bin/tc" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FLOWCRAFT_TC_LOG:?}"
if [[ "$*" == "qdisc show dev "* ]]; then printf 'qdisc fq 0: root refcnt 2\n'; fi
exit 0
MOCK
cat >"$mock_bin/sysctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FLOWCRAFT_SYSCTL_LOG:?}"
if [[ "${1:-}" == -n ]]; then
  [[ "${2:-}" == net.ipv4.tcp_congestion_control ]] && printf 'cubic\n' || printf '0\n'
fi
exit 0
MOCK
cat >"$mock_bin/modprobe" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat >"$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
output=''
while (($#)); do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done
[[ -n "$output" ]]
cp "${FLOWCRAFT_TEST_ARCHIVE:?}" "$output"
MOCK
chmod +x "$mock_bin"/*

export PATH="$mock_bin:$PATH"
export FLOWCRAFT_VERSION=0.1.0
export FLOWCRAFT_ALLOW_NON_ROOT_TESTS=1
export FLOWCRAFT_ETC_DIR="$TASK_TMP/etc/flowcraft"
export FLOWCRAFT_STATE_DIR="$TASK_TMP/state"
export FLOWCRAFT_SYSCTL_FILE="$TASK_TMP/etc/sysctl.d/99-flowcraft.conf"
export FLOWCRAFT_SERVICE_FILE="$TASK_TMP/etc/systemd/flowcraft.service"
export FLOWCRAFT_INSTALL_FILE="$TASK_TMP/usr/local/sbin/flowcraft"
export FLOWCRAFT_COMMAND_FILE="$TASK_TMP/usr/local/bin/flowcraft"
export FLOWCRAFT_INSTALL_LIB_DIR="$TASK_TMP/usr/local/lib/flowcraft"
export FLOWCRAFT_CONFIG_FILE="$FLOWCRAFT_ETC_DIR/config.conf"
export FLOWCRAFT_PROC_ROOT="$TASK_TMP/proc/sys"
export FLOWCRAFT_ROOT_PREFIX="$TASK_TMP/root"
export FLOWCRAFT_GAI_FILE="$TASK_TMP/etc/gai.conf"
export FLOWCRAFT_SYS_CLASS_NET="$TASK_TMP/sys/class/net"
export FLOWCRAFT_SYSTEMCTL_LOG="$TASK_TMP/systemctl.log"
export FLOWCRAFT_IP_LOG="$TASK_TMP/ip.log"
export FLOWCRAFT_TC_LOG="$TASK_TMP/tc.log"
export FLOWCRAFT_SYSCTL_LOG="$TASK_TMP/sysctl.log"
: >"$FLOWCRAFT_SYSTEMCTL_LOG"
: >"$FLOWCRAFT_IP_LOG"
: >"$FLOWCRAFT_TC_LOG"
: >"$FLOWCRAFT_SYSCTL_LOG"

export FLOWCRAFT_TEST_ARCHIVE="$TASK_TMP/flowcraft-source.tar.gz"
tar -czf "$FLOWCRAFT_TEST_ARCHIVE" --exclude=.git -C "$ROOT" .
FLOWCRAFT_NO_MENU=1 "$ROOT/install.sh" >/dev/null
test -x "$FLOWCRAFT_INSTALL_FILE"
test -L "$FLOWCRAFT_COMMAND_FILE"
test ! -e "$FLOWCRAFT_CONFIG_FILE"
printf 'PASS: one-line bootstrap installs program without changing network state\n'

# shellcheck source=../lib/flowcraft/core.sh
source "$ROOT/lib/flowcraft/core.sh"
# shellcheck source=../lib/flowcraft/tuning.sh
source "$ROOT/lib/flowcraft/tuning.sh"
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  path="$(fc_sysctl_proc_path "$key")"
  mkdir -p "$(dirname "$path")"
  : >"$path"
done <<<"$FC_TUNED_KEYS"

"$ROOT/bin/flowcraft" install \
  --non-interactive \
  --role relay \
  --kernel skip \
  --iface eth-test \
  --rtt 160 \
  --per-flow 430 \
  --total 900 \
  --yes >/dev/null

test -x "$FLOWCRAFT_INSTALL_FILE"
test -L "$FLOWCRAFT_COMMAND_FILE"
grep -q '^ROLE=relay$' "$FLOWCRAFT_CONFIG_FILE"
grep -q '^STAGE=complete$' "$FLOWCRAFT_STATE_DIR/install-stage"
grep -q 'net.ipv4.tcp_congestion_control = cubic' "$FLOWCRAFT_SYSCTL_FILE"
grep -q 'qdisc add dev eth-test.*htb' "$FLOWCRAFT_TC_LOG"
grep -q 'maxrate 430mbit' "$FLOWCRAFT_TC_LOG"
grep -q 'ExecStart=.*service-apply' "$FLOWCRAFT_SERVICE_FILE"
printf 'PASS: isolated full install smoke test\n'

"$ROOT/bin/flowcraft" uninstall >/dev/null
test ! -e "$FLOWCRAFT_SYSCTL_FILE"
test ! -e "$FLOWCRAFT_INSTALL_FILE"
test ! -e "$FLOWCRAFT_COMMAND_FILE"
test ! -e "$FLOWCRAFT_STATE_DIR"
grep -q 'qdisc replace dev eth-test root fq' "$FLOWCRAFT_TC_LOG"
grep -q 'net.ipv4.tcp_fin_timeout=0' "$FLOWCRAFT_SYSCTL_LOG"
printf 'PASS: isolated rollback and uninstall smoke test\n'

#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "$repo_root/install.sh" "$repo_root/quick-install.sh" "$repo_root"/bin/* "$repo_root"/lib/flowcraft/*.sh \
  "$repo_root"/tests/*.sh "$repo_root"/tests/unit/*.sh "$repo_root"/tests/integration/*.sh
bash "$repo_root/tests/unit/core-test.sh"
bash "$repo_root/tests/unit/render-test.sh"
"$repo_root/bin/flowcraft" version
"$repo_root/bin/flowcraft" help >/dev/null
printf 'PASS: CLI smoke test\n'
bash "$repo_root/tests/integration/network-namespace.sh"

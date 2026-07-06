#!/usr/bin/env bash
# regen-fixture.sh — refresh the checked-in status.json contract fixture from a
# live clauth daemon. The fixture (Sources/CCSBarKit/Fixtures/status.json) is
# the single source for both the --snapshot render and the decode contract test,
# so it must stay a faithful sample of what `clauth status --json` emits.
#
# NOTE: this captures YOUR real profile names/usage. Sanitize before committing if
# they're sensitive — the checked-in default uses fake names (xfx/cl-ax/zai).
#
# Usage: Scripts/regen-fixture.sh
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dst="$repo_root/Sources/CCSBarKit/Fixtures/status.json"

clauth="$(command -v clauth || echo "$HOME/.cargo/bin/clauth")"
if [ ! -x "$clauth" ]; then
  echo "error: clauth not found on PATH or in ~/.cargo/bin" >&2
  exit 1
fi

"$clauth" status --json | python3 -m json.tool > "$dst"
echo "wrote $dst"
echo "review it (esp. profile names) before committing; run 'swift test' to confirm it still decodes."

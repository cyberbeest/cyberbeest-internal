#!/bin/bash
# Stage 6 (final): checksum every release artifact.
#
# Usage: bash 06-checksums.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

rb_skip_if_done checksums
rb_log checksums

for f in cyberbeest-vm.qcow2 cyberbeest-en.iso cyberbeest-de.iso; do
	[ -f "$OUT_DIR/$f" ] || { echo "Missing expected output: $OUT_DIR/$f" >&2; exit 1; }
done

( cd "$OUT_DIR" && sha256sum cyberbeest-vm.qcow2 cyberbeest-en.iso cyberbeest-de.iso > SHA256SUMS )
cat "$OUT_DIR/SHA256SUMS"

rb_mark_done checksums
echo "=== $(date) : checksums done: $OUT_DIR/SHA256SUMS ==="

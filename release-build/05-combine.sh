#!/bin/bash
# Stage 5: graft the unattended installer onto the remastered live ISO --
# host-side (tower itself), not inside any guest. Thin wrapper around the
# already-existing, already-scriptable combine-live-and-installer.sh.
#
# Usage: bash 05-combine.sh en|de
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

LOCALE_CODE="${1:?Usage: $0 en|de}"
case "$LOCALE_CODE" in en|de) ;; *) echo "Unknown locale code: $LOCALE_CODE" >&2; exit 1 ;; esac

STAGE="$LOCALE_CODE-combine"
rb_skip_if_done "$STAGE"
rb_log "$STAGE"

rb_done "$LOCALE_CODE-remaster" || { echo "$LOCALE_CODE-remaster hasn't completed yet." >&2; exit 1; }

REPO_DIR="$(cd "$RB_DIR/.." && pwd)"   # usb-stick-maker/ (this repo's root)
COMBINE_SCRIPT="$REPO_DIR/combine-live-and-installer.sh"
LIVE_ISO="$OUT_DIR/cyberbeest-$LOCALE_CODE-live-remastered.iso"
OUT_ISO="$OUT_DIR/cyberbeest-$LOCALE_CODE.iso"

[ -f "$COMBINE_SCRIPT" ] || { echo "Missing $COMBINE_SCRIPT" >&2; exit 1; }
[ -f "$LIVE_ISO" ] || { echo "Missing $LIVE_ISO" >&2; exit 1; }

echo "--- Combining $LIVE_ISO + installer -> $OUT_ISO ---"
bash "$COMBINE_SCRIPT" "$LIVE_ISO" "$NETINST_ISO" "$OUT_ISO"

rb_mark_done "$STAGE"
echo "=== $(date) : $STAGE done: $OUT_ISO ==="

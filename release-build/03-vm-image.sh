#!/bin/bash
# Stage 3: convert en/provisioned.qcow2 (already fully provisioned, VM
# powered off by 02-provision.sh) into the shared, standalone distributed VM
# disk image -- output/cyberbeest-vm.qcow2. Purely offline (qemu-img on the
# file, no VM boot), same compact/convert idiom
# provisioning/experimental/build-kvm-donor-image.sh already uses.
#
# English-branch only: locale doesn't matter for the VM image (set
# externally at deploy time, per the standing decision) -- no separate
# de-vm-image stage.
#
# Usage: bash 03-vm-image.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

rb_skip_if_done vm-image
rb_log vm-image

rb_done en-provision || { echo "en-provision hasn't completed yet." >&2; exit 1; }

SRC="$WORKDIR/en/provisioned.qcow2"
OUT="$OUT_DIR/cyberbeest-vm.qcow2"

TMP="$OUT.precleanup.tmp"

echo "--- Copying $SRC -> $TMP (independent copy -- 04-remaster.sh still needs to boot the shared $SRC afterward) ---"
rm -f "$TMP"
qemu-img convert -p -O qcow2 "$SRC" "$TMP"

echo "--- Cleaning build-only cruft from the copy ---"
# Same category of cleanup remaster-live-stick.sh already does on its own
# working copy (see its "Sanitizing the copy" section) -- applied here to
# our own independent copy, never to $SRC directly, since 04-remaster.sh
# still needs to boot $SRC afterward (e.g. deleting its NetworkManager
# connection profile here could leave that later boot without networking).
# Deliberately does NOT touch /etc/fstab or /etc/crypttab (remaster blanks
# those since a live-stick boots via live-boot/squashfs+overlay, not its
# own real disk -- this VM image boots its own real attached qcow2
# normally, so real fstab/crypttab entries are exactly what it needs).
virt-customize -a "$TMP" \
	--run-command 'truncate -s 0 /etc/machine-id' \
	--run-command 'rm -f /var/lib/dbus/machine-id' \
	--run-command 'rm -f /etc/ssh/ssh_host_*' \
	--run-command 'rm -rf /root/.ssh /home/*/.ssh' \
	--run-command 'rm -f /etc/NetworkManager/system-connections/*' \
	--run-command 'rm -rf /var/log/* /var/cache/apt/archives/*.deb' \
	--run-command 'rm -f /root/.bash_history /home/*/.bash_history' \
	--run-command 'rm -rf /var/spool/cron/crontabs/* /var/mail/* /var/spool/mail/*' \
	--run-command 'rm -rf /home/*/.cache /root/.cache'

echo "--- Sparsifying/compacting $TMP -> $OUT ---"
# virt-sparsify, not a plain qemu-img convert: `rm` inside the guest only
# unlinks a file, it doesn't zero the underlying disk blocks -- a plain
# convert/compress would faithfully copy that stale data forward into the
# shipped image. Must run AFTER the cleanup above (zero-fills the blocks
# the cleanup just freed), not before. virt-sparsify examines the guest
# filesystem via libguestfs, zero-fills genuinely-freed blocks, and
# compresses in one pass -- the correct tool for "clean VM template before
# distribution", not a workaround specific to this build.
rm -f "$OUT"
virt-sparsify --compress "$TMP" "$OUT"
rm -f "$TMP"
qemu-img info "$OUT"

rb_mark_done vm-image
echo "=== $(date) : vm-image done: $OUT ==="

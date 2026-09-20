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

echo "--- Setting the VM-product-specific login password ---"
# build-preseed.cfg installs everyone (this copy and 04-remaster.sh's
# live-stick copy alike) with the shared password "live", which makes
# sense on the live stick (stateless overlay boot, nothing to protect) but
# not here -- this qcow2 IS a real persisting disk a customer boots
# repeatedly, so it gets its own password ("virtual") plus a matching
# update to the login-nag's recorded default (21-default-password-nag.sh,
# already run against "live" during 02-provision.sh) so the nag correctly
# recognizes "virtual" as still-default and prompts the customer to change
# it, instead of comparing against a value that was never actually set here.
virt-customize -a "$TMP" \
	--run-command "echo cyberbeest:virtual | chpasswd" \
	--run-command "/usr/local/sbin/cyberbeest-record-initial-password short virtual weak"

echo "--- Installing spice-vdagent + the GNOME Boxes/XFCE resize workaround ---"
# qemu-guest-agent is already baked in via build-preseed.cfg's pkgsel, but
# spice-vdagent isn't -- without it the guest never negotiates display
# resize with GNOME Boxes at all. Even with it, spice-vdagent 0.22.1's
# resize negotiation stalls on XFCE/X11 (no Mutter to answer its
# DisplayConfig D-Bus call), so lib/spice-resize-apply.sh's autostart
# watcher is also needed to actually apply the pending XRandR mode. Same
# fix, same lib/ files, as provisioning/experimental/build-kvm-donor-image.sh
# uses for the sandbox-VM donor image.
virt-customize -a "$TMP" \
	--network \
	--install spice-vdagent \
	--upload "$DIR/lib/spice-resize-apply.sh:/home/cyberbeest/.local/bin/spice-resize-apply.sh" \
	--upload "$DIR/lib/spice-resize-apply.desktop:/home/cyberbeest/.config/autostart/spice-resize-apply.desktop" \
	--run-command "chmod +x /home/cyberbeest/.local/bin/spice-resize-apply.sh" \
	--run-command "chown -R cyberbeest:cyberbeest /home/cyberbeest/.local /home/cyberbeest/.config"

echo "--- Sparsifying $TMP in-place, then compressing -> $OUT ---"
# Switched from `virt-sparsify --compress SRC OUT` (copying mode) to
# `--in-place` + separate `qemu-img convert -c` after hitting a real
# incident 2026-09-19: copying-mode virt-sparsify's "fill free space with
# zero" pass materializes every zeroed cluster as real allocated data in a
# fresh overlay file (doesn't appear to use qemu's efficient zero-write /
# zero-cluster-metadata path), so the scratch overlay grew past the size of
# the entire source disk before we killed it to avoid filling tower's disk.
# --in-place uses actual guest-side discard/trim (punches real holes via
# the virtio discard=unmap path already set on our disk defs) instead of
# writing zero bytes through an overlay -- same "no deleted-file content
# survives into the shipped image" security goal, far less scratch space,
# at the cost of recovering marginally less space than copying mode would
# (per virt-sparsify(1): "not able to recover quite as much space",
# acceptable trade for build reliability).
mkdir -p "$WORKDIR/tmp"
export TMPDIR="$WORKDIR/tmp"
virt-sparsify --in-place "$TMP"

rm -f "$OUT"
qemu-img convert -p -O qcow2 -c "$TMP" "$OUT"
rm -f "$TMP"
qemu-img info "$OUT"

rb_mark_done vm-image
echo "=== $(date) : vm-image done: $OUT ==="

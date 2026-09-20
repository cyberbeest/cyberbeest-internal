#!/bin/bash
# Stage 1 of the release-build pipeline: an unattended Debian+XFCE install
# into $WORKDIR/base.qcow2, shared as the pre-locale-branch backing file for
# both 02-provision.sh runs (en and de). See lib/common.sh for why this uses
# a NON-standard preseed (build-preseed.cfg, no LUKS, disk confirms
# preseeded true) instead of ../preseed.cfg -- that one is for real
# installer sticks, this one is for a throwaway build VM only.
#
# Usage: bash 01-base-install.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

rb_skip_if_done base-install
rb_log base-install

VM_NAME="cyberbeest-build-base"
# Bumped 2026-09-19 from 25G after the guest hit 98% full mid-remaster
# (remaster-live-stick.sh needs a full duplicate of the system on disk
# during its build: rsync copy + squashfs + ISO all coexist -- see its own
# header) -- and that was BEFORE adding the nested donor VM
# (56-cyberbeest-sandbox-vm-kvm.sh, PROVISIONING_VM_IMAGE=yes), whose real
# decompressed-for-use size isn't known yet either. Sparse/thin-provisioned,
# so this costs nothing on the host until actually written -- generous is
# fine.
DISK_SIZE_GB=110
RAM_MB=4096
VCPUS=4

if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
	echo "--- A stale '$VM_NAME' domain already exists -- undefining it (disk file is removed/recreated below too) ---"
	virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
	virsh undefine "$VM_NAME" --nvram >/dev/null 2>&1 || virsh undefine "$VM_NAME" >/dev/null 2>&1 || true
fi

rb_ensure_default_network
rb_ensure_netinst_iso
rb_ensure_ssh_key

echo "--- Creating $BASE_QCOW2 ($DISK_SIZE_GB G, sparse) ---"
rm -f "$BASE_QCOW2"
qemu-img create -f qcow2 "$BASE_QCOW2" "${DISK_SIZE_GB}G"

CONSOLE_LOG="$LOG_DIR/base-install-console.log"
echo "--- Starting unattended install (virt-install --wait, serial console -> $CONSOLE_LOG) ---"
# Attempt 1 used --noautoconsole: zero visibility, silently hung for 6.5
# hours on an unanswerable debconf question (wrong keymap preseed key,
# since fixed) with no way to tell it apart from a slow-but-fine install.
# Attempt 2 dropped --noautoconsole to get virt-install's interactive
# text-console auto-attach instead -- but that needs a real controlling
# TTY, which this script doesn't have when launched via a backgrounded,
# non-interactive SSH command (its actual deployment mode). Fix: back the
# serial device with a plain file (`--serial file,...`) instead of a pty --
# no TTY needed either way, and the file can be tailed/read anytime over a
# completely ordinary (non-pty) SSH command.
virt-install \
	--name "$VM_NAME" \
	--memory "$RAM_MB" \
	--vcpus "$VCPUS" \
	--disk "path=$BASE_QCOW2,format=qcow2,bus=virtio,discard=unmap" \
	--network network=default,model=virtio \
	--os-variant debian12 \
	--location "$NETINST_ISO" \
	--initrd-inject "$DIR/build-preseed.cfg" \
	--initrd-inject "$SSH_KEY.pub" \
	--extra-args "auto=true priority=critical preseed/file=/build-preseed.cfg console=ttyS0 quiet" \
	--graphics spice,listen=127.0.0.1 \
	--video qxl \
	--noautoconsole \
	--serial "file,path=$CONSOLE_LOG" \
	--wait 45 &
VIRT_INSTALL_PID=$!
rb_open_viewer "$VM_NAME"
wait "$VIRT_INSTALL_PID"

echo "--- Install finished, waiting for first boot + SSH ---"
IP="$(rb_wait_for_ip "$VM_NAME")"

echo "--- Sanity check: confirm autologin actually reached a desktop session ---"
# Retried, not one-shot: SSH becoming reachable doesn't mean systemd-logind/
# the autologin session is fully up yet -- a single immediate check hit this
# race and failed once (worked fine a few seconds later, tried by hand).
ok=0
for _ in $(seq 1 12); do
	if rb_ssh "$IP" 'loginctl list-sessions --no-legend' >/dev/null 2>&1; then
		ok=1
		break
	fi
	sleep 5
done
[ "$ok" -eq 1 ] || {
	echo "loginctl check failed after retrying -- autologin/session likely didn't come up correctly" >&2
	exit 1
}

echo "--- Shutting down cleanly ---"
rb_shutdown_and_wait "$VM_NAME"

rb_mark_done base-install
echo "=== $(date) : base-install done: $BASE_QCOW2 ==="

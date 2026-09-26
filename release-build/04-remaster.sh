#!/bin/bash
# Stage 4: boot a locale-branch's provisioned VM and run
# provisioning/experimental/remaster-live-stick.sh *inside* it (it must run
# on the machine being snapshotted, per its own header), then pull the
# resulting live ISO back out to output/. Deletes the provisioned.qcow2
# afterward -- this is its last consumer for the de branch, and (since
# 03-vm-image.sh already ran first for en) its last consumer for the en
# branch too. Keeps disk usage on the 59GB workspace partition to roughly
# "one provisioned VM disk + outputs" at a time instead of all of them at
# once.
#
# Usage: bash 04-remaster.sh en|de
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

LOCALE_CODE="${1:?Usage: $0 en|de}"
case "$LOCALE_CODE" in en|de) ;; *) echo "Unknown locale code: $LOCALE_CODE" >&2; exit 1 ;; esac

STAGE="$LOCALE_CODE-remaster"
rb_skip_if_done "$STAGE"
rb_log "$STAGE"

rb_done "$LOCALE_CODE-provision" || { echo "$LOCALE_CODE-provision hasn't completed yet." >&2; exit 1; }
if [ "$LOCALE_CODE" = "en" ]; then
	rb_done vm-image || { echo "vm-image hasn't completed yet -- it needs en/provisioned.qcow2 before this stage deletes it." >&2; exit 1; }
fi

VM_NAME="cyberbeest-build-$LOCALE_CODE"
PROVISIONED_QCOW2="$WORKDIR/$LOCALE_CODE/provisioned.qcow2"
REMASTER_SCRIPT_LOCAL="$HOME/claude/provisioning/experimental/remaster-live-stick.sh"
REMASTER_SCRIPT_LOCAL_TOWER="$HOME/provisioning-bleeding/experimental/remaster-live-stick.sh"
OUT_ISO="$OUT_DIR/cyberbeest-$LOCALE_CODE-live-remastered.iso"

# On tower this repo lives at ~/provisioning-bleeding (dev-machine copies
# use ~/claude/provisioning); pick whichever exists.
if [ -f "$REMASTER_SCRIPT_LOCAL_TOWER" ]; then
	REMASTER_SCRIPT="$REMASTER_SCRIPT_LOCAL_TOWER"
elif [ -f "$REMASTER_SCRIPT_LOCAL" ]; then
	REMASTER_SCRIPT="$REMASTER_SCRIPT_LOCAL"
else
	echo "Can't find remaster-live-stick.sh in either ~/provisioning-bleeding or ~/claude/provisioning" >&2
	exit 1
fi

rb_ensure_default_network

echo "--- Booting $VM_NAME from its already-provisioned disk ---"
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
	virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
	virsh undefine "$VM_NAME" --nvram >/dev/null 2>&1 || virsh undefine "$VM_NAME" >/dev/null 2>&1 || true
fi
virt-install \
	--name "$VM_NAME" \
	--memory 4096 \
	--vcpus 4 \
	--disk "path=$PROVISIONED_QCOW2,format=qcow2,bus=virtio,discard=unmap" \
	--network network=default,model=virtio \
	--os-variant debian12 \
	--import \
	--graphics spice,listen=127.0.0.1 \
	--video qxl \
	--noautoconsole
rb_open_viewer "$VM_NAME"

# script 99-remove-openssh-server.sh (part of the real provisioning
# sequence, already run in 02-provision.sh) purges sshd and wipes
# authorized_keys -- by design, matching what real shipped machines get.
# So this stage can't just SSH in like the earlier stages did. Instead:
# qemu-guest-agent (installed into base.qcow2/en's overlay specifically for
# this, see cyberbeest_release_build_pipeline memory -- virtio-serial,
# host-only, never network-exposed, kept in shipped artifacts by product
# decision) drives the actual remaster run with zero network exposure.
# SSH only comes back, briefly, at the very end -- purely to pull out the
# already-finished multi-GB ISO, which guest-agent's tiny chunked file API
# can't handle. That's timing-safe: remaster-live-stick.sh builds its
# squashfs from an EARLY rsync'd copy of the filesystem, so anything
# reinstalled after it finishes never gets captured into the shipped
# image -- and this whole disk gets deleted at the end of this script
# regardless, so its own final state (temporarily has sshd again) never
# ships anywhere.
rb_wait_for_ga "$VM_NAME"

echo "--- Writing remaster-live-stick.sh into the guest via guest-agent (no network needed) ---"
rb_ga_write_file "$VM_NAME" "/home/$BUILD_USER/remaster-live-stick.sh" "$REMASTER_SCRIPT"

echo "--- Running it via guest-agent as root (this takes a while -- squashfs + ISO build) ---"
# guest-exec already runs as root (the qemu-guest-agent service's own
# privilege level) -- remaster-live-stick.sh insists on $SUDO_USER being
# set (it checks this is being run via `sudo`, not a raw root shell, so it
# knows which real user to chown the output ISO to); we're not actually
# going through sudo here, so just set the var it's really checking for.
GA_EXEC_CMD="env SUDO_USER=$BUILD_USER http_proxy=$APT_PROXY https_proxy=$APT_PROXY bash /home/$BUILD_USER/remaster-live-stick.sh"
if ! rb_ga_exec "$VM_NAME" "$GA_EXEC_CMD" 3600; then
	echo "FAILED: remaster-live-stick.sh via guest-agent -- leaving $VM_NAME running for inspection." >&2
	exit 1
fi

echo "--- Reinstalling openssh-server (guest-agent) purely to pull the finished ISO out -- timing-safe, see comment above ---"
rb_ga_exec "$VM_NAME" "apt-get -o DPkg::Lock::Timeout=60 install -y openssh-server" 300 >/dev/null
# rb_ga_exec has no stdin-piping support (guest-exec's own input-data field
# isn't wired up here) -- the authorized_keys content travels via
# guest-file-write, same mechanism as the script upload above, not shell
# redirection into a guest-agent command.
rb_ga_write_file "$VM_NAME" "/home/$BUILD_USER/.ssh/authorized_keys.tmp" "$SSH_KEY.pub"
rb_ga_exec "$VM_NAME" "mkdir -p /home/$BUILD_USER/.ssh && mv /home/$BUILD_USER/.ssh/authorized_keys.tmp /home/$BUILD_USER/.ssh/authorized_keys && chown -R $BUILD_USER:$BUILD_USER /home/$BUILD_USER/.ssh && chmod 700 /home/$BUILD_USER/.ssh && chmod 600 /home/$BUILD_USER/.ssh/authorized_keys && systemctl enable --now ssh" 60

IP="$(rb_wait_for_ip "$VM_NAME")"

echo "--- Pulling the resulting ISO back to $OUT_ISO ---"
rb_scp_from "$IP" "/home/$BUILD_USER/cyberbeest-live-remastered-amd64.iso" "$OUT_ISO"

echo "--- Shutting down and discarding the provisioned VM disk ---"
rb_shutdown_and_wait "$VM_NAME"
virsh undefine "$VM_NAME" --nvram >/dev/null 2>&1 || virsh undefine "$VM_NAME" >/dev/null 2>&1 || true
rm -f "$PROVISIONED_QCOW2"

rb_mark_done "$STAGE"
echo "=== $(date) : $STAGE done: $OUT_ISO ==="

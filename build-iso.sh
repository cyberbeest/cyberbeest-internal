#!/bin/bash
# Remasters a stock Debian 13 (trixie) amd64 netinst ISO into an
# unattended-install Cyberbeest USB image: injects preseed.cfg and
# cyberbeest-files/ (see their own comments), and adds a boot menu entry
# that auto-selects the preseeded install after a short timeout, for both
# BIOS (isolinux) and UEFI (grub) boot paths.
#
# Usage: ./build-iso.sh /path/to/debian-13.x.x-amd64-netinst.iso [output.iso]
#
# Grab the source ISO yourself from https://www.debian.org/CD/netinst/ (or
# copy one over from another machine) -- this script doesn't fetch it, since
# doing so reliably means tracking Debian's current point release.
#
# Needs xorriso. Does not touch any USB device -- it only produces an .iso
# file; write it to a stick yourself once you're happy with it, e.g.:
#   sudo dd if=cyberbeest-13-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

SRC_ISO="${1:?Usage: $0 /path/to/debian-13.x.x-amd64-netinst.iso [output.iso]}"
OUT_ISO="${2:-$DIR/cyberbeest-13-amd64.iso}"

if [ ! -f "$SRC_ISO" ]; then
	echo "Source ISO not found: $SRC_ISO" >&2
	exit 1
fi

if ! command -v xorriso >/dev/null 2>&1; then
	echo "Installing xorriso..."
	sudo apt-get -o DPkg::Lock::Timeout=60 update
	sudo apt-get -o DPkg::Lock::Timeout=60 install -y xorriso
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Extracting boot menu files from $SRC_ISO..."
xorriso -indev "$SRC_ISO" \
	-osirrox on \
	-extract /isolinux/txt.cfg "$WORK/txt.cfg" \
	-extract /isolinux/isolinux.cfg "$WORK/isolinux.cfg" \
	-extract /boot/grub/grub.cfg "$WORK/grub.cfg"

echo "Patching isolinux menu (BIOS boot)..."
# Prepend our automated entry and make it the default; a stanza earlier in
# txt.cfg wins as the pre-highlighted "menu default" entry.
{
	cat <<-'EOF'
	label auto
		menu label ^Auto Cyberbeest install (ERASES THE DISK)
		menu default
		kernel /install.amd/vmlinuz
		append auto=true priority=high vga=788 initrd=/install.amd/initrd.gz preseed/file=/cdrom/preseed.cfg --- quiet

	label hd
		menu label Boot from ^hard disk (skip install)
		localboot 0x80

	EOF
	# Strip any pre-existing "menu default" so ours is the only one.
	sed 's/^\tmenu default$//' "$WORK/txt.cfg"
} > "$WORK/txt.cfg.new"
mv "$WORK/txt.cfg.new" "$WORK/txt.cfg"

# Wait indefinitely for a keypress instead of auto-booting -- the "auto"
# entry is still pre-highlighted (menu default above) so Enter picks it, but
# nothing happens on its own if the stick is left in a machine that reboots
# unattended. isolinux timeout 0 means "wait forever" (this is also the
# stock ISO's own default).
sed -i \
	-e 's/^timeout .*/timeout 0/' \
	"$WORK/isolinux.cfg"
if ! grep -q '^timeout ' "$WORK/isolinux.cfg"; then
	printf 'timeout 0\n' >> "$WORK/isolinux.cfg"
fi

echo "Patching grub menu (UEFI boot)..."
# grub.cfg as shipped has no "set default"/"set timeout" (GRUB waits
# indefinitely) and its existing "Automated install" entry is buried in the
# "Advanced options" submenu, which grub's plain numeric default can't
# target reliably. So: insert our own top-level entry (kernel/initrd paths
# and args verified against the real vmlinuz/initrd.gz entries already in
# this file) right before the first menuentry, and set default=0 so Enter
# picks it -- but timeout=-1 (wait indefinitely, GRUB's own default meaning)
# rather than a countdown, so it never boots itself unattended.
# /boot/grub/x86_64-efi/grub.cfg just sources this file, so patching it
# alone covers UEFI too.
awk '
	!inserted && /^menuentry --hotkey=g / {
		print "set default=0"
		print "set timeout=-1"
		print "menuentry \x27Auto Cyberbeest install (ERASES THE DISK)\x27 {"
		print "    set background_color=black"
		print "    linux    /install.amd/vmlinuz auto=true priority=high vga=788 preseed/file=/cdrom/preseed.cfg --- quiet"
		print "    initrd   /install.amd/initrd.gz"
		print "}"
		print "menuentry \x27Boot from hard disk (skip install)\x27 {"
		print "    exit"
		print "}"
		inserted = 1
	}
	{ print }
' "$WORK/grub.cfg" > "$WORK/grub.cfg.new"
if [ "$(grep -c '^set default=0$' "$WORK/grub.cfg.new")" -ne 1 ]; then
	echo "Failed to insert automated entry into grub.cfg (menu layout changed?)" >&2
	exit 1
fi
mv "$WORK/grub.cfg.new" "$WORK/grub.cfg"

echo "Assembling $OUT_ISO..."
xorriso -indev "$SRC_ISO" \
	-outdev "$OUT_ISO" \
	-volid "Cyberbeest Installer" \
	-map "$DIR/preseed.cfg" /preseed.cfg \
	-map "$DIR/cyberbeest-files" /cyberbeest-files \
	-map "$WORK/txt.cfg" /isolinux/txt.cfg \
	-map "$WORK/isolinux.cfg" /isolinux/isolinux.cfg \
	-map "$WORK/grub.cfg" /boot/grub/grub.cfg \
	-boot_image any replay \
	-changes_pending yes \
	-commit

echo
echo "Done: $OUT_ISO"
echo "Write it to a stick with:"
echo "  sudo dd if=$OUT_ISO of=/dev/sdX bs=4M status=progress conv=fsync"

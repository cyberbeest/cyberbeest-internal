#!/bin/bash
# Grafts the unattended installer (this directory's preseed.cfg +
# cyberbeest-files/, same as build-iso.sh injects into a bare netinst ISO)
# onto a Cyberbeest *live* ISO (the output of
# provisioning/experimental/remaster-live-stick.sh), so one stick can both
# boot live (try it) and install to disk (buy it / keep it).
#
# The live ISO's own boot menu is left as the default -- this only ADDS two
# entries alongside it, in both isolinux (BIOS) and grub (UEFI) menus. Live
# boot stays "menu default" / grub default=0; installing is a deliberate
# extra keypress either way:
#
# - "Auto Cyberbeest install (ERASES THE DISK)": same preseeded, unattended
#   install build-iso.sh's netinst stick offers, same ERASES-THE-DISK label,
#   plus the same partman/confirm safety net (see preseed.cfg comments --
#   those prompts stay real, unpreseeded, on purpose). This always
#   repartitions the WHOLE disk from scratch -- confirmed by reading the
#   actual d-i partman-auto source (10initial_auto -> autopartition's
#   one-argument "do not reuse existing partitions" path) -- it does NOT
#   opportunistically use free space and leave other OSes' partitions alone.
# - "Install Cyberbeest (manual partitioning)": the plain, unpreseeded
#   Debian installer (same /install.amd kernel+initrd, no preseed/file, no
#   auto=true/priority=high) -- every question including the guided-vs-manual
#   partitioning chooser is asked normally, so this is the path that can
#   shrink/keep an existing partition (e.g. a dual-boot OS) instead of
#   wiping the disk.
#
# Usage: ./combine-live-and-installer.sh /path/to/cyberbeest-live-remastered-amd64.iso [/path/to/debian-13-netinst.iso] [output.iso]
#
# The installer kernel/initrd (install.amd/vmlinuz + initrd.gz), plus the
# netinst ISO's pool/ (installer-component udebs) and firmware/ (non-free
# firmware for hardware detection) directories, are pulled from a Debian
# netinst ISO -- same source build-iso.sh uses. Those two directories are
# what let d-i bring up storage/network drivers -- including proprietary
# firmware blobs a random target machine's wifi/NIC chip might need -- on
# hardware it doesn't already know, BEFORE it has network access to fetch
# anything else (this preseed installs the actual OS packages over the
# network per apt-setup/use_mirror, but that's chicken-and-egg without a
# working NIC first). Carrying them keeps this stick's hardware coverage on
# par with build-iso.sh's netinst-remaster stick (which keeps the whole
# source ISO, pool/+firmware/ included) rather than only the exact laptop
# model this product currently ships. If omitted, or the given path doesn't
# exist, the netinst ISO is downloaded and checksum-verified the same way
# build-iso.sh does.
#
# Needs xorriso. Does not touch any USB device -- produces an .iso; write it
# to a stick yourself once you're happy with it, e.g.:
#   sudo dd if=cyberbeest-combined-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

DEBIAN_ISO_BASE_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"

LIVE_ISO="${1:?Usage: $0 /path/to/cyberbeest-live-remastered-amd64.iso [/path/to/debian-13-netinst.iso] [output.iso]}"
SRC_ISO="${2:-$DIR/debian-13-amd64-netinst.iso}"
OUT_ISO="${3:-$DIR/cyberbeest-combined-amd64.iso}"

if [ ! -f "$LIVE_ISO" ]; then
	echo "Live ISO not found: $LIVE_ISO" >&2
	echo "Build it first with provisioning/experimental/remaster-live-stick.sh" >&2
	exit 1
fi

if [ ! -f "$SRC_ISO" ]; then
	echo "Netinst ISO not found at $SRC_ISO -- downloading current Debian 13 netinst ISO..."

	ISO_NAME="$(curl -fsSL "$DEBIAN_ISO_BASE_URL/SHA256SUMS" | awk '$2 ~ /^debian-[0-9][^-]*-amd64-netinst\.iso$/ {print $2}' | head -n1)"
	if [ -z "$ISO_NAME" ]; then
		echo "Couldn't find a netinst ISO listed in $DEBIAN_ISO_BASE_URL/SHA256SUMS" >&2
		exit 1
	fi

	DL_TMP="$(mktemp)"
	trap 'rm -f "$DL_TMP"' EXIT
	curl -fSL --progress-bar "$DEBIAN_ISO_BASE_URL/$ISO_NAME" -o "$DL_TMP"

	echo "Verifying checksum..."
	EXPECTED_SUM="$(curl -fsSL "$DEBIAN_ISO_BASE_URL/SHA256SUMS" | awk -v f="$ISO_NAME" '$2 == f {print $1}')"
	ACTUAL_SUM="$(sha256sum "$DL_TMP" | awk '{print $1}')"
	if [ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]; then
		echo "Checksum mismatch for $ISO_NAME: expected $EXPECTED_SUM, got $ACTUAL_SUM" >&2
		exit 1
	fi

	mkdir -p "$(dirname "$SRC_ISO")"
	mv "$DL_TMP" "$SRC_ISO"
	trap - EXIT
	echo "Downloaded and verified: $SRC_ISO"
fi

if ! command -v xorriso >/dev/null 2>&1; then
	echo "Installing xorriso..."
	sudo apt-get -o DPkg::Lock::Timeout=60 update
	sudo apt-get -o DPkg::Lock::Timeout=60 install -y xorriso
fi

WORK="$(mktemp -d)"
# osirrox preserves the source ISO's (read-only) permissions on extracted
# files/dirs, which blocks a plain rm -rf on cleanup -- chmod first.
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

echo "Extracting installer kernel/initrd + pool/firmware/dists (for hardware coverage) from $SRC_ISO..."
mkdir -p "$WORK/install.amd" "$WORK/disk-markers"
xorriso -indev "$SRC_ISO" \
	-osirrox on \
	-extract /install.amd/vmlinuz "$WORK/install.amd/vmlinuz" \
	-extract /install.amd/initrd.gz "$WORK/install.amd/initrd.gz" \
	-extract /pool "$WORK/pool" \
	-extract /firmware "$WORK/firmware" \
	-extract /dists "$WORK/dists" \
	-extract /.disk/base_components "$WORK/disk-markers/base_components" \
	-extract /.disk/base_installable "$WORK/disk-markers/base_installable" \
	-extract /.disk/cd_type "$WORK/disk-markers/cd_type" \
	-extract /.disk/udeb_include "$WORK/disk-markers/udeb_include"
# dists/ is the actual APT repository index (Release/Packages files) that
# tells apt what's in pool/ and how to trust it -- without it, apt-setup
# can't recognize this stick as a valid package source at all
# ("Error reading release file", found testing the manual-install entry
# 2026-09-09). The .disk/base_installable + cd_type + base_components +
# udeb_include marker files are what cdrom-detect/base-installer check to
# know a mounted disc can supply the base system and udebs -- added
# alongside (not replacing) the live ISO's own /.disk/info + mkisofs, which
# describe the live image and aren't checked by the installer.

echo "Extracting live ISO's boot menu files to patch..."
xorriso -indev "$LIVE_ISO" \
	-osirrox on \
	-extract /isolinux/menu.cfg "$WORK/menu.cfg" \
	-extract /boot/grub/grub.cfg "$WORK/grub.cfg"

echo "Patching isolinux menu (BIOS boot) -- adding install entries, not touching the live default..."
cat >"$WORK/installer.cfg" <<-'EOF'
label auto-install
	menu label ^Install Cyberbeest (ERASES THE DISK)
	kernel /install.amd/vmlinuz
	append auto=true priority=high vga=788 initrd=/install.amd/initrd.gz preseed/file=/cdrom/preseed.cfg --- quiet

label manual-install
	menu label Install Cyberbeest (^manual partitioning)
	kernel /install.amd/vmlinuz
	append vga=788 initrd=/install.amd/initrd.gz preseed/file=/cdrom/preseed-manual-grubfix.cfg --- quiet

EOF
awk '
	/^include live\.cfg$/ { print; print "include installer.cfg"; next }
	{ print }
' "$WORK/menu.cfg" > "$WORK/menu.cfg.new"
if ! grep -q '^include installer\.cfg$' "$WORK/menu.cfg.new"; then
	echo "Failed to insert installer.cfg include into isolinux/menu.cfg (layout changed?)" >&2
	exit 1
fi
mv "$WORK/menu.cfg.new" "$WORK/menu.cfg"

echo "Patching grub menu (UEFI boot) -- adding install entries, not touching default=0..."
awk '
	!inserted && /^# You can add more entries like this$/ {
		print "menuentry \x27Install Cyberbeest (ERASES THE DISK)\x27 {"
		print "    set background_color=black"
		print "    linux    /install.amd/vmlinuz auto=true priority=high vga=788 preseed/file=/cdrom/preseed.cfg --- quiet"
		print "    initrd   /install.amd/initrd.gz"
		print "}"
		print "menuentry \x27Install Cyberbeest (manual partitioning)\x27 {"
		print "    set background_color=black"
		print "    linux    /install.amd/vmlinuz vga=788 preseed/file=/cdrom/preseed-manual-grubfix.cfg --- quiet"
		print "    initrd   /install.amd/initrd.gz"
		print "}"
		inserted = 1
	}
	{ print }
' "$WORK/grub.cfg" > "$WORK/grub.cfg.new"
if [ "$(grep -c "Install Cyberbeest (ERASES THE DISK)" "$WORK/grub.cfg.new")" -ne 1 ] || \
   [ "$(grep -c "Install Cyberbeest (manual partitioning)" "$WORK/grub.cfg.new")" -ne 1 ]; then
	echo "Failed to insert installer entries into grub.cfg (menu layout changed?)" >&2
	exit 1
fi
mv "$WORK/grub.cfg.new" "$WORK/grub.cfg"

echo "Assembling $OUT_ISO..."
xorriso -indev "$LIVE_ISO" \
	-outdev "$OUT_ISO" \
	-volid "Cyberbeest Combined" \
	-map "$DIR/preseed.cfg" /preseed.cfg \
	-map "$DIR/preseed-manual-grubfix.cfg" /preseed-manual-grubfix.cfg \
	-map "$DIR/cyberbeest-files" /cyberbeest-files \
	-map "$WORK/install.amd" /install.amd \
	-map "$WORK/pool" /pool \
	-map "$WORK/firmware" /firmware \
	-map "$WORK/dists" /dists \
	-map "$WORK/disk-markers/base_components" /.disk/base_components \
	-map "$WORK/disk-markers/base_installable" /.disk/base_installable \
	-map "$WORK/disk-markers/cd_type" /.disk/cd_type \
	-map "$WORK/disk-markers/udeb_include" /.disk/udeb_include \
	-map "$WORK/menu.cfg" /isolinux/menu.cfg \
	-map "$WORK/installer.cfg" /isolinux/installer.cfg \
	-map "$WORK/grub.cfg" /boot/grub/grub.cfg \
	-boot_image any replay \
	-changes_pending yes \
	-commit

echo
echo "Done: $OUT_ISO"
echo "Write it to a stick with:"
echo "  sudo dd if=$OUT_ISO of=/dev/sdX bs=4M status=progress conv=fsync"

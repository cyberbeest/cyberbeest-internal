#!/bin/bash
# Applies the display mode spice-vdagent negotiates but never switches to.
# spice-vdagent tries GNOME Mutter's DisplayConfig D-Bus API first for
# resolution changes; on XFCE/X11 (no Mutter running) that fails, and its
# fallback only registers the new mode via XRandR (visible as a "+"-marked
# pending mode) without ever calling `xrandr --output ... --mode ...` to
# switch to it -- so GNOME Boxes just stretches/scales the old framebuffer
# into the resized window instead of the guest truly changing resolution.
# This closes that gap: watch for a pending mode that differs from the
# current one and apply it.
#
# Ships inside the Cyberbeest sandbox guest image itself (installed via
# lib/build-kvm-donor-image.sh at image-build time, not per-install), paired
# with the autostart entry that launches it on login.
OUTPUT=Virtual-1

while sleep 1; do
  pending=$(xrandr | awk -v out="$OUTPUT" '
    $0 ~ "^"out" connected" {want=1; next}
    /^[A-Za-z]/ {want=0}
    want && /\+/ {print $1; exit}
  ')
  current=$(xrandr | awk -v out="$OUTPUT" '
    $0 ~ "^"out" connected" {want=1; next}
    /^[A-Za-z]/ {want=0}
    want && /\*/ {print $1; exit}
  ')
  if [ -n "$pending" ] && [ "$pending" != "$current" ]; then
    xrandr --output "$OUTPUT" --mode "$pending"
  fi
done

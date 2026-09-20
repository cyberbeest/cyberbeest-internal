# usb-stick-maker

Builds an unattended-install Cyberbeest USB/DVD image from a stock Debian 13
(trixie) amd64 netinst ISO: a preseed file plus a small first-boot bootstrap
that kicks off the real provisioning from
[cyberbeest/provisioning](https://github.com/cyberbeest/provisioning).

## Usage

```
./build-iso.sh [/path/to/debian-13.x.x-amd64-netinst.iso] [output.iso]
```

If the source ISO is omitted, or the given path doesn't exist yet,
`build-iso.sh` downloads the current Debian 13 (trixie) amd64 netinst ISO
from Debian's cdimage mirror, verifies it against the published
SHA256SUMS, and caches it there (or at `debian-13-amd64-netinst.iso` next
to the script if no path was given) for reuse on later runs.

Write the result to a stick with:

```
sudo dd if=cyberbeest-13-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Booting it wipes the target disk and installs Cyberbeest unattended, aside
from a couple of deliberately-unpreseeded confirmation/keyboard-layout
prompts (see the comments in `preseed.cfg` for why).

## Combined live + install stick

For a stick sold to a customer, `combine-live-and-installer.sh` grafts this
same installer onto a Cyberbeest **live** ISO (built separately by
`provisioning/experimental/remaster-live-stick.sh`), so one stick can both
boot live to try it and install to disk to keep it -- as one more boot menu
entry, without touching the live image's own default boot:

```
./combine-live-and-installer.sh /path/to/cyberbeest-live-remastered-amd64.iso [/path/to/debian-13-netinst.iso] [output.iso]
```

Adds two install entries alongside the live boot menu: a preseeded
"ERASES THE DISK" one, and a plain unpreseeded one (normal Debian installer,
including the guided-vs-manual partitioning question) for keeping an
existing OS partition (e.g. dual-boot) instead of wiping the disk. Also
carries over the netinst ISO's `pool/` and `firmware/` directories (~750MB),
which is what lets the installer bring up storage/network drivers --
including non-free firmware for an unknown wifi/NIC chip -- on hardware it
doesn't already know, so a stick meant to be sold isn't limited to the exact
laptop model this product currently ships on. Output is ~3.7GB (~2.9GB live
snapshot + ~750MB installer support files).

Same netinst-download-and-cache behavior as `build-iso.sh` for the second
argument. Write the result to a stick the same way (`dd`, see above).

## Files

- `build-iso.sh` — remasters a netinst ISO into an installer-only stick
- `combine-live-and-installer.sh` — grafts the installer onto a live ISO instead, for a combined try-then-install stick
- `preseed.cfg` — the Debian installer preseed
- `cyberbeest-files/` — first-boot bootstrap files copied onto the target disk

## License

[PolyForm Shield 1.0.0](LICENSE), same as `provisioning`.

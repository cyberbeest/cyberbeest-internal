# usb-stick-maker

Builds an unattended-install Cyberbeest USB/DVD image from a stock Debian 13
(trixie) amd64 netinst ISO: a preseed file plus a small first-boot bootstrap
that kicks off the real provisioning from
[cyberbeest/provisioning](https://github.com/cyberbeest/provisioning).

## Usage

Grab a Debian 13 netinst ISO yourself (`build-iso.sh` doesn't fetch it, since
that means tracking Debian's current point release), then:

```
./build-iso.sh /path/to/debian-13.x.x-amd64-netinst.iso [output.iso]
```

Write the result to a stick with:

```
sudo dd if=cyberbeest-13-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Booting it wipes the target disk and installs Cyberbeest unattended, aside
from a couple of deliberately-unpreseeded confirmation/keyboard-layout
prompts (see the comments in `preseed.cfg` for why).

## Files

- `build-iso.sh` — remasters the source ISO
- `preseed.cfg` — the Debian installer preseed
- `cyberbeest-files/` — first-boot bootstrap files copied onto the target disk

## License

[PolyForm Shield 1.0.0](LICENSE), same as `provisioning`.

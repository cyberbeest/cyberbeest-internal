#!/bin/sh
# Run via preseed.cfg's d-i preseed/early_command, right at the start of the
# automated install, so there's an explicit "this erases the disk" screen
# on top of the boot menu label and partman's own unmodified confirm
# screens later.
#
# whiptail is NOT actually part of this environment: the ISO's pool only
# carries it as a regular .deb, not a udeb, and confirmed by test-boot to
# fail with exit 127 ("not found") when called directly. Every dialog you
# actually see in the installer -- including partman's own confirm screens
# -- is cdebconf (via libnewt0.52-udeb) rendering a registered debconf
# template, not a whiptail call. So this uses the same mechanism: register
# an ad-hoc "note" template with debconf-loadtemplate and show it at
# priority critical, same idiom preseed.cfg relies on for partman's
# "really wipe this disk?" confirms to survive priority=critical/auto=true.
. /usr/share/debconf/confmodule
debconf-loadtemplate cyberbeest /cdrom/cyberbeest-files/warn.templates
db_input critical cyberbeest/erase-warning
db_go

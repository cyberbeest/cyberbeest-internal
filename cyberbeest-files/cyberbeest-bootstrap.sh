#!/bin/bash
# First-boot autostart entry point, installed by preseed.cfg's late_command.
# Fetches and runs the real beestify.sh from the provisioning repo (single
# source of truth -- this script does not duplicate its clone/menu logic)
# and only removes its own autostart entry once every NN-*.sh provisioning
# script has actually completed, so an interrupted run just tries again on
# the next login.
set -uo pipefail

AUTOSTART_FILE="$HOME/.config/autostart/cyberbeest-provisioning.desktop"
BEESTIFY_URL="https://raw.githubusercontent.com/cyberbeest/provisioning/stable/beestify.sh"
# Must match beestify.sh's own CLONE_DIR.
CLONE_DIR="$HOME/provisioning"

echo "Starting Cyberbeest provisioning..."
echo

if ! command -v curl >/dev/null 2>&1; then
	sudo apt-get -o DPkg::Lock::Timeout=60 update
	sudo apt-get -o DPkg::Lock::Timeout=60 install -y curl
fi

bash -c "$(curl -fsSL "$BEESTIFY_URL")"
status=$?

# run-gui.py's own exit status isn't a reliable "did it finish" signal:
# closing its window normally always exits 0 no matter how much was run,
# while logging out or rebooting *without* closing it first kills the
# process via SIGTERM instead -- which Python doesn't catch, so it reports
# a nonzero/killed status even after every script genuinely succeeded.
# Check the actual on-disk state instead: a script counts as done once its
# .log is newer than the script itself, the same test run-gui.py's own
# sidebar status uses.
COMPLETE=0
if [ -d "$CLONE_DIR" ]; then
	COMPLETE=1
	for f in "$CLONE_DIR"/[0-9][0-9]-*.sh "$CLONE_DIR"/[0-9][0-9][a-z]-*.sh; do
		[ -e "$f" ] || continue
		log="${f%.sh}.log"
		if [ ! -e "$log" ] || [ "$f" -nt "$log" ]; then
			COMPLETE=0
			break
		fi
	done
fi

echo
if [ "$COMPLETE" -eq 1 ]; then
	rm -f "$AUTOSTART_FILE"
	echo "Provisioning finished. This window will not reappear on next login."
else
	echo "Provisioning did not finish (run-gui.py exit status: $status)."
	echo "It will run again next time you log in, or run:"
	echo "  bash -c \"\$(curl -fsSL $BEESTIFY_URL)\""
fi

echo
echo "Press Enter to close this window."
read -r _

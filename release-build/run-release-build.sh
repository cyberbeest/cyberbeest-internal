#!/bin/bash
# Runs every release-build stage in order, skipping any already marked done
# (state/<stage>.done) -- safe to re-run after a crash/interruption (tower's
# PSU flakiness and the xfce4-panel segfault are both known, pre-existing
# issues -- see cyberbeest_tower_psu_black_screen_incident and
# tower_xfce_panel_liblauncher_segfault memories) since it just resumes from
# whatever the last completed stage was.
#
# This is the CLI form of the pipeline; build-release-gui.py (planned, not
# yet written) will wrap the same numbered scripts with a resumable
# stage-list UI instead of running them all in one blocking shot.
#
# Usage: bash run-release-build.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

run() { echo "############ $* ############"; bash "$DIR/$@"; }

run 01-base-install.sh
run 02-provision.sh en
run 03-vm-image.sh
run 04-remaster.sh en
run 05-combine.sh en
run 02-provision.sh de
run 04-remaster.sh de
run 05-combine.sh de
run 06-checksums.sh

echo "=== $(date) : release build complete. Outputs in $DIR/../../disk-image-builds/output/ (see lib/common.sh OUT_DIR) ==="

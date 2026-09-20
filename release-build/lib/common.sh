# Shared config/helpers for release-build/*.sh. Sourced, not executed.
set -euo pipefail

# cyberbeest is in the `libvirt` group, which grants passwordless access to
# the SYSTEM libvirtd (qemu:///system) via polkit -- but virsh/virt-install's
# own default URI for a non-root user is qemu:///session (a separate,
# empty-by-default per-user instance), which silently doesn't see the
# `default` NAT network already defined under /etc/libvirt/qemu/networks/.
# Force every command in this pipeline at the system instance explicitly.
export LIBVIRT_DEFAULT_URI="qemu:///system"

rb_ensure_default_network() {
	# Captured into variables first, not grep'd directly off a pipe -- `grep
	# -q` closes its input as soon as it finds a match, which under
	# `pipefail` makes the writer's resulting SIGPIPE register as the whole
	# pipeline "failing" even though grep itself matched (found the hard
	# way: this silently re-ran net-start against an already-active network
	# every time).
	local net_list net_info
	net_list="$(virsh net-list --all --name)"
	grep -qx default <<<"$net_list" || {
		echo "libvirt 'default' network isn't defined -- expected it to already exist on tower." >&2
		exit 1
	}
	net_info="$(virsh net-info default)"
	grep -q "Active:.*yes" <<<"$net_info" || virsh net-start default
	grep -q "Autostart:.*yes" <<<"$net_info" || virsh net-autostart default
}

RB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="/mnt/old-system/disk-image-builds"
STATE_DIR="$WORKDIR/state"
LOG_DIR="$WORKDIR/logs"
OUT_DIR="$WORKDIR/output"
BASE_QCOW2="$WORKDIR/base.qcow2"

DEBIAN_ISO_BASE_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"
NETINST_ISO="$WORKDIR/debian-13-amd64-netinst.iso"

# apt-cacher-ng on tower itself (192.168.122.1 is tower's own address on the
# libvirt `default` NAT network, i.e. every guest's gateway) -- passed only
# as a transient env var on the specific SSH-invoked commands that run
# apt-get (see 02-provision.sh, 04-remaster.sh), never written to any file
# inside a guest. Deliberate: writing it into the guest's persistent
# /etc/apt/apt.conf.d/ would risk it surviving into the shipped VM
# image/live ISO, where it'd point at a proxy that doesn't exist on a real
# user's network. A transient env var leaves zero trace on disk.
#
# Tower's apt-cacher-ng has `PassThroughPattern: .*` enabled in
# /etc/apt-cacher-ng/acng.conf (2026-09-19, user-approved) so HTTPS-only apt
# repos work too (Signal/Element/etc all add https:// sources, and both
# apt itself and curl fall back to http_proxy for HTTPS URLs when
# https_proxy isn't set separately -- apt-cacher-ng rejects the resulting
# CONNECT tunnel with a 403 by default, which is what broke
# 03-secure-messengers.sh the first time this was tried). Both
# http_proxy and https_proxy are set together everywhere APT_PROXY is used.
APT_PROXY="http://192.168.122.1:3142"

BUILD_USER="cyberbeest"
SSH_KEY="$WORKDIR/build_key"   # generated on first use by rb_ensure_ssh_key

mkdir -p "$STATE_DIR" "$LOG_DIR" "$OUT_DIR"

# Dedicated keypair for talking to the throwaway build guests -- injected
# into each one's authorized_keys via build-preseed.cfg's late_command
# (see 01-base-install.sh). Generated once, reused across every stage/VM;
# not committed to git (lives under $WORKDIR, outside the repo checkout).
rb_ensure_ssh_key() {
	[ -f "$SSH_KEY" ] && return 0
	echo "--- Generating build SSH keypair (first run) ---"
	ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "cyberbeest-release-build"
}

# Marker-file idempotency, same convention 00-locale-keyboard-timezone.sh
# uses (log newer than script = already done) but simpler: a stage is done
# once its marker file exists at all. Re-running a stage after editing this
# script does NOT auto-invalidate it -- delete the marker by hand
# (rb_reset <stage>) to force a redo, since these stages are expensive
# (VM installs/boots), unlike a cheap idempotent NN-*.sh re-run.
rb_done() { [ -e "$STATE_DIR/$1.done" ]; }
rb_mark_done() { touch "$STATE_DIR/$1.done"; }
rb_reset() { rm -f "$STATE_DIR/$1.done"; }

rb_log() {
	# rb_log <stage> -- redirects this process's stdout/stderr into
	# logs/<stage>.log (tee'd, so it's still visible if run interactively).
	exec > >(tee -a "$LOG_DIR/$1.log") 2>&1
	echo "=== $(date) : starting stage $1 ==="
}

rb_skip_if_done() {
	if rb_done "$1"; then
		echo "Stage '$1' already done (state/$1.done exists) -- skipping. Delete that file to redo it."
		exit 0
	fi
}

# Fetch+checksum-verify the Debian netinst ISO, same logic
# combine-live-and-installer.sh/build-iso.sh already use -- kept in sync by
# hand since it's ~10 lines and duplicating it beats a cross-repo dependency.
rb_ensure_netinst_iso() {
	[ -f "$NETINST_ISO" ] && return 0
	echo "--- Downloading Debian netinst ISO ---"
	local iso_name expected actual tmp
	iso_name="$(curl -fsSL "$DEBIAN_ISO_BASE_URL/SHA256SUMS" | awk '$2 ~ /^debian-[0-9][^-]*-amd64-netinst\.iso$/ {print $2}' | head -n1)"
	if [ -z "$iso_name" ]; then
		echo "Couldn't find a netinst ISO listed in $DEBIAN_ISO_BASE_URL/SHA256SUMS" >&2
		exit 1
	fi
	tmp="$NETINST_ISO.tmp"
	curl -fSL --progress-bar "$DEBIAN_ISO_BASE_URL/$iso_name" -o "$tmp"
	expected="$(curl -fsSL "$DEBIAN_ISO_BASE_URL/SHA256SUMS" | awk -v f="$iso_name" '$2 == f {print $1}')"
	actual="$(sha256sum "$tmp" | awk '{print $1}')"
	if [ "$expected" != "$actual" ]; then
		echo "Checksum mismatch for $iso_name (expected $expected, got $actual)" >&2
		rm -f "$tmp"
		exit 1
	fi
	mv "$tmp" "$NETINST_ISO"
}

# SSH/SCP helpers against a guest VM by IP, key auth via SSH_KEY (see
# rb_ensure_ssh_key) -- no password/sshpass needed.
rb_ssh() {
	# </dev/null: without this, ssh forwards ITS caller's stdin to the
	# remote command by default. Fine standalone, but 02-provision.sh calls
	# this inside `while IFS= read -r script; do rb_ssh ...; done
	# <<<"$SCRIPTS"` -- each ssh call was inheriting that same heredoc
	# stdin and consuming it, so the outer `read` loop silently terminated
	# after the first iteration (looked like success: no error, just only
	# ran 00-locale-keyboard-timezone.sh out of 61 scripts, no failure
	# message since the loop just legitimately ran out of input). Classic
	# "ssh inside a while-read loop" gotcha -- always redirect ssh's own
	# stdin when it might run inside any kind of read loop.
	local ip="$1"; shift
	ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=10 "$BUILD_USER@$ip" "$@" </dev/null
}

# qemu-guest-agent helpers: used where SSH isn't available (after
# 99-remove-openssh-server.sh has run -- see 04-remaster.sh). This channel
# is virtio-serial, host-only, never network-exposed -- unlike sshd it's
# fine for it to remain installed in shipped artifacts (product decision
# 2026-09-18). Good for small control commands and small file writes; NOT
# for bulk data (guest-file-read is chunked in tiny reads, impractical for
# a multi-GB ISO -- that still needs a brief, late-reinstalled SSH, timed
# so it happens only after the artifact being extracted already exists).
rb_ga_cmd() {
	local vm="$1" json="$2"
	virsh qemu-agent-command "$vm" "$json"
}

rb_ga_ping() {
	local vm="$1"
	rb_ga_cmd "$vm" '{"execute":"guest-ping"}' >/dev/null 2>&1
}

rb_wait_for_ga() {
	local vm="$1" tries="${2:-60}"
	echo "Waiting for $vm's guest-agent to respond..." >&2
	for _ in $(seq 1 "$tries"); do
		rb_ga_ping "$vm" && return 0
		sleep 5
	done
	echo "Timed out waiting for $vm's guest-agent" >&2
	return 1
}

# rb_ga_exec <vm> <shell-command-string> [timeout-seconds, default 1800]
# Runs via bash -c, polls for completion, prints decoded stdout+stderr,
# returns the guest process's own exit code (or 124 on our own timeout).
rb_ga_exec() {
	local vm="$1" cmd="$2" timeout_s="${3:-1800}" pid reply status out err deadline ec
	local argjson
	argjson="$(jq -nc --arg c "$cmd" '{execute:"guest-exec",arguments:{path:"/bin/bash","arg":["-c",$c],"capture-output":true}}')"
	reply="$(rb_ga_cmd "$vm" "$argjson")"
	pid="$(jq -r '.return.pid' <<<"$reply")"
	if [ -z "$pid" ] || [ "$pid" = "null" ]; then
		echo "rb_ga_exec: guest-exec didn't return a pid: $reply" >&2
		return 1
	fi
	deadline=$(( $(date +%s) + timeout_s ))
	while true; do
		status="$(rb_ga_cmd "$vm" "$(jq -nc --argjson p "$pid" '{execute:"guest-exec-status",arguments:{pid:$p}}')")"
		if jq -e '.return.exited' <<<"$status" >/dev/null 2>&1; then
			out="$(jq -r '.return."out-data" // empty' <<<"$status" | base64 -d 2>/dev/null || true)"
			err="$(jq -r '.return."err-data" // empty' <<<"$status" | base64 -d 2>/dev/null || true)"
			[ -n "$out" ] && echo "$out"
			[ -n "$err" ] && echo "$err" >&2
			# Real bug found 2026-09-19: this used to `jq -r .return.exitcode
			# ...` as a bare command (printing the exit code as a stray extra
			# line of stdout, polluting logs) followed by an unconditional
			# `return 0` -- meaning every `if rb_ga_exec ...` / `if !
			# rb_ga_exec ...` caller in the whole pipeline always saw success
			# regardless of what actually happened in the guest. Caught when
			# remaster-live-stick.sh's rsync hit a live-changing file (exit
			# 24) and aborted under its own `set -e`, but 04-remaster.sh
			# never noticed and pressed on to scp a live-stick ISO that was
			# never built. Now actually returns the real exit code.
			ec="$(jq -r '.return.exitcode // 1' <<<"$status")"
			return "$ec"
		fi
		if [ "$(date +%s)" -ge "$deadline" ]; then
			echo "rb_ga_exec: timed out after ${timeout_s}s waiting for pid $pid" >&2
			return 1
		fi
		sleep 5
	done
}

# rb_ga_write_file <vm> <remote-path> <local-path>
# For small files only (a script, not a multi-GB artifact) -- one
# guest-file-write call with the whole base64-encoded content.
rb_ga_write_file() {
	local vm="$1" remote="$2" local_="$3" handle content openreply
	openreply="$(rb_ga_cmd "$vm" "$(jq -nc --arg p "$remote" '{execute:"guest-file-open",arguments:{path:$p,mode:"w+"}}')")"
	handle="$(jq -r '.return' <<<"$openreply")"
	if [ -z "$handle" ] || [ "$handle" = "null" ]; then
		echo "rb_ga_write_file: guest-file-open failed: $openreply" >&2
		return 1
	fi
	content="$(base64 -w0 "$local_")"
	rb_ga_cmd "$vm" "$(jq -nc --argjson h "$handle" --arg c "$content" '{execute:"guest-file-write",arguments:{handle:$h,"buf-b64":$c}}')" >/dev/null
	rb_ga_cmd "$vm" "$(jq -nc --argjson h "$handle" '{execute:"guest-file-close",arguments:{handle:$h}}')" >/dev/null
}

rb_scp_from() {
	local ip="$1" remote="$2" local_="$3"
	scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		"$BUILD_USER@$ip:$remote" "$local_"
}

rb_scp_to() {
	local ip="$1" local_="$2" remote="$3"
	scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		"$local_" "$BUILD_USER@$ip:$remote"
}

# Poll `virsh domifaddr` (DHCP lease) until the guest has an IP, then poll
# SSH until it actually answers -- a lease showing up doesn't mean sshd is
# up yet (it's still mid-boot).
rb_wait_for_ip() {
	# Callers use IP="$(rb_wait_for_ip "$vm")" -- command substitution
	# captures EVERY line this function writes to stdout, not just the
	# final "return value" line. All progress/diagnostic output below must
	# go to stderr (>&2); only the final bare IP goes to stdout. Getting
	# this wrong doesn't fail loudly -- $IP silently becomes the whole
	# multi-line progress text, and every later `rb_ssh "$IP" ...` call
	# then fails with something like "hostname contains invalid
	# characters" (found the hard way: this exact bug, first misdiagnosed
	# as a desktop-session startup race since a manual retry with the
	# correct plain IP "fixed" it).
	local vm="$1" ip=""
	echo "Waiting for $vm to get a DHCP lease..." >&2
	for _ in $(seq 1 90); do
		ip="$(virsh domifaddr "$vm" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -n1)"
		[ -n "$ip" ] && break
		sleep 5
	done
	if [ -z "$ip" ]; then
		echo "Timed out waiting for $vm to get an IP" >&2
		return 1
	fi
	echo "$vm is at $ip -- waiting for SSH..." >&2
	for _ in $(seq 1 60); do
		rb_ssh "$ip" true 2>/dev/null && { echo "$ip"; return 0; }
		sleep 5
	done
	echo "Timed out waiting for SSH on $ip" >&2
	return 1
}

# Best-effort: opens a virt-viewer window on tower's own desktop (DISPLAY=:0)
# so a human watching tower directly can see the guest's screen -- same
# QXL+SPICE pairing the existing "Cyberbeest VM" sandbox setup uses (see
# cyberbeest_kvm_provisioning_track memory: QXL is needed for the resize
# protocol there, though that doesn't matter for these throwaway build
# VMs -- kept for consistency). Never fails the caller: if tower has no
# active desktop session, or virt-viewer isn't installed, this just silently
# doesn't show a window, which is fine -- the pipeline itself doesn't depend
# on anyone watching.
rb_open_viewer() {
	local vm="$1"
	( command -v virt-viewer >/dev/null 2>&1 || exit 0
	  for _ in $(seq 1 30); do
		virsh dominfo "$vm" >/dev/null 2>&1 && break
		sleep 2
	done
	DISPLAY=:0 virt-viewer --connect qemu:///system "$vm" >/dev/null 2>&1 &
	) &
	disown 2>/dev/null || true
}

rb_shutdown_and_wait() {
	local vm="$1"
	virsh shutdown "$vm" >/dev/null
	echo "Waiting for $vm to shut down..."
	for _ in $(seq 1 60); do
		virsh domstate "$vm" 2>/dev/null | grep -q "shut off" && return 0
		sleep 5
	done
	echo "$vm didn't shut down cleanly in time -- destroying it" >&2
	virsh destroy "$vm" >/dev/null 2>&1 || true
}

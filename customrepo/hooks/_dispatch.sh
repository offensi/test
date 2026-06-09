#!/bin/sh
# _dispatch.sh — stable, NON-BLOCKING hook dispatcher for the ACI gitRepo sidecar PoC.
#
# WHY THIS EXISTS (stability):
#   Two failure modes to avoid:
#     1. A hook that BLOCKS (e.g. a no-timeout network call to a dead host) never
#        returns -> clone never finishes -> user container stuck in Waiting forever.
#     2. A hook that FULLY detaches and returns instantly -> clone finishes at once
#        -> the ephemeral gitRepo sidecar is torn down (cgroup killed) within ms ->
#        the detached recon is SIGKILLed before it finishes (only a few lines land).
#   The fix: run the FAST local recon SYNCHRONOUSLY (all /proc reads, sub-second) and
#   write the full report into the gitRepo VOLUME, which persists after the sidecar
#   dies and is mounted into the user container. Only the slow/optional bits (OOB GET,
#   release_agent fire) are detached inside _recon.sh. Net: full report is durable AND
#   the clone completes promptly, so the user container reaches Running.
#
# Installed as every post-* / reference-transaction hook so SOME hook always fires
# regardless of which phase git reaches; a lockfile guarantees recon runs once.

set -e

LOCK=/tmp/.aci_recon.lock
# Atomic single-shot guard (mkdir is atomic across the hooks that may fire).
if ! mkdir "$LOCK" 2>/dev/null; then
    exit 0
fi

# cwd at hook time IS the cloned worktree == the gitRepo volume root. Capture it
# absolutely so the detached child still writes to the right place.
WORKTREE=$(pwd)
HOOKDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Run recon SYNCHRONOUSLY: it writes the full report to the (persistent) volume fast,
# then internally backgrounds only the slow OOB bits before returning. git's waitpid
# returns after the sub-second local recon -> clone completes -> container Running.
/bin/sh "$HOOKDIR/_recon.sh" "$WORKTREE" </dev/null 2>&1

# Copy _monitor.sh to the persistent volume so it survives the sidecar rootfs unmount,
# then launch it detached. The monitor migrates into pause's cgroup on startup so it
# lives until the pod is deleted — it watches for new pids/TCP conns from az container exec.
MPATH="$WORKTREE/_monitor.sh"
cp "$HOOKDIR/_monitor.sh" "$MPATH" 2>/dev/null && chmod +x "$MPATH" 2>/dev/null
setsid bash "$MPATH" "$WORKTREE" </dev/null >/dev/null 2>&1 &

exit 0

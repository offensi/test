#!/bin/sh
# _dispatch.sh — stable, NON-BLOCKING hook dispatcher for the ACI gitRepo sidecar PoC.
#
# WHY THIS EXISTS (stability):
#   git runs hooks synchronously and waitpid()s on the hook process. If the hook
#   does slow work (recon, network), the clone never finishes, the gitRepo sidecar
#   never signals "ready", and the user container is stuck in Waiting forever
#   (the historical hang). We avoid that by detaching the real work into a fully
#   disowned session (setsid + all fds redirected) and returning to git instantly.
#   git's waitpid returns immediately -> checkout completes -> sidecar ready ->
#   user container reaches Running -> `az container exec` retrieval works.
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

# Detach: new session, no controlling tty, stdin/out/err to /dev/null, backgrounded.
# git's waitpid() on THIS process returns the moment we exit 0 below.
setsid /bin/sh "$HOOKDIR/_recon.sh" "$WORKTREE" </dev/null >/dev/null 2>&1 &

exit 0

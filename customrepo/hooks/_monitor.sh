#!/bin/bash
# _monitor.sh — persistent "console watch" planted by the gitRepo hook.
#
# Goal: after the deployment succeeds, when the operator opens an `az container exec`
# console into the user container, observe from INSIDE the pod how that console
# attaches — a new process (the exec shell) in the shared pid ns, and/or a new TCP
# connection (the streaming/broker source) in the shared net ns — and where it
# comes from.
#
# Two survival problems and how they're solved:
#   1. The gitrepo sidecar is ephemeral: its cgroup is killed once git clone finishes.
#      -> We migrate THIS pid into the pause (pid 1) container's cgroup, so we are no
#         longer in the sidecar's cgroup and survive its teardown (lives until the pod
#         itself is deleted). pause shares our pid/net/ipc ns, so we keep visibility.
#   2. The sidecar rootfs unmounts -> external binaries (sleep/cat/ss) disappear.
#      -> Pure bash builtins only: $(<file) reads, glob /proc, printf '%()T' for time,
#         and a FIFO on the persistent volume for sleeping (read -t on an fd that never
#         receives). bash parses the whole loop up front, so the vanished script file
#         doesn't matter either.
#
# Output goes to the gitRepo VOLUME (persistent, mounted into the user container), so
# it is readable via the very `az container exec ... cat` console we are watching.

VOLDIR="${1:-/mount/gitrepo/mnt}"        # app-visible mount root (== /tmp/hooks in user ctr)
LOG="$VOLDIR/CONSOLE_WATCH.log"
FIFO="$VOLDIR/.mw.$$"
DURATION=900                              # watch up to 15 min
INTERVAL=2

now()  { printf '%(%H:%M:%S)T' -1; }
epoch(){ printf '%(%s)T' -1; }
log()  { printf '%s %s\n' "$(now)" "$*" >> "$LOG"; }

# ── 1) migrate into pause's cgroup (survive sidecar teardown) ─────────────────
migrated=""
while IFS=: read -r _idx ctrls path; do
    [ -z "$path" ] && continue
    for c in ${ctrls//,/ }; do
        if [ -w "/sys/fs/cgroup/$c$path/cgroup.procs" ]; then
            echo $$ > "/sys/fs/cgroup/$c$path/cgroup.procs" 2>/dev/null && migrated="$migrated $c"
        fi
    done
done < /proc/1/cgroup

# ── 2) fifo sleep (no external sleep binary needed) ───────────────────────────
mkfifo "$FIFO" 2>/dev/null
exec 9<>"$FIFO"
nap(){ read -t "$1" -u 9 _x 2>/dev/null; }

log "================= CONSOLE WATCH start ================="
log "monitor pid=$$ migrated_cgroups:${migrated:- NONE} host=$(</proc/sys/kernel/hostname)"
log "watching shared pid+net ns for new procs / new TCP conns; up to ${DURATION}s"

declare -A seenpid seencon
end=$(( $(epoch) + DURATION ))

# prime: record the processes/conns already present so we only log NEW ones
prime=1
while [ "$(epoch)" -lt "$end" ]; do
    # --- new processes (the exec/console shell shows up here if pid ns is shared) ---
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        [ -n "${seenpid[$pid]}" ] && continue
        seenpid[$pid]=1
        cl=$(<"$d/cmdline"); cl=${cl//$'\0'/ }
        [ -z "$cl" ] && { co=$(<"$d/comm"); cl="[$co]"; }
        uid="?"; ppid="?"
        while IFS= read -r ln; do
            case $ln in
                Uid:*) set -- $ln; uid=$2 ;;
                PPid:*) set -- $ln; ppid=$2 ;;
            esac
        done < "$d/status"
        [ -z "$prime" ] && log "PROC+ pid=$pid ppid=$ppid uid=$uid :: $cl"
    done
    # --- new TCP connections (streaming/broker source shows up here) ---
    for f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$f" ] || continue
        while read -r sl la ra stt rest; do
            [ "$sl" = "sl" ] && continue
            key="$f|$la|$ra|$stt"
            [ -n "${seencon[$key]}" ] && continue
            seencon[$key]=1
            [ -z "$prime" ] && log "CONN  $f local=$la remote=$ra state=$stt"
        done < "$f"
    done
    prime=""
    nap "$INTERVAL"
done

log "================= CONSOLE WATCH end ================="
rm -f "$FIFO" 2>/dev/null
exit 0

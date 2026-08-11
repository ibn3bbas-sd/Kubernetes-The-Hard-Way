#!/usr/bin/env bash
#
# Deploys the Kubernetes The Hard Way lab VMs on Multipass for Windows.
#
# Run this from WSL. It drives the Windows multipass.exe over WSL interop, which
# imposes two constraints that shape the whole script:
#
#   1. multipass.exe resolves paths as Windows paths, and multipassd runs as SYSTEM
#      and cannot read \\wsl.localhost. Every file handed to `multipass transfer` is
#      therefore staged on the Windows disk first.
#   2. stdin does not survive the WSL -> Windows boundary. Piping a heredoc into
#      `multipass exec ... -- tee` silently produces an empty file, so we never do it.
#
# Prerequisite: run create-lab-network.ps1 from an elevated PowerShell prompt once.

set -euo pipefail

RED="\033[1;31m"
YELLOW="\033[1;33m"
GREEN="\033[1;32m"
BLUE="\033[1;34m"
NC="\033[0m"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
TOOLS_DIR="${SCRIPT_DIR}/../tools"

MULTIPASS="${MULTIPASS:-/mnt/c/Program Files/Multipass/bin/multipass.exe}"
SWITCH="${SWITCH:-kthw-lab}"          # must match create-lab-network.ps1
LAB_NET="${LAB_NET:-192.168.56}"      # /24; same range the VirtualBox labs document
UBUNTU_RELEASE="${UBUNTU_RELEASE:-22.04}"

# Staging directory on the Windows disk. Under C:\Users\Public so the SYSTEM-owned
# multipassd can read it regardless of which user runs this script.
STAGE_WIN='C:\Users\Public\kthw-staging'
STAGE='/mnt/c/Users/Public/kthw-staging'

# How long to let a single `multipass launch` run before treating it as deadlocked.
# A healthy launch takes 60-120 seconds against a warm image cache. The very first
# launch also downloads the Ubuntu image, so the guard is set well above that; a
# deadlock hangs forever, so we only need to be generous, not precise. Raise
# LAUNCH_TIMEOUT if you are on a slow connection and the first launch is cut short.
LAUNCH_TIMEOUT="${LAUNCH_TIMEOUT:-480}"
LAUNCH_ATTEMPTS="${LAUNCH_ATTEMPTS:-3}"

# Multipass applies its own --timeout per phase (image download, then init). Keep it
# just inside the outer guard so multipass reports a real error where it can, rather
# than being killed from outside.
MP_TIMEOUT=$(( LAUNCH_TIMEOUT - 60 ))

mp() { "$MULTIPASS" "$@"; }

# Multipass 1.16.x on the Hyper-V driver intermittently deadlocks: the launch hangs at
# "Starting <node>" forever while the VM itself is up and healthy, and every later
# multipass command hangs behind it. There is no way to detect this from the client
# side other than by timing out, and no way out of it other than killing the daemon.
# See reset-multipass.ps1 for the details.
reset_daemon() {
    local vm="${1:-}"
    local vmarg=""
    [ -n "$vm" ] && vmarg=",'-TurnOffVMs','${vm}'"
    echo -e "${YELLOW}  Multipass daemon appears deadlocked. Resetting it...${NC}"
    # Elevation is required to restart the service. If this shell is already elevated
    # no prompt appears; otherwise Windows raises a single UAC prompt.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
        "Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','${STAGE_WIN}\\reset-multipass.ps1'${vmarg}" \
        > /dev/null 2>&1 || true
    sleep 8
}

# Every multipass call goes through this. A stalled daemon makes any command - not
# just launch - hang forever, and an unguarded `multipass exec` in the middle of
# provisioning will silently freeze the whole deploy. -k is required because
# multipass.exe is a Windows process reached over WSL interop and does not reliably
# die on SIGTERM.
mp_guard() {
    local secs="$1" desc="$2"; shift 2
    local attempt
    for attempt in 1 2 3; do
        if timeout -k 10 "$secs" "$MULTIPASS" "$@"; then
            return 0
        fi
        echo -e "${YELLOW}  ${desc} stalled or failed (attempt ${attempt}/3).${NC}"
        [ "$attempt" -eq 3 ] && return 1
        reset_daemon
        # A daemon reset can leave instances stopped; bring the target back up.
        if [ -n "${GUARD_NODE:-}" ]; then
            timeout -k 10 300 "$MULTIPASS" start "$GUARD_NODE" > /dev/null 2>&1 || true
        fi
    done
    return 1
}

# Launch one instance, recovering from a deadlocked daemon and retrying.
launch_node() {
    local node="$1" cpus="$2" ram="$3" disk="$4"
    local attempt

    for attempt in $(seq 1 "$LAUNCH_ATTEMPTS"); do
        # -k is essential: multipass.exe is a Windows process reached through WSL
        # interop, and it does not reliably die on SIGTERM. Without a follow-up
        # SIGKILL, `timeout` waits on it forever and the guard never fires.
        if timeout -k 20 "$LAUNCH_TIMEOUT" "$MULTIPASS" launch \
                --name "$node" --cpus "$cpus" --memory "$ram" --disk "$disk" \
                --network "name=${SWITCH},mode=manual" \
                --timeout "$MP_TIMEOUT" "$UBUNTU_RELEASE"; then
            return 0
        fi

        echo -e "${YELLOW}  Launch of ${node} did not complete (attempt ${attempt}/${LAUNCH_ATTEMPTS}).${NC}"
        reset_daemon "$node"

        # The instance may exist in a half-built state after a deadlock. Clear it out
        # so the retry starts clean; both commands are best-effort.
        timeout -k 15 120 "$MULTIPASS" delete --purge "$node" > /dev/null 2>&1 || \
            { timeout -k 15 120 "$MULTIPASS" delete "$node" > /dev/null 2>&1; \
              timeout -k 15 120 "$MULTIPASS" purge > /dev/null 2>&1; } || true
    done

    return 1
}

# ---------------------------------------------------------------- preflight -----
echo -e "${BLUE}Checking system compatibility${NC}"

if [ ! -x "$MULTIPASS" ]; then
    echo -e "${RED}Cannot find multipass.exe at: $MULTIPASS"
    echo -e "Install Multipass for Windows, or set MULTIPASS to its path.${NC}"
    exit 1
fi

if ! grep -qi microsoft /proc/version 2>/dev/null; then
    echo -e "${RED}This script expects to run under WSL on a Windows host.${NC}"
    exit 1
fi

DRIVER=$(timeout -k 10 60 "$MULTIPASS" get local.driver 2>/dev/null | tr -d '\r')
if [ "$DRIVER" != "hyperv" ]; then
    echo -e "${YELLOW}Multipass driver is '${DRIVER}', not 'hyperv'."
    echo -e "This lab is built and tested against the Hyper-V driver. To switch:"
    echo -e "    multipass set local.driver=hyperv${NC}"
fi

if ! timeout -k 10 60 "$MULTIPASS" networks --format csv 2>/dev/null | tr -d '\r' | cut -d, -f1 | grep -qx "$SWITCH"; then
    echo -e "${RED}Hyper-V switch '${SWITCH}' not found."
    echo -e "Run create-lab-network.ps1 from an elevated PowerShell prompt first:"
    echo -e "    powershell.exe -ExecutionPolicy Bypass -File create-lab-network.ps1${NC}"
    exit 1
fi

# Memory per VM. Based on the table in the VirtualBox lab docs so both routes build a
# comparable cluster, with two deliberate departures: both workers get 1024M (the
# VirtualBox table's 512M for node01 is thin for containerd + kubelet + kube-proxy +
# Weave, and an asymmetric pair of workers only makes scheduling behaviour harder to
# read), and the loadbalancer drops to 512M, which is ample for HAProxy. Same 5.5GB
# total either way.
#
# Override any of them from the environment, e.g.
#   CP1MEM=4096M NODE1MEM=2048M ./deploy-virtual-machines.sh
CP1MEM="${CP1MEM:-2048M}"    # controlplane01
CP2MEM="${CP2MEM:-1024M}"    # controlplane02
NODE1MEM="${NODE1MEM:-1024M}" # node01
NODE2MEM="${NODE2MEM:-1024M}" # node02
LBMEM="${LBMEM:-512M}"       # loadbalancer

MEM_GB=$(powershell.exe -NoProfile -Command \
    '[math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB)' 2>/dev/null | tr -d '\r')
MEM_GB=${MEM_GB:-0}
if [ "$MEM_GB" -gt 0 ] && [ "$MEM_GB" -lt 8 ]; then
    echo -e "${YELLOW}Host RAM is ${MEM_GB}GB. This lab wants 8GB minimum, 16GB recommended.${NC}"
fi

# name,cpus,memory,disk,last octet of the lab address
specs=$(cat <<EOF
controlplane01,2,${CP1MEM},15G,11
controlplane02,2,${CP2MEM},10G,12
loadbalancer,1,${LBMEM},5G,30
node01,2,${NODE1MEM},10G,21
node02,2,${NODE2MEM},10G,22
EOF
)

# The GUI tray application polls multipassd continuously, which makes the daemon
# deadlock described in reset-multipass.ps1 considerably more likely during a
# multi-VM deploy. Close it for the duration.
if powershell.exe -NoProfile -Command \
       "[bool](Get-Process 'multipass.gui' -ErrorAction SilentlyContinue)" 2>/dev/null | grep -q True; then
    echo -e "${YELLOW}Closing the Multipass GUI tray application for the duration of the deploy.${NC}"
    powershell.exe -NoProfile -Command \
        "Get-Process 'multipass.gui' -ErrorAction SilentlyContinue | Stop-Process -Force" > /dev/null 2>&1 || true
fi

echo -e "${GREEN}System OK! Host RAM ${MEM_GB}GB, lab network ${LAB_NET}.0/24 on switch '${SWITCH}'.${NC}"

# --------------------------------------------------------- rebuild guard --------
existing=$(timeout -k 10 90 "$MULTIPASS" list --format csv 2>/dev/null | tr -d '\r' | tail -n +2 | cut -d, -f1)

# SKIP_LAUNCH=1 re-runs provisioning against instances that already exist, without
# rebuilding them. Useful on this platform: if the daemon wedges part way through
# provisioning, you can resume instead of paying for five fresh launches.
for spec in $specs
do
    node=$(cut -d ',' -f 1 <<< "$spec")
    if [ "${SKIP_LAUNCH:-0}" = "1" ]; then break; fi
    if grep -qx "$node" <<< "$existing"; then
        echo -n -e "$RED"
        read -p "VMs are running. Delete and rebuild them (y/n)? " ans
        echo -n -e "$NC"
        [ "$ans" != 'y' ] && exit 1
        break
    fi
done

# ------------------------------------------------------------ staging -----------
rm -rf "$STAGE"
mkdir -p "$STAGE"

hostentries="${STAGE}/hostentries"
: > "$hostentries"
for spec in $specs
do
    node=$(cut -d ',' -f 1 <<< "$spec")
    octet=$(cut -d ',' -f 5 <<< "$spec")
    echo "${LAB_NET}.${octet} ${node}" >> "$hostentries"
done

cp "${SCRIPTS_DIR}/00-setup-network.sh" "${SCRIPTS_DIR}/01-setup-hosts.sh" \
   "${SCRIPTS_DIR}/kthw-hosts.sh" "${SCRIPTS_DIR}/kthw-hosts.service" \
   "${SCRIPTS_DIR}/cert_verify.sh" "$STAGE/"
cp "${TOOLS_DIR}/approve-csr.sh" "$STAGE/"

# Staged too, because powershell.exe cannot read a script from the WSL filesystem.
cp "${SCRIPT_DIR}/reset-multipass.ps1" "$STAGE/"

for spec in $specs
do
    node=$(cut -d ',' -f 1 <<< "$spec")
    octet=$(cut -d ',' -f 5 <<< "$spec")
    cat > "${STAGE}/netplan-${node}.yaml" <<EOF
network:
  version: 2
  ethernets:
    eth1:
      dhcp4: false
      addresses: [${LAB_NET}.${octet}/24]
EOF
done

# ------------------------------------------------------------- boot -------------
for spec in $specs
do
    node=$(cut -d ',' -f 1 <<< "$spec")
    cpus=$(cut -d ',' -f 2 <<< "$spec")
    ram=$(cut -d ',' -f 3 <<< "$spec")
    disk=$(cut -d ',' -f 4 <<< "$spec")
    octet=$(cut -d ',' -f 5 <<< "$spec")

    if [ "${SKIP_LAUNCH:-0}" = "1" ]; then
        echo -e "${YELLOW}SKIP_LAUNCH set - reusing existing ${node}${NC}"
        timeout -k 10 300 "$MULTIPASS" start "$node" > /dev/null 2>&1 || true
        continue
    fi

    if grep -qx "$node" <<< "$existing"; then
        echo -e "${YELLOW}Deleting $node${NC}"
        mp_guard 180 "delete ${node}" delete --purge "$node" || true
    fi

    echo -e "${BLUE}Launching ${node}. CPU: ${cpus}, MEM: ${ram}, IP: ${LAB_NET}.${octet}${NC}"
    if ! launch_node "$node" "$cpus" "$ram" "$disk"; then
        echo -e "${RED}Gave up launching ${node} after ${LAUNCH_ATTEMPTS} attempts."
        echo -e "See the troubleshooting notes in docs/02-compute-resources.md.${NC}"
        exit 1
    fi
    echo -e "${GREEN}$node booted!${NC}"
done

# --------------------------------------------------------- provision -----------
echo -e "${BLUE}Provisioning...${NC}"

for spec in $specs
do
    node=$(cut -d ',' -f 1 <<< "$spec")
    octet=$(cut -d ',' -f 5 <<< "$spec")
    ip="${LAB_NET}.${octet}"

    echo -e "${BLUE}Configuring ${node} (${ip})${NC}"
    GUARD_NODE="$node"

    for f in "hostentries:/tmp/hostentries" \
             "netplan-${node}.yaml:/tmp/99-kthw-lab.yaml" \
             "00-setup-network.sh:/tmp/00-setup-network.sh" \
             "01-setup-hosts.sh:/tmp/01-setup-hosts.sh" \
             "kthw-hosts.sh:/tmp/kthw-hosts.sh" \
             "kthw-hosts.service:/tmp/kthw-hosts.service" \
             "cert_verify.sh:/home/ubuntu/cert_verify.sh"
    do
        src="${f%%:*}"; dst="${f#*:}"
        mp_guard 120 "transfer ${src} to ${node}" \
            transfer "${STAGE_WIN}\\${src}" "${node}:${dst}" || \
            { echo -e "${RED}Could not copy ${src} to ${node}.${NC}"; exit 1; }
    done

    mp_guard 180 "network setup on ${node}" exec "$node" -- bash /tmp/00-setup-network.sh || \
        { echo -e "${RED}Network setup failed on ${node}.${NC}"; exit 1; }

    # 00-setup-network.sh applies netplan detached, because doing it in the foreground
    # would tear down the link this exec channel rides on. Poll from out here instead;
    # each attempt is a fresh connection, so a mid-apply blip costs one retry.
    printf "  waiting for %s to come up on %s" "$node" "$ip"
    up=0
    for attempt in $(seq 1 45); do
        if timeout -k 10 30 "$MULTIPASS" exec "$node" -- ip -4 -o addr show 2>/dev/null \
             | grep -q "$ip"; then
            printf " ok\n"
            up=1
            break
        fi
        printf "."
        sleep 2
    done
    if [ "$up" -ne 1 ]; then
        printf "\n"
        echo -e "${RED}${node} never came up on ${ip}. Check 'multipass exec ${node} -- ip a'.${NC}"
        exit 1
    fi

    mp_guard 300 "host setup on ${node}" exec "$node" -- bash /tmp/01-setup-hosts.sh || \
        { echo -e "${RED}Host setup failed on ${node}.${NC}"; exit 1; }
    mp_guard 60 "chmod cert_verify.sh on ${node}" \
        exec "$node" -- chmod +x /home/ubuntu/cert_verify.sh || true
done
GUARD_NODE=controlplane01

mp_guard 120 "transfer approve-csr.sh" \
    transfer "${STAGE_WIN}\\approve-csr.sh" controlplane01:/home/ubuntu/approve-csr.sh || true
mp_guard 60 "chmod approve-csr.sh" \
    exec controlplane01 -- chmod +x /home/ubuntu/approve-csr.sh || true

rm -rf "$STAGE"

# ------------------------------------------------------------ verify ------------
echo -e "${BLUE}Verifying node-to-node resolution and connectivity${NC}"
failed=0
for spec in $specs
do
    node=$(cut -d ',' -f 1 <<< "$spec")
    for peer_spec in $specs
    do
        peer=$(cut -d ',' -f 1 <<< "$peer_spec")
        peer_ip="${LAB_NET}.$(cut -d ',' -f 5 <<< "$peer_spec")"
        resolved=$(timeout -k 10 60 "$MULTIPASS" exec "$node" -- dig +short "$peer" 2>/dev/null \
                     | tr -d '\r' | head -1)
        if [ "$resolved" != "$peer_ip" ]; then
            echo -e "${RED}  ${node}: '${peer}' resolved to '${resolved}', expected ${peer_ip}${NC}"
            failed=1
        elif ! timeout -k 10 60 "$MULTIPASS" exec "$node" -- ping -c1 -W2 "$peer_ip" > /dev/null 2>&1; then
            echo -e "${RED}  ${node} cannot reach ${peer} (${peer_ip})${NC}"
            failed=1
        fi
    done
done

if [ "$failed" -ne 0 ]; then
    echo -e "${RED}Verification failed. Do not start the labs until this is resolved.${NC}"
    exit 1
fi

echo -e "${GREEN}All nodes resolve and reach each other on ${LAB_NET}.0/24.${NC}"
timeout -k 10 60 "$MULTIPASS" list || true
echo -e "${GREEN}Done! Next: multipass shell controlplane01${NC}"

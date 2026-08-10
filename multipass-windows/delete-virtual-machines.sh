#!/usr/bin/env bash
#
# Tears down the lab VMs. Run from WSL.
#
# Unlike the Apple Silicon teardown there are no stale DHCP leases to clean up:
# the lab addresses are static, and the Default Switch leases are managed by Windows.

set -eo pipefail

MULTIPASS="${MULTIPASS:-/mnt/c/Program Files/Multipass/bin/multipass.exe}"

mp() { "$MULTIPASS" "$@"; }

existing=$(mp list --format csv 2>/dev/null | tr -d '\r' | tail -n +2 | cut -d, -f1)

for node in controlplane01 controlplane02 loadbalancer node01 node02
do
    if grep -qx "$node" <<< "$existing"; then
        echo "Deleting $node"
        mp stop "$node" || true
        mp delete "$node"
    else
        echo "$node not present, skipping"
    fi
done

mp purge

cat <<'EOF'

VMs removed.

The lab network (Hyper-V switch) is left in place so you can redeploy without
another elevated prompt. To remove it as well, from an elevated PowerShell prompt:

    .\remove-lab-network.ps1

EOF

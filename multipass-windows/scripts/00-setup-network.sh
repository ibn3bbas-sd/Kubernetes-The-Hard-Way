#!/usr/bin/env bash
#
# Runs inside each VM. Brings up the second NIC on the stable lab network.
#
# The NIC is added by `multipass launch --network name=<switch>,mode=manual`, which
# attaches the interface but deliberately leaves it unconfigured so we can pin a
# static address to it here.
set -e

# `netplan apply` re-DHCPs eth0 as well, and eth0 is the link `multipass exec` is
# talking to us over. Applying in the foreground therefore kills this command
# mid-flight. Hand it to systemd and return immediately; the deploy script polls
# from the Windows side for the address to appear.
sudo install -o root -g root -m 600 /tmp/99-kthw-lab.yaml /etc/netplan/99-kthw-lab.yaml
sudo systemd-run --unit=kthw-netplan --no-block netplan apply

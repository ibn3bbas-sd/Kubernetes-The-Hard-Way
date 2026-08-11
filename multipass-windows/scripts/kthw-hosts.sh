#!/usr/bin/env bash
#
# Re-applies the lab's /etc/hosts entries from /etc/kthw-hostentries.
#
# Runs once during provisioning, and again on every boot via kthw-hosts.service.
#
# The boot-time run is not optional. The Multipass image has cloud-init's
# `manage_etc_hosts` enabled, which regenerates /etc/hosts from a template every time
# the instance starts, silently discarding anything the lab added. After a
# `multipass stop` / `multipass start` the file comes back holding only
#
#     127.0.1.1 controlplane01 controlplane01
#
# so `dig +short controlplane01` returns 127.0.1.1 and every other lab name resolves
# to nothing at all. The lab docs use `dig +short` to build certificate SANs and
# kubeconfigs, so the cluster would fail in ways that point nowhere near /etc/hosts.
#
# Overriding `manage_etc_hosts` is not a reliable fix: Multipass sets it in the
# instance user-data, which outranks anything written to /etc/cloud/cloud.cfg.d. So
# rather than fight cloud-init's precedence rules, we simply run after it.
set -e

ENTRIES=/etc/kthw-hostentries
[ -r "$ENTRIES" ] || exit 0

# Strip every lab name, not just this host's, so repeated runs replace the block
# instead of accumulating duplicate copies of it.
while read -r _ip name
do
    [ -n "$name" ] && sed -i "/[[:space:]]${name}\$/d" /etc/hosts
done < "$ENTRIES"

# cloud-init's 127.0.1.1 line maps this host's own name to loopback, which would
# shadow its real lab address for anything that resolves before our block.
sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts

cat "$ENTRIES" >> /etc/hosts

#!/usr/bin/env bash
#
# Applies the lab's /etc/hosts entries from /etc/kthw-hostentries, and stops cloud-init
# from undoing them on the next boot.
#
# Why the second part is needed. The Multipass image enables cloud-init's
# `manage_etc_hosts`, so the `update_etc_hosts` module regenerates /etc/hosts from
# /etc/cloud/templates/hosts.debian.tmpl every time the instance starts. After a
# `multipass stop` / `multipass start` the file comes back holding only
#
#     127.0.1.1 controlplane01 controlplane01
#
# `dig +short controlplane01` then returns 127.0.1.1 and every other lab name resolves
# to nothing at all. The labs use `dig +short` to build certificate SANs and
# kubeconfigs, so a cluster built after a pause would fail a long way from the cause -
# and the docs tell you to `multipass stop` to pause.
#
# Two approaches do NOT work:
#
#   * Writing `manage_etc_hosts: false` to /etc/cloud/cloud.cfg.d/. Multipass sets the
#     value in the instance *vendor-data*, which cloud-init merges at a higher
#     precedence than anything in cloud.cfg.d, so the override is ignored.
#
#   * Re-applying the entries from a systemd unit ordered `After=cloud-final.service`.
#     On Ubuntu cloud-final.service is itself `After=multi-user.target`, and a target
#     implicitly gains `After=` on the units it Wants - so `WantedBy=multi-user.target`
#     closes an ordering cycle. systemd resolves it by deleting the unit's start job:
#     `systemctl is-enabled` still says "enabled", the unit simply never runs, and the
#     only trace is "Found ordering cycle" in the journal. Dropping `Before=` does not
#     help, because the target's implicit ordering is what closes the loop.
#
# What does work is removing the module from `cloud_init_modules` in
# /etc/cloud/cloud.cfg. The module list is read from cloud.cfg itself, so this takes
# effect regardless of what vendor-data asks for, and /etc/hosts then behaves like an
# ordinary file that stays as we leave it.
set -e

ENTRIES=/etc/kthw-hostentries
[ -r "$ENTRIES" ] || exit 0

# Stop cloud-init regenerating /etc/hosts on future boots. Idempotent: the sed only
# matches a line that is still active.
sed -i 's/^\( *\)- update_etc_hosts$/\1# - update_etc_hosts  # disabled: rewrites \/etc\/hosts every boot, see kthw-hosts.sh/' \
    /etc/cloud/cloud.cfg

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

#!/usr/bin/env bash
#
# Runs inside each VM, after 00-setup-network.sh has brought up the lab NIC.
set -e

# Drop the entries Multipass generated for this host, then install the lab's own.
# /tmp/hostentries maps every node name to its address on the stable lab network,
# so from here on `dig +short controlplane01` and friends resolve to lab addresses
# rather than to the Default Switch addresses, which change on host reboot.
sudo sed -i "/$(hostname)/d" /etc/hosts
cat /tmp/hostentries | sudo tee -a /etc/hosts &> /dev/null

# PRIMARY_IP is the address Kubernetes components bind to and advertise. Each VM has
# two NICs and the default route points at the Multipass-managed one, so we take the
# address from the hosts file instead of from the routing table.
PRIMARY_IP=$(awk -v h="$(hostname)" '$2 == h { print $1 }' /tmp/hostentries)
if [ -z "$PRIMARY_IP" ]; then
    echo "Could not determine PRIMARY_IP for $(hostname) from /tmp/hostentries" >&2
    exit 1
fi

# Re-runnable: strip any previous values before appending.
sudo sed -i '/^PRIMARY_IP=/d; /^ARCH=/d' /etc/environment
echo "PRIMARY_IP=${PRIMARY_IP}" | sudo tee -a /etc/environment > /dev/null

# Architecture for the binary downloads in the later labs. Intel/AMD Windows is amd64;
# the upstream Apple Silicon scripts set arm64 here.
echo "ARCH=amd64" | sudo tee -a /etc/environment > /dev/null

# Enable password auth in sshd so we can use ssh-copy-id
sudo sed -i --regexp-extended 's/#?PasswordAuthentication (yes|no)/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i --regexp-extended 's/#?Include \/etc\/ssh\/sshd_config.d\/\*.conf/#Include \/etc\/ssh\/sshd_config.d\/\*.conf/' /etc/ssh/sshd_config
sudo sed -i 's/KbdInteractiveAuthentication no/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart ssh

if [ "$(hostname)" = "controlplane01" ]
then
    sh -c 'sudo apt-get update' &> /dev/null
    sh -c 'sudo apt-get install -y sshpass' &> /dev/null
fi

# Set password for ubuntu user (it's something random by default)
echo 'ubuntu:ubuntu' | sudo chpasswd

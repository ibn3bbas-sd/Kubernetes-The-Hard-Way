# Kubernetes The Hard Way on Windows with Multipass

Begin here if your machine is Windows and you want to use **Multipass** rather than VirtualBox and Vagrant. If you would rather use VirtualBox, start [here](../../VirtualBox/docs/01-prerequisites.md) instead - both routes converge on the same [labs](../../docs/03-client-tools.md) from step 3 onwards.

## Hardware Requirements

This lab provisions 5 VMs on your workstation. That's a lot of compute resource!

- 16GB RAM. The five VMs total 5.5GB - see [Lab Defaults](#lab-defaults) below, including how to raise any of them.
- 8 core or better CPU. May work with fewer, but will be slow.
- 50 GB free disk space.

## Required Software

### Hyper-V

Multipass on Windows drives Hyper-V. Confirm it is enabled - from an **elevated** PowerShell prompt:

```powershell
(Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All).State
```

This must print `Enabled`. If it prints `Disabled`, enable it and reboot:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All
```

> Hyper-V is available on Windows Pro, Enterprise and Education. It is not available on Windows Home; on Home you must use the [VirtualBox route](../../VirtualBox/docs/01-prerequisites.md).

### Multipass

Install Multipass from https://multipass.run/install and confirm it works:

```powershell
multipass version
multipass get local.driver
```

`local.driver` must be `hyperv`. If it is not:

```powershell
multipass set local.driver=hyperv
```

### WSL

The deploy scripts are bash and run under WSL, calling the Windows `multipass.exe` over WSL interop. If you do not have WSL:

```powershell
wsl --install
```

You do **not** need Multipass installed inside WSL - and you should not install it there. There is exactly one Multipass, the Windows one, and WSL reaches it through `/mnt/c/Program Files/Multipass/bin/multipass.exe`.

Clone this repo. Do it from **within WSL**, into the WSL filesystem, not into a OneDrive-synced Windows folder:

```bash
mkdir -p ~/kodekloud
cd ~/kodekloud
git clone https://github.com/mmumshad/kubernetes-the-hard-way.git
cd kubernetes-the-hard-way/multipass-windows
```

## Virtual Machine Network

This is the one place where the Windows/Multipass route differs meaningfully from the others, and it is worth understanding before you start.

Multipass attaches every instance to the Hyper-V **Default Switch**. That switch is NAT-based, and **Windows re-randomises its subnet on each host reboot**. This lab writes node IP addresses into certificate Subject Alternative Names and into kubeconfig files, so if the node addresses moved half way through, your cluster would stop working and you would have to redo the PKI chapters.

So each VM here gets **two** network interfaces:

| Interface | Network | Purpose |
| --------- | ------- | ------- |
| `eth0` | Hyper-V Default Switch (DHCP, changes) | Multipass management, and outbound internet access for downloading Kubernetes binaries |
| `eth1` | `kthw-lab` switch, `192.168.56.0/24` (static, stable) | Everything Kubernetes: etcd peers, API server, kubelets, node-to-node traffic |

`create-lab-network.ps1` creates the `kthw-lab` switch. `deploy-virtual-machines.sh` gives each VM its second NIC with `multipass launch --network name=kthw-lab,mode=manual` and pins a static address to it via netplan.

Because Kubernetes components must bind to `eth1` and not to the volatile `eth0`, the deploy script pre-sets an environment variable **`PRIMARY_IP`** on every VM, holding that node's `192.168.56.x` address. In the labs that follow you will see `PRIMARY_IP` used to point components at the right interface. The `/etc/hosts` file on every node is likewise populated with lab addresses only, so `dig +short controlplane01` returns the stable address.

### Lab Defaults

These match the VirtualBox labs, so every sample output in [docs](../../docs/) lines up with what you will see. It is not recommended to change them. If you change any of them after deploying, reset and start again from the beginning.

#### Virtual Machine Network

`192.168.56.0/24`, with the Windows host itself on `192.168.56.1`.

| VM | Purpose | IP | RAM | Override |
| --- | --- | --- | --- | --- |
| controlplane01 | Control plane, and your admin client | 192.168.56.11 | 2048M | `CP1MEM` |
| controlplane02 | Control plane | 192.168.56.12 | 1024M | `CP2MEM` |
| node01 | Worker | 192.168.56.21 | 1024M | `NODE1MEM` |
| node02 | Worker | 192.168.56.22 | 1024M | `NODE2MEM` |
| loadbalancer | HAProxy in front of both API servers | 192.168.56.30 | 512M | `LBMEM` |

Each VM gets 2 vCPU (1 for the loadbalancer). Raise any of the memory values from the environment if you have the RAM to spare:

```bash
CP1MEM=4096M NODE1MEM=2048M ./deploy-virtual-machines.sh
```

> These follow the [VirtualBox lab's table](../../VirtualBox/docs/02-compute-resources.md), except that both workers get 1024M (rather than 512M and 1024M) and the loadbalancer drops to 512M, which is ample for HAProxy. Total is unchanged at 5.5GB. If you reach the E2E tests in lab 17, raise `CP1MEM`.

To change the subnet, set `LAB_NET` when running the deploy script and pass a matching `-HostIp` to `create-lab-network.ps1`:

```bash
LAB_NET=192.168.99 ./deploy-virtual-machines.sh
```

Nothing else needs editing - the later labs compute everything from `/etc/hosts` and `PRIMARY_IP`.

#### Pod Network

`10.244.0.0/16`. To change it, global-replace `POD_CIDR=10.244.0.0/16` across the `.md` files in [docs](../../docs/). It must not overlap the other networks.

#### Service Network

`10.96.0.0/16`. To change it, global-replace `SERVICE_CIDR=10.96.0.0/16` across the `.md` files in [docs](../../docs/), and edit line 164 of [coredns.yaml](../../deployments/coredns.yaml) to set the new DNS service address (it should still end with `.10`).

### Reaching the cluster from Windows

Unlike the NAT-only Apple Silicon setup, the `192.168.56.0/24` network is reachable from Windows itself, because your host holds `192.168.56.1` on it. `create-lab-network.ps1` adds a firewall rule permitting inbound traffic from that subnet, so once you reach the smoke-test lab you can open a NodePort in your Windows browser at `http://192.168.56.21:<nodeport>`.

This is a convenience, not part of the lab. Nothing in the tutorial depends on it.

## Running Commands in Parallel with Windows Terminal

Several labs ask you to run identical commands on more than one node. Windows Terminal can broadcast your keystrokes to every open pane:

1. Open a Windows Terminal tab and `multipass shell controlplane01`.
2. Split the pane with `ALT`+`SHIFT`+`+` (vertical) or `ALT`+`SHIFT`+`-` (horizontal), and `multipass shell` into a different node in each new pane.
3. Toggle broadcast with the **Toggle broadcast input to all panes** command from the command palette (`CTRL`+`SHIFT`+`P`).

Remember to turn broadcast off when you finish a section that applies to multiple nodes.

Alternatively `tmux` works exactly as described in the [VirtualBox prerequisites](../../VirtualBox/docs/01-prerequisites.md#running-commands-in-parallel-with-tmux) if you run it inside one of the VMs.

> The use of either is optional and not required to complete this tutorial.

Next: [Compute Resources](02-compute-resources.md)

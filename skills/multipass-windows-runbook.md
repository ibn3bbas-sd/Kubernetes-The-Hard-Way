# Kubernetes The Hard Way on Multipass (Windows / Hyper-V)

**Living doc.** Status: **DONE 2026-08-10** — the 5-VM lab deploys, provisions and self-verifies
end to end on the Windows workstation. The Kubernetes labs themselves (docs 03-17) have **not**
been walked through yet; only the infrastructure is proven.

Adds a **third hypervisor route** to the KodeKloud
[kubernetes-the-hard-way](https://github.com/mmumshad/kubernetes-the-hard-way) lab, which upstream
ships for VirtualBox+Vagrant (Windows/Intel Mac) and Multipass (Apple Silicon only). The Apple
Silicon scripts are Multipass-based but macOS-bound: they read host RAM with `sysctl hw.memsize`,
clean up `/var/db/dhcpd_leases`, and set `ARCH=arm64`.

| Item | Value |
|---|---|
| Upstream | `https://github.com/mmumshad/kubernetes-the-hard-way` (remote `upstream`) |
| New directory | `multipass-windows/` |
| Host | Windows 11 **Pro**, 32 GB RAM, 16 vCPU, Hyper-V enabled |
| Multipass | 1.16.3+win, driver **`hyperv`** |
| Driven from | **WSL bash**, calling `/mnt/c/Program Files/Multipass/bin/multipass.exe` |
| Guest | Ubuntu 22.04 (jammy) |

## Node layout

Deliberately identical to the VirtualBox route's addresses, so every sample output in the shared
`docs/` pages matches what you actually see.

| VM | Role | Lab IP | RAM (32 GB host) |
|---|---|---|---|
| `controlplane01` | control plane + admin client | 192.168.56.11 | 4 GB |
| `controlplane02` | control plane | 192.168.56.12 | 2 GB |
| `node01` | worker | 192.168.56.21 | 2 GB |
| `node02` | worker | 192.168.56.22 | 2 GB |
| `loadbalancer` | HAProxy over both API servers | 192.168.56.30 | 512 MB |

Windows itself holds `192.168.56.1`, so NodePorts are reachable from the host browser — a
convenience the NAT-only Apple Silicon route cannot offer. Sizing auto-scales: >=24 GB host gets the
above, 15-24 GB shrinks `controlplane01` to 2 GB, <15 GB shrinks everything and warns that the
final E2E-test lab will not run.

## Run it

```powershell
# once, ELEVATED PowerShell, from multipass-windows/
.\create-lab-network.ps1
```
```bash
# from WSL, from multipass-windows/
./deploy-virtual-machines.sh          # ~12 min cold, ~8 min with the image cached
multipass shell controlplane01        # then follow ../docs/03-client-tools.md
```

Teardown: `./delete-virtual-machines.sh`, then optionally `.\remove-lab-network.ps1` (elevated).
The switch is deliberately left behind so a rebuild needs no second elevation.

## Why a dedicated Hyper-V switch (the central design decision)

Multipass attaches every instance to the Hyper-V **Default Switch**, and **Windows re-randomises
that switch's subnet on each host reboot**. This lab writes node IPs into **certificate SANs and
kubeconfig files**, so a reboot part-way through would invalidate the cluster and force a redo of
the whole PKI chapter.

Not theoretical — observed live: a VM's `eth0` moved `192.168.147.3` -> `192.168.155.232` during a
single session, simply from a `netplan apply`.

So every VM gets **two NICs**:

| NIC | Network | Purpose |
|---|---|---|
| `eth0` | Default Switch, DHCP, **volatile** | Multipass management + internet (binary downloads) |
| `eth1` | `kthw-lab` internal switch, **static** `192.168.56.x` | all Kubernetes traffic |

Created with `multipass launch --network name=kthw-lab,mode=manual` — `mode=manual` attaches the
NIC but leaves it unconfigured, so a netplan drop-in can pin the static address.

**No `New-NetNat`.** Internet already flows over `eth0`, and Windows permits only one NetNat —
WSL already owns it. Adding one would have broken WSL networking.

Because Kubernetes must bind to the stable NIC, `PRIMARY_IP` is set from **`/etc/hosts`, not the
default route** — the default route points at the volatile `eth0`.

## Gotchas

Each of these cost a failed run.

### `New-VMSwitch` fails with 0x800700B7 on a name that was never used
`Internal miniport create failed ... Cannot create a file when that file already exists`, for a
switch name that does not exist and never appeared in `Get-VMSwitch` or `Get-NetAdapter
-IncludeHidden`. The name `k8s-hard-way` was permanently poisoned; `kthw-lab` worked first try.
Hyper-V retains the name somewhere the usual cmdlets don't show. **Don't debug it — pick another
name** and pass `-SwitchName` / `SWITCH=` consistently.

### stdin does NOT cross the WSL -> Windows boundary
```bash
cat file | multipass.exe exec node -- bash -c 'sudo tee /etc/netplan/x.yaml'   # WRONG
```
Creates the file **empty**, exit code **0**, no error anywhere. Silent data loss. Everything must
go through `multipass transfer`.

### `multipass transfer` needs *Windows* paths, and a Windows-readable source
`multipassd` runs as **SYSTEM** and cannot read `\\wsl.localhost`, so `wslpath -w` of a WSL-side
file is not enough. Files are staged in `C:\Users\Public\kthw-staging` and passed as
`C:\...` paths. Same applies to `powershell.exe -File` — it cannot read a `.ps1` from the WSL
filesystem, which is why `reset-multipass.ps1` is staged too.

### `netplan apply` kills the channel it is running on
It re-DHCPs `eth0`, which is the link `multipass exec` is riding. Running it in the foreground
hangs the command forever. Dispatch detached and poll from outside:
```bash
sudo systemd-run --unit=kthw-netplan --no-block netplan apply
```
Each poll is a fresh connection, so a mid-apply blip costs one retry instead of the run.

### `timeout` alone cannot kill a Windows process — use `timeout -k`
`multipass.exe` is reached over WSL interop and **does not reliably die on SIGTERM**, so plain
`timeout N` waits on it forever and the guard never fires. Every call needs `timeout -k <grace> N`.
This silently defeated the first version of the deadlock guard.

### Multipass 1.16.x + Hyper-V deadlocks the daemon
A launch hangs at `Starting <node>` **forever** while the VM is demonstrably healthy — Hyper-V says
`Running`, it answers ping, SSH with multipass's own key works, `cloud-init status: done`. Every
later `multipass` command then hangs behind it, and **`Restart-Service Multipass` sits in
`StopPending` indefinitely**.

Recovery (this is `reset-multipass.ps1`): force the VM off (releases the daemon), **kill the
`multipassd` process** — not stop the service — then start the service.

Contributing factors, both worth avoiding: the **GUI tray app polls the daemon** continuously (it
also **respawns after being killed**), and **two concurrent deploys** will do it reliably. A
chunk of the debugging here was chasing an orphaned run of my own competing with a new one.

> Diagnostic dead end, recorded so it isn't repeated: `Get-VMIntegrationService` reports
> **Key-Value Pair Exchange: "No Contact"** and `Get-VMNetworkAdapter ... IPAddresses` is empty on
> every instance. That looks like the smoking gun but is **normal** — the Ubuntu cloud image ships
> no `hv_kvp_daemon` at all (`dpkg -l | grep -c linux-cloud-tools` = 0). Multipass does not use it.

### Guard *every* multipass call, not just `launch`
An unguarded `multipass exec` mid-provisioning froze a run for **20 minutes with no output** —
no dots, no error, process alive. `mp_guard` in the deploy script wraps every call with a timeout,
a daemon reset and a retry.

### Provisioning must be idempotent
`01-setup-hosts.sh` originally removed only *its own* hostname before appending the lab block, so a
second pass left **two copies of every peer** in `/etc/hosts`. It now strips all five lab names
first. Re-running is supported on purpose:
```bash
SKIP_LAUNCH=1 ./deploy-virtual-machines.sh   # re-provision existing VMs, skip the launches
```

## What the deploy verifies before declaring success

Every node must resolve **and** ping every other node on the lab network (25 checks). If that fails
the script exits non-zero — do **not** start the labs, because the PKI chapters would fail later in
confusing ways.

Confirmed by hand afterwards on `controlplane01`:
```
PRIMARY_IP=192.168.56.11        ARCH=amd64
dig +short controlplane02  ->   192.168.56.12
~/cert_verify.sh  ~/approve-csr.sh   present, executable
```

`dig` works against `/etc/hosts` because systemd-resolved answers from it via the `127.0.0.53`
stub — the shared `docs/` pages depend on this (`CONTROL01=$(dig +short controlplane01)`), and
`dig` is already present in the image.

## Files

| Path | Purpose |
|---|---|
| `../multipass-windows/create-lab-network.ps1` | Elevated, once. Internal switch + host IP + firewall rule. Idempotent |
| `../multipass-windows/deploy-virtual-machines.sh` | Main driver (WSL). Launch, provision, verify |
| `../multipass-windows/delete-virtual-machines.sh` | Teardown. No stale DHCP leases to clean (unlike macOS) |
| `../multipass-windows/remove-lab-network.ps1` | Elevated. Removes switch + firewall rule |
| `../multipass-windows/reset-multipass.ps1` | Deadlock recovery; called automatically by the deploy |
| `../multipass-windows/scripts/00-setup-network.sh` | In-VM: static `eth1` via netplan, applied detached |
| `../multipass-windows/scripts/01-setup-hosts.sh` | In-VM: `/etc/hosts`, `PRIMARY_IP`, `ARCH=amd64`, sshd password auth, `ubuntu:ubuntu` |
| `../multipass-windows/scripts/cert_verify.sh` | Upstream's, with `PRIMARY_IP=$(dig +short $(hostname))` |
| `../multipass-windows/docs/01-prerequisites.md` | Windows prerequisites + the two-NIC explanation |
| `../multipass-windows/docs/02-compute-resources.md` | Deploy, verify, pause/resume, teardown, troubleshooting |

## Tunables

`SWITCH`, `LAB_NET`, `UBUNTU_RELEASE`, `LAUNCH_TIMEOUT`, `LAUNCH_ATTEMPTS`, `SKIP_LAUNCH`,
`MULTIPASS` — all environment variables. Changing `LAB_NET` needs a matching `-HostIp` on
`create-lab-network.ps1`; nothing else needs editing, because the labs compute everything from
`/etc/hosts` and `PRIMARY_IP`.

## Open / not done

- The Kubernetes labs (`docs/03`-`17`) have not been run. Only the VM infrastructure is proven.
- Not tested across a **host reboot**. The design intent is that static `eth1` addresses survive
  where Default Switch ones would not, but that has not been demonstrated.
- Not offered upstream as a PR.

See also [../multipass-windows/docs/01-prerequisites.md](../multipass-windows/docs/01-prerequisites.md)
for the user-facing version of the network explanation, and
[../multipass-windows/docs/02-compute-resources.md](../multipass-windows/docs/02-compute-resources.md)
for the run/teardown/troubleshooting steps.

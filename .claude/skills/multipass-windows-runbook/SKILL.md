---
name: multipass-windows-runbook
description: Design rationale and build history for the multipass-windows/ route - Multipass + Hyper-V on Windows 11 Pro, driven from WSL. SUPERSEDED for day-to-day access by hyperv-mobaxterm-runbook; read this one for WHY the lab network is built as it is, or when touching anything under multipass-windows/. Explains why the lab needs a dedicated Hyper-V switch and two NICs (the Default Switch subnet is re-randomised on every host reboot, and the labs write node IPs into certificate SANs), why cloud-init wipes /etc/hosts on every boot and which two obvious fixes fail silently, and the Multipass defects that led to dropping it: the daemon deadlock needing a multipassd kill, stdin not crossing the WSL boundary and silently writing empty files, multipass transfer needing Windows paths readable by SYSTEM, netplan apply killing the multipass exec channel, timeout needing -k against a Windows process, and New-VMSwitch 0x800700B7 on an unused name.
---

# Kubernetes The Hard Way on Multipass (Windows / Hyper-V)

**Living doc.** Status: **SUPERSEDED 2026-08-12 for day-to-day use** — the Multipass service is now
stopped and disabled, and the VMs are driven directly through Hyper-V and accessed over SSH from
MobaXterm. **To start, stop, connect to or troubleshoot the lab, use
[hyperv-mobaxterm-runbook](../hyperv-mobaxterm-runbook/SKILL.md).** The `multipass` commands below
will not run.

This document is still the record of **why the network is built the way it is** — the two-NIC
design, the dedicated `kthw-lab` switch, and the cloud-init `/etc/hosts` fix are all inherited
unchanged by the Hyper-V route, and the reasoning is here, not there. The daemon deadlock documented
below is why Multipass was dropped.

Status of the work it describes: **DONE 2026-08-10** — the 5-VM lab deploys, provisions and
self-verifies end to end on the Windows workstation. The Kubernetes labs themselves (docs 03-17)
have **not** been walked through yet; only the infrastructure is proven.

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

| VM | Role | Lab IP | RAM | Override |
|---|---|---|---|---|
| `controlplane01` | control plane + admin client | 192.168.56.11 | 2048M | `CP1MEM` |
| `controlplane02` | control plane | 192.168.56.12 | 1024M | `CP2MEM` |
| `node01` | worker | 192.168.56.21 | 1024M | `NODE1MEM` |
| `node02` | worker | 192.168.56.22 | 1024M | `NODE2MEM` |
| `loadbalancer` | HAProxy over both API servers | 192.168.56.30 | 512M | `LBMEM` |

Based on the **VirtualBox lab's table** (5.5 GB total) with two deliberate departures: both workers
get 1024M rather than 512M/1024M, since 512M is thin for containerd + kubelet + kube-proxy + Weave
and an asymmetric worker pair makes scheduling behaviour harder to read; and the loadbalancer drops
to 512M, ample for HAProxy.

Windows itself holds `192.168.56.1`, so NodePorts are reachable from the host browser — a
convenience the NAT-only Apple Silicon route cannot offer.

## Run it

```powershell
# once, ELEVATED PowerShell, from multipass-windows/
.\create-lab-network.ps1
```
```bash
# from WSL, from multipass-windows/
./deploy-virtual-machines.sh          # ~12 min cold, ~8 min with the image cached
multipass shell controlplane01        # then follow docs/03-client-tools.md
```

Teardown: `./delete-virtual-machines.sh`, then optionally `.\remove-lab-network.ps1` (elevated).
The switch is deliberately left behind so a rebuild needs no second elevation.

**Before lab 04, read [pasting-lab-commands-from-windows](../pasting-lab-commands-from-windows/SKILL.md).**
Commands copied from a browser on Windows arrive CRLF-terminated, which silently truncates the
`\`-continued commands the labs are full of - and the failure looks like success.

## Why a dedicated Hyper-V switch (the central design decision)

Multipass attaches every instance to the Hyper-V **Default Switch**, and **Windows re-randomises
that switch's subnet on each host reboot**. This lab writes node IPs into **certificate SANs and
kubeconfig files**, so a reboot part-way through would invalidate the cluster and force a redo of
the whole PKI chapter.

Not theoretical — observed live: a VM's `eth0` moved `192.168.147.3` -> `192.168.155.232` during a
single session, simply from a `netplan apply`.

**Confirmed upstream, and it will not be fixed.** Canonical
[multipass#1153](https://github.com/canonical/multipass/issues/1153) (2019) reports precisely this -
*"the IP address of the vEthernet (default switch) changes every time after Windows reboot"* - filed
by someone with our exact use case, maintaining hosts-file entries for Windows and WSL. It was closed
with the advice to use `<instance>.mshome.net` instead of addresses.
[multipass#3582](https://github.com/canonical/multipass/issues/3582) asks directly for a static IP on
the default interface; a maintainer's answer is that it would have to be implemented across every
platform and backend and that *"Windows and macOS specific bits are closed FTTB"*. Closed 2026-04-27
pointing at a community blog workaround. Same request, also closed: #567, #1293, #1545.

So the sanctioned options are (a) `.mshome.net` hostnames, or (b) attach your own network and
configure it yourself. **`.mshome.net` does not solve this lab**, which is why we do (b): the labs put
node IPs in certificate SANs and bind etcd and the API servers to addresses, so a stable *name* does
not help - the address behind it still moves, invalidating the PKI.

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

**This is upstream bug [multipass#5080](https://github.com/canonical/multipass/issues/5080)** -
*"Daemon blocks indefinitely on spawning new SSHProcess when the underlying VM has shut down"*,
opened 2026-07-15, still `needs triage` with no fix PR. Their gdb traces give the mechanism:
`state_mut` is held in `exec_process` in `BaseVM` while an ssh session to a downed VM blocks on
`poll` **with no timeout**, so the mutex is never released and the main thread deadlocks on
`on_shutdown`. The reporter's own summary - *"No timeouts bail out the daemon"* - is exactly why
`mp_guard` has to impose a timeout from outside, and why killing the process is the only exit.

Their trigger, an **aborted instance start**, matches ours: every deadlock here followed a launch
that had been interrupted or timed out. The failure is self-feeding - one stall creates the
conditions for the next - which is why the deploy script purges a half-built instance before
retrying rather than just re-running `launch`.

Contributing factors, both worth avoiding: the **GUI tray app polls the daemon** continuously (it
also **respawns after being killed**), and **two concurrent deploys** will do it reliably. A
chunk of the debugging here was chasing an orphaned run of my own competing with a new one.

> Diagnostic dead end, recorded so it isn't repeated: `Get-VMIntegrationService` reports
> **Key-Value Pair Exchange: "No Contact"** and `Get-VMNetworkAdapter ... IPAddresses` is empty on
> every instance. That looks like the smoking gun but is **normal** — the Ubuntu cloud image ships
> no `hv_kvp_daemon` at all (`dpkg -l | grep -c linux-cloud-tools` = 0). Multipass does not use it.

### cloud-init wipes `/etc/hosts` on every boot - and the two obvious fixes both fail
The static addresses survive `multipass stop` / `start` exactly as designed. **`/etc/hosts` does
not.** The image enables cloud-init's `manage_etc_hosts`, so `update_etc_hosts` regenerates the file
from `/etc/cloud/templates/hosts.debian.tmpl` on every boot, leaving only:

```
127.0.1.1 controlplane01 controlplane01
127.0.0.1 localhost
```

`dig +short controlplane01` then returns **`127.0.1.1`** and every other lab name resolves to
**nothing**. The labs build certificate SANs and kubeconfigs from `dig +short`, so a cluster built
after a pause fails with errors pointing nowhere near `/etc/hosts` - and the docs tell you to
`multipass stop` to pause, so this is on the default path.

**Fix 1, `manage_etc_hosts: false` in `/etc/cloud/cloud.cfg.d/` - does not work.** Multipass sets
the value in the instance **vendor-data**, which cloud-init merges at higher precedence than
anything in `cloud.cfg.d`. The override is silently ignored.

**Fix 2, a systemd unit ordered `After=cloud-final.service` - does not work either, and fails
silently.** On Ubuntu `cloud-final.service` is itself `After=multi-user.target`, and **a target
implicitly gains `After=` on the units it `Wants`**, so `WantedBy=multi-user.target` closes an
ordering cycle. systemd resolves it by deleting the unit's start job. The tell is brutal:

```
$ systemctl is-enabled kthw-hosts.service   ->  enabled
$ systemctl is-active  kthw-hosts.service   ->  inactive
$ journalctl -b | grep -i 'ordering cycle'
  multi-user.target: Found ordering cycle on kthw-hosts.service/start
  Job kthw-hosts.service/start deleted to break ordering cycle
```

Removing `Before=multi-user.target` does **not** help - the target's implicit ordering is what
closes the loop. I shipped this version, and only caught it because I stopped a VM to check.

**What works:** comment `- update_etc_hosts` out of `cloud_init_modules` in `/etc/cloud/cloud.cfg`.
The module list is read from `cloud.cfg` itself, so it takes effect whatever vendor-data asks for,
and `/etc/hosts` becomes an ordinary file again. Verified across a stop/start of all five instances.

Upstream's own prescription ([multipass#3614](https://github.com/canonical/multipass/issues/3614),
closed) is to edit `/etc/cloud/templates/hosts.debian.tmpl` and leave cloud-init in charge; that is
equally valid. Both #3614 and [#2385](https://github.com/canonical/multipass/issues/2385) are closed
as working-as-designed, so this is behaviour to work around, not a bug to wait on.

> Worth internalising: `PRIMARY_IP`, `ARCH` and netplan **all** survived. Only the
> cloud-init-managed file was reset. When something "doesn't persist", ask whether cloud-init owns
> it before assuming the write failed. And a systemd unit that is `enabled` is not necessarily a
> unit that **runs**.

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

## Upstream issues behind the two hard parts

Checked 2026-08-11. Neither is our misconfiguration; both are Canonical's, and neither has a fix.

| Issue | State | What it establishes |
|---|---|---|
| [#5080](https://github.com/canonical/multipass/issues/5080) | **open**, needs triage, no fix PR | The daemon deadlock. Root-caused to `state_mut` held across a timeout-less ssh `poll` in `BaseVM::exec_process`. Trigger is an aborted instance start |
| [#3582](https://github.com/canonical/multipass/issues/3582) | closed 2026-04-27, won't-fix | Static IP on the default interface is unsupported and unplanned; the Windows-specific parts are closed source |
| [#1153](https://github.com/canonical/multipass/issues/1153) | closed 2019 | The Default Switch subnet changes on every Windows reboot. Answered with "use `.mshome.net`", not fixed |
| [#4383](https://github.com/canonical/multipass/issues/4383) | closed | Same class of problem on macOS - an OS upgrade moved the bridge subnet |
| [#708](https://github.com/canonical/multipass/issues/708) | closed, believed stale | Shutting Windows down with an instance running left it unusable on next boot. Worth knowing if a host crash ever wedges the lab |

Practical consequence: **do not spend time trying to make `multipass` itself behave here.** The
second NIC and the daemon-reset retry work around defects upstream has either declined to fix or has
not yet triaged.

## Files

Paths are repo-relative, so they paste straight into a shell from the repo root.

| Path | Purpose |
|---|---|
| `multipass-windows/create-lab-network.ps1` | Elevated, once. Internal switch + host IP + firewall rule. Idempotent |
| `multipass-windows/deploy-virtual-machines.sh` | Main driver (WSL). Launch, provision, verify |
| `multipass-windows/delete-virtual-machines.sh` | Teardown. No stale DHCP leases to clean (unlike macOS) |
| `multipass-windows/remove-lab-network.ps1` | Elevated. Removes switch + firewall rule |
| `multipass-windows/reset-multipass.ps1` | Deadlock recovery; called automatically by the deploy |
| `multipass-windows/scripts/00-setup-network.sh` | In-VM: static `eth1` via netplan, applied detached |
| `multipass-windows/scripts/01-setup-hosts.sh` | In-VM: installs the hosts unit, `PRIMARY_IP`, `ARCH=amd64`, sshd password auth, `ubuntu:ubuntu` |
| `multipass-windows/scripts/kthw-hosts.sh` | In-VM: applies `/etc/hosts` from `/etc/kthw-hostentries` and disables cloud-init's `update_etc_hosts` so it stays applied |
| `multipass-windows/scripts/cert_verify.sh` | Upstream's, with `PRIMARY_IP=$(dig +short $(hostname))` |
| `multipass-windows/docs/01-prerequisites.md` | Windows prerequisites + the two-NIC explanation |
| `multipass-windows/docs/02-compute-resources.md` | Deploy, verify, pause/resume, teardown, troubleshooting |

## Tunables

`SWITCH`, `LAB_NET`, `UBUNTU_RELEASE`, `LAUNCH_TIMEOUT`, `LAUNCH_ATTEMPTS`, `SKIP_LAUNCH`,
`MULTIPASS`, and the per-VM memory overrides `CP1MEM` / `CP2MEM` / `NODE1MEM` / `NODE2MEM` / `LBMEM` — all environment variables. Changing `LAB_NET` needs a matching `-HostIp` on
`create-lab-network.ps1`; nothing else needs editing, because the labs compute everything from
`/etc/hosts` and `PRIMARY_IP`.

## Open / not done

- The Kubernetes labs (`docs/03`-`17`) have not been run. Only the VM infrastructure is proven.
- **Stop/start is tested** (2026-08-11): all five instances stopped and started, every node's
  `eth1` address, `PRIMARY_IP` and full name resolution intact, while the `eth0` addresses had all
  moved - the design working as intended. That test is what exposed the cloud-init `/etc/hosts`
  wipe above, and re-running it is what caught the broken first fix.
- Still **not tested across a full host reboot**, where the Default Switch subnet itself is
  re-randomised. The switch and its `192.168.56.1` host address survived a day of uptime, but a
  real reboot has not been done.
- Not offered upstream as a PR.

See also [multipass-windows/docs/01-prerequisites.md](../../../multipass-windows/docs/01-prerequisites.md)
for the user-facing version of the network explanation, and
[multipass-windows/docs/02-compute-resources.md](../../../multipass-windows/docs/02-compute-resources.md)
for the run/teardown/troubleshooting steps.

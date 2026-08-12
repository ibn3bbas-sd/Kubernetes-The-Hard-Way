---
name: hyperv-mobaxterm-runbook
description: Running the lab VMs as plain Hyper-V VMs, accessed over SSH from MobaXterm, after dropping Multipass. Use when starting, stopping, connecting to, or troubleshooting the five lab VMs on Windows now that the multipass CLI is gone - how to reach a VM when SSH is down (VMConnect console, ubuntu/ubuntu), the two separate SSH key setups and which host each runs on, ssh-keygen failing with "No such file or directory" on a fresh MobaXterm home, a private key generated world-readable, ping failing from Windows while SSH works, AutomaticStopAction=Save corrupting cluster state on host shutdown, and the cloud-init ISO left dangling in the Multipass vault after Move-VMStorage. Supersedes multipass-windows-runbook for day-to-day access; that doc still explains why the network is built this way.
---

# Hyper-V + MobaXterm: running the lab without Multipass

**Living doc.** Status: **IN PROGRESS, started 2026-08-12.** The five VMs run as ordinary Hyper-V
VMs and are reachable from MobaXterm over SSH with key auth. **Two things are still open** - see
[Open / not done](#open--not-done). The Kubernetes labs (`docs/03`-`17`) have still not been walked
through.

Replaces the `multipass` CLI as the way the lab is driven. Multipass was dropped because its daemon
deadlocks against Hyper-V often enough to cost whole runs - see
[multipass-windows-runbook](../multipass-windows-runbook/SKILL.md), which remains the record of
**why the network is built the way it is**. That design is inherited wholesale here and is what made
this migration nearly free.

## The thing to understand first

Multipass did not create anything exotic. It created five **ordinary Gen2 Hyper-V VMs**:

| VM | eth1 (lab, static) | eth0 | Mem | vCPU |
|---|---|---|---|---|
| `controlplane01` | 192.168.56.11 | Default Switch | 2048M | 2 |
| `controlplane02` | 192.168.56.12 | Default Switch | 1024M | 2 |
| `node01` | 192.168.56.21 | Default Switch | 1024M | 2 |
| `node02` | 192.168.56.22 | Default Switch | 1024M | 2 |
| `loadbalancer` | 192.168.56.30 | Default Switch | 512M | 1 |

Windows holds `192.168.56.1` on `vEthernet (kthw-lab)`. **Nothing had to be rebuilt** - no
re-install, no re-provision, no new PKI. The only real tie to Multipass was where the VM's files
lived. Everything the provisioning scripts wrote - the netplan drop-in for `eth1`, `PRIMARY_IP`,
`ARCH`, the `/etc/hosts` fix, sshd password auth - is on the guest disk and travels with the VHDX.

`eth0` on the Default Switch keeps working after Multipass is gone: that switch's DHCP and NAT come
from Windows ICS, not from `multipassd`.

## The cut-over

Run in this order. Steps 1-4 are done; step 5 is not.

**1. Confirm you have a login that does not need Multipass.** Do this *first* - it is the only
irreversible mistake available here. `multipass-windows/scripts/01-setup-hosts.sh:37-49` enables
sshd password auth and sets `ubuntu:ubuntu`, so both SSH and the Hyper-V console work. Verified with
`sudo sshd -T | grep -i passwordauthentication` -> `yes`.

**2. Shut the VMs down gracefully** - `Stop-VM`, not save.

**3. Move the storage out of the Multipass vault.** The disks were in
`C:\ProgramData\Multipass\data\vault\instances\<name>\` (12.4 GB total), which a
`multipass delete --purge` or an uninstall deletes:

```powershell
foreach ($vm in 'controlplane01','controlplane02','node01','node02','loadbalancer') {
  Move-VMStorage -VMName $vm -DestinationStoragePath "C:\Hyper-V\kthw\$vm"
}
```

`Move-VMStorage` relocates the files *and* rewrites the VM config to match. Keep the destination
**out of the OneDrive tree** this repo lives in - a syncing 12 GB VHDX with file locks is its own
disaster.

**4. Fix the automatic actions**, then disable the service:

```powershell
Get-VM controlplane01,controlplane02,node01,node02,loadbalancer |
  Set-VM -AutomaticStopAction ShutDown -AutomaticStartAction Nothing

Stop-Process -Name multipass -EA SilentlyContinue   # tray app; also remove from startup, it respawns
Stop-Service Multipass
Set-Service Multipass -StartupType Disabled
```

**5. Re-point the cloud-init ISOs — NOT DONE.** See the gotcha below.

## Access

### MobaXterm (normal path)

Session -> SSH, host `192.168.56.11`, **Specify username** `ubuntu`, port 22. Bookmark folder
`KTHW`, then **Duplicate session** for `.12`, `.21`, `.22`, `.30`. Password is `ubuntu` until keys
are in place. Start from `controlplane01` - it is the admin client the labs run `kubectl` and
`cert_verify.sh` from.

Two MobaXterm features replace what Multipass gave us: the **SFTP pane** (auto-connects with each
session) replaces `multipass transfer`, with none of the Windows-path/SYSTEM-readability problems;
and **MultiExec** types into all open terminals at once, which suits the "run this on both workers"
steps. Be careful with MultiExec during the PKI chapters - several steps look identical across nodes
but must produce per-node output.

### Hyper-V console (when SSH is down)

With Multipass disabled there is no `multipass shell` fallback, so the console is the only way in:
Hyper-V Manager -> double-click the VM -> log in `ubuntu` / `ubuntu`. This is not a last resort, it
is the normal tool for fixing anything network-related, and it is how the boot-time outage below was
diagnosed.

Consequence: **never break sshd and networking in the same change** without checking the console
still logs in first.

## Gotchas

### There are TWO SSH key setups, on different machines - don't conflate them
| | Where you run it | Key | Targets | Why |
|---|---|---|---|---|
| MobaXterm convenience | Windows, MobaXterm local terminal | `~/.ssh/kthw` | the five IPs | Stop typing the password |
| **Lab 03, required** | `controlplane01` | `~/.ssh/id_rsa` (default name) | four hostnames **+ itself** | The PKI chapters `scp` certs between nodes |

`docs/03-client-tools.md:16-39` is the second one. It uses **hostnames**, the **default** key name
that later labs assume, and appends the key to `controlplane01`'s own `authorized_keys` because some
steps `scp` to themselves. `$(whoami)` is `ubuntu` on this route and the password is `ubuntu`.
Substituting the MobaXterm key for it will fail later, far from the cause.

### `ssh-keygen` fails with "No such file or directory" on a fresh MobaXterm home
```
Saving key "/home/mobaxterm/.ssh/kthw" failed: No such file or directory
```
Reads like a bad path; it means **`~/.ssh` does not exist**. `ssh-keygen` creates the key files but
not the directory. Every subsequent `ssh-copy-id` then fails on the missing `.pub`.
```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/kthw -N ""       # -N "" skips the passphrase prompts
```
Also check **Settings -> Configuration -> General -> Persistent home directory** is enabled - a
missing `~/.ssh` is a hint the home is fresh, and a non-persistent one loses the key on restart.

### The generated private key is world-readable
MobaXterm's Cygwin layer creates it `644`, and is permissive enough that SSH still uses it:
```
-rw-r--r-- 1 Home None 411 /home/mobaxterm/.ssh/kthw
```
`chmod 600 ~/.ssh/kthw`. If it does not stick, the mount has no ACL support - not worth fighting,
but know the key is readable by anything running as your Windows user.

### Ping fails from Windows while SSH works — this is normal, don't chase it
```
192.168.56.11  ping=False  ssh22=True
```
ICMP is filtered on the Windows side. TCP is what the lab needs, and node-to-node ping *inside* the
lab network is a different path (the one `deploy-virtual-machines.sh` verified with 25 checks). Use
`Test-NetConnection <ip> -Port 22` and read **`TcpTestSucceeded`**, not `PingSucceeded`.

### `AutomaticStopAction` defaults to `Save`, which is wrong for this lab
Multipass leaves every VM on `Save`. On host shutdown that freezes the VM and resumes it with a
stale clock - etcd's raft ticks and the kubelet's certificate and lease handling both react badly to
a clock jump. Set `ShutDown` (step 4 above). `AutomaticCheckpointsEnabled` is already `False`, which
is correct - automatic checkpoints build AVHDX differencing chains behind your back.

### `Move-VMStorage` leaves the cloud-init ISO behind
After the move, the VHDX is in the new location but the DVD drive still points into the vault:
```
HDD  C:\Hyper-V\kthw\controlplane01\Virtual Hard Disks\ubuntu-22.04-server-cloudimg-amd64.vhdx
DVD  C:\ProgramData\Multipass\data\vault\instances\controlplane01\cloud-init-config.iso
```
That ISO is cloud-init's NoCloud datasource. It resolves today only because the vault still happens
to exist, so **the cut-over is not finished and Multipass cannot be uninstalled yet.** With the VMs
shut down:
```powershell
foreach ($vm in 'controlplane01','controlplane02','node01','node02','loadbalancer') {
  $dst = "C:\Hyper-V\kthw\$vm\cloud-init-config.iso"
  Copy-Item "C:\ProgramData\Multipass\data\vault\instances\$vm\cloud-init-config.iso" $dst -Force
  Set-VMDvdDrive -VMName $vm -Path $dst
}
```
Then prove nothing references the vault before uninstalling:
```powershell
Get-VM | ForEach-Object { Get-VMHardDiskDrive $_.Name; Get-VMDvdDrive $_.Name } |
  Where-Object Path -like '*Multipass*'      # empty output means clear
```

### The lab network is not up immediately after boot
Observed 2026-08-12: at **~2 minutes uptime** every node was unreachable from Windows -
`Test-NetConnection 192.168.56.11 -Port 22` gave `PingSucceeded: False`, `TcpTestSucceeded: False`,
while the host side was provably healthy (`vEthernet (kthw-lab)` Up with `192.168.56.1/24`, both VM
NICs attached and `Ok`). At **~28 minutes uptime** all five answered on port 22.

**Root cause not established** - see Open below. The static address is a netplan drop-in written to
`/etc/netplan/99-kthw-lab.yaml` by `multipass-windows/scripts/00-setup-network.sh:14`, so it is on
the guest disk and should come up on its own.

Diagnose from the console, not by guessing:
```bash
ip -br addr                  # is eth1 present, and does it have 192.168.56.x/24?
ip -br link                  # if eth1 is absent entirely, the NIC was renamed
ls -l /etc/netplan/
cloud-init status
sudo netplan apply           # safe at the console; it re-DHCPs eth0, which no longer matters
```
`netplan apply` killing the session was a *Multipass* hazard - it rode the `eth0` link. On the
console it is harmless, which is one concrete thing this route made easier.

## Verify the whole lab is reachable

From WSL or PowerShell:
```powershell
foreach ($ip in '192.168.56.11','192.168.56.12','192.168.56.21','192.168.56.22','192.168.56.30') {
  $r = Test-NetConnection -ComputerName $ip -Port 22 -WarningAction SilentlyContinue
  '{0}  ssh22={1}' -f $ip, $r.TcpTestSucceeded
}
```
All five `True` is the green light. Read `TcpTestSucceeded` only.

## Checkpoints

For restore points between lab chapters:
```powershell
Checkpoint-VM -Name controlplane01 -SnapshotName 'post-lab-04-pki'
```
**Shut all five down and checkpoint all five together.** Checkpointing live, or one node at a time,
lets etcd and PKI state diverge between nodes - restoring one node into a cluster that moved on is
worse than rebuilding. Leave automatic checkpoints disabled.

## Still read the CRLF doc before lab 04

[pasting-lab-commands-from-windows](../pasting-lab-commands-from-windows/SKILL.md) applies *more*
here, not less: MobaXterm means pasting `\`-continued `openssl` commands from a browser into a real
terminal, and the failure looks like success.

## Open / not done

- **The cloud-init ISOs still point into the Multipass vault.** Until step 5 is run, uninstalling
  Multipass or deleting the vault breaks every VM's datasource. This is the one blocking item.
- **Why the lab network needed ~28 minutes after boot is unexplained.** "Slow to come up on its own"
  and "needed a manual kick" are very different problems and this lab is stopped and started often.
  Next boot: check `ip -br addr` at the console immediately, then again at 1, 5 and 10 minutes, and
  record `systemd-analyze blame | head` plus `systemctl status systemd-networkd-wait-online`.
- **Not tested across a full host reboot**, where the Default Switch subnet is re-randomised.
  Unchanged from the Multipass route.
- `multipass-windows/deploy-virtual-machines.sh` no longer works, including `SKIP_LAUNCH=1`
  re-provisioning - it drives everything through the `multipass` CLI. Nothing has replaced it; the
  in-VM scripts under `multipass-windows/scripts/` are still valid if run by hand over SSH.
- Consider retiring cloud-init entirely once `eth1` is confirmed stable: `sudo touch
  /etc/cloud/cloud-init.disabled` in each guest. It has now caused two separate problems (the
  `/etc/hosts` wipe, and the ISO dependency), the VMs are fully provisioned, and the files it
  already wrote stay on disk. Do it as its own change, not alongside a network fix.

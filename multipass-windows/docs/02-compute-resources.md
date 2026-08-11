# Provisioning Compute Resources

Note: You must have Hyper-V enabled, Multipass installed with the `hyperv` driver, and WSL available at this point. See [prerequisites](01-prerequisites.md).

All commands on this page are run from the `multipass-windows` directory of your clone.

## 1. Create the lab network

This is a one-off step and the only one that needs Administrator rights. It creates the Hyper-V switch that carries the stable `192.168.56.0/24` lab network described in the [prerequisites](01-prerequisites.md#virtual-machine-network).

Open PowerShell **as Administrator**, `cd` to the `multipass-windows` directory of your clone, and run:

```powershell
.\create-lab-network.ps1
```

Expected output ends with:

```
Lab network ready. Next, from WSL:  ./deploy-virtual-machines.sh
```

You only ever need to run this again if you remove the switch.

> **If it fails with `0x800700B7` / "Cannot create a file when that file already exists"** - this is a Hyper-V quirk where a previously removed adapter still holds the name. Pick another name and use it consistently:
> ```powershell
> .\create-lab-network.ps1 -SwitchName kthw-lab2
> ```
> ```bash
> SWITCH=kthw-lab2 ./deploy-virtual-machines.sh
> ```

## 2. Deploy the virtual machines

From **WSL**:

```bash
./deploy-virtual-machines.sh
```

This takes roughly 10 minutes on a first run - the Ubuntu 22.04 image is downloaded once and cached, so rebuilds are faster.

It deploys 5 VMs - 2 control plane, 2 worker and 1 load balancer - on the stable `192.168.56.0/24` lab network:

| VM | Purpose | IP | CPU | RAM | Disk | Override |
| --- | --- | --- | --- | --- | --- | --- |
| controlplane01 | Control plane, and your admin client | 192.168.56.11 | 2 | 2048M | 15G | `CP1MEM` |
| controlplane02 | Control plane | 192.168.56.12 | 2 | 1024M | 10G | `CP2MEM` |
| node01 | Worker | 192.168.56.21 | 2 | 1024M | 10G | `NODE1MEM` |
| node02 | Worker | 192.168.56.22 | 2 | 1024M | 10G | `NODE2MEM` |
| loadbalancer | HAProxy in front of both API servers | 192.168.56.30 | 1 | 512M | 5G | `LBMEM` |

5.5GB of RAM in total. Raise any of them from the environment if you have it to spare:

```bash
CP1MEM=4096M NODE1MEM=2048M ./deploy-virtual-machines.sh
```

> These follow the [VirtualBox lab's table](../../VirtualBox/docs/02-compute-resources.md) with two deliberate departures: both workers get 1024M rather than 512M and 1024M, because 512M is thin for a worker running containerd, kubelet, kube-proxy and Weave - and two identical workers make scheduling behaviour easier to reason about. The loadbalancer drops to 512M, which is plenty for HAProxy. The total is unchanged.

There are no forwarded ports. The VirtualBox route needs them because its VMs sit behind NAT; here the lab network is directly reachable from Windows, so you can `ssh ubuntu@192.168.56.11` (password `ubuntu`) or open a NodePort in your browser without any port mapping.

> **Leave Multipass alone while this runs.** Do not open a second terminal and run `multipass list`, and close the Multipass GUI tray application if it is running. `multipassd` serialises operations, and issuing a command while a launch is in progress can deadlock it - the launch then hangs at `Starting <node>` forever even though the VM itself is up and healthy. See the troubleshooting note below if this happens to you.

The script:

- Deploys 5 VMs - 2 control plane, 2 worker and 1 load balancer - sized from your host RAM.
- Gives each a second NIC on the `kthw-lab` switch with a static address in `192.168.56.0/24`.
- Writes `/etc/hosts` on every node so all five resolve each other by name.
- Sets `PRIMARY_IP` (this node's lab address) and `ARCH=amd64` in `/etc/environment`.
- Enables password SSH authentication and sets the `ubuntu` user's password to `ubuntu`, so `ssh-copy-id` works in the next lab.
- Installs `cert_verify.sh` in the home directory of every node, and `approve-csr.sh` on `controlplane01`.
- Verifies, before finishing, that every node resolves and can ping every other node on the lab network.

It ends with a table of instances and `Done!`. If the verification step reports a failure, **do not start the labs** - something is wrong with the lab network and the PKI chapters will fail in confusing ways later.

### Resuming a failed deploy

If the deploy dies part way through provisioning, you do not have to rebuild all five VMs. Re-run it against the instances that already exist:

```bash
SKIP_LAUNCH=1 ./deploy-virtual-machines.sh
```

That skips the launch phase entirely, starts any instance that is stopped, and re-runs provisioning and verification. Provisioning is idempotent, so it is safe to run as often as you like.

## 3. Verify

Confirm you can connect to all VMs:

```bash
multipass shell controlplane01
```

You should see a command prompt like `ubuntu@controlplane01:~$`.

Check the lab network is the one Kubernetes will use:

```bash
echo $PRIMARY_IP        # 192.168.56.11 on controlplane01
dig +short node01       # 192.168.56.21
```

Type `exit` to return to your WSL prompt. Do this for the other controlplane, both nodes and the loadbalancer.

## SSH to the nodes

There are two ways in:

1. **`multipass shell <vm>`** - the recommended way, equivalent to `vagrant ssh` in the VirtualBox labs.
2. **Any SSH client**, including from Windows itself, using the lab addresses above with username `ubuntu` and password `ubuntu`. For example `ssh ubuntu@192.168.56.11`.

# Pausing the Environment

You do not need to complete the entire lab in one session. From WSL:

```bash
multipass stop controlplane01 controlplane02 node01 node02 loadbalancer
```

To resume:

```bash
multipass start controlplane01 controlplane02 node01 node02 loadbalancer
```

The lab addresses are static and survive stop/start, which is the whole reason for the dedicated switch. The `eth0` addresses will change, and that is expected and harmless - nothing in the cluster refers to them.

`/etc/hosts` also survives, but only because the deploy installs a small service to make it so. The Multipass image has cloud-init's `manage_etc_hosts` enabled, which **regenerates `/etc/hosts` from a template on every boot** and would otherwise wipe the lab entries - leaving `dig +short controlplane01` returning `127.0.1.1` and every other lab name resolving to nothing. `kthw-hosts.service` re-applies them after cloud-init has finished. If you ever suspect it:

```bash
multipass exec controlplane01 -- systemctl status kthw-hosts.service
multipass exec controlplane01 -- dig +short node01     # expect 192.168.56.21
```

Re-running `SKIP_LAUNCH=1 ./deploy-virtual-machines.sh` reinstalls and re-applies it.

> After a host reboot, give Hyper-V a moment before starting the VMs. If a VM fails to start with a network error, confirm the switch survived with `multipass networks` - it should still list `kthw-lab`.

# Deleting the Virtual Machines

When you have finished with your cluster and want to reclaim the resources:

1. Exit from all your VM sessions.
2. From WSL:

    ```bash
    ./delete-virtual-machines.sh
    ```

This stops, deletes and purges all five instances. Unlike the Apple Silicon teardown there are no stale DHCP leases to clean up by hand - the lab addresses are static.

The `kthw-lab` switch is deliberately left behind so you can redeploy without another elevated prompt. To remove it too, from an elevated PowerShell prompt:

```powershell
.\remove-lab-network.ps1
```

# Troubleshooting

### `Hyper-V switch 'kthw-lab' not found`

You have not run `create-lab-network.ps1`, or you ran it with a different `-SwitchName`. See step 1.

### `Multipass daemon appears deadlocked. Resetting it...`

This is expected, and the script handles it. Multipass 1.16.x on the Hyper-V driver intermittently deadlocks: a launch hangs at `Starting <node>` forever even though the VM has booted cleanly and answers SSH, and every subsequent `multipass` command hangs behind it. `Restart-Service Multipass` does not help - the service sits in `StopPending` indefinitely.

`deploy-virtual-machines.sh` detects the stall by timeout, runs [reset-multipass.ps1](../reset-multipass.ps1) to force the daemon back to life, clears the half-built instance and retries, up to three times per node. You may see a UAC prompt when it does this, because restarting the service needs Administrator rights. Approve it and the deploy continues.

Reduce the odds of hitting it at all by leaving Multipass alone during the deploy - no second terminal, no GUI tray application, and never two deploys at once.

If a node exhausts all three attempts the script stops and names it. Recover manually from an elevated PowerShell prompt:

```powershell
.\reset-multipass.ps1 -TurnOffVMs <node>
multipass list                            # should respond immediately again
```

Then start over:

```bash
./delete-virtual-machines.sh
./deploy-virtual-machines.sh
```

The instances themselves are not damaged by any of this - only the daemon's view of them.

### A VM never comes up on its lab address

The deploy script polls for up to 90 seconds and then fails with the node name. Inspect it:

```bash
multipass exec node01 -- ip a
multipass exec node01 -- sudo systemctl status kthw-netplan
```

`eth1` should hold the lab address. If `eth1` is missing entirely, the `--network` flag did not take - confirm `multipass get local.driver` is `hyperv`.

### `multipass: command not found` in WSL

Expected - Multipass is installed on the Windows side only. The scripts call it by full path. To use it interactively from WSL, add to your `~/.bashrc`:

```bash
alias multipass='/mnt/c/Program\ Files/Multipass/bin/multipass.exe'
```

### `multipass transfer` fails, or transferred files arrive empty

You are almost certainly passing a Linux path. `multipassd` runs as `SYSTEM` on Windows and cannot read `\\wsl.localhost`, and stdin does not cross the WSL boundary - piping into `multipass exec ... -- tee` produces an empty file with no error. The deploy script stages every file under `C:\Users\Public\kthw-staging` and passes Windows paths for exactly this reason. Do the same in anything you write yourself.

Next: [Client tools](../../docs/03-client-tools.md)<br>
Prev: [Prerequisites](01-prerequisites.md)

<#
.SYNOPSIS
    Recovers a deadlocked Multipass daemon.

.DESCRIPTION
    Multipass 1.16.x with the Hyper-V driver intermittently deadlocks: a `multipass
    launch` hangs at "Starting <node>" forever even though the VM itself has booted
    cleanly and is reachable over SSH, and every subsequent multipass command hangs
    too. The daemon cannot be stopped through the Service Control Manager in that
    state - `Restart-Service` sits in StopPending indefinitely.

    This script forces it back to a working state: it closes the GUI tray application
    (which polls the daemon and makes the deadlock more likely), force-terminates the
    daemon process, and brings the service back up.

    Instances are not harmed. Only the daemon's view of them is reset.

    deploy-virtual-machines.sh calls this automatically when a launch stalls. You can
    also run it by hand from an elevated PowerShell prompt.

.PARAMETER TurnOffVMs
    Also force off these VMs before restarting the daemon. A VM the daemon is stuck
    waiting on must be powered off, or the restarted daemon will block on it again.
#>
[CmdletBinding()]
param(
    [string[]]$TurnOffVMs = @()
)

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run elevated (Run as Administrator)."
    exit 1
}

# The tray app polls the daemon continuously. Leaving it running during a multi-VM
# deploy measurably increases the chance of a deadlock.
Get-Process 'multipass.gui' -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process 'multipass'     -ErrorAction SilentlyContinue | Stop-Process -Force

foreach ($vm in $TurnOffVMs) {
    Get-VM -Name $vm -ErrorAction SilentlyContinue | Where-Object State -ne 'Off' |
        Stop-VM -TurnOff -Force -ErrorAction SilentlyContinue
}

# Stop-Service will not work against a deadlocked daemon; kill the process instead.
Get-Process multipassd -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 5

for ($i = 0; $i -lt 30; $i++) {
    if ((Get-Service Multipass).Status -eq 'Running') { break }
    Start-Service Multipass -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

$status = (Get-Service Multipass).Status
Write-Output "Multipass service: $status"
if ($status -ne 'Running') { exit 1 }

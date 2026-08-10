<#
.SYNOPSIS
    Creates the stable private network used by the Kubernetes The Hard Way lab VMs.

.DESCRIPTION
    Multipass on Windows attaches every instance to the Hyper-V "Default Switch",
    whose subnet Windows re-randomises on each host reboot. This lab writes node IP
    addresses into certificate SANs and kubeconfig files, so a shifting subnet would
    invalidate the cluster part-way through.

    This script creates a dedicated Hyper-V *internal* switch. The deploy script gives
    every VM a second NIC on it with a static address, so node-to-node addressing stays
    put for the life of the lab. Internet access still flows over the Default Switch NIC,
    so no NAT is configured here (and none is wanted - Windows permits only one NetNat,
    and WSL already uses it).

    Safe to re-run; every step is idempotent.

.PARAMETER SwitchName
    Name of the Hyper-V switch to create. Must match SWITCH in deploy-virtual-machines.sh.

.PARAMETER HostIp
    Address given to the Windows side of the switch. Must be in the lab subnet and must
    not collide with a node address (.11, .12, .21, .22, .30).

.EXAMPLE
    Run from an *elevated* PowerShell prompt:
        .\create-lab-network.ps1
#>
[CmdletBinding()]
param(
    [string]$SwitchName = 'kthw-lab',
    [string]$HostIp     = '192.168.56.1',
    [int]$PrefixLength  = 24
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Error "This script must be run from an elevated PowerShell prompt (Run as Administrator)."
}

if ((Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All).State -ne 'Enabled') {
    Write-Error "Hyper-V is not enabled. Enable it, reboot, and re-run this script."
}

# --- the switch -----------------------------------------------------------------
if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) {
    Write-Host "Switch '$SwitchName' already exists." -ForegroundColor Yellow
} else {
    # Hyper-V occasionally refuses a switch name that a previous (even long removed)
    # adapter still holds in the registry, failing with 0x800700B7
    # "Cannot create a file when that file already exists". If that happens, pass a
    # different -SwitchName and set SWITCH to match in deploy-virtual-machines.sh.
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    Write-Host "Created internal switch '$SwitchName'." -ForegroundColor Green
}

# --- the host side of the switch ------------------------------------------------
$adapterName = "vEthernet ($SwitchName)"
$adapter = Get-NetAdapter -Name $adapterName

$existing = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $HostIp }

if ($existing) {
    Write-Host "Host address $HostIp already assigned." -ForegroundColor Yellow
} else {
    New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $HostIp -PrefixLength $PrefixLength | Out-Null
    Write-Host "Assigned $HostIp/$PrefixLength to '$adapterName'." -ForegroundColor Green
}

# An internal switch has no gateway, so Windows files it under the Public profile and
# blocks inbound traffic. Move it to Private so you can reach NodePorts from Windows.
Set-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -NetworkCategory Private -ErrorAction SilentlyContinue

$subnet = ($HostIp -split '\.')[0..2] -join '.'
$ruleName = "Kubernetes The Hard Way lab ($SwitchName)"
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName `
                        -Direction Inbound -Action Allow `
                        -RemoteAddress "$subnet.0/$PrefixLength" | Out-Null
    Write-Host "Added firewall rule allowing inbound traffic from $subnet.0/$PrefixLength." -ForegroundColor Green
} else {
    Write-Host "Firewall rule already present." -ForegroundColor Yellow
}

Write-Host ""
Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 |
    Select-Object IPAddress, PrefixLength, InterfaceAlias | Format-Table -AutoSize

Write-Host "Lab network ready. Next, from WSL:  ./deploy-virtual-machines.sh" -ForegroundColor Green

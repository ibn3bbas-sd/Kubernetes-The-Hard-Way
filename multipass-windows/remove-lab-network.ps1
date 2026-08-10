<#
.SYNOPSIS
    Removes the private lab network created by create-lab-network.ps1.

.DESCRIPTION
    Run this only after delete-virtual-machines.sh has removed the VMs. Removing the
    switch while instances are still attached to it leaves them unable to start.

.EXAMPLE
    Run from an *elevated* PowerShell prompt:
        .\remove-lab-network.ps1
#>
[CmdletBinding()]
param(
    [string]$SwitchName = 'kthw-lab'
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run from an elevated PowerShell prompt (Run as Administrator)."
}

$ruleName = "Kubernetes The Hard Way lab ($SwitchName)"
if (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue) {
    Remove-NetFirewallRule -DisplayName $ruleName
    Write-Host "Removed firewall rule." -ForegroundColor Green
}

if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) {
    Remove-VMSwitch -Name $SwitchName -Force
    Write-Host "Removed switch '$SwitchName'." -ForegroundColor Green
} else {
    Write-Host "Switch '$SwitchName' not present." -ForegroundColor Yellow
}

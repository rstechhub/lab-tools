# Gives an ESXi host a VMkernel adapter on the storage VLAN, mounts an NFS 4.1 datastore
# over it, and proves the path with a jumbo-frame vmkping.
# Without a storage vmk, NFS goes out of the management vmk to the default gateway and is
# routed between VLANs, often on a switch CPU, and loses jumbo frames on the way.
# Written up at https://rstechhub.com/truenas-scale-dell-r620-part-5-storage-vlan-dac-certificate/
#   Connect-VIServer vcenter.example.internal
#   .\Add-NfsDatastore.ps1 -VMHost esx01.example.internal -VSwitch vSwitch0 -VlanId 48 `
#       -VmkIP 192.168.48.10 -NfsServer 192.168.48.100 -NfsPath /mnt/tank/vmware -DatastoreName nfs-vmware
#Requires -Modules VMware.VimAutomation.Core
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$VMHost,
    [string]$VSwitch = 'vSwitch0',
    [string]$PortGroup = 'Storage-NFS',
    [Parameter(Mandatory)][int]$VlanId,
    [Parameter(Mandatory)][string]$VmkIP,
    [string]$SubnetMask = '255.255.255.0',
    [int]$Mtu = 9000,
    [Parameter(Mandatory)][string]$NfsServer,
    [Parameter(Mandatory)][string]$NfsPath,
    [Parameter(Mandatory)][string]$DatastoreName
)

$h  = Get-VMHost -Name $VMHost -ErrorAction Stop
$vs = Get-VirtualSwitch -VMHost $h -Name $VSwitch -Standard -ErrorAction Stop
if ($vs.Mtu -lt $Mtu) { Write-Warning "$VSwitch MTU is $($vs.Mtu). Raise it to $Mtu first (and on the physical switch ports)." }

$vmk = Get-VMHostNetworkAdapter -VMHost $h -VMKernel | Where-Object PortGroupName -eq $PortGroup
if (-not $vmk -and $PSCmdlet.ShouldProcess("$VMHost $PortGroup VLAN $VlanId $VmkIP", 'Add VMkernel adapter')) {
    $pg = Get-VirtualPortGroup -VMHost $h -Name $PortGroup -ErrorAction SilentlyContinue
    if (-not $pg) { $pg = New-VirtualPortGroup -VirtualSwitch $vs -Name $PortGroup -VLanId $VlanId }
    $vmk = New-VMHostNetworkAdapter -VMHost $h -VirtualSwitch $vs -PortGroup $PortGroup -IP $VmkIP -SubnetMask $SubnetMask -Mtu $Mtu
    Write-Host "Added $($vmk.Name) $VmkIP on $PortGroup (VLAN $VlanId)"
}

if ($vmk -and -not $WhatIfPreference) {
    $esxcli = Get-EsxCli -VMHost $h -V2
    $ping = $esxcli.network.diag.ping.Invoke(@{ host = $NfsServer; interface = $vmk.Name; size = $Mtu - 28; df = $true; count = 3 })
    if ($ping.Summary.Recieved -gt 0) { Write-Host "Jumbo ping to $NfsServer via $($vmk.Name): OK" }
    else { Write-Warning "Jumbo ping to $NfsServer via $($vmk.Name) failed. Check VLAN tagging and MTU end to end." }
}

if (Get-Datastore -VMHost $h -Name $DatastoreName -ErrorAction SilentlyContinue) {
    Write-Host "Datastore $DatastoreName already mounted"
} elseif ($PSCmdlet.ShouldProcess("$($NfsServer):$NfsPath as $DatastoreName", 'Mount NFS 4.1')) {
    New-Datastore -VMHost $h -Nfs -FileSystemVersion '4.1' -NfsHost $NfsServer -Path $NfsPath -Name $DatastoreName | Out-Null
    Write-Host "Mounted $DatastoreName"
}

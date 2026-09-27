# Bulk-creates DNS A + PTR records from a CSV. Creates missing forward zones and /24 reverse
# zones (AD-integrated), and never overwrites: a name or IP that already exists is skipped.
# Handy for pre-creating every VCF component record before running the VCF Installer.
#   CSV columns: Zone,Name,IP   (see records-example.csv)
#   Dry run: .\Import-DnsRecords.ps1 -Path .\records.csv -WhatIf
#   Apply:   .\Import-DnsRecords.ps1 -Path .\records.csv
# Run on a DNS server / DC as a domain admin.
#Requires -Modules DnsServer
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][string]$Path)

$rows = Import-Csv $Path
foreach ($z in ($rows.Zone | Sort-Object -Unique)) {
    if (-not (Get-DnsServerZone -Name $z -ErrorAction SilentlyContinue) -and $PSCmdlet.ShouldProcess($z,'Create zone')) {
        Add-DnsServerPrimaryZone -Name $z -ReplicationScope Forest; Write-Host "Created zone $z"
    }
}
foreach ($net in ($rows | ForEach-Object { ($_.IP -split '\.')[0..2] -join '.' } | Sort-Object -Unique)) {
    $o = $net -split '\.'; $rz = "$($o[2]).$($o[1]).$($o[0]).in-addr.arpa"
    if (-not (Get-DnsServerZone -Name $rz -ErrorAction SilentlyContinue) -and $PSCmdlet.ShouldProcess($rz,'Create reverse zone')) {
        Add-DnsServerPrimaryZone -NetworkId "$net.0/24" -ReplicationScope Forest; Write-Host "Created zone $rz"
    }
}
foreach ($r in $rows) {
    $fqdn = "$($r.Name).$($r.Zone)"
    if (Get-DnsServerResourceRecord -ZoneName $r.Zone -Name $r.Name -RRType A -ErrorAction SilentlyContinue) {
        Write-Warning "SKIP  $fqdn exists"; continue }
    $o = $r.IP -split '\.'; $rz = "$($o[2]).$($o[1]).$($o[0]).in-addr.arpa"
    if (Get-DnsServerResourceRecord -ZoneName $rz -Name $o[3] -RRType Ptr -ErrorAction SilentlyContinue) {
        Write-Warning "SKIP  $($r.IP) already has a PTR"; continue }
    if ($PSCmdlet.ShouldProcess("$fqdn -> $($r.IP)",'Add A + PTR')) {
        Add-DnsServerResourceRecordA -ZoneName $r.Zone -Name $r.Name -IPv4Address $r.IP -CreatePtr
        Write-Host "ADDED $fqdn -> $($r.IP)"
    }
}

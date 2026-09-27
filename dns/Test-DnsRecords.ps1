# Read-only DNS health check: duplicate IPs, A records with no matching PTR, and PTR records
# with no matching A (stale). The VCF Installer rejects any component whose forward and
# reverse records disagree, so run this before a deployment.
#   .\Test-DnsRecords.ps1 -Zones example.internal, vcf.example.internal
# Run on a DNS server / DC. Zones you do not list are ignored, so a PTR whose A record lives
# in an unlisted zone will show as stale.
#Requires -Modules DnsServer
param([Parameter(Mandatory)][string[]]$Zones)

$skip = '@','DomainDnsZones','ForestDnsZones'
$fwd = foreach ($z in $Zones) {
    Get-DnsServerResourceRecord -ZoneName $z -RRType A -ErrorAction SilentlyContinue |
      Where-Object { $_.HostName -notin $skip } |
      ForEach-Object { [pscustomobject]@{ FQDN = "$($_.HostName).$z".ToLower(); IP = $_.RecordData.IPv4Address.ToString() } } }
$revZones = Get-DnsServerZone | Where-Object { $_.IsReverseLookupZone -and $_.ZoneName -notmatch '^(0|127|255)\.' }
$rev = foreach ($rz in $revZones) {
    Get-DnsServerResourceRecord -ZoneName $rz.ZoneName -RRType Ptr | ForEach-Object {
        $o = $rz.ZoneName -replace '\.in-addr\.arpa$','' -split '\.'; [array]::Reverse($o)
        $h = $_.HostName -split '\.'; [array]::Reverse($h)
        [pscustomobject]@{ IP = (($o + $h) -join '.'); FQDN = $_.RecordData.PtrDomainName.TrimEnd('.').ToLower() } } }
# Note: variables are $fwd/$rev, not $A/$P: PowerShell names are case-insensitive, and a
# loop variable like $a would silently overwrite $A.
$revKeys = $rev | ForEach-Object { "$($_.IP)|$($_.FQDN)" }
$fwdKeys = $fwd | ForEach-Object { "$($_.IP)|$($_.FQDN)" }

'== Duplicate IPs =='
$fwd | Group-Object IP | Where-Object Count -gt 1 | ForEach-Object { "$($_.Name): $($_.Group.FQDN -join ', ')" }
'== A with no PTR =='
$fwd | Where-Object { "$($_.IP)|$($_.FQDN)" -notin $revKeys } | ForEach-Object { "$($_.IP)  $($_.FQDN)" }
'== PTR with no A (stale, or A in an unlisted zone) =='
$rev | Where-Object { "$($_.IP)|$($_.FQDN)" -notin $fwdKeys } | ForEach-Object { "$($_.IP)  $($_.FQDN)" }
'== Counts =='
"A: $($fwd.Count)  PTR: $($rev.Count)"

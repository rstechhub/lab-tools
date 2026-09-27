# Publishes a KMS host in DNS so Windows clients activate on their own.
# KMS clients look up the SRV record _vlmcs._tcp.<domain> and activate against the host it
# names. Without it, a freshly deployed server shows License Status: Notification and
# error 0xC004F056. Creates an A + PTR for the KMS host (if missing) and the SRV record.
# Written up at https://rstechhub.com/core-infrastructure-part-7-windows-server-template/
#   .\Set-KmsDnsRecord.ps1 -Zone example.internal -HostName kms01 -IPAddress 192.168.10.250 -WhatIf
# Run on a DNS server / DC as a domain admin.
#Requires -Modules DnsServer
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Zone,
    [Parameter(Mandatory)][string]$HostName,
    [Parameter(Mandatory)][ipaddress]$IPAddress,
    [int]$Port = 1688
)

$fqdn = "$HostName.$Zone"

if (-not (Test-NetConnection $IPAddress.ToString() -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    Write-Warning "Nothing answers on $($IPAddress):$Port. Is the KMS host running and the firewall open?"
}

if (Get-DnsServerResourceRecord -ZoneName $Zone -Name $HostName -RRType A -ErrorAction SilentlyContinue) {
    Write-Host "A record $fqdn exists"
} elseif ($PSCmdlet.ShouldProcess("$fqdn -> $IPAddress", 'Add A + PTR')) {
    Add-DnsServerResourceRecordA -ZoneName $Zone -Name $HostName -IPv4Address $IPAddress -CreatePtr -ErrorAction Continue
    Write-Host "Added $fqdn -> $IPAddress"
}

if (Get-DnsServerResourceRecord -ZoneName $Zone -Name '_vlmcs._tcp' -RRType Srv -ErrorAction SilentlyContinue) {
    Write-Host "SRV _vlmcs._tcp.$Zone exists"
} elseif ($PSCmdlet.ShouldProcess("_vlmcs._tcp.$Zone -> $($fqdn):$Port", 'Add SRV')) {
    Add-DnsServerResourceRecord -ZoneName $Zone -Srv -Name '_vlmcs._tcp' -DomainName $fqdn -Priority 0 -Weight 0 -Port $Port
    Write-Host "Added SRV _vlmcs._tcp.$Zone -> $($fqdn):$Port"
}

if (-not $WhatIfPreference) {
    Resolve-DnsName -Type SRV "_vlmcs._tcp.$Zone" -DnsOnly | Where-Object Type -eq 'SRV' |
        Select-Object Name, NameTarget, Port
    Write-Host 'On a client: slmgr /ato, then slmgr /dli should show License Status: Licensed.'
}

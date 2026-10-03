<#
.SYNOPSIS
    Read-only checks on freshly installed ESX hosts: network ports from the iDRAC, then the ESX settings over SSH.

.DESCRIPTION
    For each host:
      1. lists the server's network ports from its iDRAC (Redfish): Id, MAC, link state, speed
      2. logs in to ESX over SSH as root and shows version, platform, vmk0 address,
         management port group and VLAN, DNS search domain, NTP, IPv6 state and the
         certificate subject and SAN

    Changes nothing. Asks for the iDRAC login once. SSH uses the key Install-EsxKickstart.ps1 adds to the
    host (~/.ssh/esx_kickstart_ecdsa), otherwise it asks for the ESX root password per host. Domain comes from esx-settings.json.

.EXAMPLE
    .\Test-EsxHost.ps1 -Name esx01
    .\Test-EsxHost.ps1 -Name esx01,esx02

.NOTES
    PowerShell 7. MIT licence. https://rstechhub.com
#>
[CmdletBinding()]
param(
    [string[]]$Name        = @('esx01'),
    [string]  $Settings    = (Join-Path $PSScriptRoot 'esx-settings.json'),
    [string]  $Domain,
    [string]  $IdracSuffix = '-idrac.example.internal',
    [switch]  $SkipPorts,
    [switch]  $SkipEsx
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Run this in PowerShell 7 (pwsh).' }

if (-not $Domain) {
    if (-not (Test-Path $Settings)) { throw "Give -Domain or put esx-settings.json next to the script" }
    $Domain = (Get-Content $Settings -Raw | ConvertFrom-Json).Domain
}
if (-not $SkipPorts) { $cred = Get-Credential -UserName root -Message 'iDRAC login' }

$esxChecks = @(
    'echo "--- version";        esxcli system version get'
    'echo "--- platform";       esxcli hardware platform get | grep -E "Product Name|Vendor Name"'
    'echo "--- vmk0";           esxcli network ip interface ipv4 get'
    'echo "--- port groups";    esxcli network vswitch standard portgroup list'
    'echo "--- DNS search";     esxcli network ip dns search list'
    'echo "--- NTP";            esxcli system ntp get | grep -E "Enabled|Servers|Synchronized"'
    'echo "--- IPv6";           esxcli network ip get'
    'echo "--- certificate";    openssl x509 -in /etc/vmware/ssl/rui.crt -noout -subject -ext subjectAltName'
) -join '; '

foreach ($h in $Name) {
    $fqdn = "$h.$Domain"

    if (-not $SkipPorts) {
        Write-Host "`n=== $h : network ports (iDRAC $h$IdracSuffix)" -ForegroundColor Cyan
        $base = "https://$h$IdracSuffix"
        $rf = @{ Credential = $cred; Authentication = 'Basic'; SkipCertificateCheck = $true }
        try {
            (Invoke-RestMethod "$base/redfish/v1/Systems/System.Embedded.1/EthernetInterfaces" @rf).Members |
                ForEach-Object { Invoke-RestMethod "$base$($_.'@odata.id')" @rf } |
                Sort-Object Id | Format-Table Id, MACAddress, LinkStatus, SpeedMbps -AutoSize | Out-Host
        } catch { Write-Warning "$h : iDRAC query failed - $($_.Exception.Message)" }
    }

    if (-not $SkipEsx) {
        Write-Host "=== $h : ESX settings (ssh root@$fqdn)" -ForegroundColor Cyan
        $key = Join-Path $HOME '.ssh/esx_kickstart_ecdsa'
        if (Test-Path $key) { ssh -i $key "root@$fqdn" $esxChecks } else { ssh "root@$fqdn" $esxChecks }
    }
}

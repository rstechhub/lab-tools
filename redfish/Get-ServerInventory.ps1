<#
.SYNOPSIS
    Firmware and physical-disk inventory from Dell iDRAC 9 / iDRAC 7 and HPE iLO 4, side by side.

.DESCRIPTION
    Reads every server's management controller over Redfish and builds two reports:
      - Firmware matrix: one row per component, one column per server, MISMATCH flagged
      - Physical disks: every drive with slot, model, type, size, firmware and health
    Both are shown on screen and saved as CSV.

    Read-only: it changes nothing on the servers. Safe to run at any time, although a controller
    that is in the middle of a firmware update will not answer (it is skipped with a warning).

.PARAMETER Idrac
    Dell iDRAC names or IPs (iDRAC 9 fully supported; iDRAC 7/8 report firmware, disks where available).

.PARAMETER Ilo
    HPE iLO 4 names or IPs.

.PARAMETER Credential / IloCredential
    Logins for the iDRACs (one shared account) and the iLOs. Prompted if not supplied.

.PARAMETER OutDir
    Folder for the CSV reports. Default: .\Reports

.EXAMPLE
    .\Get-ServerInventory.ps1 -Idrac idrac1.example.com, idrac2.example.com

.EXAMPLE
    .\Get-ServerInventory.ps1 -Idrac 192.0.2.11, 192.0.2.12 -Ilo ilo1.example.com -OutDir C:\Reports

.NOTES
    Requires Windows PowerShell 5.1 or PowerShell 7. The controllers' own certificates are not
    validated (many still use self-signed ones); run it from a trusted management network.
    Test in a lab first. MIT licence - see LICENSE.
    https://rstechhub.com
#>
param(
    [string[]]$Idrac = @(),
    [string[]]$Ilo   = @(),
    [pscredential]$Credential,
    [pscredential]$IloCredential,
    [string]$OutDir  = '.\Reports'
)
$ErrorActionPreference = 'Stop'
if (-not $Idrac -and -not $Ilo) { throw 'Specify at least one server with -Idrac and/or -Ilo.' }

# Accept the controllers' certificates for this session only (self-signed is common)
if ($PSVersionTable.PSVersion.Major -lt 6) {
    if (-not ('TrustAllCerts' -as [type])) {
Add-Type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
  public bool CheckValidationResult(ServicePoint sp, X509Certificate c, WebRequest r, int p) { return true; } }
"@ }
    [Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
    [Net.ServicePointManager]::SecurityProtocol  = [Net.SecurityProtocolType]::Tls12
    $rf = @{}
} else { $rf = @{ SkipCertificateCheck = $true } }

# Windows PowerShell only sends credentials after a challenge, which Redfish often never issues:
# send Basic auth up front instead.
function New-Hdr($cred) {
    $pair = "{0}:{1}" -f $cred.UserName, $cred.GetNetworkCredential().Password
    @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair)) }
}
$dellHdr = if ($Idrac) { New-Hdr $(if ($Credential)    { $Credential }    else { Get-Credential -Message 'iDRAC login (same on all)' }) }
$hpeHdr  = if ($Ilo)   { New-Hdr $(if ($IloCredential) { $IloCredential } else { Get-Credential -Message 'iLO login' }) }
function Get-RF($uri, $hdr) { Invoke-RestMethod -Uri $uri -Headers $hdr -Method Get @rf }

$servers = @($Idrac) + @($Ilo)
$fw = @{}; $disks = @()
function Add-Fw($server, $name, $ver) {
    $name = ($name -replace '\s+in Slot.*$','' -replace '\s+\d+$','').Trim()
    if (-not $name -or -not $ver) { return }
    if (-not $fw[$name]) { $fw[$name] = @{} }
    $fw[$name][$server] = (@($fw[$name][$server]) + $ver | Where-Object { $_ } | Sort-Object -Unique) -join ' / '
}

foreach ($s in $servers) {
    Write-Host "Reading $s ..." -ForegroundColor Cyan
    $base = "https://$s"
    try {
        if ($Ilo -contains $s) {
            # ---------- HPE iLO 4 ----------
            $h = $hpeHdr
            $inv = Get-RF "$base/redfish/v1/Systems/1/FirmwareInventory/" $h
            foreach ($grp in $inv.Current.PSObject.Properties) { foreach ($item in @($grp.Value)) { Add-Fw $s $item.Name $item.VersionString } }
            $acs = Get-RF "$base/redfish/v1/Systems/1/SmartStorage/ArrayControllers/" $h
            foreach ($m in $acs.Members) {
                $dd = Get-RF "$base$($m.'@odata.id')DiskDrives/" $h
                foreach ($dm in $dd.Members) {
                    $dr = Get-RF "$base$($dm.'@odata.id')" $h
                    $disks += [pscustomobject]@{ Server=$s; Slot=$dr.Location; Model=$dr.Model; Type="$($dr.MediaType) $($dr.InterfaceType)"
                        SizeGB=[math]::Round($dr.CapacityMiB * 1MB / 1GB); Firmware=$dr.FirmwareVersion.Current.VersionString; Health=$dr.Status.Health }
                }
            }
        } else {
            # ---------- Dell iDRAC 9 / 7 ----------
            $h = $dellHdr
            $inv = Get-RF "$base/redfish/v1/UpdateService/FirmwareInventory" $h
            foreach ($m in $inv.Members) {
                if ($m.'@odata.id' -notmatch '/Installed-') { continue }
                $c = Get-RF "$base$($m.'@odata.id')" $h
                Add-Fw $s $c.Name $c.Version
            }
            $got = $false
            try {
                $sto = Get-RF "$base/redfish/v1/Systems/System.Embedded.1/Storage" $h
                foreach ($ctl in $sto.Members) {
                    $cinfo = Get-RF "$base$($ctl.'@odata.id')" $h
                    foreach ($d in @($cinfo.Drives)) {
                        $dr = Get-RF "$base$($d.'@odata.id')" $h; $got = $true
                        $disks += [pscustomobject]@{ Server=$s; Slot=$dr.Name; Model=$dr.Model; Type="$($dr.MediaType) $($dr.Protocol)"
                            SizeGB=[math]::Round($dr.CapacityBytes / 1GB); Firmware=$dr.Revision; Health=$dr.Status.Health }
                    }
                }
            } catch { }
            foreach ($legacy in '/redfish/v1/Systems/System.Embedded.1/Storage/Controllers', '/redfish/v1/Systems/System.Embedded.1/SimpleStorage/Controllers', '/redfish/v1/Systems/System.Embedded.1/SimpleStorage') {
                if ($got) { break }
                try {
                    $ctls = Get-RF "$base$legacy" $h
                    foreach ($cm in $ctls.Members) {
                        $cinfo = Get-RF "$base$($cm.'@odata.id')" $h
                        foreach ($dv in @($cinfo.Devices)) {
                            $got = $true
                            $disks += [pscustomobject]@{ Server=$s; Slot=$dv.Name; Model=$dv.Model; Type=$dv.Manufacturer
                                SizeGB=$(if ($dv.CapacityBytes) { [math]::Round($dv.CapacityBytes / 1GB) }); Firmware=$dv.Revision; Health=$dv.Status.Health }
                        }
                    }
                } catch { }
            }
            if (-not $got) { Write-Warning "$s : firmware read OK, but this iDRAC does not publish its disks over Redfish" }
        }
    } catch { Write-Warning "$s failed: $($_.Exception.Message)" }
}

$matrix = foreach ($name in ($fw.Keys | Sort-Object)) {
    $row = [ordered]@{ Component = $name }
    foreach ($s in $servers) { $row[$s] = $fw[$name][$s] }
    $vals = @($servers | ForEach-Object { $fw[$name][$_] } | Where-Object { $_ } | Sort-Object -Unique)
    $row['Check'] = if ($vals.Count -gt 1) { 'MISMATCH' } else { '' }
    [pscustomobject]$row
}

New-Item $OutDir -ItemType Directory -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$matrix | Export-Csv (Join-Path $OutDir "firmware-$stamp.csv") -NoTypeInformation
$disks  | Export-Csv (Join-Path $OutDir "disks-$stamp.csv")    -NoTypeInformation
Write-Host "`nFIRMWARE" -ForegroundColor Yellow
$matrix | Format-Table -AutoSize -Wrap
Write-Host "PHYSICAL DISKS" -ForegroundColor Yellow
$disks | Sort-Object Server, Slot | Format-Table -AutoSize
Write-Host "Saved: $(Join-Path $OutDir "firmware-$stamp.csv") and $(Join-Path $OutDir "disks-$stamp.csv")"

<#
.SYNOPSIS
    Issues a Dell iDRAC 9 web certificate from an internal Microsoft (AD CS) certificate authority, over Redfish.

.DESCRIPTION
    Avoids the iDRAC web upload, which can reject perfectly good certificates (RAC0622 / RAC0613 /
    SYS426 / RAC0615 on some firmware). Steps:
      0. (optional) Sets the iDRAC's DNS name, domain and DNS servers, so browsing by name works
         (iDRAC 9 returns "400 Bad Request" for names it does not know as its own)
      1. The iDRAC generates the key and CSR itself - the private key never leaves the iDRAC
      2. certreq submits the CSR to your CA using the given template
      3. The signed certificate is imported as PEM text (LF line endings)
      4. The iDRAC restarts to load it (the server itself is not affected). Allow up to 10 minutes.

.PARAMETER Name
    iDRAC short name, e.g. idrac-host01. Used for the certificate CN and SAN together with -Domain.

.PARAMETER IP
    iDRAC address used to reach it.

.PARAMETER Domain
    DNS domain, e.g. example.com. The certificate is issued for <Name>.<Domain>.

.PARAMETER CA
    CA config string: "<ca-server-fqdn>\<CA Name>". Run: certutil -config - -ping   to find it.

.PARAMETER Template
    Certificate template. Default: WebServer.

.PARAMETER SetDnsName
    Also set the iDRAC's DNS name and domain (step 0).

.PARAMETER DnsServers
    With -SetDnsName: up to two DNS servers to configure on the iDRAC.

.PARAMETER Organization / OrganizationalUnit / City / State / Country / Email
    Certificate subject fields.

.EXAMPLE
    .\Set-IdracCertificate.ps1 -Name idrac-host01 -IP 192.0.2.11 -Domain example.com -CA "ca01.example.com\Example-Root-CA"

.EXAMPLE
    $cred = Get-Credential root
    foreach ($i in @(@{N='idrac-host01';IP='192.0.2.11'}, @{N='idrac-host02';IP='192.0.2.12'})) {
        .\Set-IdracCertificate.ps1 -Name $i.N -IP $i.IP -Domain example.com -CA "ca01.example.com\Example-Root-CA" -Credential $cred -SetDnsName -DnsServers 192.0.2.53
    }

.NOTES
    Run on a domain-joined Windows machine that can reach the iDRACs and submit to the CA (certreq).
    Requires Windows PowerShell 5.1 or PowerShell 7. Tested on iDRAC 9 firmware 7.00.00.x.
    iDRAC 7/8 do not expose these Redfish actions - use the web UI or racadm there.
    Test in a lab first. MIT licence - see LICENSE.
    https://rstechhub.com
#>
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$IP,
    [Parameter(Mandatory)][string]$Domain,
    [Parameter(Mandatory)][string]$CA,
    [string]$Template = 'WebServer',
    [pscredential]$Credential,
    [switch]$SetDnsName,
    [string[]]$DnsServers = @(),
    [string]$Organization = 'Lab',
    [string]$OrganizationalUnit = 'OOB',
    [string]$City = 'City',
    [string]$State = 'State',
    [string]$Country = 'GB',
    [string]$Email = '',
    [string]$WorkDir = '.\Certs'
)
$ErrorActionPreference = 'Stop'

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

$cred = if ($Credential) { $Credential } else { Get-Credential -Message "iDRAC login for $Name" }
# Windows PowerShell only sends credentials after a challenge; the iDRAC never challenges a POST.
$pair = "{0}:{1}" -f $cred.UserName, $cred.GetNetworkCredential().Password
$hdr  = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair)) }
$base = "https://$IP/redfish/v1"
$fqdn = "$Name.$Domain"
New-Item $WorkDir -ItemType Directory -Force | Out-Null
$csrFile = Join-Path $WorkDir "$Name.csr"; $cerFile = Join-Path $WorkDir "$Name.cer"
Remove-Item $csrFile, $cerFile, (Join-Path $WorkDir "$Name.rsp") -ErrorAction SilentlyContinue

# 0. Optional: the iDRAC's own DNS name, domain and DNS servers
if ($SetDnsName) {
    $attrs = @{ 'NIC.1.DNSRacName' = $Name; 'NIC.1.DNSDomainNameFromDHCP' = 'Disabled'; 'NIC.1.DNSDomainName' = $Domain }
    if ($DnsServers.Count -ge 1) { $attrs['IPv4Static.1.DNS1'] = $DnsServers[0] }
    if ($DnsServers.Count -ge 2) { $attrs['IPv4Static.1.DNS2'] = $DnsServers[1] }
    Invoke-RestMethod -Method Patch -Uri "$base/Managers/iDRAC.Embedded.1/Attributes" -Headers $hdr `
        -Body (@{ Attributes = $attrs } | ConvertTo-Json -Depth 3) -ContentType 'application/json' @rf | Out-Null
    Write-Host "Name    $fqdn"
    Start-Sleep 10
}

# 1. CSR generated on the iDRAC
$csrBody = @{
    CertificateCollection = @{ '@odata.id' = '/redfish/v1/Managers/iDRAC.Embedded.1/NetworkProtocol/HTTPS/Certificates' }
    CommonName = $fqdn; AlternativeNames = @($fqdn)
    Organization = $Organization; OrganizationalUnit = $OrganizationalUnit
    City = $City; State = $State; Country = $Country
}
if ($Email) { $csrBody.Email = $Email }
$csr = Invoke-RestMethod -Method Post -Uri "$base/CertificateService/Actions/CertificateService.GenerateCSR" `
        -Headers $hdr -Body ($csrBody | ConvertTo-Json -Depth 4) -ContentType 'application/json' @rf
Set-Content -Path $csrFile -Value $csr.CSRString -Encoding ascii
Write-Host "CSR     $csrFile"

# 2. Sign on the CA
certreq -submit -config $CA -attrib "CertificateTemplate:$Template" $csrFile $cerFile | Out-Host
if (-not (Test-Path $cerFile)) { throw "The CA did not issue a certificate (check the template and your enrolment rights)." }

# 3. Import as PEM text with LF line endings
$pem = (Get-Content $cerFile -Raw) -replace "`r", ""
Invoke-RestMethod -Method Post `
    -Uri "$base/Managers/iDRAC.Embedded.1/Oem/Dell/DelliDRACCardService/Actions/DelliDRACCardService.ImportSSLCertificate" `
    -Headers $hdr -Body (@{ CertificateType = 'Server'; SSLCertificateFile = $pem } | ConvertTo-Json) -ContentType 'application/json' @rf | Out-Null
Write-Host "Imported certificate for $fqdn"

# 4. Restart the iDRAC so its web server loads the certificate
Invoke-RestMethod -Method Post `
    -Uri "$base/Managers/iDRAC.Embedded.1/Oem/Dell/DelliDRACCardService/Actions/DelliDRACCardService.iDRACReset" `
    -Headers $hdr -Body (@{ Force = 'Graceful' } | ConvertTo-Json) -ContentType 'application/json' @rf | Out-Null
Write-Host "iDRAC restarting. Open https://$fqdn in 2-10 minutes."

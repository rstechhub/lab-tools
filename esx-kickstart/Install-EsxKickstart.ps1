<#
.SYNOPSIS
    Fully automated ESX install on physical Dell servers: kickstart ISO per host, mounted and booted over
    Redfish, with pre-flight checks, a VCF readiness check after the install and an HTML report.

.DESCRIPTION
    Run from the management PC. For every host in the hosts file it:
      1. checks DNS (A and PTR), the stock ISO's SHA-256 and, over Redfish, UEFI boot mode, power state,
         link on the management port and iDRAC virtual media (pre-flight)
      2. shows what the host runs now and asks whether to reinstall it (root passwords per host can come
         from Vaultwarden). A reinstall WIPES ALL DISKS in
         that server, so the host name has to be typed back. Then asks which disk ESX goes on.
      3. builds a kickstart ISO per host on a Linux build box (build-ks-isos.sh over SSH) and checks the
         box's nginx serves it with HTTP Range support (iDRAC virtual media needs 206 Partial Content)
      4. mounts the ISO as iDRAC virtual media, sets a one-time boot from it and restarts the server
      5. waits until the host answers on 443 with a certificate issued to its FQDN and SSH is up
      6. logs in with the management PC's SSH key (added to root by the kickstart) and checks the host
         is ready for VCF: build, vmk0 IP, management VLAN, DNS search, NTP servers and sync, IPv6 off,
         certificate SAN, and every disk except the boot disk empty and eligible for vSAN
      7. ejects the media, deletes the ISOs (they contain the root password) and writes an HTML report
         with the results, the checks and iDRAC console screenshots, plus a transcript log

    -DryRun stops after step 3: everything is built and checked, nothing is rebooted.

.PARAMETER HostsCsv
    The hosts file (a CSV; it opens and saves in Excel as "CSV (Comma delimited)").
    EVERY host you want checked or installed must have a row in it: the script never touches a host
    that is not listed. Physical Dell servers with an iDRAC only; nested ESX hosts need another method.
    Columns: name,ip,idrac,nic[,bootdisk]
      nic      = iDRAC FQDD of the management port, e.g. NIC.Integrated.1-1-1 or NIC.Slot.2-1-1
      bootdisk = optional disk model to install ESX on, as the iDRAC reports it. Empty: the script lists
                 the server's disks and asks (with -Force it uses DefaultBootDisk from the settings).

.PARAMETER Settings
    JSON file with the network values (domain, netmask, gateway, DNS, NTP, VLAN), the build box, the ISO
    and its SHA-256, and optional Vaultwarden item names. Default: esx-settings.json next to the script.
    Keep your real one private; esx-settings.example.json shows the layout.

.PARAMETER BuildHost / BuildUser / StockIso
    Override the values in the settings file.

.PARAMETER Force
    Install every host in the file without asking, wiping all of its disks.

.PARAMETER DryRun
    Run the pre-flight checks, build and serve the ISOs, then stop. Nothing is mounted or rebooted.

.PARAMETER NoVault
    Ignore the Vault items in the settings and ask for every password instead.

.PARAMETER NoScreenshots
    Don't capture iDRAC console screenshots for the report.

.PARAMETER ReportFolder
    Where the HTML report, the transcript and the screenshots go. Default: reports next to the script.

.EXAMPLE
    .\Install-EsxKickstart.ps1 -HostsCsv .\hosts.csv
    .\Install-EsxKickstart.ps1 -HostsCsv .\hosts.csv -DryRun

.NOTES
    PowerShell 7. Tested against iDRAC 9 and ESX 9.0.2. Needs ssh/scp (Windows OpenSSH client) and a key
    for the build box. Optional: Bitwarden CLI (bw) for Vaultwarden. MIT licence. https://rstechhub.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HostsCsv,
    [string]$Settings      = (Join-Path $PSScriptRoot 'esx-settings.json'),
    [string]$BuildHost,
    [string]$BuildUser,
    [string]$StockIso,
    [string]$Template      = (Join-Path $PSScriptRoot 'ks-template.cfg'),
    [string]$BuildScript   = (Join-Path $PSScriptRoot 'build-ks-isos.sh'),
    [int]   $TimeoutMinutes = 45,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$NoScreenshots,
    [switch]$NoVault,
    [string]$ReportFolder  = (Join-Path $PSScriptRoot 'reports')
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Run this in PowerShell 7 (pwsh).' }

# --- settings -------------------------------------------------------------------------------
if (-not (Test-Path $Settings)) { throw "Settings file $Settings not found. Copy esx-settings.example.json to esx-settings.json and fill it in." }
$cfg = Get-Content $Settings -Raw | ConvertFrom-Json
foreach ($k in 'Domain','Netmask','Gateway','Dns','Ntp','Vlan','Keyboard','BuildHost','BuildUser','HttpPort','StockIso') {
    if ($null -eq $cfg.$k -or "$($cfg.$k)" -eq '') { throw "$Settings has no value for '$k'" }
}
if (-not $BuildHost) { $BuildHost = $cfg.BuildHost }
if (-not $BuildUser) { $BuildUser = $cfg.BuildUser }
if (-not $StockIso)  { $StockIso  = $cfg.StockIso }
$Domain   = $cfg.Domain
$HttpPort = [int]$cfg.HttpPort
$remote   = "$BuildUser@$BuildHost"
$isoName  = Split-Path $StockIso -Leaf
$isoBuild = if ($isoName -match '\.(\d{7,9})\.x86_64\.iso$') { $Matches[1] } else { $null }
$runStart = Get-Date
$stamp    = '{0:yyyyMMdd-HHmm}' -f $runStart
$runError = $null
$allHosts = @()
$isoCheck = 'not checked'
$sshKey   = Join-Path $HOME '.ssh/esx_kickstart_ecdsa'
$mtu = if ($cfg.Mtu) { [int]$cfg.Mtu } else { 1500 }

New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null
$shotDir = Join-Path $ReportFolder "esx-install-$stamp"
Start-Transcript -Path (Join-Path $ReportFolder "esx-install-$stamp.log") -UseMinimalHeader | Out-Null

# --- helpers --------------------------------------------------------------------------------
function Invoke-Redfish {
    param([string]$Idrac, [string]$Path, [string]$Method = 'Get', $Body, [switch]$NoRetry)
    $cred = if ($script:idracCreds.ContainsKey($Idrac)) { $script:idracCreds[$Idrac] } else { $script:idracCred }
    $p = @{ Uri = "https://$Idrac$Path"; Method = $Method; Credential = $cred; Authentication = 'Basic'
            SkipCertificateCheck = $true; ContentType = 'application/json' }
    if ($Body) { $p.Body = ($Body | ConvertTo-Json -Depth 5) }
    # the iDRAC answers 503 / SYS518 "data sources unavailable" while the server is in POST or the
    # Lifecycle Controller is busy: wait and retry instead of failing the whole run
    for ($try = 1; ; $try++) {
        try { return Invoke-RestMethod @p }
        catch {
            $busy = "$($_.ErrorDetails.Message)$($_.Exception.Message)" -match 'SYS518|ServiceTemporarilyUnavailable|503'
            if ($NoRetry -or -not $busy -or $try -ge 10) { throw }
            Write-Host "$Idrac is busy (server starting or Lifecycle Controller working), retrying in 30 s ($try/10)" -ForegroundColor DarkYellow
            Start-Sleep 30
        }
    }
}

function Get-VirtualCdPath([string]$Idrac) {
    # iDRAC 9 firmware 6.x+ moved virtual media under Systems; older firmware has it under Managers
    foreach ($p in '/redfish/v1/Systems/System.Embedded.1/VirtualMedia/1',
                   '/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD') {
        try { $null = Invoke-Redfish $Idrac $p; return $p } catch { Write-Verbose "$Idrac : no virtual media at $p" }
    }
    return $null
}

function Get-CertSubject([string]$Name) {
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        if (-not $tcp.ConnectAsync($Name, 443).Wait(3000)) { return $null }
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, { $true })
        $ssl.AuthenticateAsClient($Name)
        $subject = ([System.Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate).Subject
        $ssl.Dispose(); $tcp.Dispose(); return $subject
    } catch { return $null }
}

function Get-EsxInfo([string]$Name) {
    # anonymous RetrieveServiceContent on the host's SOAP API returns the ESX version and build
    $body = '<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:vim25="urn:vim25"><soapenv:Body><vim25:RetrieveServiceContent><vim25:_this type="ServiceInstance">ServiceInstance</vim25:_this></vim25:RetrieveServiceContent></soapenv:Body></soapenv:Envelope>'
    try {
        $r = Invoke-WebRequest "https://$Name/sdk" -Method Post -Body $body -ContentType 'text/xml' `
                -Headers @{ SOAPAction = 'urn:vim25/8.0' } -SkipCertificateCheck -TimeoutSec 10
        if ($r.Content -match '<build>(\d+)</build>') {
            $b = $Matches[1]
            $f = if ($r.Content -match '<fullName>([^<]+)</fullName>') { $Matches[1] } else { "ESX build $b" }
            return [pscustomobject]@{ Build = $b; FullName = $f }
        }
    } catch { Write-Verbose "$Name : no ESX SOAP answer" }
    return $null
}

function Get-VaultLogin([string]$Item) {
    # Vaultwarden through the Bitwarden CLI: needs 'bw' on the PATH and an unlocked session (BW_SESSION)
    if ($NoVault -or -not $Item) { return $null }
    if (-not (Get-Command bw -ErrorAction SilentlyContinue)) { Write-Warning "Vault item '$Item' set but the Bitwarden CLI (bw) is not installed - asking instead"; return $null }
    if (-not $env:BW_SESSION) { Write-Warning "Vault item '$Item' set but the vault is locked (run: `$env:BW_SESSION = bw unlock --raw) - asking instead"; return $null }
    try { $i = bw get item $Item 2>$null | ConvertFrom-Json; return $i.login }
    catch { Write-Warning "Could not read '$Item' from the vault - asking instead"; return $null }
}

function Get-RedfishDrives([string]$Idrac) {
    $ctrls = (Invoke-Redfish $Idrac '/redfish/v1/Systems/System.Embedded.1/Storage').Members
    foreach ($c in $ctrls) {
        $ctrl = Invoke-Redfish $Idrac $c.'@odata.id'
        foreach ($d in $ctrl.Drives) {
            $dr = Invoke-Redfish $Idrac $d.'@odata.id'
            [pscustomobject]@{ Model = "$($dr.Model)".Trim(); SizeGB = [math]::Round($dr.CapacityBytes / 1e9)
                               Media = $dr.MediaType; Protocol = $dr.Protocol; Controller = $ctrl.Id }
        }
    }
}

function Select-BootDisk($p) {
    $drives = @(Get-RedfishDrives $p.idrac | Sort-Object Protocol, Model)
    if (-not $drives) { throw "$($p.name): the iDRAC reports no drives" }
    Write-Host "`n$($p.name): disks found by the iDRAC" -ForegroundColor Cyan
    $i = 0
    $drives | ForEach-Object { $i++; [pscustomobject]@{ '#' = $i; Model = $_.Model; 'Size GB' = $_.SizeGB
                                Media = $_.Media; Protocol = $_.Protocol; Controller = $_.Controller } } |
        Format-Table -AutoSize | Out-Host
    do { $n = Read-Host "$($p.name): install ESX on which disk? [1-$($drives.Count)]" }
    until ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $drives.Count)
    $model = $drives[[int]$n - 1].Model
    $same  = @($drives | Where-Object Model -eq $model).Count
    if ($same -gt 1) { Write-Warning "$($p.name): $same disks are model '$model'. ESX installs on the first of them it finds." }
    Write-Host "$($p.name): ESX goes on '$model'." -ForegroundColor Green
    return $model
}

function Save-ConsoleShot($p, [string]$Label) {
    # Dell OEM action: PNG of the server console, base64 in the response
    if ($NoScreenshots) { return }
    try {
        $r = Invoke-Redfish $p.idrac '/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellLCService/Actions/DellLCService.ExportServerScreenShot' `
                Post @{ FileType = 'ServerScreenShot' } -NoRetry
        if (-not $r.ServerScreenShotFile) { return }
        New-Item -ItemType Directory -Path $shotDir -Force | Out-Null
        $bytes = [Convert]::FromBase64String($r.ServerScreenShotFile)
        # iDRAC 9 returns JPEG; keep the right extension and MIME type
        $isJpg = $bytes.Length -gt 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8
        $ext   = if ($isJpg) { 'jpg' } else { 'png' }
        $file  = Join-Path $shotDir ("{0}-{1}.{2}" -f $p.name, ($Label -replace '\W+', '-').ToLower(), $ext)
        [System.IO.File]::WriteAllBytes($file, $bytes)
        $p.shots += [pscustomobject]@{ Label = $Label; File = $file; Base64 = $r.ServerScreenShotFile; Mime = "image/$(if ($isJpg) { 'jpeg' } else { 'png' })"; Time = Get-Date }
    } catch { Write-Verbose "$($p.name): no console screenshot ($Label) - $($_.Exception.Message)" }
}

function Test-EsxReadiness($p) {
    # read-only checks over SSH with the key the kickstart added for root
    $cmd = 'vmware -v; echo @@; esxcli network ip interface ipv4 get -i vmk0; echo @@; esxcli network vswitch standard portgroup list; ' +
           'echo @@; esxcli network ip dns search list; echo @@; esxcli system ntp get; echo @@; esxcli network ip get; ' +
           'echo @@; openssl x509 -in /etc/vmware/ssl/rui.crt -noout -ext subjectAltName; echo @@; vdq -q; ' +
           "echo @@; esxcli network ip interface list | grep -A30 '^vmk0' | grep -m1 'MTU:'; echo @@; " +
           "vmkping -I vmk0 -d -s $($mtu - 28) -c 2 $($cfg.Gateway) >/dev/null 2>&1 && echo JUMBO_OK || echo JUMBO_FAIL"
    $sshOpts = @('-i', $sshKey, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10')
    $checks = $null
    for ($try = 1; $try -le 10; $try++) {
        $out = (ssh @sshOpts "root@$($p.ip)" $cmd 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0 -or -not $out) {
            # the kickstart's first-boot section reboots the host once more: SSH can drop right after the
            # host first answers, so keep trying for a few minutes before calling it a failure
            if ($try -lt 10) { Write-Host "$($p.name): SSH not ready yet (host may still be rebooting), retrying in 30 s ($try/10)"; Start-Sleep 30; continue }
            return @([pscustomobject]@{ Check = 'SSH login with key'; Expected = 'works'; Actual = "failed (is $sshKey.pub in /etc/ssh/keys-root/authorized_keys?)"; Pass = $false })
        }
        $s = $out -split '@@'
        $ntpSync = $s[4] -match 'Synchronized:\s*true'
        $vlan = if ($s[2] -match 'Management Network\s+\S+\s+\d+\s+(\d+)') { $Matches[1] } else { '?' }
        $vmk  = if ($s[1] -match 'vmk0\s+(\d+\.\d+\.\d+\.\d+)') { $Matches[1] } else { '?' }
        $ntpS = if ($s[4] -match 'Servers:\s*(.+)') { $Matches[1].Trim() } else { '' }
        # vdq -q: one "State" per local disk; the wiped data disks must be eligible, the boot disk is not
        $diskTotal = ([regex]::Matches($s[7], '"State"\s*:')).Count
        $diskOk    = ([regex]::Matches($s[7], '"State"\s*:\s*"Eligible for use by VSAN"')).Count
        $checks = @(
            [pscustomobject]@{ Check = 'ESX build';        Expected = $isoBuild;       Actual = $s[0].Trim();                 Pass = $s[0] -match $isoBuild }
            [pscustomobject]@{ Check = 'vmk0 address';     Expected = $p.ip;           Actual = $vmk;                         Pass = $vmk -eq $p.ip }
            [pscustomobject]@{ Check = 'Management VLAN';  Expected = "$($cfg.Vlan)";  Actual = $vlan;                        Pass = $vlan -eq "$($cfg.Vlan)" }
            [pscustomobject]@{ Check = 'DNS search domain';Expected = $Domain;         Actual = ($s[3] -replace '.*Domains:\s*', '').Trim(); Pass = $s[3] -match [regex]::Escape($Domain) }
            [pscustomobject]@{ Check = 'NTP servers';      Expected = ($cfg.Ntp -join ', '); Actual = $ntpS;                  Pass = -not ($cfg.Ntp | Where-Object { $ntpS -notmatch [regex]::Escape($_) }) }
            [pscustomobject]@{ Check = 'NTP synchronised'; Expected = 'true';          Actual = "$ntpSync".ToLower();         Pass = $ntpSync }
            [pscustomobject]@{ Check = 'IPv6';             Expected = 'disabled';      Actual = $(if ($s[5] -match 'IPv6Enabled:\s*false') { 'disabled' } else { 'enabled' }); Pass = $s[5] -match 'IPv6Enabled:\s*false' }
            [pscustomobject]@{ Check = 'Disks eligible for vSAN'; Expected = "all but the boot disk ($diskTotal disks seen)"; Actual = "$diskOk of $([math]::Max($diskTotal - 1, 0))"; Pass = $diskTotal -gt 1 -and $diskOk -eq $diskTotal - 1 }
            [pscustomobject]@{ Check = 'Certificate SAN';  Expected = "DNS:$($p.fqdn)"; Actual = ($s[6] -replace '(?s).*Alternative Name:\s*', '').Trim(); Pass = $s[6] -match [regex]::Escape("DNS:$($p.fqdn)") }
            [pscustomobject]@{ Check = 'vmk0 MTU';         Expected = "$mtu"; Actual = $(if ($s[8] -match 'MTU:\s*(\d+)') { $Matches[1] } else { '?' }); Pass = $s[8] -match "MTU:\s*$mtu\b" }
            [pscustomobject]@{ Check = "Frames of $mtu to the gateway"; Expected = 'no fragmentation'; Actual = $(if ($s[9] -match 'JUMBO_OK') { 'reply' } else { 'no reply (check switch and gateway MTU)' }); Pass = $s[9] -match 'JUMBO_OK' }
        )
        # NTP needs a few minutes to sync after the last reboot: wait for it, everything else is final
        if ($ntpSync) { break }
        if ($try -lt 10) { Write-Host "$($p.name): waiting for NTP to synchronise ($try/10)"; Start-Sleep 30 }
    }
    return $checks
}

function Write-InstallReport($Rows) {
    $enc = { param($v) [System.Net.WebUtility]::HtmlEncode("$v") }
    $file = Join-Path $ReportFolder "esx-install-$stamp.html"
    $end  = Get-Date
    $ok   = @($Rows | Where-Object result -in 'Installed', 'Dry run OK').Count
    $skip = @($Rows | Where-Object result -in 'Left as it is', 'Not confirmed').Count
    $bad  = @($Rows).Count - $ok - $skip
    $rowsHtml = foreach ($r in $Rows) {
        $cls = switch -Regex ($r.result) { '^(Installed|Dry run OK)$' { 'ok' } '^(Left as it is|Not confirmed)$' { 'skip' } default { 'bad' } }
        $ready = if ($r.checks) { $f = @($r.checks | Where-Object { -not $_.Pass }).Count
                                  if ($f) { "<span class='b bad'>$f check(s) failed</span>" } else { "<span class='b ok'>ready for VCF</span>" } } else { '' }
        "<tr><td><b>$(& $enc $r.name)</b><br><span class='m'>$(& $enc $r.fqdn)</span></td>" +
        "<td>$(& $enc $r.ip)<br><span class='m'>$(& $enc $r.mac)</span></td><td>$(& $enc $r.idrac)</td>" +
        "<td>$(& $enc ($r.preflight -join '; '))</td><td>$(& $enc $r.before)</td>" +
        "<td><span class='b $cls'>$(& $enc $r.result)</span> $ready</td>" +
        "<td>$(& $enc $r.bootdisk)</td><td>$(& $enc $r.wiped)</td><td>$(& $enc $r.minutes)</td><td>$(& $enc $r.after)</td></tr>"
    }
    $details = foreach ($r in $Rows | Where-Object { $_.checks -or $_.shots }) {
        $c = if ($r.checks) {
            "<table class='chk'><tr><th>Check</th><th>Expected</th><th>Found</th><th></th></tr>" + (($r.checks | ForEach-Object {
                "<tr><td>$(& $enc $_.Check)</td><td>$(& $enc $_.Expected)</td><td>$(& $enc $_.Actual)</td><td>$(if ($_.Pass) { '<span class=''b ok''>pass</span>' } else { '<span class=''b bad''>fail</span>' })</td></tr>" }) -join '') + '</table>' } else { '' }
        $s = ($r.shots | ForEach-Object { "<figure><img src='data:$($_.Mime);base64,$($_.Base64)' alt='$(& $enc $_.Label)'><figcaption>$(& $enc $_.Label), $('{0:HH:mm}' -f $_.Time)</figcaption></figure>" }) -join ''
        "<h3>$(& $enc $r.name)</h3>$c<div class='shots'>$s</div>"
    }
    $err = if ($runError) { "<p class='err'>The run stopped with an error: $(& $enc $runError)</p>" } else { '' }
    $mode = @($(if ($Force) { '-Force (no questions, all disks wiped)' } else { 'interactive' }); $(if ($DryRun) { '-DryRun (nothing rebooted)' })) -join ', '
    $html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>ESX install report $('{0:yyyy-MM-dd HH:mm}' -f $runStart)</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1f2937;background:#f8fafc}
h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin-top:22px}h3{font-size:14px;margin:18px 0 6px}.sub{color:#64748b;margin-bottom:18px}
.cards{display:flex;gap:12px;margin:16px 0}.card{background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:12px 18px;min-width:120px}
.card .n{font-size:26px;font-weight:600}.card .l{color:#64748b;font-size:13px}
table{border-collapse:collapse;width:100%;background:#fff;border:1px solid #e2e8f0;font-size:13px}
th{background:#0f172a;color:#fff;text-align:left;padding:8px}td{padding:8px;border-top:1px solid #e2e8f0;vertical-align:top}
table.chk{width:auto;min-width:60%}.m{color:#64748b;font-size:12px}.b{padding:2px 8px;border-radius:10px;font-weight:600;white-space:nowrap}
.ok{background:#dcfce7;color:#166534}.skip{background:#f1f5f9;color:#475569}.bad{background:#fee2e2;color:#991b1b}
dl{display:grid;grid-template-columns:max-content auto;gap:4px 16px;background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:12px 18px}
dt{color:#64748b}.err{background:#fee2e2;color:#991b1b;padding:10px;border-radius:6px}.foot{color:#64748b;font-size:12px;margin-top:16px}
.shots{display:flex;flex-wrap:wrap;gap:12px;margin-top:10px}figure{margin:0;background:#fff;border:1px solid #e2e8f0;padding:6px;border-radius:6px}
figure img{width:420px;display:block}figcaption{font-size:12px;color:#64748b;margin-top:4px}
</style></head><body>
<h1>ESX install report</h1><div class="sub">$('{0:dddd d MMMM yyyy, HH:mm}' -f $runStart) to $('{0:HH:mm}' -f $end) ($([math]::Round(($end - $runStart).TotalMinutes)) min)</div>
$err
<div class="cards"><div class="card"><div class="n">$ok</div><div class="l">$(if ($DryRun) { 'dry run OK' } else { 'installed' })</div></div>
<div class="card"><div class="n">$skip</div><div class="l">left as they were</div></div>
<div class="card"><div class="n">$bad</div><div class="l">failed, timed out or blocked</div></div></div>
<dl><dt>ESX image</dt><dd>$(& $enc $isoName) (build $(& $enc $isoBuild)), SHA-256 $(& $enc $isoCheck)</dd>
<dt>Hosts file</dt><dd>$(& $enc (Resolve-Path $HostsCsv))</dd>
<dt>Settings</dt><dd>$(& $enc (Resolve-Path $Settings)): domain $(& $enc $Domain), VLAN $(& $enc $cfg.Vlan), gateway $(& $enc $cfg.Gateway)</dd>
<dt>Build box</dt><dd>$(& $enc $BuildHost) (nginx port $HttpPort)</dd>
<dt>Run by</dt><dd>$(& $enc $env:USERNAME) on $(& $enc ([System.Net.Dns]::GetHostName()))</dd>
<dt>Options</dt><dd>$(& $enc $mode), timeout $TimeoutMinutes min</dd></dl>
<h2>Hosts</h2>
<table><tr><th>Host</th><th>IP / MAC</th><th>iDRAC</th><th>Pre-flight</th><th>Found before</th><th>Result</th><th>Boot disk</th><th>Disks wiped</th><th>Minutes</th><th>ESX now</th></tr>
$($rowsHtml -join "`n")
</table>
$(if ($details) { "<h2>VCF readiness checks and console screenshots</h2>" + ($details -join "`n") })
<p class="foot">Kickstart ISOs (they hold the root password) are deleted from the build box at the end of every run. The root password is not written to this report, the log or to disk.
Transcript: esx-install-$stamp.log next to this report.</p>
</body></html>
"@
    [System.IO.File]::WriteAllText($file, $html)
    Write-Host "`nReport: $file" -ForegroundColor Cyan
    if ($IsWindows) { Invoke-Item $file }
}

try {
    # --- 0. hosts file, DNS and ISO -----------------------------------------------------------
    $hosts = @(Import-Csv $HostsCsv)
    Write-Host "Hosts file: $HostsCsv"
    Write-Host 'Physical servers only. Only the hosts listed in this file are checked or installed: add a row for every host you want to build.' -ForegroundColor Yellow
    if (-not $hosts) { throw "$HostsCsv has no host rows" }
    foreach ($h in $hosts) {
        if (-not $h.idrac -or -not $h.nic) { throw "$($h.name): the idrac and nic columns must be filled in (this script is for physical servers with an iDRAC)" }
    }
    $hosts | Format-Table name, ip, idrac, nic -AutoSize | Out-Host

    # DNS must already be right for VCF: each FQDN resolves to the IP in the file, and back
    foreach ($h in $hosts) {
        $fqdn = "$($h.name).$Domain"
        $fwd = try { @([System.Net.Dns]::GetHostAddresses($fqdn) | ForEach-Object IPAddressToString) } catch { @() }
        $rev = try { [System.Net.Dns]::GetHostEntry($h.ip).HostName } catch { $null }
        if ($fwd -notcontains $h.ip) { throw "$($h.name): $fqdn resolves to '$($fwd -join ', ')', not $($h.ip). Fix DNS (A record) first." }
        if ($rev -ne $fqdn)          { throw "$($h.name): $($h.ip) reverse-resolves to '$rev', not $fqdn. Fix DNS (PTR record) first." }
        Write-Host "$($h.name): DNS OK ($fqdn <-> $($h.ip))"
    }

    if (-not (Test-Path $StockIso)) { throw "Stock ISO not found: $StockIso" }
    if ($cfg.StockIsoSha256) {
        Write-Host "Checking SHA-256 of $isoName..."
        $hash = (Get-FileHash $StockIso -Algorithm SHA256).Hash
        if ($hash -ne $cfg.StockIsoSha256.ToUpper()) { throw "SHA-256 of $isoName is $hash, settings say $($cfg.StockIsoSha256). Download the ISO again." }
        $isoCheck = 'matches the settings file'
        Write-Host "ISO SHA-256 OK"
    } else { $isoCheck = 'not checked (no StockIsoSha256 in the settings)'; Write-Warning $isoCheck }

    # --- credentials: Vaultwarden if configured, otherwise ask ---------------------------------
    # Vault.IdracItem can name one item for every iDRAC, or contain {name} for one item per host,
    # e.g. "iDRAC {name}" reads "iDRAC esx01", "iDRAC esx02", ...
    $script:idracCreds = @{}
    $script:idracCred  = $null
    $item = "$($cfg.Vault.IdracItem)"
    foreach ($h in $hosts) {
        if (-not $item) { break }
        $v = Get-VaultLogin ($item -replace '\{name\}', $h.name)
        if ($v) { $script:idracCreds[$h.idrac] = [pscredential]::new($v.username, [System.Net.NetworkCredential]::new($v.username, $v.password).SecurePassword)
                  Write-Host "$($h.name): iDRAC login read from the vault" }
        if ($item -notmatch '\{name\}') { if ($v) { $script:idracCred = $script:idracCreds[$h.idrac] }; break }
    }
    if (-not $script:idracCred -and @($hosts | Where-Object { -not $script:idracCreds.ContainsKey($_.idrac) }).Count) {
        $script:idracCred = Get-Credential -UserName root -Message 'iDRAC login (for the iDRACs not read from the vault)'
    }

    # --- 1. MAC address and pre-flight per host ------------------------------------------------
    $plan = foreach ($h in $hosts) {
        [pscustomobject]@{ name = $h.name; ip = $h.ip; idrac = $h.idrac; nic = $h.nic; fqdn = "$($h.name).$Domain"
                           bootdisk = "$($h.bootdisk)".Trim(); mac = $null; cd = $null; preflight = @(); blocked = $false
                           before = $null; result = $null; wiped = $null; minutes = $null; after = $null
                           checks = $null; shots = @(); started = $null; wentDown = $false; shotInstaller = $false }
    }
    $allHosts = @($plan)
    Write-Host "`nPre-flight checks (Redfish)..." -ForegroundColor Cyan
    foreach ($p in $plan) {
        try {
            $nic = Invoke-Redfish $p.idrac "/redfish/v1/Systems/System.Embedded.1/EthernetInterfaces/$($p.nic)"
            $p.mac = $nic.MACAddress.ToLower()
            $sys  = Invoke-Redfish $p.idrac '/redfish/v1/Systems/System.Embedded.1'
            $mode = (Invoke-Redfish $p.idrac '/redfish/v1/Systems/System.Embedded.1/Bios').Attributes.BootMode
            $p.cd = Get-VirtualCdPath $p.idrac
            $p.preflight = @("$($sys.Model)", "power $($sys.PowerState)", "boot mode $mode", "link $($nic.LinkStatus)", $(if ($p.cd) { 'virtual media OK' } else { 'no virtual media' }))
            if ($mode -ne 'Uefi')            { $p.blocked = $true; $p.result = 'Blocked: BIOS not in UEFI mode' }
            elseif ($nic.LinkStatus -ne 'LinkUp') { $p.blocked = $true; $p.result = "Blocked: $($p.nic) has no link" }
            elseif (-not $p.cd)              { $p.blocked = $true; $p.result = 'Blocked: no iDRAC virtual media' }
        } catch { $p.blocked = $true; $p.result = "Blocked: iDRAC query failed"; $p.preflight = @($_.Exception.Message) }
        $col = if ($p.blocked) { 'Red' } else { 'Green' }
        Write-Host ("{0}: {1}{2}" -f $p.name, ($p.preflight -join ', '), $(if ($p.blocked) { " -> $($p.result)" } else { ' -> OK' })) -ForegroundColor $col
    }

    # --- 1b. what is on each host now, and do we reinstall it? ---------------------------------
    # Installing ALWAYS wipes every disk in the server (clearpart --alldrives): explicit yes and the
    # host name typed back. -Force skips the questions.
    $selected = foreach ($p in $plan | Where-Object { -not $_.blocked }) {
        $esx  = Get-EsxInfo $p.ip
        $subj = Get-CertSubject $p.ip
        $now  = if ($esx) { "$($esx.FullName)" + $(if ($subj -match [regex]::Escape($p.fqdn)) { " as $($p.fqdn)" } else { ' (not under its VCF name)' }) }
                else      { 'no ESX answering on its IP (blank, PXE, another OS or powered off)' }
        $same = $esx -and $isoBuild -and $esx.Build -eq $isoBuild -and $subj -match [regex]::Escape($p.fqdn)
        $p.before = $now
        Write-Host "`n$($p.name): $now" -ForegroundColor Cyan
        if ($Force) { Write-Host "$($p.name): -Force given, installing and wiping all disks"; $p.result = 'Pending'; $p.wiped = 'All disks'; $p; continue }

        $hint = if ($same) { 'already this build, y/N' } else { 'Y/n' }
        $a = Read-Host "$($p.name): install ESX build $isoBuild on this host? ($hint)"
        if ([string]::IsNullOrWhiteSpace($a)) { $a = if ($same) { 'n' } else { 'y' } }
        if ($a -notmatch '^(y|yes)$') { Write-Host "$($p.name): left as it is" -ForegroundColor Yellow; $p.result = 'Left as it is'; continue }

        Write-Host "$($p.name): installing DELETES ALL DATA ON EVERY DISK in this server (boot disk, VMFS, vSAN, everything)." -ForegroundColor Red
        $c = Read-Host "Type $($p.name) to confirm"
        if ($c -ne $p.name) { Write-Host "$($p.name): not confirmed, left as it is" -ForegroundColor Yellow; $p.result = 'Not confirmed'; continue }
        $p.result = 'Pending'; $p.wiped = 'All disks'
        $p
    }
    $plan = @($selected)
    if (-not $plan) { Write-Host "`nNothing to install."; return }

    # --- 1c. boot disk per host ---------------------------------------------------------------
    foreach ($p in $plan) {
        if ($p.bootdisk)                      { Write-Host "$($p.name): ESX goes on '$($p.bootdisk)' (from the hosts file)" }
        elseif ($Force -and $cfg.DefaultBootDisk) { $p.bootdisk = $cfg.DefaultBootDisk; Write-Host "$($p.name): ESX goes on '$($p.bootdisk)' (DefaultBootDisk)" }
        else                                  { $p.bootdisk = Select-BootDisk $p }
        if ($p.bootdisk -match ',') { throw "$($p.name): disk model '$($p.bootdisk)' contains a comma, which the kickstart cannot take" }
    }

    # --- root password per host: Vaultwarden if configured, otherwise ask once ----------------
    # Vault.RootPasswordItem: one item for every host, or a pattern with {name}, e.g. "ESXi root {name}"
    $rootPw = @{}
    $item = "$($cfg.Vault.RootPasswordItem)"
    foreach ($p in $plan) {
        if (-not $item) { break }
        $v = Get-VaultLogin ($item -replace '\{name\}', $p.name)
        if ($v) { $rootPw[$p.name] = $v.password; Write-Host "$($p.name): root password read from the vault" }
        if ($item -notmatch '\{name\}') { if ($v) { foreach ($q2 in $plan) { $rootPw[$q2.name] = $v.password } }; break }
    }
    $missing = @($plan | Where-Object { -not $rootPw.ContainsKey($_.name) })
    if ($missing) {
        do {
            $a1 = [System.Net.NetworkCredential]::new('', (Read-Host -AsSecureString "ESX root password for $(($missing.name) -join ', ')")).Password
            $a2 = [System.Net.NetworkCredential]::new('', (Read-Host -AsSecureString 'Repeat it')).Password
            if ($a1 -ne $a2) { Write-Warning 'They do not match, try again' }
        } until ($a1 -eq $a2 -and $a1)
        foreach ($m in $missing) { $rootPw[$m.name] = $a1 }
        $a1 = $a2 = $null
    }

    # a dedicated key for root on the hosts, for the readiness checks. ESX runs sshd in FIPS mode,
    # which refuses ed25519 keys, so this one is ECDSA P-384 (created on first use, no passphrase)
    $pubKey = ''
    if ($cfg.AddRootSshKey -ne $false) {
        if (-not (Test-Path $sshKey)) {
            Write-Host "Creating SSH key $sshKey for the ESX hosts (ECDSA P-384, FIPS-compatible)"
            ssh-keygen -q -t ecdsa -b 384 -N '' -C "esx-kickstart@$([System.Net.Dns]::GetHostName())" -f $sshKey
        }
        $pubKey = (Get-Content "$sshKey.pub" -Raw).Trim()
    }

    # --- 2. build the ISOs on the build box ---------------------------------------------------
    $q = { param($s) "'" + ("$s" -replace "'", "'\''") + "'" }   # single-quote for bash
    $envFile = Join-Path $env:TEMP 'ks-settings.env'
    $envLines = @(
        "KS_DOMAIN=$(& $q $Domain)", "KS_NETMASK=$(& $q $cfg.Netmask)", "KS_GATEWAY=$(& $q $cfg.Gateway)",
        "KS_DNS=$(& $q ($cfg.Dns -join ','))", "KS_NTP=$(& $q ($cfg.Ntp -join ','))", "KS_VLAN=$(& $q $cfg.Vlan)",
        "KS_KEYBOARD=$(& $q $cfg.Keyboard)", "KS_BOOTDISK=$(& $q $cfg.DefaultBootDisk)", "KS_SSHKEY=$(& $q $pubKey)", "KS_MTU=$(& $q $mtu)")
    [System.IO.File]::WriteAllText($envFile, ($envLines -join "`n") + "`n")
    $csvTmp = Join-Path $env:TEMP 'ks-hosts.csv'
    $lines = @('name,ip,mac,bootdisk') + ($plan | ForEach-Object { "$($_.name),$($_.ip),$($_.mac),$($_.bootdisk)" })
    [System.IO.File]::WriteAllText($csvTmp, ($lines -join "`n") + "`n")
    ssh $remote "mkdir -p ~/ks"
    scp $Template $BuildScript $csvTmp $envFile "${remote}:~/ks/"
    Remove-Item $csvTmp, $envFile
    ssh $remote "test -f ~/ks/$isoName" 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "Uploading $isoName to $BuildHost"; scp $StockIso "${remote}:~/ks/" }

    Write-Host 'Building kickstart ISOs...'
    ($plan | ForEach-Object { "$($_.name)`t$($rootPw[$_.name])" }) -join "`n" | ssh $remote "cd ~/ks && chmod +x build-ks-isos.sh && rm -f /srv/ks/*.iso && ./build-ks-isos.sh '$isoName' ks-hosts.csv ks-template.cfg /srv/ks ks-settings.env; rc=`$?; rm -f ks-settings.env; exit `$rc"
    if ($LASTEXITCODE -ne 0) { throw 'ISO build failed on the build box' }
    $rootPw = $null

    # --- 3. the build box must serve them with Range support ----------------------------------
    $testUrl = "http://${BuildHost}:$HttpPort/esx-ks-$($plan[0].name).iso"
    $probe = Invoke-WebRequest $testUrl -Headers @{ Range = 'bytes=0-1' } -SkipHttpErrorCheck
    if ($probe.StatusCode -ne 206) { throw "$testUrl answered $($probe.StatusCode), not 206. Is nginx serving /srv/ks on port $HttpPort?" }
    Write-Host "Build box serves the ISOs with Range support (206)"

    if ($DryRun) {
        foreach ($p in $plan) { $p.result = 'Dry run OK'; $p.wiped = 'none (dry run)' }
        Write-Host "`nDry run: pre-flight passed, ISOs built and served. Nothing was mounted or rebooted." -ForegroundColor Green
        return
    }

    # --- 4. mount, boot once from CD, restart -------------------------------------------------
    foreach ($p in $plan) {
        $url = "http://${BuildHost}:$HttpPort/esx-ks-$($p.name).iso"
        try { $null = Invoke-Redfish $p.idrac "$($p.cd)/Actions/VirtualMedia.EjectMedia" Post @{} } catch { Write-Verbose "$($p.name): nothing to eject" }
        $null = Invoke-Redfish $p.idrac "$($p.cd)/Actions/VirtualMedia.InsertMedia" Post @{ Image = $url; Inserted = $true; WriteProtected = $true }
        $null = Invoke-Redfish $p.idrac '/redfish/v1/Systems/System.Embedded.1' Patch @{
            Boot = @{ BootSourceOverrideTarget = 'Cd'; BootSourceOverrideEnabled = 'Once' } }
        $power = (Invoke-Redfish $p.idrac '/redfish/v1/Systems/System.Embedded.1').PowerState
        $reset = if ($power -eq 'On') { 'ForceRestart' } else { 'On' }
        $null = Invoke-Redfish $p.idrac '/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset' Post @{ ResetType = $reset }
        $p.started = Get-Date
        Write-Host "$($p.name): booting $url ($reset)"
    }

    # --- 5/6. wait for each host, then check it -----------------------------------------------
    $pending = [System.Collections.Generic.List[object]]$plan
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($pending.Count -and (Get-Date) -lt $deadline) {
        Start-Sleep 30
        foreach ($p in @($pending)) {
            # one screenshot of the installer at work, about 6 minutes in
            if (-not $p.shotInstaller -and ((Get-Date) - $p.started).TotalMinutes -ge 6) { Save-ConsoleShot $p 'Installer'; $p.shotInstaller = $true }
            $subj = Get-CertSubject $p.ip
            # the old install may answer for a minute or two: only count the host once it has gone down
            if (-not $subj) { $p.wentDown = $true; continue }
            if (-not $p.wentDown) { continue }
            # SSH is switched on by the kickstart's first-boot section, so port 22 means it has run
            $t = [System.Net.Sockets.TcpClient]::new()
            $sshUp = $t.ConnectAsync($p.ip, 22).Wait(3000); $t.Dispose()
            if (-not ($sshUp -and $subj -match [regex]::Escape($p.fqdn))) { continue }

            $p.minutes = [math]::Round(((Get-Date) - $p.started).TotalMinutes, 1)
            $p.result  = 'Installed'
            Write-Host "$($p.name): up as $($p.fqdn) after $($p.minutes) min" -ForegroundColor Green
            try { $null = Invoke-Redfish $p.idrac "$($p.cd)/Actions/VirtualMedia.EjectMedia" Post @{} } catch { Write-Warning "$($p.name): eject failed, unmap it in the iDRAC" }
            # hostd can take a minute after SSH and the certificate are up: ask a few times
            $i = $null
            for ($k = 0; $k -lt 6 -and -not $i; $k++) { $i = Get-EsxInfo $p.ip; if (-not $i) { Start-Sleep 10 } }
            $p.after = if ($i) { $i.FullName } else { 'up, version not read' }
            # a reinstall generates new SSH host keys: drop the old ones before connecting
            ssh-keygen -R $p.fqdn 2>&1 | Out-Null; ssh-keygen -R $p.ip 2>&1 | Out-Null
            Save-ConsoleShot $p 'Finished'
            [void]$pending.Remove($p)
        }
    }
    # readiness checks once every host is up, so waiting for one host's NTP never delays spotting the others
    if ($pubKey) {
        foreach ($p in $plan | Where-Object result -eq 'Installed') {
            Write-Host "$($p.name): VCF readiness checks..."
            $p.checks = Test-EsxReadiness $p
            $failed = @($p.checks | Where-Object { -not $_.Pass })
            if ($failed) { Write-Warning "$($p.name): $($failed.Count) check(s) failed: $(($failed.Check) -join ', ')" }
            else { Write-Host "$($p.name): ready for VCF" -ForegroundColor Green }
        }
    }
    foreach ($p in $pending) {
        $p.result = "Not up after $TimeoutMinutes min"
        Save-ConsoleShot $p 'At timeout'
        Write-Warning "$($p.name): not up after $TimeoutMinutes min - see the screenshot in the report or the iDRAC console"
    }
    $plan | Select-Object name, fqdn, ip, result, minutes | Format-Table -AutoSize | Out-Host
}
catch { $runError = $_.Exception.Message; throw }
finally {
    # ISOs hold the root password: always delete them
    if ($plan -and $remote) { ssh $remote 'rm -f /srv/ks/*.iso' 2>$null; Write-Host 'Kickstart ISOs deleted from the build box.' }
    foreach ($p in $allHosts) { if ($p.result -eq 'Pending') { $p.result = 'Stopped before finishing' } }
    if ($allHosts) { Write-InstallReport $allHosts }
    Stop-Transcript | Out-Null
}

<#
.SYNOPSIS
    Stops, starts or restarts all Veeam Backup & Replication services in a safe order.

.DESCRIPTION
    Run on the Veeam backup server in an elevated PowerShell session.

    Stop:    closes any open Veeam console, then stops every Veeam* service
             (the main Veeam Backup Service last).
    Start:   starts the configuration database first (PostgreSQL or SQL Server),
             then the Veeam Backup Service, then every other Veeam* service set to Automatic.
    Restart: Stop, then Start.
    Status:  lists the Veeam services and the database service.

    Only services with StartType Automatic are started, so anything you disabled stays off.
    Supports -WhatIf.

.EXAMPLE
    .\Restart-VeeamServices.ps1 -Action Status
.EXAMPLE
    .\Restart-VeeamServices.ps1 -Action Restart
.EXAMPLE
    .\Restart-VeeamServices.ps1 -Action Stop -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Stop', 'Start', 'Restart', 'Status')]
    [string]$Action = 'Status',

    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

$mainName = 'VeeamBackupSvc'

function Get-VeeamService {
    Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue | Sort-Object DisplayName
}

function Get-VeeamDbService {
    # PostgreSQL (default since 12.0) or a local SQL Server instance
    Get-Service -Name 'postgresql*', 'MSSQL$*' -ErrorAction SilentlyContinue
}

function Wait-ServiceState {
    param($Service, [string]$State)
    try {
        $Service.WaitForStatus($State, [TimeSpan]::FromSeconds($TimeoutSeconds))
    }
    catch {
        Write-Warning "$($Service.DisplayName) did not reach '$State' within $TimeoutSeconds s"
    }
}

function Show-Status {
    $rows = @(Get-VeeamDbService) + @(Get-VeeamService)
    $rows | Select-Object Status, StartType, Name, DisplayName | Format-Table -AutoSize
    $notRunning = $rows | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' }
    if ($notRunning) {
        Write-Warning ("Automatic but not running: " + ($notRunning.Name -join ', '))
    }
}

function Stop-Veeam {
    $consoles = Get-Process -Name 'Veeam.Backup.Shell' -ErrorAction SilentlyContinue
    if ($consoles -and $PSCmdlet.ShouldProcess('Veeam console (Veeam.Backup.Shell)', 'Close')) {
        $consoles | Stop-Process -Force
        Write-Output "Closed $(@($consoles).Count) Veeam console process(es)"
    }

    $services = Get-VeeamService | Where-Object Status -eq 'Running'
    # Everything except the main service first, the main service last
    $ordered = @($services | Where-Object Name -ne $mainName) + @($services | Where-Object Name -eq $mainName)
    foreach ($svc in $ordered) {
        if ($PSCmdlet.ShouldProcess($svc.DisplayName, 'Stop service')) {
            Write-Output "Stopping  $($svc.DisplayName)"
            Stop-Service -InputObject $svc -Force -NoWait
        }
    }
    if (-not $WhatIfPreference) {
        foreach ($svc in $ordered) { Wait-ServiceState -Service $svc -State 'Stopped' }
    }
}

function Start-Veeam {
    foreach ($db in Get-VeeamDbService | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' }) {
        if ($PSCmdlet.ShouldProcess($db.DisplayName, 'Start database service')) {
            Write-Output "Starting  $($db.DisplayName)"
            Start-Service -InputObject $db
            Wait-ServiceState -Service $db -State 'Running'
        }
    }

    $auto = Get-VeeamService | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' }
    $ordered = @($auto | Where-Object Name -eq $mainName) + @($auto | Where-Object Name -ne $mainName)
    foreach ($svc in $ordered) {
        if ($PSCmdlet.ShouldProcess($svc.DisplayName, 'Start service')) {
            Write-Output "Starting  $($svc.DisplayName)"
            try {
                Start-Service -InputObject $svc
                Wait-ServiceState -Service $svc -State 'Running'
            }
            catch {
                Write-Warning "Could not start $($svc.DisplayName): $($_.Exception.Message)"
            }
        }
    }
}

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if ($Action -ne 'Status' -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell session (Run as administrator).'
}

switch ($Action) {
    'Status'  { Show-Status }
    'Stop'    { Stop-Veeam;  Show-Status }
    'Start'   { Start-Veeam; Show-Status }
    'Restart' { Stop-Veeam;  Start-Veeam; Show-Status }
}

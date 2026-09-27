# Baseline settings for a Windows Server VM that will become a vCenter template.
# Run once inside the VM as Administrator, after VMware Tools and before Windows Update.
# Do NOT sysprep or domain-join the template: the vCenter customization spec does both per clone.
# Written up at https://rstechhub.com/core-infrastructure-part-7-windows-server-template/
param(
    [string]$TimeZone = 'GMT Standard Time',
    # KMS client key (GVLK) for your edition. Microsoft publishes them:
    # https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys
    [string]$KmsClientKey
)

Set-TimeZone -Id $TimeZone

# RDP on, with Network Level Authentication
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'

# Allow ping (ICMPv4 echo)
Enable-NetFirewallRule -Name FPS-ICMP4-ERQ-In

# High performance power plan, no Server Manager at every logon
powercfg /setactive SCHEME_MIN
Get-ScheduledTask -TaskName ServerManager | Disable-ScheduledTask | Out-Null

if ($KmsClientKey) {
    cscript //nologo "$env:windir\System32\slmgr.vbs" /ipk $KmsClientKey
    Write-Host 'KMS client key installed. Clones find the KMS host via the _vlmcs._tcp DNS SRV record.'
}

Write-Host 'Baseline applied. Next: Windows Update until clean, then:'
Write-Host '  Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase'
Write-Host 'Shut down, set the CD/DVD drive to Client Device, convert to template.'

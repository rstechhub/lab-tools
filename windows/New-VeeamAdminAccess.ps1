# Gives Veeam its own admin access path instead of the domain Administrator.
# Creates the AD group veeam-admins and the named admin account labadmin (if missing),
# adds labadmin to the group, and makes the group a local Administrator on the Veeam server.
# Safe to re-run. Run as a domain admin on a DC (or any machine with the AD PowerShell module).
# The Veeam console step (Users and Roles) is manual: add <DOMAIN>\veeam-admins as Veeam Backup
# Administrator and remove BUILTIN\Administrators.
# Example: .\New-VeeamAdminAccess.ps1 -VeeamServer veeam01.example.internal -GroupOU "OU=Groups,DC=example,DC=internal"
# Written up at https://rstechhub.com/ (Backing Up the Lab with Veeam)
param(
    [Parameter(Mandatory)][string]$VeeamServer,
    [string]$GroupName = 'veeam-admins',
    [string]$UserName  = 'labadmin',
    [string]$GroupOU,   # defaults to the domain's Users container
    [string]$UserOU
)
Import-Module ActiveDirectory
if (-not $GroupOU) { $GroupOU = (Get-ADDomain).UsersContainer }
if (-not $UserOU)  { $UserOU  = (Get-ADDomain).UsersContainer }
$domain = (Get-ADDomain).NetBIOSName

if (-not (Get-ADGroup -Filter "Name -eq '$GroupName'")) {
    New-ADGroup -Name $GroupName -GroupScope Global -GroupCategory Security -Path $GroupOU `
        -Description 'Veeam Backup Administrators'
    Write-Host "Created group $GroupName"
} else { Write-Host "Group $GroupName exists" }

if (-not (Get-ADUser -Filter "SamAccountName -eq '$UserName'")) {
    New-ADUser -Name $UserName -SamAccountName $UserName -UserPrincipalName "$UserName@$((Get-ADDomain).DNSRoot)" `
        -Path $UserOU -Description 'Named lab admin (Veeam and day-to-day)' `
        -AccountPassword (Read-Host -AsSecureString "Password for $UserName") -Enabled $true
    Write-Host "Created user $UserName (store the password in the vault)"
} else { Write-Host "User $UserName exists" }

if (-not (Get-ADGroupMember $GroupName | Where-Object SamAccountName -eq $UserName)) {
    Add-ADGroupMember $GroupName -Members $UserName
    Write-Host "Added $UserName to $GroupName"
} else { Write-Host "$UserName already in $GroupName" }

# Local Administrators on the Veeam server (well-known SID, works in any Windows language)
Invoke-Command -ComputerName $VeeamServer -ScriptBlock {
    param($member)
    if (-not (Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object Name -eq $member)) {
        Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $member
        "Added $member to local Administrators on $env:COMPUTERNAME"
    } else { "$member already a local Administrator on $env:COMPUTERNAME" }
} -ArgumentList "$domain\$GroupName"

Write-Host "Done. Now in the Veeam console: Users and Roles -> add $domain\$GroupName (Veeam Backup Administrator), remove BUILTIN\Administrators."

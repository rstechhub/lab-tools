<#
.SYNOPSIS
  Creates a test user and adds it to the read-only SSO group.
  The password is prompted for and never stored in the script.
.EXAMPLE
  .\New-VcfReadOnlyTestUser.ps1 -Name vcf-ro-test -Path 'OU=Lab,DC=lab,DC=internal' -Group vcf-readonly -Domain lab.internal
#>
param(
    [string]$Name   = 'vcf-ro-test',
    [string]$Path   = 'OU=Lab,DC=lab,DC=internal',
    [string]$Group  = 'vcf-readonly',
    [string]$Domain = 'lab.internal'
)
Import-Module ActiveDirectory
$pw = Read-Host "Password for $Name" -AsSecureString
New-ADUser -Name $Name -SamAccountName $Name -UserPrincipalName "$Name@$Domain" `
    -GivenName 'VCF' -Surname 'ReadOnly' -Path $Path `
    -AccountPassword $pw -Enabled $true -PasswordNeverExpires $true
Add-ADGroupMember -Identity $Group -Members $Name
Get-ADGroupMember $Group | Select-Object Name

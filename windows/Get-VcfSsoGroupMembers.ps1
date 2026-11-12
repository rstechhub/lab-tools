<#
.SYNOPSIS
  Lists the members of the VCF SSO groups and the OU each account lives in,
  then lists every OU under the lab root. Read-only.
.EXAMPLE
  .\Get-VcfSsoGroupMembers.ps1 -Groups vcf-admins,vcf-readonly -SearchBase 'OU=Lab,DC=lab,DC=internal'
#>
param(
    [string[]]$Groups = @('vcf-admins','vcf-readonly'),
    [string]$SearchBase = 'OU=Lab,DC=lab,DC=internal'
)
Import-Module ActiveDirectory

foreach ($g in $Groups) {
    Write-Host "`n== $g ==" -ForegroundColor Cyan
    Get-ADGroupMember -Identity $g -Recursive |
        Where-Object objectClass -eq 'user' |
        ForEach-Object {
            $u = Get-ADUser $_ -Properties Enabled
            [pscustomobject]@{
                Group   = $g
                User    = $u.SamAccountName
                Enabled = $u.Enabled
                OU      = ($u.DistinguishedName -replace '^CN=[^,]+,','')
            }
        } | Format-Table -AutoSize
}

Write-Host "`n== OUs under $SearchBase ==" -ForegroundColor Cyan
Get-ADOrganizationalUnit -SearchBase $SearchBase -Filter * |
    Select-Object -ExpandProperty DistinguishedName | Sort-Object

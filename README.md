# lab-tools

Scripts from the [rstechhub.com](https://rstechhub.com) home lab: a VMware Cloud Foundation lab on Dell and HPE servers, MikroTik networking, TrueNAS and Synology storage, and Veeam backups. Each script is written up in a blog post, linked below.

All examples use placeholder names and addresses (`example.internal`, `192.0.2.x`, `192.168.10.x`). Adjust them to your environment.

| Folder | Script | What it does | Blog post |
|---|---|---|---|
| `redfish/` | `Get-ServerInventory.ps1` | Firmware and physical-disk inventory across Dell iDRAC 9/7/8 and HPE iLO 4, flags version mismatches. Read-only. | [Firmware updates on a running VCF cluster](https://rstechhub.com/lab-maintenance-firmware-updates-vcf-cluster/) |
| `redfish/` | `Set-IdracCertificate.ps1` | CA-signed iDRAC 9 web certificate: CSR on the iDRAC, signed with `certreq`, imported over Redfish. | [Core Infrastructure Part 4: a certificate authority](https://rstechhub.com/core-infrastructure-part-4-certificate-authority/) |
| `dns/` | `Import-DnsRecords.ps1` | Bulk A + PTR records from a CSV, creates missing zones, never overwrites. `-WhatIf` supported. | [Core Infrastructure Part 1: DNS, AD and time](https://rstechhub.com/core-infrastructure-part-1-dns-ad-time/) |
| `dns/` | `Test-DnsRecords.ps1` | Read-only check for duplicate IPs, A records without PTR, and stale PTRs. Run before a VCF deployment. | [Core Infrastructure Part 1: DNS, AD and time](https://rstechhub.com/core-infrastructure-part-1-dns-ad-time/) |
| `windows/` | `Set-TemplateBaseline.ps1` | Baseline settings for a Windows Server VM before it becomes a vCenter template. | [Core Infrastructure Part 7: a Windows Server template](https://rstechhub.com/core-infrastructure-part-7-windows-server-template/) |
| `windows/` | `New-VeeamAdminAccess.ps1` | AD group and named admin for Veeam, local admin on the backup server, so the domain Administrator is not used. | Backing Up the Lab with Veeam (coming soon) |
| `linux/` | `switch-backup.sh` | Nightly MikroTik `/export` over read-only SSH, committed to Git only when something changed. | [Nightly MikroTik config backups to Gitea](https://rstechhub.com/nightly-mikrotik-config-backups-gitea/) |
| `linux/` | `vault-backup.sh` | Nightly consistent backup of a Vaultwarden install to an NFS share, with retention. | |

## Requirements

- PowerShell scripts: Windows PowerShell 5.1 or PowerShell 7. `dns/` needs the DnsServer module (run on a DNS server or DC); `New-VeeamAdminAccess.ps1` needs the ActiveDirectory module and WinRM to the Veeam server.
- Redfish scripts: HTTPS access to the iDRAC / iLO and an administrator account. `Set-IdracCertificate.ps1` also needs a domain-joined machine with enrolment rights on your AD CS template (default `WebServer`).
- Shell scripts: bash, and the packages listed in each script's header.

## Redfish scripts

```powershell
.\redfish\Get-ServerInventory.ps1 -Idrac idrac1.example.com, idrac2.example.com -Ilo ilo1.example.com

.\redfish\Set-IdracCertificate.ps1 -Name idrac-host01 -IP 192.0.2.11 -Domain example.com `
    -CA "ca01.example.com\Example-Root-CA" -SetDnsName -DnsServers 192.0.2.53
```

`Get-ServerInventory.ps1` saves firmware and disk tables as timestamped CSVs in `.\Reports`. A controller mid-update answers 503/500 and is skipped with a warning. iDRAC 7 does not publish disks over Redfish.

`Set-IdracCertificate.ps1` with `-SetDnsName` sets the iDRAC's own DNS name first; without it iDRAC 9 returns 400 Bad Request when browsed by a name it does not know. The private key never leaves the iDRAC. Why not the web upload? Some firmware rejects valid certificates there (`RAC0622`, `RAC0613`, `SYS426`, `RAC0615`); Redfish has worked every time.

Both skip validation of the controllers' own HTTPS certificates, since most start self-signed. Run them from a trusted management network.

## Disclaimer

Provided as-is under the MIT licence. Test in a lab first. Read each script's header before running it: the read-only ones say so, the others change configuration.

# lab-tools

[![lint](https://github.com/rstechhub/lab-tools/actions/workflows/lint.yml/badge.svg)](https://github.com/rstechhub/lab-tools/actions/workflows/lint.yml)

Scripts from the [rstechhub.com](https://rstechhub.com) home lab: a VMware Cloud Foundation lab on Dell and HPE servers, MikroTik networking, TrueNAS and Synology storage, and Veeam backups. Each script is written up in a blog post, linked below. Every folder has its own README with usage and the gotchas found along the way.

All examples use placeholder names and addresses (`example.internal`, `192.0.2.x`, `192.168.x.x`). Adjust them to your environment.

| Folder | Script | What it does | Blog post |
|---|---|---|---|
| [`redfish/`](redfish/) | `Get-ServerInventory.ps1` | Firmware and physical-disk inventory across Dell iDRAC 9/7/8 and HPE iLO 4, flags version mismatches. Read-only. | [Firmware updates on a running VCF cluster](https://rstechhub.com/lab-maintenance-firmware-updates-vcf-cluster/) |
| [`redfish/`](redfish/) | `Set-IdracCertificate.ps1` | CA-signed iDRAC 9 web certificate: CSR on the iDRAC, signed with `certreq`, imported over Redfish. | [Core Infrastructure Part 4](https://rstechhub.com/core-infrastructure-part-4-certificate-authority/) |
| [`dns/`](dns/) | `Import-DnsRecords.ps1` | Bulk A + PTR records from a CSV, creates missing zones, never overwrites. `-WhatIf` supported. | [Core Infrastructure Part 3](https://rstechhub.com/core-infrastructure-part-3-domain-controllers/) |
| [`dns/`](dns/) | `Test-DnsRecords.ps1` | Read-only check for duplicate IPs, A records without PTR, and stale PTRs. Run before a VCF deployment. | [Core Infrastructure Part 3](https://rstechhub.com/core-infrastructure-part-3-domain-controllers/) |
| [`windows/`](windows/) | `Set-TemplateBaseline.ps1` | Baseline settings for a Windows Server VM before it becomes a vCenter template. | [Core Infrastructure Part 7](https://rstechhub.com/core-infrastructure-part-7-windows-server-template/) |
| [`windows/`](windows/) | `Set-KmsDnsRecord.ps1` | KMS host A + PTR and the `_vlmcs._tcp` SRV record, so clones activate on their own. | [Core Infrastructure Part 7](https://rstechhub.com/core-infrastructure-part-7-windows-server-template/) |
| [`veeam/`](veeam/) | `New-VeeamAdminAccess.ps1`, `Restart-VeeamServices.ps1` | AD group and named admin for Veeam, so the domain Administrator is not used; stop, start or restart all Veeam services in order for troubleshooting. | [Backing Up the Lab with Veeam](https://rstechhub.com/veeam-lab-backups-part-1-design-backup-server/) |
| [`vmware/`](vmware/) | `Add-NfsDatastore.ps1` | Storage VMkernel adapter, jumbo-frame path check, NFS datastore, NFS 3 by default (PowerCLI). | [TrueNAS Part 5](https://rstechhub.com/truenas-scale-dell-r620-part-5-storage-vlan-dac-certificate/) |
| [`truenas/`](truenas/) | `set-storage-vlan.sh` | Tagged storage VLAN with jumbo frames on TrueNAS SCALE, as the management and gateway network. | [TrueNAS Part 5](https://rstechhub.com/truenas-scale-dell-r620-part-5-storage-vlan-dac-certificate/) |
| [`truenas/`](truenas/) | `create-nfs-shares.sh` | Datasets and NFS shares for vSphere, vCenter backups and Veeam, bound to the storage IP. | [TrueNAS Part 5](https://rstechhub.com/truenas-scale-dell-r620-part-5-storage-vlan-dac-certificate/) |
| [`mikrotik/`](mikrotik/) | `*.rsc` | RouterOS 7: read-only backup user, break-glass admin, clear logs. | [MikroTik config backups](https://rstechhub.com/nightly-mikrotik-config-backups-gitea/) |
| [`linux/`](linux/) | `switch-backup.sh` | Nightly MikroTik `/export` over read-only SSH, committed to Git only when something changed. | [MikroTik config backups](https://rstechhub.com/nightly-mikrotik-config-backups-gitea/) |
| [`linux/`](linux/) | `prepare-ubuntu-template.sh` | Seals an Ubuntu 24.04 VM before it becomes a vSphere template: new SSH host keys and machine-id per clone, cloud-init off for vCenter customization. | [Core Infrastructure Part 8](https://rstechhub.com/core-infrastructure-part-8-ubuntu-template/) |
| [`linux/`](linux/) | `vault-backup.sh` | Nightly consistent backup of a Vaultwarden install to an NFS share, with retention. | |
| [`esx-kickstart/`](esx-kickstart/) | `Install-EsxKickstart.ps1` + helpers | Unattended ESX 9 installs on Dell servers: pre-flight checks, kickstart ISO per host, iDRAC virtual-media boot, parallel installs, VCF readiness checks, HTML report. | [Building a VCF 9 Lab, Part 2](https://rstechhub.com/vcf-9-lab-part-2-automated-esx-installs/) |

## Requirements

- PowerShell scripts: Windows PowerShell 5.1 or PowerShell 7. Modules needed are listed in each folder's README (DnsServer, ActiveDirectory, VMware PowerCLI).
- Shell scripts: bash, and the packages listed in each script's header. TrueNAS scripts run on TrueNAS SCALE 25.x.
- RouterOS snippets: RouterOS 7.

## Checks

Every push runs [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) on the PowerShell scripts and [ShellCheck](https://www.shellcheck.net/) on the shell scripts. See [CHANGELOG.md](CHANGELOG.md) for what changed.

## Disclaimer

Provided as-is under the MIT licence. Test in a lab first. Read each script's header before running it: the read-only ones say so, the others change configuration.

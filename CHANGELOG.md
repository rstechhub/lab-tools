# Changelog

## v1.1 (2 Oct 2026)

- `vmware/Add-NfsDatastore.ps1`: new `-NfsVersion` parameter, default changed from NFS 4.1 to NFS 3. ESXi 8.0 U3 over NFS 4.1 to TrueNAS SCALE reported stale file sizes (new thin VMDKs at 0 bytes), so VMs would not power on.

## v1.0 (27 Sep 2026)

- Repository renamed from `redfish-lab-tools` to `lab-tools` (old links redirect).
- Scripts organised into folders: `redfish/`, `dns/`, `windows/`, `veeam/`, `vmware/`, `truenas/`, `mikrotik/`, `linux/`.
- Added: `dns/Import-DnsRecords.ps1`, `dns/Test-DnsRecords.ps1`, `windows/Set-TemplateBaseline.ps1`, `windows/Set-KmsDnsRecord.ps1`, `veeam/New-VeeamAdminAccess.ps1`, `vmware/Add-NfsDatastore.ps1`, `truenas/set-storage-vlan.sh`, `truenas/create-nfs-shares.sh`, `mikrotik/*.rsc`, `linux/switch-backup.sh`, `linux/vault-backup.sh`.
- Lint checks on every push: PSScriptAnalyzer and ShellCheck.

## 2026-09-24

- First release: `Get-ServerInventory.ps1` and `Set-IdracCertificate.ps1`.

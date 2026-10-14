# Changelog

## v1.6.1 (14 Oct 2026)

- `esx-kickstart`: the wait for SSH no longer stops the run when a host refuses the connection while it reboots after the install.

## v1.6 (14 Oct 2026)

- `esx-kickstart`: management port detection. With `nic` empty or `auto` in the hosts file the script picks the fastest port that has link, and falls back to it when the named port has none.
- `esx-kickstart`: add-in NICs report the link on the partition (`NIC.Slot.4-1-1`) but the MAC on the port (`NIC.Slot.4-1`); the MAC now comes from the parent port, so the kickstart gets its uplink.
- `esx-kickstart`: boot card option. `BootCardModel` in the settings names a boot device the iDRAC can't list (HPE NS204i-p in a Dell R740xd); the disk prompt offers it as `B` (default) and USB/SD as `U`.
- `esx-kickstart`: the ESX build number is read from Dell-customised ISO names too. Tested with ESXi 8.0 U3 (Dell A11) on two R740xds.

## v1.5 (6 Oct 2026)

- `esx-kickstart`: new `Mtu` setting sets vSwitch0 and vmk0 at first boot; two new readiness checks (vmk0 MTU, and a no-fragment ping of that size to the gateway).
- `esx-kickstart`: the readiness checks retry SSH for up to 5 minutes, because the kickstart's first-boot section reboots the host once more after it first answers.
- `esx-kickstart`: `-NoVault` switch to ignore the Vault items and ask for the passwords.
- `esx-kickstart`: `Vlan` 0 leaves `--vlanid` out of the kickstart (untagged), for hosts behind an access port.

## v1.4 (3 Oct 2026)

- Added `esx-kickstart/`: unattended ESX 9 installs on physical Dell servers from a Windows management PC. Pre-flight checks over Redfish, a kickstart ISO per host built on a Linux box, boot through iDRAC virtual media, parallel installs, VCF readiness checks over SSH and an HTML report. Passwords can come from Vaultwarden through the Bitwarden CLI.
- ShellCheck now also covers `esx-kickstart/*.sh`.

## v1.3 (3 Oct 2026)

- Added `linux/prepare-ubuntu-template.sh`: seals an Ubuntu 24.04 VM before converting it to a vSphere template (NTP servers as arguments, cloud-init off, installer netplan removed, SSH host keys regenerated on first boot, machine-id cleared, logs and history cleared, shutdown).

## v1.2 (2 Oct 2026)

- Added `veeam/Restart-VeeamServices.ps1`: stop, start, restart or list all Veeam services in a safe order (database first, main service last on stop), closes any open console, `-WhatIf` support.
- `veeam/README.md` and the main README now link to the published Veeam posts.

## v1.1 (2 Oct 2026)

- `vmware/Add-NfsDatastore.ps1`: new `-NfsVersion` parameter, default changed from NFS 4.1 to NFS 3. ESXi 8.0 U3 over NFS 4.1 to TrueNAS SCALE reported stale file sizes (new thin VMDKs at 0 bytes), so VMs would not power on.

## v1.0 (27 Sep 2026)

- Repository renamed from `redfish-lab-tools` to `lab-tools` (old links redirect).
- Scripts organised into folders: `redfish/`, `dns/`, `windows/`, `veeam/`, `vmware/`, `truenas/`, `mikrotik/`, `linux/`.
- Added: `dns/Import-DnsRecords.ps1`, `dns/Test-DnsRecords.ps1`, `windows/Set-TemplateBaseline.ps1`, `windows/Set-KmsDnsRecord.ps1`, `veeam/New-VeeamAdminAccess.ps1`, `vmware/Add-NfsDatastore.ps1`, `truenas/set-storage-vlan.sh`, `truenas/create-nfs-shares.sh`, `mikrotik/*.rsc`, `linux/switch-backup.sh`, `linux/vault-backup.sh`.
- Lint checks on every push: PSScriptAnalyzer and ShellCheck.

## 2026-09-24

- First release: `Get-ServerInventory.ps1` and `Set-IdracCertificate.ps1`.

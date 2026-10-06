# esx-kickstart

Unattended ESX installs on physical Dell servers, driven from a Windows management PC. One command
checks the hosts, builds a kickstart ISO per host, boots each server from it through its iDRAC,
waits for the install to finish, checks the host is ready for VCF and writes an HTML report.

| File | What it is |
|---|---|
| `Install-EsxKickstart.ps1` | The install run (PowerShell 7, management PC) |
| `build-ks-isos.sh` | Builds one kickstart ISO per host (runs on the build box over SSH) |
| `ks-template.cfg` | The kickstart, with `{{tokens}}` filled in per host |
| `Test-EsxHost.ps1` | Read-only checks of a host afterwards: NICs from the iDRAC, ESX settings over SSH |
| `esx-settings.example.json` | Settings layout: copy to `esx-settings.json` and fill in (keep yours private) |
| `hosts.example.csv` | Hosts file layout: one row per server you want to install |

## What a run does

1. **Pre-flight:** DNS A and PTR for every host, the stock ISO's SHA-256, and over Redfish the BIOS
   boot mode (must be UEFI), power state, link on the management port and iDRAC virtual media.
   A host that fails is blocked and listed in the report; the others carry on.
2. **Asks per host** what to do, showing what it runs now. A reinstall wipes every local disk
   (`clearpart --alldrives`), so you type the host name to confirm. Then you pick the boot disk from
   the iDRAC's list (or set it in the hosts file).
3. **Builds the ISOs** on the build box and checks nginx answers HTTP Range requests (206).
   iDRAC virtual media reads the ISO in pieces; a server without Range support makes the UEFI boot fail.
4. **Boots each server** from its ISO (virtual media, one-time boot override, restart).
5. **Waits** until each host answers with a certificate issued to its FQDN and SSH is up.
6. **Checks VCF readiness** over SSH with a dedicated key, `~/.ssh/esx_kickstart_ecdsa`, created on first
   use and added for root by the kickstart: build, vmk0 IP,
   management VLAN, DNS search domain, NTP servers and sync, IPv6 off, certificate SAN, vmk0 MTU and a
   no-fragment ping of that size to the gateway, and every disk except the boot disk empty and eligible
   for vSAN (`vdq -q`).
7. **Cleans up and reports:** ejects the media, deletes the ISOs (they contain the root password) and
   writes `reports\esx-install-<date>.html` with the results, the checks and iDRAC console screenshots,
   plus a transcript log.

`-DryRun` stops after step 3. `-Force` installs every host in the file without questions. `-NoVault` ignores the Vault items and asks for the passwords.

## Requirements

- **Management PC:** PowerShell 7, the Windows OpenSSH client, an SSH key copied to the build box (the
  key for the ESX hosts is created by the script). Optional: the Bitwarden CLI (`bw`) to read passwords from Vaultwarden.
- **Build box:** Linux with `xorriso` and nginx serving `/srv/ks` on port 8080, writable by the SSH user:
  ```bash
  sudo apt install -y xorriso nginx
  sudo install -d -o $USER -g $USER -m 755 /srv/ks
  printf 'server {\n    listen 8080;\n    root /srv/ks;\n}\n' | sudo tee /etc/nginx/sites-available/ks
  sudo ln -s /etc/nginx/sites-available/ks /etc/nginx/sites-enabled/ks && sudo systemctl reload nginx
  ```
- **Servers:** Dell iDRAC 9 (Redfish, virtual media over HTTP), BIOS in UEFI mode, the iDRAC able to
  reach the build box on port 8080, and A + PTR records for every host.

## Use

```powershell
Copy-Item esx-settings.example.json esx-settings.json   # then edit it
Copy-Item hosts.example.csv hosts.csv                   # one row per server
.\Install-EsxKickstart.ps1 -HostsCsv .\hosts.csv -DryRun
.\Install-EsxKickstart.ps1 -HostsCsv .\hosts.csv
```

To read the passwords from Vaultwarden, set `Vault.IdracItem` and `Vault.RootPasswordItem` to the item
names (each can be one item for all hosts, or a pattern such as `iDRAC {name}` / `ESXi root {name}` for one per host), then unlock the vault in the same window before the run: `$env:BW_SESSION = bw unlock --raw`.

Vaultwarden notes: the Bitwarden CLI ignores the Windows certificate store, so for a private CA export the
root CA to PEM and set `NODE_EXTRA_CA_CERTS` to it. CLI 2026.9.x can't log in to Vaultwarden 1.37.x
(`KeyIdBackfillError`, vaultwarden issue #7750); use CLI 2026.8.0 and don't run `bw update` until it's fixed.

`Mtu` in the settings (default 1500) sets vSwitch0 and vmk0 at first boot. With 9000, the readiness checks
prove jumbo frames reach the gateway before the VCF bring-up, which builds its own switch with the MTU you
give the wizard.

## Gotchas found on the way

- `python3 -m http.server` ignores Range requests, so iDRAC virtual media can't read the ISO and the
  server reports "Boot Failed: Virtual Optical Drive". nginx works.
- PowerShell 7 doesn't send credentials until the server asks for them, and the iDRAC refuses first.
  The Redfish calls use `-Authentication Basic`.
- A password piped from Windows to Linux arrives with a trailing `\r` on each line.
- The iDRAC answers `SYS518` / 503 while the server is starting; the script waits and retries.
- A reinstall gives the host new SSH host keys; the script removes the old ones from `known_hosts`.
- ESX runs sshd with `fipsmode yes`, which refuses ed25519 keys even when they are in `authorized_keys`.
  The script uses an ECDSA P-384 key for the hosts.
- The installer warns that it can't get a DHCP address before it reads the kickstart. Harmless: the
  static address is applied from the kickstart.

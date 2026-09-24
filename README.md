# Redfish lab tools

Two PowerShell scripts for looking after Dell and HPE servers through their management controllers (Redfish). Built for a VMware Cloud Foundation home lab, written up on [rstechhub.com](https://rstechhub.com).

| Script | What it does | Works with |
|---|---|---|
| `Get-ServerInventory.ps1` | Firmware and physical-disk inventory for every server, side by side. Flags any component whose version differs between servers. Read-only. | Dell iDRAC 9 (full), iDRAC 7/8 (firmware), HPE iLO 4 |
| `Set-IdracCertificate.ps1` | Issues an iDRAC web certificate from an internal Microsoft CA: CSR on the iDRAC, signed with `certreq`, imported over Redfish. | Dell iDRAC 9 |

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- Network access to the iDRAC / iLO interfaces (HTTPS)
- An iDRAC / iLO account with administrator rights
- For `Set-IdracCertificate.ps1`: a domain-joined machine that can reach your AD CS certificate authority, with enrolment rights on the template (default `WebServer`)

## Get-ServerInventory.ps1

```powershell
.\Get-ServerInventory.ps1 -Idrac idrac1.example.com, idrac2.example.com -Ilo ilo1.example.com
```

Prompts for the iDRAC login (one shared account) and the iLO login, then shows:

- **Firmware**: one row per component (BIOS, iDRAC, NIC, storage controller, drives, ...), one column per server, and `MISMATCH` where they differ
- **Physical disks**: slot, model, type, size, firmware and health for every drive

Both tables are saved as timestamped CSVs in `.\Reports`. Run it before and after a firmware round: before to see what needs doing, after to prove every host landed on the same versions.

Notes:
- A controller in the middle of a firmware update does not answer (503 / 500). It is skipped with a warning; run again later.
- iDRAC 7 does not publish its disks over Redfish. The script reports its firmware and says so.

## Set-IdracCertificate.ps1

```powershell
.\Set-IdracCertificate.ps1 -Name idrac-host01 -IP 192.0.2.11 -Domain example.com `
    -CA "ca01.example.com\Example-Root-CA" -SetDnsName -DnsServers 192.0.2.53
```

1. (`-SetDnsName`) sets the iDRAC's own DNS name and domain. Without this, iDRAC 9 answers **400 Bad Request** when you browse to it by a name it does not recognise.
2. The iDRAC generates the key and CSR. The private key never leaves the iDRAC.
3. `certreq` submits the CSR to your CA.
4. The certificate is imported over Redfish and the iDRAC restarts (2-10 minutes; the server itself keeps running).

Why not the web upload? On some iDRAC firmware the web page rejects valid certificates (`RAC0622`, `RAC0613`, `SYS426`, `RAC0615`). The Redfish route has worked every time.

For several iDRACs with one password prompt, see the second example in the script header.

## A note on certificates and security

Both scripts skip validation of the controllers' own HTTPS certificates, because most start life with a self-signed one. Run them from a trusted management network. Once your controllers have CA-signed certificates, you can remove the trust-all block.

## Disclaimer

Provided as-is under the MIT licence. Test in a lab first. `Get-ServerInventory.ps1` is read-only; `Set-IdracCertificate.ps1` changes the iDRAC's certificate (and, with `-SetDnsName`, its DNS settings) and restarts the iDRAC.

# redfish

PowerShell over the Redfish API, for Dell iDRAC and HPE iLO. Works in Windows PowerShell 5.1 and PowerShell 7.

| Script | What it does |
|---|---|
| `Get-ServerInventory.ps1` | Firmware and physical-disk inventory across Dell iDRAC 9/7/8 and HPE iLO 4, flags version mismatches. Read-only. |
| `Set-IdracCertificate.ps1` | CA-signed iDRAC 9 web certificate: CSR on the iDRAC, signed with `certreq`, imported over Redfish. |

```powershell
.\Get-ServerInventory.ps1 -Idrac idrac1.example.com, idrac2.example.com -Ilo ilo1.example.com

.\Set-IdracCertificate.ps1 -Name idrac-host01 -IP 192.0.2.11 -Domain example.com `
    -CA "ca01.example.com\Example-Root-CA" -SetDnsName -DnsServers 192.0.2.53
```

`Get-ServerInventory.ps1` saves firmware and disk tables as timestamped CSVs in `.\Reports`. A controller mid-update answers 503/500 and is skipped with a warning. iDRAC 7 does not publish disks over Redfish.

`Set-IdracCertificate.ps1` needs a domain-joined machine with enrolment rights on your AD CS template (default `WebServer`). With `-SetDnsName` it sets the iDRAC's own DNS name first; without it iDRAC 9 returns 400 Bad Request when browsed by a name it does not know. The private key never leaves the iDRAC. Why not the web upload? Some firmware rejects valid certificates there (`RAC0622`, `RAC0613`, `SYS426`, `RAC0615`); Redfish has worked every time.

Both skip validation of the controllers' own HTTPS certificates, since most start self-signed. Run them from a trusted management network.

Blog posts: [Firmware updates on a running VCF cluster](https://rstechhub.com/lab-maintenance-firmware-updates-vcf-cluster/), [Core Infrastructure Part 4: a certificate authority](https://rstechhub.com/core-infrastructure-part-4-certificate-authority/).

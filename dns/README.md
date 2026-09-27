# dns

Windows DNS Server scripts. Run on a DNS server or domain controller as a domain admin (needs the DnsServer module).

| Script | What it does |
|---|---|
| `Import-DnsRecords.ps1` | Bulk A + PTR records from a CSV (`Zone,Name,IP`, see `records-example.csv`). Creates missing zones, never overwrites. `-WhatIf` supported. |
| `Test-DnsRecords.ps1` | Read-only check for duplicate IPs, A records without PTR, and stale PTRs. Run before a VCF deployment: the installer rejects any component whose forward and reverse records disagree. |

```powershell
.\Import-DnsRecords.ps1 -Path .\records.csv -WhatIf
.\Import-DnsRecords.ps1 -Path .\records.csv
.\Test-DnsRecords.ps1 -Zones example.internal, vcf.example.internal
```

On a multi-DC setup, a record added on one DC can take a while to show on the other. `Sync-DnsServerZone` and `Clear-DnsServerCache` on the second DC speed it up.

Blog post: [Core Infrastructure Part 3: domain controllers and DNS](https://rstechhub.com/core-infrastructure-part-3-domain-controllers/).

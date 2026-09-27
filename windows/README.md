# windows

Windows Server scripts for a vCenter template and KMS activation.

| Script | Where to run | What it does |
|---|---|---|
| `Set-TemplateBaseline.ps1` | Inside the template VM, as Administrator | RDP with NLA, ping allowed, high-performance power plan, Server Manager off at logon, time zone, optional KMS client key (GVLK). |
| `Set-KmsDnsRecord.ps1` | DNS server / DC | A + PTR for the KMS host and the `_vlmcs._tcp` SRV record, so clones activate on their own. `-WhatIf` supported. |

```powershell
.\Set-TemplateBaseline.ps1 -TimeZone 'GMT Standard Time' -KmsClientKey <GVLK for your edition>
.\Set-KmsDnsRecord.ps1 -Zone example.internal -HostName kms01 -IPAddress 192.168.10.250 -WhatIf
```

Microsoft publishes the GVLKs: https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys

Do not sysprep or domain-join the template yourself: the vCenter customization spec does both per clone. A clone showing `License Status: Notification` and error `0xC004F056` has not found a KMS host, which usually means the SRV record is missing.

Blog post: [Core Infrastructure Part 7: a Windows Server template](https://rstechhub.com/core-infrastructure-part-7-windows-server-template/).

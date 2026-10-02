# veeam

| Script | Where to run | What it does |
|---|---|---|
| `New-VeeamAdminAccess.ps1` | DC or any machine with the ActiveDirectory module, as a domain admin | Creates an AD group (`veeam-admins`) and a named admin account, adds the account to the group, and makes the group a local Administrator on the Veeam server over WinRM. Safe to re-run. |
| `Restart-VeeamServices.ps1` | The Veeam backup server, elevated PowerShell | Stops, starts or restarts every Veeam service in a safe order: database first on start, main Veeam Backup Service last on stop. Closes any open console first. Only starts services set to Automatic. Supports `-WhatIf`. |

```powershell
.\New-VeeamAdminAccess.ps1 -VeeamServer veeam01.example.internal -GroupOU "OU=Groups,DC=example,DC=internal"
```

The password for a new account is prompted for, never passed on the command line. `-GroupOU` and `-UserOU` default to the domain's Users container.

One step stays manual: in the Veeam console, Users and Roles, add `<DOMAIN>\veeam-admins` as Veeam Backup Administrator, then remove `BUILTIN\Administrators`. After that, the domain Administrator account is no longer the way into your backups.

### Restart-VeeamServices.ps1

```powershell
.\Restart-VeeamServices.ps1                     # Status (default)
.\Restart-VeeamServices.ps1 -Action Restart
.\Restart-VeeamServices.ps1 -Action Stop -WhatIf
```

Useful when a job hangs, after a component update, or when an installer complains that `Veeam.Backup.Shell.exe` is locked. Status warns about any service set to Automatic that is not running.

Blog posts: [Backing Up the Lab with Veeam, Part 1](https://rstechhub.com/veeam-lab-backups-part-1-design-backup-server/) and [Part 2](https://rstechhub.com/backing-up-the-lab-with-veeam-part-2-backups-nobody-can-delete/).

# veeam

| Script | Where to run | What it does |
|---|---|---|
| `New-VeeamAdminAccess.ps1` | DC or any machine with the ActiveDirectory module, as a domain admin | Creates an AD group (`veeam-admins`) and a named admin account, adds the account to the group, and makes the group a local Administrator on the Veeam server over WinRM. Safe to re-run. |

```powershell
.\New-VeeamAdminAccess.ps1 -VeeamServer veeam01.example.internal -GroupOU "OU=Groups,DC=example,DC=internal"
```

The password for a new account is prompted for, never passed on the command line. `-GroupOU` and `-UserOU` default to the domain's Users container.

One step stays manual: in the Veeam console, Users and Roles, add `<DOMAIN>\veeam-admins` as Veeam Backup Administrator, then remove `BUILTIN\Administrators`. After that, the domain Administrator account is no longer the way into your backups.

Blog post: Backing Up the Lab with Veeam (coming soon).

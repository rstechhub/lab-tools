# mikrotik

RouterOS 7 snippets. Paste into the switch terminal (WinBox > New Terminal, or SSH), or upload the file and run `/import <file>.rsc`. Edit addresses and names first.

| File | What it does |
|---|---|
| `add-backup-user.rsc` | Read-only group and user for automated config backups, restricted to one host, SSH key login. Pairs with `linux/switch-backup.sh`. |
| `add-breakglass-admin.rsc` | Second full-admin account, so one lost password is not a lockout. |
| `clear-logs.rsc` | Empties the memory and echo log stores, including the critical messages shown at every login. |

Passwords typed at the RouterOS command line: avoid `$`, `\`, `?` and `"`. The CLI treats `$` as a variable and `\` as an escape, so what gets stored is not what you typed. Test a new account from a second session before closing the first.

Blog post: [Nightly MikroTik config backups to Gitea](https://rstechhub.com/nightly-mikrotik-config-backups-gitea/).

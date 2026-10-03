# linux

Bash scripts for Linux hosts in the lab. Install steps and cron lines are in each script's header.

| Script | What it does |
|---|---|
| `switch-backup.sh` | Nightly MikroTik `/export` over read-only SSH (see `mikrotik/add-backup-user.rsc`), committed to Git only when something changed. |
| `prepare-ubuntu-template.sh` | Seals an Ubuntu 24.04 VM before it becomes a vSphere template: NTP, cloud-init off, installer netplan removed, new SSH host keys and machine-id per clone, logs cleared, shutdown. |
| `vault-backup.sh` | Nightly consistent backup of a Vaultwarden (Docker) install to an NFS share: SQLite `.backup` while it runs, data folder, compose file and TLS cert, with retention. |

The vault backup stays encrypted with each user's master password, but treat it as sensitive anyway: restrict the NFS share to the vault host.

Blog post: [Nightly MikroTik config backups to Gitea](https://rstechhub.com/nightly-mikrotik-config-backups-gitea/).

Ubuntu template post: [Core Infrastructure Part 8](https://rstechhub.com/core-infrastructure-part-8-ubuntu-template/).

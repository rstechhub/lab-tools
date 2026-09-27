# RouterOS 7: read-only account for automated config backups (see linux/switch-backup.sh).
# The group can log in over SSH and read config, nothing else. Without the 'sensitive'
# policy, /export leaves secrets out, which is what you want in Git.
# Edit the address to your backup host, then paste into the switch terminal or:
#   /import add-backup-user.rsc
/user group add name=backup policy=ssh,read comment="config backups"
/user add name=netbackup group=backup address=192.0.2.28/32 comment="config backup host"
# Then add the backup host's public key (one line, from ~/.ssh/id_ed25519.pub):
# /user ssh-keys add user=netbackup key="ssh-ed25519 AAAA... netbackup@backuphost"

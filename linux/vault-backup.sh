#!/bin/bash
# Nightly backup of a Vaultwarden (Docker) install to an NFS share.
# Takes a consistent copy of the SQLite database while Vaultwarden runs, packs it with
# the rest of the data folder, the compose file and the TLS cert, and keeps N days.
# The vault data stays encrypted with each user's master password.
#
# Install:
#   sudo apt -y install nfs-common sqlite3
#   echo 'nas.example.com:/mnt/pool/backups /mnt/backup nfs defaults,_netdev,noauto,x-systemd.automount 0 0' | sudo tee -a /etc/fstab
#   sudo cp vault-backup.sh /usr/local/bin/ && sudo chmod 700 /usr/local/bin/vault-backup.sh
#   echo '30 2 * * * root /usr/local/bin/vault-backup.sh >> /var/log/vault-backup.log 2>&1' | sudo tee /etc/cron.d/vault-backup
set -euo pipefail

SRC=/opt/vaultwarden            # folder with compose.yaml, data/ and ssl/
DST=/mnt/backup/vaultwarden      # on the NFS mount
KEEP_DAYS=14

ts=$(date +%F_%H%M)
mkdir -p "$DST"
sqlite3 "$SRC/data/db.sqlite3" ".backup '/tmp/db-$ts.sqlite3'"
tar czf "$DST/vault-$ts.tar.gz" --exclude='db.sqlite3*' -C "$SRC" data compose.yaml ssl -C /tmp "db-$ts.sqlite3"
rm -f "/tmp/db-$ts.sqlite3"
find "$DST" -name 'vault-*.tar.gz' -mtime +"$KEEP_DAYS" -delete
echo "$(date -Is) backup ok: vault-$ts.tar.gz"

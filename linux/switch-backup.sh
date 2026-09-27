#!/bin/bash
# Nightly MikroTik config backups into a Git repository.
# Exports each switch over SSH with a read-only account, strips the timestamp line
# RouterOS adds, and commits only when something actually changed.
# Written up at https://rstechhub.com/nightly-mikrotik-config-backups-gitea/
#
# On each switch (RouterOS 7), create a read-only group and user restricted to the backup host:
#   /user group add name=backup policy=ssh,read
#   /user add name=netbackup group=backup address=<backup-host-ip>/32
#   /user ssh-keys add user=netbackup key="<contents of the backup host's id_ed25519.pub>"
# Note: /export without the 'sensitive' policy leaves secrets out, which is what you want in Git.
#
# Cron (as the backup user's owner): 15 2 * * * /usr/local/bin/switch-backup.sh >> /var/log/switch-backup.log 2>&1
set -u

REPO=/home/netbackup/lab-configs          # clone with a deploy key that has write access
SWITCHES="core:192.0.2.1 access:192.0.2.3 oob:192.0.2.4"   # name:ip pairs

cd "$REPO" || exit 1
git pull -q --ff-only || { echo "$(date -Is) git pull failed"; exit 1; }
mkdir -p mikrotik
failed=""
for s in $SWITCHES; do
  name=${s%%:*}; ip=${s#*:}
  if ssh -o BatchMode=yes -o ConnectTimeout=15 netbackup@"$ip" /export > "mikrotik/$name.tmp" 2>/dev/null && [ -s "mikrotik/$name.tmp" ]; then
    tr -d '\r' < "mikrotik/$name.tmp" | sed '1{/^# .* by RouterOS/d}' > "mikrotik/$name.rsc"
  else
    failed="$failed $name"
  fi
  rm -f "mikrotik/$name.tmp"
done
git add mikrotik/*.rsc
if git diff --cached --quiet; then
  echo "$(date -Is) no changes${failed:+, failed:$failed}"
else
  git commit -q -m "Nightly switch backup $(date +%F)${failed:+ (failed:$failed)}"
  git push -q && echo "$(date -Is) committed and pushed${failed:+, failed:$failed}"
fi

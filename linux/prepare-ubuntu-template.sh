#!/usr/bin/env bash
# prepare-ubuntu-template.sh - seal an Ubuntu 24.04 VM before converting it to a vSphere template
#
# Usage (on the VM, as root):
#   sudo bash prepare-ubuntu-template.sh [ntp-server ...]
#   e.g. sudo bash prepare-ubuntu-template.sh dc01.example.internal dc02.example.internal
#
# Clones are expected to be named and addressed by a vCenter guest customization spec
# (open-vm-tools), so this script:
#   - points systemd-timesyncd at the NTP servers given (skipped if none)
#   - cleans apt caches and unused packages
#   - disables cloud-init and removes the installer's cloud-init and netplan files
#   - deletes the SSH host keys and adds a first-boot service that generates new ones
#   - empties /etc/machine-id so every clone gets its own
#   - truncates logs, clears temp files and shell history
#   - shuts the VM down
# Convert the VM to a template straight after. Do not power it on again first.
#
# Changes configuration and deletes data on the VM it runs on. Run it on the template VM only.
# https://rstechhub.com/core-infrastructure-part-8-ubuntu-template/   MIT licence
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

if [[ $# -gt 0 ]]; then
  echo "== Time sync: $*"
  mkdir -p /etc/systemd/timesyncd.conf.d
  printf '[Time]\nNTP=%s\n' "$*" > /etc/systemd/timesyncd.conf.d/ntp.conf
else
  echo "== No NTP servers given, leaving timesyncd as it is"
fi

echo "== Packages"
apt-get -y autoremove --purge
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "== cloud-init off (vCenter customization does the naming and IP)"
touch /etc/cloud/cloud-init.disabled
rm -f /etc/cloud/cloud.cfg.d/99-installer.cfg \
      /etc/cloud/cloud.cfg.d/90-installer-network.cfg \
      /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg
cloud-init clean --logs || true

echo "== Remove the installer's network config (clones get theirs from the customization spec)"
rm -f /etc/netplan/50-cloud-init.yaml /etc/netplan/00-installer-config*.yaml

echo "== New SSH host keys on each clone's first boot"
rm -f /etc/ssh/ssh_host_*
cat > /etc/systemd/system/regen-ssh-host-keys.service <<'UNIT'
[Unit]
Description=Generate SSH host keys on first boot
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable regen-ssh-host-keys.service

echo "== Unique machine-id per clone"
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

echo "== Logs, temp files, history"
journalctl --rotate && journalctl --vacuum-time=1s
find /var/log -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' \) -delete
find /var/log -type f -exec truncate -s 0 {} \;
rm -rf /tmp/* /var/tmp/*
rm -f /root/.bash_history /home/*/.bash_history

echo "== Done. Shutting down - convert to template next."
sleep 3
shutdown -h now

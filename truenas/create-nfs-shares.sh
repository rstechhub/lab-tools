#!/bin/bash
# Creates datasets and NFS shares for vSphere and backups on TrueNAS SCALE (25.x),
# binds NFS to the storage IP and starts the service. Existing share definitions are
# removed first (the data in the datasets is not touched).
# Written up at https://rstechhub.com/truenas-scale-dell-r620-part-5-storage-vlan-dac-certificate/
#
# Notes:
# - maproot=root is needed: ESXi, the vCenter appliance and Veeam all write as root.
# - Access control is the allowed networks list, so keep it tight. Narrow to single
#   hosts once the clients exist.
# - The TrueNAS shell is zsh: paste commands without '#' comment lines, or run this file.
set -euo pipefail

POOL=tank
STORAGE_IP=192.168.48.100
STORAGE_NET=192.168.48.0/24
MGMT_NET=192.168.10.0/24

create_dataset() {  # name recordsize
  if ! sudo midclt call pool.dataset.query "[[\"id\",\"=\",\"$POOL/$1\"]]" | grep -q "\"$POOL/$1\""; then
    sudo midclt call pool.dataset.create "{\"name\":\"$POOL/$1\",\"share_type\":\"GENERIC\",\"recordsize\":\"$2\"}" > /dev/null
    echo "created dataset $POOL/$1 (recordsize $2)"
  else
    echo "dataset $POOL/$1 exists"
  fi
}
create_dataset vmware 64K
create_dataset vcenter-backup 128K
create_dataset veeam 1M

for id in $(sudo midclt call sharing.nfs.query | python3 -c 'import sys,json;print(" ".join(str(s["id"]) for s in json.load(sys.stdin)))'); do
  sudo midclt call sharing.nfs.delete "$id" > /dev/null
done

share() {  # path comment networks-json
  sudo midclt call sharing.nfs.create "{\"path\":\"/mnt/$POOL/$1\",\"comment\":\"$2\",\"networks\":$3,\"maproot_user\":\"root\",\"maproot_group\":\"root\"}" > /dev/null
  echo "shared /mnt/$POOL/$1 to $3"
}
share vmware "ESXi datastore" "[\"$STORAGE_NET\"]"
share vcenter-backup "vCenter file backup" "[\"$MGMT_NET\",\"$STORAGE_NET\"]"
share veeam "Veeam repository" "[\"$MGMT_NET\",\"$STORAGE_NET\"]"

sudo midclt call nfs.update "{\"bindip\":[\"$STORAGE_IP\"],\"protocols\":[\"NFSV3\",\"NFSV4\"]}" > /dev/null
sudo midclt call service.update nfs '{"enable": true}' > /dev/null
sudo midclt call --job service.control START nfs > /dev/null

showmount -e "$STORAGE_IP"

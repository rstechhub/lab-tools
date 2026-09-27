# truenas

Shell scripts for TrueNAS SCALE 25.x. They use the middleware (`midclt`), so the config is stored properly and survives reboots. Run in the TrueNAS shell (System > Shell) or over SSH as an admin with sudo. Edit the variables at the top first.

| Script | What it does |
|---|---|
| `set-storage-vlan.sh` | Tagged storage VLAN on one physical NIC, jumbo frames, and makes it the management and default-gateway network. Commits with rollback disabled: have the iDRAC/IPMI console open. |
| `create-nfs-shares.sh` | Datasets for vSphere, vCenter backups and Veeam, NFS shares restricted to your networks, NFS bound to the storage IP, service started. |

```bash
sudo bash set-storage-vlan.sh
sudo bash create-nfs-shares.sh
```

Gotchas from the lab:

- The TrueNAS shell is zsh. Pasting lines that start with `#` fails, so run the file instead of pasting it.
- `midclt call` jobs need `--job` (two dashes).
- A pool imported from the shell with `zpool import` is unknown to the middleware and disappears on every reboot. Import it with Storage > Import Pool, or `midclt call --job pool.import_pool`.
- Once you save any interface, TrueNAS stops configuring the others by DHCP. Move the gateway in the same change or you lose the box.

Blog post: [TrueNAS Scale on a Dell R620, Part 5](https://rstechhub.com/truenas-scale-dell-r620-part-5-storage-vlan-dac-certificate/).

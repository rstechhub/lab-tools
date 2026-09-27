# vmware

PowerCLI scripts. Connect first with `Connect-VIServer`.

| Script | What it does |
|---|---|
| `Add-NfsDatastore.ps1` | Adds a VMkernel adapter on the storage VLAN, checks the path with a jumbo-frame ping (8972 bytes, don't fragment), then mounts an NFS 4.1 datastore. `-WhatIf` supported. |

```powershell
Connect-VIServer vcenter.example.internal
.\Add-NfsDatastore.ps1 -VMHost esx01.example.internal -VSwitch vSwitch0 -VlanId 48 `
    -VmkIP 192.168.48.10 -NfsServer 192.168.48.100 -NfsPath /mnt/tank/vmware -DatastoreName nfs-vmware
```

Why a separate vmk: without one, NFS leaves through the management vmk to the default gateway and gets routed between VLANs, often by a switch CPU, and loses jumbo frames on the way. Also check the management vmk's subnet mask. A mask wider than the real subnet (a /16 on a /24 network, say) makes ESXi think the NAS is on the management network and it will skip the storage vmk.

The vSwitch and the physical switch ports must already be at MTU 9000. VMs cannot use a VMkernel port group; create a normal VM port group on the same VLAN if a VM (a backup server, say) needs the storage network too.

Blog post: [TrueNAS Scale on a Dell R620, Part 5](https://rstechhub.com/truenas-scale-dell-r620-part-5-storage-vlan-dac-certificate/).

# iSCSI target on the storage guest

OpenBSD has **no iSCSI target in the base system**. Block-level storage for the
lab is therefore an optional extra that needs a package:

```sh
pkg_add tgt                     # the port of the Linux target framework
```

Everything up to that point — NFS and Samba — is already configured in this
tree. This document exists so the decision, the commands and the pf rules are
written down rather than rediscovered.

## When to use iSCSI instead of NFS

| Want | Use |
| ---- | --- |
| Share files between guests | NFS (`/etc/exports`) or Samba |
| A guest that needs a *disk* (its own filesystem, its own fsck) | iSCSI |
| Backups of a whole filesystem image | iSCSI, then `dd`/`dump` the LUN |
| Anything a Windows client must mount without extra software | Samba |

For this lab the realistic use is a **LUN per guest for the database's WAL
volume**, so that the WAL is on a filesystem the db guest controls.

## Layout on the storage guest

Create the backing files (or, better, dedicated partitions on the second disk
suggested in `hostname.vio0`):

```sh
mkdir -p /export/iscsi
vmctl create -s 10G /export/iscsi/db-wal.img      # on the host, then scp it in
# or, on the guest, with a sparse file:
dd if=/dev/zero of=/export/iscsi/db-wal.img bs=1m count=0 seek=10240
```

Files are simpler than partitions and can be grown later, which matters more in
a lab than the last few percent of performance.

## Target configuration

`tgt` uses `/etc/tgt/targets.conf`:

```
# /etc/tgt/targets.conf — storage guest
<target iqn.2026-10.lab.example.org:storage:db-wal>
	backing-store /export/iscsi/db-wal.img
	# One initiator, by IP: the lab has no CHAP secrets to distribute and the
	# pf rules already restrict who can reach 3260.
	initiator-address 10.10.50.12
	# Write-through: an iSCSI target that acknowledges writes it has not
	# committed is a data-loss generator when the guest reboots.
	write-cache off
</target>
```

Enable and verify:

```sh
rcctl enable tgt
rcctl start tgt
tgtadm --mode target --op show
```

## Client side (db guest)

```sh
# discover, then attach
iscsictl discover -v 10.10.50.13
iscsictl -A -h 10.10.50.13 -n iqn.2026-10.lab.example.org:storage:db-wal
iscsictl -L                       # shows the attached LUN and its sd device

# one-time: newfs the LUN, then mount it
newfs /dev/rsd2a
mount /dev/sd2a /var/postgresql/wal
```

Add the corresponding line to the db guest's `/etc/fstab` **after** confirming
the device name is stable (it will not be, if other disks are added — which is
why people use `disklabel -h` DUIDs in fstab rather than `/dev/sd2a`).

## pf rules

The rules already in `vms/storage/etc/pf.conf` need one addition on the storage
side, and the mirror of it on the db side:

```
# storage guest: allow the db guest to reach the target
pass in quick proto tcp from 10.10.50.12 to $me port 3260 keep state
```

```sh
# db guest
pass out quick proto tcp from $me to 10.10.50.13 port 3260 keep state
```

The gateway's `pf.conf` needs nothing: SRV-to-SRV traffic is already allowed,
and iSCSI never leaves the segment.

## Notes

* Keep the LUN off the same physical disk as the NFS exports if you can — the
  point of block storage is usually performance isolation.
* `tgt` can also serve CD-ROM images (`backing-store type=cdrom`), which is a
  convenient way to hand an ISO to a guest without putting it in `/var/vmm`.
* There is no multipath in this setup. If you want it, run two targets on
  separate guests and let the client do `iscsictl -A` twice; the extra
  complexity is rarely worth it for a lab.

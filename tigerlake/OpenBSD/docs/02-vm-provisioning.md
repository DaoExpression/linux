# Provisioning the guests

Seven OpenBSD guests on the gateway, each built the same way: an unattended
install over a dedicated provisioning network, then configuration from this
repository. The install and the configuration are separate on purpose — an
install can be redone in ten minutes, and the configuration is the part worth
versioning.

## How the unattended install works

```
gateway                                        installing guest
  veb2 10.10.99.1/24  <── vmd switch "install" ──>  vio0 (dhcp)
  dhcpd:  next-server 10.10.99.1                     bsd.rd
          filename "auto_install"                      │
  httpd:  /install.conf  ──────────────────────────>   │  "auto_install" in
          base77.tgz etc  ─────────────────────────>   └─> the lease makes
                                                           the installer run
                                                           unattended
```

Two design choices matter:

* **Our own `dhcpd(8)` instead of vmd's `-L` local interfaces.** vmd's local
  interfaces hand out `100.64.<id>.2` addresses, which depend on the VM's
  runtime ID — the `install.conf` would have to be generated after the VM
  starts. Using a fixed subnet makes the whole step deterministic.
* **The sets come from the gateway, not the internet.** An installing guest has
  no route anywhere except 10.10.99.1, so a bad install cannot phone home, and
  provisioning works on a dead WAN.

## 1. Fill in the answers

Each guest has `vms/<name>/install.conf`. Before the first install:

```sh
# password hashes (run on any OpenBSD host; prompts twice)
encrypt                      # -> paste the $2b$... into install.conf
# the SSH public key goes into "Public SSH key for user admin"
```

Also decide the guest's disk size now; `vm.conf` and the addressing plan expect
12–40G depending on the role, and growing a qcow2 later is easy but not free.

## 2. Get the sets onto the gateway

```sh
ssh gw 'doas /usr/local/sbin/fetch-sets.sh'          # or: make sets GW=gw
```

This downloads `bsd.rd` plus the release sets into
`/var/www/htdocs/install` and verifies `SHA256.sig` with the release key. If
your mirror is not `cdn.openbsd.org`, pass `-m`.

## 3. Deploy the host tree

The provisioning scripts and the per-guest answers live in `host/`:

```sh
scripts/deploy.sh host gw.lab.example.org
```

That also copies `vms/<name>/install.conf` to
`/var/www/htdocs/install/install.conf.<name>` on the gateway.

## 4. Create and install a guest

```sh
ssh gw
doas /usr/local/sbin/provision-vm.sh bastion      # create disk + start bsd.rd
doas vmctl console bastion-install                # watch it; leave with "~."
```

The installer partitions the disk, fetches the sets from 10.10.99.1, installs,
and reboots into the new system by itself. When it is sitting at a login prompt
it is finished.

Do the guests **one at a time** while you are learning the flow: `dhcpd` serves
one address per guest and the httpd log is much easier to read that way. Once it
is boring, `vmctl start` several and let `staggered start` (see `vm.conf`)
serialise the disk I/O.

## 5. Move the guest onto its real network

```sh
doas /usr/local/sbin/provision-vm.sh -f bastion    # stops the install VM
```

Then deploy its configuration from the repository:

```sh
scripts/deploy.sh bastion bastion.lab.example.org
```

This replaces the install-time `hostname.vio0` (a DHCP address on the install
network) with the static address from the addressing plan, and installs the
guest's `pf.conf`, `sshd_config`, service configuration and `rc.conf.local`.

Finally start it under its real name, which attaches it to its switch per
`vm.conf`:

```sh
ssh gw 'doas vmctl start bastion && doas vmctl console bastion'
```

## 6. Verify a guest

```sh
# from the gateway
doas vmctl status
ssh 10.10.50.10 'uname -a; ifconfig vio0; doas pfctl -sr | head'
ssh 10.10.50.10 'doas rcctl ls on'

# the paths that must work
ping -c2 10.10.50.10                    # gateway -> guest
dig @10.10.50.11 www                     # guest -> dns VM (once dns is up)
ssh -J admin@gw.lab.example.org admin@10.10.50.10    # through the bastion
```

## 7. Order to build them in

The dependency order is not the same as the addressing order:

| Order | Guest | Why here |
| --- | --- | --- |
| 1 | `dns` | everything else wants to resolve names |
| 2 | `bastion` | the way in for everything after this |
| 3 | `storage` | backups and scratch space for the rest |
| 4 | `db` | the web VM needs it |
| 5 | `web` | needs `db`; gives relayd a backend |
| 6 | `mail` | its own certificates, and the zone must be live first |
| 7 | `mon` | it is easier to monitor guests that already exist |

`make deploy-all GW=gw.lab.example.org` pushes configuration to all seven once
they are built; it does not create them.

## 8. Rebuilding one guest

```sh
doas /usr/local/sbin/provision-vm.sh -w db      # deletes the disk, asks first
doas /usr/local/sbin/provision-vm.sh db
# ... watch the install ...
doas /usr/local/sbin/provision-vm.sh -f db
scripts/deploy.sh db db.lab.example.org
doas vmctl start db
```

Restore the data from `/export/backup` on the storage guest afterwards; the
backup script is the only thing in the lab that remembers what was on the disk.

## Known rough edges

* **The install network is not isolated from the rest of the lab by hardware** —
  only by `pf.conf`. The provisioning rules there block guest-to-lab traffic on
  `veb2`, but if you leave a machine on that subnet permanently, review them.
* **`mountd(8)` uses a port from the reserved range.** NFS through the gateway
  needs that port allowed in both firewalls; find it with
  `rpcinfo -p 10.10.50.13` and add it to `nfs_ports`. This is the most common
  "NFS works locally but not across the lab" cause.
* **`vmctl start` cannot change a running VM.** Stop it, `vmctl reload`, start
  it again. Half of the confusion in every vmd troubleshooting session is this.

# Installing the gateway

Target: one bare-metal machine, OpenBSD **7.7**, two NVMe disks, running `pf`
plus the services in `host/etc/`. Work through this once; after that the box is
rebuilt from this repository, not by hand.

`REPLACE-ME` and `lab.example.org` appear throughout the tree — decide the
domain and the addresses *before* the first install, because the DNS zone,
certificates, mail and the firewall all have to agree.

## 1. Firmware

| Setting | Value | Why |
| --- | --- | --- |
| VT-x / SVM | **on** | `vmm(4)` will not attach without it |
| Secure Boot | off | OpenBSD's bootloader is unsigned |
| Hyperthreading | on | fine; pin vCPUs later if you measure a problem |
| Boot mode | UEFI preferred, CSM also fine | both install identically |
| Console redirect | optional | `Change the default console to com0` during install if there is no keyboard |

Check after installing that virtualisation is visible:

```sh
dmesg | grep -i -e vmx -e svm
```

## 2. Disks

Two NVMe disks, mirrored with `softraid(4)` so that a single disk failure is a
non-event, with `/var/vmm` on its own partition so that runaway guest images
cannot fill `/var`.

```sh
# From the installer shell, or after booting bsd.rd with (S)hell:
#
#   Layout per disk (labels, not sizes in the disklabel, are what the fstab
#   template in host/etc/fstab expects):
#     a  /            2G
#     b  swap         4G
#     d  /var         16G
#     e  /tmp         4G
#     f  /var/vmm     rest
#
disklabel -E sd0        # create the partitions above, type 4.2BSD
disklabel -E sd1
bioctl -c 1 -l sd0a,sd1a softraid0     # and repeat per partition pair, or
                                       # use one big mirror plus disklabel
```

Simpler alternative, if you would rather not mirror: one disk, same partition
layout, and accept that a failure means a restore from the backup on the
storage guest.

The mirror is what `/etc/fstab` in this tree documents. Install-time `/etc/fstab`
is authoritative — never copy this repository's copy over it (`deploy.sh` lists
it as protected for that reason).

## 3. Interface names

The tree assumes:

| Role | Name | Notes |
| --- | --- | --- |
| WAN | `igc0` | Tiger Lake boards are usually `igc(4)` or `em(4)` |
| LAN trunk | `igc1` | carries VLANs 10–50 |

Confirm with `ifconfig -a`. If the names differ, rename the files under
`host/etc/`, and update `ext_if`/`trunk_if` in `host/etc/pf.conf`. Everything
else refers to the VLAN and veb names, which do not change.

Also fix `host/etc/myname` (the FQDN) and `host/etc/hosts`.

## 4. Install

Answer the installer as usual, with two specifics:

* **Network**: do not configure the LAN interfaces. `dhcpleased` gets the WAN up
  on the first boot from `hostname.igc0`; the VLANs and bridges are configured
  by the files in this tree.
* **Sets**: `bsd`, `bsd.rd`, `base`, `comp`, `man`, `sys` are enough on the
  gateway. Add `x*` only if you want a graphical console.

Create the admin account and the two service accounts the tree references:

```sh
# admin: the human account, wheel group, key-only login
useradd -m -c "Lab Administrator" -G wheel -s /bin/ksh admin
mkdir -p /home/admin/.ssh && chmod 700 /home/admin/.ssh
# paste the operator's public key
vi /home/admin/.ssh/authorized_keys && chmod 600 /home/admin/.ssh/authorized_keys
chown -R admin:admin /home/admin/.ssh

# backup: non-interactive, used by the backup scripts
useradd -d /var/backup -s /sbin/nologin backup
install -d -o backup -g wheel -m 700 /var/backup

# monitor: non-interactive, used by the monitoring guest
useradd -d /var/monitor -s /sbin/nologin monitor
install -d -o monitor -g wheel -m 700 /var/monitor
```

## 5. Deploy the tree

From the machine that holds this repository:

```sh
make lint                                   # catch macro/brace mistakes first
scripts/deploy.sh host gw.lab.example.org   # or: make deploy-host GW=gw...
```

Then on the gateway, validate and activate:

```sh
doas pfctl -nf /etc/pf.conf          # must print nothing
doas nsd-checkzone lab.example.org /var/nsd/zones/lab.example.org.zone
doas nsd-control-setup               # once, for nsd's control socket
doas sshd -t
doas dhcpd -n vlan20 vlan30 veb2
doas httpd -n ; doas smtpd -n ; doas unwind -n ; doas ntpd -n ; doas iked -n ; doas relayd -n
doas vmctl reload                    # parses vm.conf; must print nothing
```

Fix anything the validators complain about *before* enabling the daemons: a
ruleset that fails to load at boot leaves the gateway wide open.

## 6. Bring it up in this order

The order matters because later steps depend on earlier ones existing:

```sh
doas sh /etc/netstart                  # all hostname.* files at once
doas rcctl restart dhcpleased slaacd   # WAN address and default route
ifconfig igc0 | grep inet              # confirm you have a route off-net
doas rcctl start pf                    # 4. above already loaded the ruleset

doas rcctl enable nsd unwind ntpd snmpd syslogd
doas rcctl start nsd unwind ntpd snmpd syslogd
doas nsd-control reload                # load the zone

doas sysctl net.inet.ip.forwarding     # expect: net.inet.ip.forwarding=1
doas rcctl enable dhcpd radvd
doas rcctl start dhcpd radvd           # now USERS and GUEST come up

doas rcctl enable vmd
doas rcctl start vmd
doas usermod -L vmd vmd                # apply /etc/login.conf.d/vmd-limits
doas vmctl status                      # should list the seven guests, all stopped
```

`iked`, `relayd`, `httpd` and `smtpd` come last: they need the WAN address and
the DMZ guests. See `docs/03-service-map.md` and then
`docs/02-vm-provisioning.md`.

## 7. First-boot checklist

| Check | Command | Expected |
| --- | --- | --- |
| WAN address | `ifconfig igc0` | ISP address, default route present |
| VLANs | `ifconfig vlan10 vlan20 vlan30 veb0 veb1` | all `up`, addresses per the plan |
| Firewall | `pfctl -si \| head -5` | `Status: Enabled`, non-zero states |
| Public rules | `pfctl -sn` | NAT and the two mail redirects |
| DNS | `dig @10.10.50.1 www.lab.example.org` | answers from the local zone |
| DHCP | `tcpdump -n -i vlan20 port 67` | offers on the USERS segment |
| Time | `ntpctl -s status` | `synced` |
| Guests | `vmctl status` | seven guests, none running yet |

## 8. Things this tree deliberately does not do

* **IPv6 prefix delegation.** There is no DHCPv6-PD client in the base system,
  so the internal segments use a ULA prefix (`fd00:10:10::/48`) announced by
  `radvd(8)`, and IPv6 DNS is not announced at all (clients use the DHCPv4
  resolvers). Adding it means running a DHCPv6 server from packages.
* **CARP/failover.** `sysctl.conf` has the `net.inet.carp.preempt` line ready
  but commented; a second gateway is a separate project.
* **ALTQ.** The queueing block in `pf.conf` is commented: it only loads if the
  kernel carries ALTQ, and a ruleset that fails to parse is worse than no
  shaping.

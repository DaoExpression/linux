# Addressing plan

Lab supernet: `10.10.0.0/16`. Domain: `lab.example.org` (replace with a domain
you control — it appears in DNS zones, TLS certs, mail and `acme-client.conf`).

## Layer 3 segments on the gateway

| Zone  | VLAN | Host iface | Subnet          | gw        | DHCP        | Notes                                    |
| ----- | ---- | ---------- | --------------- | --------- | ----------- | ---------------------------------------- |
| MGMT  | 10   | `vlan10`   | 10.10.10.0/24   | .1        | static      | admin hosts, SSH to `gw`                 |
| USERS | 20   | `vlan20`   | 10.10.20.0/24   | .1        | `dhcpd`     | wired clients / AP SSID `lab`            |
| GUEST | 30   | `vlan30`   | 10.10.30.0/24   | .1        | `dhcpd`     | untrusted, internet only, client isolation |
| DMZ   | 40   | `veb0`     | 10.10.40.0/24   | .1        | static      | internet-facing VMs (`web`, `mail`)      |
| SRV   | 50   | `veb1`     | 10.10.50.0/24   | .1        | static      | internal VMs                             |
| VPN   | 60   | `enc0`     | 10.10.60.0/24   | .1        | `iked` pool | IKEv2 road warriors (iked.conf)          |
| INST  | —    | `veb2`     | 10.10.99.0/24   | .1        | `dhcpd`     | guest provisioning only (vmd switch "install") |

`igc1` is an 802.1Q trunk with **no** address of its own. `vlan40`/`vlan50`
carry no address either: the gateway address lives on the `veb0`/`veb1`
aggregates that `vmd(8)` uses as VM switches, so host and guests share one
broadcast domain without a bridge loop.

## Host addresses

| Name                          | Address              | Where              |
| ----------------------------- | -------------------- | ------------------ |
| `gw.lab.example.org`          | 10.10.10.1           | MGMT               |
|                               | 10.10.20.1           | USERS              |
|                               | 10.10.30.1           | GUEST              |
|                               | 10.10.40.1           | DMZ (`veb0`)       |
|                               | 10.10.50.1           | SRV (`veb1`)       |
|                               | 10.10.60.1           | VPN (`vpn`)        |
|                               | DHCP (ISP)           | WAN (`igc0`)       |

## Guest addresses

| Guest     | Zone | Address     | Disk       | vCPU | RAM  | vmd switch |
| --------- | ---- | ----------- | ---------- | ---- | ---- | ---------- |
| `bastion` | SRV  | 10.10.50.10 | 12G qcow2  | 2    | 1G   | `srv`      |
| `dns`     | SRV  | 10.10.50.11 | 12G qcow2  | 1    | 512M | `srv`      |
| `db`      | SRV  | 10.10.50.12 | 40G qcow2  | 2    | 2G   | `srv`      |
| `storage` | SRV  | 10.10.50.13 | 40G qcow2  | 2    | 1G   | `srv`      |
| `mon`     | SRV  | 10.10.50.14 | 20G qcow2  | 2    | 1G   | `srv`      |
| `web`     | DMZ  | 10.10.40.20 | 20G qcow2  | 2    | 1G   | `dmz`      |
| `mail`    | DMZ  | 10.10.40.21 | 20G qcow2  | 2    | 2G   | `dmz`      |

Guest disk path on the host: `/var/vmm/<name>.qcow2` (see `host/etc/vm.conf`).

## Reserved ranges

| Range            | Use                                        |
| ---------------- | ------------------------------------------ |
| 10.10.20.100-199 | `dhcpd` dynamic pool, USERS                |
| 10.10.30.100-250 | `dhcpd` dynamic pool, GUEST                |
| 10.10.50.200-250 | `dhcpd` reservations for lab hardware      |
| 10.10.60.10-250  | VPN pool, handed out by `iked`/`wg`        |
| 10.10.40.100-150 | DMZ staging (spare VMs)                    |

## Public / transit

| Item                | Value                       |
| ------------------- | --------------------------- |
| WAN addressing      | DHCPv4 + SLAAC (ISP)        |
| Public v4 (example) | 203.0.113.10                |
| Public v6 prefix    | 2001:db8:1::/64 (delegate)  |
| SPF/DKIM/mail PTR   | `mail.lab.example.org`      |## DNS

Two daemons, two jobs, and the split is what makes either one replaceable:

| Role | Where | Config |
| ---- | ----- | ------ |
| Authoritative for `lab.example.org` | gateway `nsd` @ 10.10.50.1, 10.10.10.1 | `host/etc/nsd.conf`, zones in `host/var/nsd/zones/` |
| Recursion for the lab | `dns` VM `unbound` @ 10.10.50.11 | `vms/dns/etc/unbound.conf` |
| Recursion for the gateway itself | gateway `unwind` @ 127.0.0.1 | `host/etc/unwind.conf` |

Clients are pointed at 10.10.50.11 by `dhcpd(8)`; unbound carries a `stub-zone`
for the lab domain so private names never leave the lab and public names never
resolve through the internal nsd. The reverse zone for the SRV segment is
`50.10.10.in-addr.arpa`, served by the same nsd for readable logs and
traceroutes.

IPv6 DNS is not announced (see `radvd.conf`): clients use the DHCPv4 resolvers.

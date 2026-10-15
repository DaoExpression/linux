# OpenBSD lab — configuration tree

Declarative configuration for an OpenBSD lab: **one bare-metal gateway host**
(`gw`) running `pf`/routing plus local network, internet and ops services, and
**seven `vmm(4)` guests** running the higher-level services.

```
host/            mirrors /etc on the gateway   (bare metal, OpenBSD 7.7)
vms/<name>/      mirrors /etc on each guest    (vmm guests)
scripts/         provisioning, deployment, validation, pf ban
docs/            install runbook, addressing plan, service map
secrets/         keys/certs, never committed (chmod 700)
```

Nothing here is applied automatically. `scripts/deploy.sh` copies a tree to a
target host. `scripts/lint-config.sh` (via `make lint`) checks what can be
checked anywhere — undefined `pf` macros, unbalanced braces, dangling file
references, shell syntax — and `make check` runs the real validators
(`pfctl -nf`, `httpd -n`, `smtpd -n`, `nsd-checkconf`, ...) on the gateway,
because those binaries only exist on OpenBSD.

## Topology

```
                 Internet
                    │
              ┌─────┴─────┐
              │  igc0 WAN │  DHCP from ISP
              └─────┬─────┘
              ┌─────┴─────────────────────────────────────────┐
              │           gw.lab.example.org  (bare metal)    │
              │   pf · dhcpleased · dhcpd · radvd · unwind    │
              │   nsd · iked · relayd · snmpd · ntpd · vmd   │
              │   igc1 = 802.1Q trunk                         │
              └─────┬─────────────────────────────────────────┘
   vlan10 ──────────┤ MGMT    10.10.10.0/24   (host .1)
   vlan20 ──────────┤ USERS   10.10.20.0/24   (host .1)
   vlan30 ──────────┤ GUEST   10.10.30.0/24   (host .1)
   vlan40 ──────────┤ DMZ     10.10.40.0/24   (host .1 via veb0)
   vlan50 ──────────┤ SRV     10.10.50.0/24   (host .1 via veb1)
   vlan60 ──────────┤ VPN     10.10.60.0/24   (iked/wg peers)
```

Guests live on the DMZ and SRV layer-2 domains, which `vmd(8)` attaches to the
`veb(4)` interfaces `veb0`/`veb1` (see `host/etc/vm.conf`).

| VM        | Zone | Address      | Services                                    |
| --------- | ---- | ------------ | ------------------------------------------- |
| `bastion` | SRV  | 10.10.50.10  | ssh jump host, `doas`, audit                |
| `dns`     | SRV  | 10.10.50.11  | `unbound` recursor + lab-zone stub (package) |
| `db`      | SRV  | 10.10.50.12  | PostgreSQL, local backups                   |
| `storage` | SRV  | 10.10.50.13  | NFS, Samba, iSCSI target notes, softraid    |
| `mon`     | SRV  | 10.10.50.14  | `snmpd`, `syslogd` collector, metrics, cron |
| `web`     | DMZ  | 10.10.40.20  | `httpd` + `relayd`, `acme-client`           |
| `mail`    | DMZ  | 10.10.40.21  | `smtpd` + `dovecot`, DKIM/SPF/DMARC         |

## Deploy order

1. `docs/01-host-install.md` — install OpenBSD 7.7 on the gateway.
2. `scripts/deploy.sh host gw.lab.example.org` — push the host tree, then
   `make check GW=gw.lab.example.org` to run the real validators on the box.
3. `docs/02-vm-provisioning.md` — create disks and autoinstall the seven guests.
4. `scripts/deploy.sh <vm> <host>` — push each guest tree (see `make deploy-all`).
5. `docs/03-service-map.md` — enable and verify each service.

`make lint` runs the offline checks (`scripts/lint-config.sh`) and works on any
machine; `make check` needs the gateway, because `pfctl -nf` and friends only
exist on OpenBSD.

## Where each decision is written down

| Question | File |
| -------- | ---- |
| Addresses, VLANs, VM sizes | `docs/00-addressing-plan.md` |
| Disk layout, softraid, first boot | `docs/01-host-install.md` |
| How guests are built unattended | `docs/02-vm-provisioning.md` |
| Which service runs where, and why | `docs/03-service-map.md` |
| Firewall policy per zone | `host/etc/pf.conf` (header comment) |
| iSCSI target notes | `vms/storage/docs/iscsi.md` |

## Placeholders to replace

| Token              | Meaning                                             |
| ------------------ | --------------------------------------------------- |
| `igc0`, `igc1`     | NIC names — check with `ifconfig`, adjust `hostname.*` |
| `lab.example.org`  | Real domain for DNS/TLS/mail; replace everywhere     |
| `10.10.0.0/16`     | Lab supernet — renumber consistently if you change it |
| `REPLACE-ME`       | Secret/hash/token to fill in before deploying        |
| `203.0.113.10`     | Example public IP (RFC 5737)                         |

Never commit `secrets/`; it is git-ignored.

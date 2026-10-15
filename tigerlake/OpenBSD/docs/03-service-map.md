# Service map

Every service is enabled through `rc.conf.local` (`daemon_flags=""` enables,
`daemon_flags=NO` disables) and configured by the file listed here.

## Gateway `gw` (bare metal)

| Service       | Config file                        | Enable key            | Role                                    |
| ------------- | ---------------------------------- | --------------------- | --------------------------------------- |
| `pf`          | `host/etc/pf.conf`                 | `pf=YES`              | filtering, NAT, redirects               |
| `pflogd`      | `host/etc/pf.conf`, `syslog.conf`  | `pflogd_flags`        | packet logging to `/var/log/pflog*`     |
| `sshd`        | `host/etc/ssh/sshd_config`         | `sshd_flags`          | admin access (MGMT only)                |
| `dhcpleased`  | `host/etc/hostname.igc0`           | `dhcpleased_flags`    | WAN DHCP client                         |
| `slaacd`      | `host/etc/hostname.igc0`           | `slaacd_flags`        | IPv6 autoconf + RDNSS                   |
| `resolvd`     | `host/etc/resolv.conf`             | `resolvd_flags`       | merges resolver info from DHCP/SLAAC    |
| `unwind`      | `host/etc/unwind.conf`             | `unwind_flags`        | recursor for *the gateway itself* (localhost only) |
| `nsd`         | `host/etc/nsd.conf`                | `nsd_flags`           | **primary** authoritative for `lab.example.org` |
| `dhcpd`       | `host/etc/dhcpd.conf`              | `dhcpd_flags`         | DHCP for USERS + GUEST                  |
| `radvd`       | `host/etc/radvd.conf`              | `radvd_flags`         | IPv6 RA for USERS + GUEST               |
| `iked`        | `host/etc/iked.conf`               | `iked_flags`          | IKEv2 road-warrior + site tunnel        |
| `relayd`      | `host/etc/relayd.conf`             | `relayd_flags`        | TLS termination / load balance to DMZ   |
| `httpd`       | `host/etc/httpd.conf`              | `httpd_flags`         | ACME `well-known` responder + status    |
| `smtpd`       | `host/etc/smtpd.conf`              | `smtpd_flags`         | mail relay for `mail.lab.example.org`   |
| `snmpd`       | `host/etc/snmpd.conf`              | `snmpd_flags`         | read-only metrics for `mon`             |
| `syslogd`     | `host/etc/syslog.conf`             | `syslogd_flags`       | central log collection from guests      |
| `ntpd`        | `host/etc/ntpd.conf`               | `ntpd_flags`          | NTP server for the lab                  |
| `pflow`       | —                                  | `pflow_flags=NO`      | off (no NetFlow collector yet)          |
| `vmd`         | `host/etc/vm.conf`                 | `vmd_flags`           | VM host                                 |
| `acme-client` | `host/etc/acme-client.conf`        | cron                  | cert issuance/renewal                   |

## Guests

### `bastion` (10.10.50.10)
`sshd` (single entry point), `doas`, `pf` default-deny, audit of admin logins.

### `dns` (10.10.50.11)
`unbound` (package) is the **recursive resolver for the whole lab**: it answers
on 10.10.50.11:53, validates DNSSEC, and carries a `stub-zone` for
`lab.example.org` pointing at the gateway's `nsd(8)`. The base `unwind(8)` stays
enabled on this guest for its *own* localhost lookups, which is why unbound binds
the LAN address rather than 127.0.0.1.

Clients get 10.10.50.11 from `dhcpd(8)` on the gateway; the zone itself lives
on the gateway under `host/var/nsd/zones/` (one writable copy, transferred by
AXFR where a second copy is wanted).

### `db` (10.10.50.12)
PostgreSQL listener on `10.10.50.12:5432` for `web`; `pf` allows only the web
+ mon hosts. `cron` runs `pg_dump` to `storage`.

### `storage` (10.10.50.13)
`exports` (NFSv4 to SRV/DMZ), `samba` (`/etc/samba/smb.conf`), `iscsi` target
notes, ZFS-style `softraid(4)` layout in `docs/01-host-install.md`.

### `mon` (10.10.50.14)
`collectd` (package) polling every host over SNMP and ICMP, `snmpd` for its own
metrics, `syslogd -u` as a second log sink, and `cron` for reports and backup
verification. Configuration in `vms/mon/etc/collectd.conf`; history under
`/var/db/collectd`, mirrored to the storage guest.

### `web` (10.10.40.20)
`httpd` (static + reverse proxy), `relayd` (TLS), `acme-client`, `pf` in
`docs`… allowed from DMZ gateway only on 80/443.

### `mail` (10.10.40.21)
`smtpd` (in/out), `dovecot` (IMAP/LMTP), DKIM signer, SPF/DMARC in the `dns`
zone. `pf` allows 25/465/587/993 from WAN via the gateway redirect.

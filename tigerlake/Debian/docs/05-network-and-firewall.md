# 05 — Network and firewall

**Read this entire document before applying anything.** This is the step that can lock you out of
the machine. Do it with a physical console available, and always load rules with `nft -c -f` first.

---

## 1. Design

```
              ┌──────────────────────── this machine ───────────────────────┐
 internet ────┤ inet filter: policy DROP                                  │
              │   · 443/tcp  → Apache (rate/per-IP limited, conntrack)    │
              │   · 80/tcp   → only if you use HTTP-01 ACME; else closed  │
              │   · 22/tcp   → wg0 ONLY (Tier 2). Never on the WAN.       │
              │   · ICMP     → echo-request rate-limited, PMTU allowed    │
              │   · DNS/NTP  → loopback only (unbound/chrony on 127.0.0.1)│
              │ output:      allowlist (Tier 2) — see §4                  │
              └───────────────────────────────────────────────────────────┘
 admin ─────── wg0 (WireGuard, UDP 51820) ──► sshd bound to the tunnel address
```

Principles:

1. **Default DROP, both directions.** Ingress is obvious; egress is what stops a compromised Apache
   from being useful (T10 in `docs/01`).
2. **No rule for a service that is not running.** Rules are a consequence of the design, not a
   wishlist. If you later install something (`docs/09`), you edit the ruleset deliberately.
3. **Rate-limit rather than block** on 443: you want the internet to reach you, but not with
   a million new connections per second per address.
4. **Log what you drop, at a rate you can actually read.**
5. **Never let a container daemon rewrite your ruleset.** Rootful Docker inserts DOCKER chains in
   iptables and silently bypasses nftables `filter`. We do not run it (`docs/09`).

## 2. The ruleset — `files/etc/nftables.conf`

Structure (read the file itself for the full text):

```nft
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    # --- dynamic sets: brute-force and abuse counters (self-expiring) ---
    set ssh4   { type ipv4_addr; flags dynamic, timeout; timeout 1h; }
    set http4  { type ipv4_addr; flags dynamic, timeout; timeout 10m; }
    set ssh6   { type ipv6_addr; flags dynamic, timeout; timeout 1h; }

    chain input {
        type filter hook input priority filter; policy drop;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

        # malformed-flag filter (silently drops scans and naive spoofing)
        tcp flags & (fin|syn|rst|psh|ack|urg) == 0 drop
        tcp flags fin,syn == fin,syn drop
        tcp flags syn,rst == syn,rst drop
        tcp flags fin,rst == fin,rst drop
        tcp flags fin,psh,urg == fin,psh,urg drop
        tcp flags syn,fin == syn,fin drop
        tcp flags syn,psh == syn,psh drop

        # — SSH: only via the admin interface, and slow it down —
        iifname "wg0" tcp dport 22 ct state new accept
        tcp dport 22 ct state new \
            meter sshmeter4 { ip saddr limit rate over 4/minute burst 3 packets } drop
        tcp dport 22 ct state new ip saddr @ssh4 limit rate over 6/minute drop

        # — HTTPS: allowed from anywhere, but bounded per source —
        tcp dport 443 ct state new \
            meter httpmeter4 { ip saddr limit rate over 60/minute burst 30 packets } drop
        tcp dport 443 accept

        # — HTTP: only for ACME validation; delete this if you use DNS-01 (recommended) —
        tcp dport 80 ct state new ip saddr limit rate over 10/minute drop
        tcp dport 80 accept

        # — ICMP/ICMPv6: just enough for path MTU discovery and neighbor discovery —
        icmp type { echo-request } limit rate 4/second accept
        icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
        icmpv6 type { destination-unreachable, packet-too-big, time-exceeded,
                      parameter-problem, nd-router-advert, nd-neighbor-solicit,
                      nd-neighbor-advert, nd-redirect } accept
        ipv6 icmp type echo-request limit rate 4/second accept

        counter log prefix "nft-drop-in: " level info limit rate 5/minute drop
    }
    ...
}
```

Points worth your attention:

- The `meter` + `limit rate over` combination is a **per-source** limiter implemented in the kernel:
  no userspace daemon needed for the common flood case.
- `iifname "wg0" tcp dport 22 ... accept` is what makes SSH invisible on the internet. If you choose
  Tier 1 (SSH on 22 exposed), replace it with the plain rate-limited accept for `tcp dport 22` and
  keep `sshguard` running (§6).
- Port 80 exists **only** for ACME. If you use DNS-01 validation (`docs/06` §4 recommends it), delete
  the two port-80 lines and close it. Fewer open ports is always better.
- The final `counter log ... drop` gives you a rate-limited record of what hits the wall. Read it
  with `journalctl -k | grep nft-drop-in`.

```bash
sudo nft -c -f files/etc/nftables.conf      # CHECK ONLY — must print nothing
sudo cp files/etc/nftables.conf /etc/nftables.conf
sudo nft list ruleset > /var/backups/nft.$(date +%F-%H%M).ruleset   # rollback point
sudo systemctl enable --now nftables
sudo nft list ruleset | head -40
```

**Rollback in one command** (keep this memorised for the "I locked myself out" moment):

```bash
sudo nft flush ruleset                      # console access only; opens everything
sudo nft -f /var/backups/nft.<stamp>.ruleset
```

## 3. Forward chain and virtualization

`files/etc/nftables.conf` ships a `forward` chain with **policy drop** and a commented block for
internal VM/container networks. When you build isolation in `docs/08`, uncomment *that block only*:

```nft
iifname "virbr0" oifname "virbr0" accept          # guests ↔ guests, same bridge, if you want it
iifname "virbr0" oifname "enp0s31f6" ct state new tcp dport { 80, 443 } accept   # explicit egress
drop                                              # everything else from guests
```

Note the asymmetry: guests get **no** DNS, **no** SSH, **no** arbitrary egress by default. If a guest
needs to resolve DNS, you explicitly forward to `127.0.0.1:53` (or your bridge address) — that is the
point of egress filtering.

## 4. Egress filtering (Tier 2) — the highest-value unusual control

Most hardening guides stop at ingress. On a public web server, a compromised service with unrestricted
egress is a ready-made C2 client and a staging point. The shipped `output` chain:

```nft
chain output {
    type filter hook output priority filter; policy drop;

    oif "lo" accept
    ct state established,related accept
    ct state invalid drop

    # the local validating resolver and NTP may reach the internet
    meta l4proto { tcp, udp } th dport 53   ip daddr @dns_upstreams accept
    meta l4proto { tcp, udp } th dport 853  ip daddr @dns_upstreams accept
    meta l4proto udp th dport 123 ip daddr @ntp_upstreams accept
    meta l4proto udp th dport 4460 ip daddr @ntp_upstreams accept     # NTS-KE

    # apt may fetch over TLS, and only as the _apt user (see the artefact for exact syntax)
    meta skuid _apt tcp dport 443 accept
    meta skuid root tcp dport 443 accept       # fwupd/ACME while you are administering

    # WireGuard handshake
    udp dport 51820 ct state new accept

    # NTP/resolver on loopback handled above; ICMP echoes for diagnosis
    icmp type echo-request accept

    counter log prefix "nft-drop-out: " level info limit rate 10/minute drop
}
```

Honest caveats:

- `meta skuid` works for direct sockets; a process that delegates downloads to a helper under a
  different uid will be blocked. Symptom: apt hangs on "Connecting". Fix: add the specific uid/host,
  do not open `tcp dport 443` for everyone.
- Replace `@dns_upstreams`/`@ntp_upstreams` with the real addresses from your `unbound.conf` and
  `chrony.conf`. Keeping them as sets means one place to edit.
- If your ACME client uses HTTP-01, it needs outbound 80. DNS-01 (recommended in `docs/06`) needs
  outbound 53/853 to the *API* endpoint over 443 — covered by the `root`/dedicated-uid rule.
- **This will break things.** Expect to iterate for the first week; that iteration is the control
  working. Log `nft-drop-out` to see exactly what tried to leave.

## 5. Admin plane with WireGuard (Tier 2)

The point is not "encryption" (SSH is already encrypted) — it is **not having SSH on the internet at
all**, and having a stable address to bind to.

```bash
sudo apt-get install --no-install-recommends wireguard-tools
sudo install -m 0700 -d /etc/wireguard
sudo cp files/etc/wireguard/wg0.conf.example /etc/wireguard/wg0.conf
# generate keys on BOTH ends; the server's private key never leaves the machine
umask 077; wg genkey | tee server.key | wg pubkey > server.pub
sudo sed -i "s|^PrivateKey = .*|PrivateKey = $(cat server.key)|" /etc/wireguard/wg0.conf
sudo chmod 0600 /etc/wireguard/wg0.conf && sudo systemctl enable --now wg-quick@wg0
sudo wg show
ip -brief addr show wg0
```

Then bind sshd to the tunnel address and drop 22 from the WAN:

```bash
echo 'ListenAddress 10.66.0.1' | sudo tee /etc/ssh/sshd_config.d/05-listen-wg.conf
sudo sshd -t && sudo systemctl reload ssh
```

**You must test from a client before you disconnect the current session:** confirm SSH over the
tunnel works, then remove the WAN 22 rule. If the tunnel ever fails, physical console access is the
only way in — that is the accepted cost of Tier 2. Keep the WireGuard client config on a USB key in a
safe, with its private key, and record the server's public key + endpoint on paper.

`files/etc/wireguard/wg0.conf.example` includes `PostUp`/`PostDown` nftables snippets so the tunnel's
interface rules exist only while the tunnel is up.

## 6. Brute-force handling (choose one, not both)

**Option A — `sshguard` (default in this repo).** ~100 KB of C, no config language, watches the
journal and adds offenders to an nftables set.

```bash
sudo apt-get install --no-install-recommends sshguard
ls /usr/lib/sshguard/                       # confirm which backends your version ships
# sshguard.conf: set BACKEND to the nftables backend present on YOUR system
sudo sed -i 's|^#*BACKEND=.*|BACKEND=/usr/lib/sshguard/sshguard-nftables|' /etc/sshguard/sshguard.conf
sudo systemctl enable --now sshguard
journalctl -u sshguard -n 5
```

**Option B — `fail2ban`.** More flexible (jails for Apache as well), but Python + a real config
surface. If you pick it, use the nftables action, not iptables:

```
# /etc/fail2ban/jail.d/paranoid.local
[DEFAULT]
banaction = nftables-multiport
banaction_allports = nftables-allports
bantime = 1h
findtime = 10m
maxretry = 4
backend = systemd
[sshd]
enabled = true
```

Either way, HTTP abuse is already bounded in-kernel by the `httpmeter4` rule, and application-level
abuse is bounded by mod_security3 + CRS (`docs/06` §5). Do not stack three tools doing the same job;
pick the kernel meter + one daemon.

## 7. Interface and service surface discipline

- **The only listening sockets you should see:**

```bash
sudo ss -tulpn | grep -v '127.0.0.1\|::1'
```

Expect exactly: `sshd` on the WireGuard address (Tier 2) or `:22` (Tier 1), `:443` on Apache,
`nftables`-visible `:80` only if HTTP-01, and `:51820/udp` for WireGuard. Anything else — a
third-party agent, `rpcbind`, `avahi`, `cups`, `systemd-resolved` on `:53` competing with unbound — is
a finding. `verify-hardening.sh` enumerates this and flags unexpected listeners.

- **IPv6**: `docs/04` §3 disables redirects and RA acceptance. If you have no IPv6 connectivity, set
  `net.ipv6.conf.all.disable_ipv6=1` and delete the `ip6`/`inet` IPv6 lines — do not run a half-broken
  IPv6 stack. The `inet` table already covers both families; the file marks the IPv6-only lines.
- **Wi-Fi**: if you must use it, the interface should be `deny` in `usbguard`'s world? no — it is
  PCI, not USB. Lock it with `rfkill` and **do not** run `wpa_supplicant` as a roaming client unless
  it is required: `systemctl disable --now wpa_supplicant`. A wired server with a Wi-Fi radio that is
  up and associating to whatever SSID is nearby is a finding on its own.

```bash
sudo rfkill list
sudo nmcli device status 2>/dev/null || true        # if NetworkManager is installed (it should not be)
sudo systemctl disable --now wpa_supplicant NetworkManager 2>/dev/null || true
```

## 8. Verification

```bash
sudo nft -c -f /etc/nftables.conf                        # syntax
sudo nft list chain inet filter input | tail -20
sudo nft list chain inet filter output | tail -20
sudo nft list sets
sudo ss -tulpn | grep -v '127.0.0.1\|::1'
sudo nft list ruleset | grep -c 'meter'                  # > 0 means rate limiting is active
journalctl -k --since '-1h' | grep -c nft-drop           # drops are being logged
bash scripts/verify-hardening.sh --tier 2 --section network
```

External check (from another machine, ideally an offsite host):

```bash
# from a client outside your network
nmap -Pn -p 1-1024 --reason <server-ip>     # expect only the ports you intended
curl -sSI https://<server> | head -3
```

Then move to `docs/06` (Apache) and `docs/07` (physical/firmware).

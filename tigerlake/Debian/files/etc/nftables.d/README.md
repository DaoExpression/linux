# /etc/nftables.d — drop-in ruleset fragments

`/etc/nftables.conf` ends with:

```
include "/etc/nftables.d/*.conf"
```

so anything you put in this directory is loaded **after** the main ruleset. That is convenient and
also the easiest way to accidentally weaken the machine, so the rules for this directory are:

1. **Never set a policy here.** A fragment that says `policy accept` (or an `accept` for a whole
   port you did not intend) silently undoes the main file. Additions only.
2. **Every fragment explains itself.** Header comment: what it allows, why, which document in
   `docs/` authorises it, and the date.
3. **Reviewed like code.** These files are in the AIDE and auditd watches
   (`-w /etc/nftables.conf -p wa`; add `-w /etc/nftables.d/ -p wa -k firewall` if you use fragments).
4. **Load-test before applying:** `sudo nft -c -f /etc/nftables.conf`.

Example - allow a container's published port from the LAN only:

```nft
# 2026-10-14: allow the app01 container's metrics port from the WireGuard admin subnet only.
# Authorised by docs/08 §2. Do not broaden this without a new entry in /etc/paranoid/local-overrides.md
table inet filter {
    chain input {
        iifname "lo" tcp dport 9100 ip saddr 10.66.0.0/24 accept
    }
}
```

Remember: the main input chain already accepts `iif "lo"` and drops everything else, so a fragment
that re-opens loopback (as above) is only safe because the source is restricted to the admin subnet.

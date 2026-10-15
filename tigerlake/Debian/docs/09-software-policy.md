# 09 — "Only necessary software": the decision procedure

This is the policy that keeps the machine from drifting into a general-purpose server over 18 months.
Every package on the host must pass this test, and the test has receipts (commands you can run).

---

## 1. The five questions, in order

Ask them in this order and stop at the first "yes".

1. **Can the host do it without new software?**
   `systemd` already provides: timers (cron), socket activation, `systemd-networkd` (DHCP/static),
   `systemd-resolved` or `unbound` (DNS), `journald` (logging/rotation), `nftables` (firewalling),
   `systemd-cryptsetup` (encryption), `systemd-nspawn` (containers), `systemd-oomd` (memory pressure).
   A startling number of "must-install" packages are redundant daemons.
2. **Is it already installed as a dependency of something essential?** Check before adding:
   `dpkg -l | grep -E '^ii' | wc -l` and `apt-cache rdepends <pkg>`. Do not install a second tool for a
   job an existing dependency already does.
3. **Can it run isolated instead of on the host?** → `docs/08`. Container or rootless VM. Default answer
   for databases, application runtimes, build tools, and anything that ships its own updater.
4. **Is it needed only once?** → install, use, purge **in the same session**:
   `sudo apt-get install --no-install-recommends fwupd && sudo fwupdmgr ... && sudo apt-get purge --auto-remove fwupd`
   This is the documented pattern for firmware updates in this repo.
5. **Otherwise**: install it with `--no-install-recommends`, in the fewest packages possible, record
   *why* in `/etc/paranoid/package-justifications`, and re-review at the quarterly audit (`docs/10`).

The justification file is not bureaucracy — it is what lets you (or future-you) tell the difference
between "load-bearing" and "someone installed it at 2 a.m. and forgot".

```bash
sudo install -d -m 0700 /etc/paranoid
sudo tee -a /etc/paranoid/package-justifications >/dev/null <<'EOF'
# package                     date        justification
# fwupd                       2026-10-14  monthly Dell BIOS/EC firmware updates (installed on demand, purged after)
# unbound                     2026-10-14  local DNSSEC-validating resolver for the host (docs/04 §11)
# sshguard                    2026-10-14  SSH brute-force response, nftables backend (docs/05 §6)
EOF
```

## 2. Apt hygiene that enforces the policy mechanically

`files/etc/apt/apt.conf.d/99-paranoid` (installed in `docs/04` §9) already sets:

- `APT::Get::Install-Recommends "false"` — the single most effective anti-bloat switch on Debian.
  **Know the cost**: some packages genuinely rely on a Recommends for functionality (e.g. a driver's
  firmware, a `-doc` you wanted). When something misbehaves right after install,
  `apt-get install --no-install-recommends -o APT::Get::Install-Recommends=true <missing-recommend>`
  is the targeted fix — not flipping the global switch back.
- `APT::Get::Install-Suggests "false"`, `AllowUnauthenticated false`, `Check-Valid-Until true`.
- Sources restricted to `main` + `non-free-firmware` (no `contrib`, no backports, no third-party repos).

```bash
# what is installed, and what is only there as a dependency
apt-mark showmanual | wc -l ; apt-mark showmanual | sort
# orphans you can remove
sudo deborphan 2>/dev/null || sudo apt-get autoremove --purge -s
# does anything actually use this?
apt-cache rdepends --installed <package> | tail -n +3
# why is this file here?
dpkg -S /usr/bin/<thing>
```

**Rules for sources:** never add a third-party apt repo to this host. If a vendor only ships a `.deb`
repo, that vendor goes in a container or a VM, or you build the package yourself on a different
machine and install it after verifying its signature/hash. A PPA-style repo on a public server is a
permanent, silent root path.

## 3. Verdicts for the things people usually want

| Want | Verdict | Notes |
|---|---|---|
| PHP / Python / Node app | **container or VM** (`docs/08`) | Never `mod_php`/`libapache2-mod-php`, never a host `python3 -m http.server` in production. |
| MariaDB / PostgreSQL | **container or VM** with its own LUKS volume | The DB is the data. Give it its own isolation and its own backup/verify loop. Do not `bind-address 0.0.0.0`. |
| Docker / rootful podman | **no** | Rewrites nftables, gives a root-equivalent socket, drags in a daemon. Rootless podman covers most needs (`docs/08` §3). |
| Git (server) | **SSH + bare repos + `git-shell`**, not a web UI | If you need a forge, put it in a VM; Gitea/GitLab are full applications with their own CVE stream. |
| `certbot` | **yes, on host** | It holds your TLS keys and needs to be the thing that reloads Apache. Minimal, purpose-built. |
| `nginx` alongside Apache | **no** | Two web servers = two parsers, two rule sets, two update streams. Pick one. |
| `fail2ban` | optional | Python + daemon. `sshguard` + kernel `meter` rules cap the same buckets (`docs/05` §6). |
| `fwupd` | **on demand** | Purge after the firmware cycle; it pulls `polkit` and a daemon. |
| `lynis`, `nmap`, `sslyze`, `testssl` | **on demand, or on your workstation** | Auditing tools on the audited host can be used against you. Run scanners from a client machine. |
| `git`, `curl`, `wget`, `vim` | **on demand** | Convenient, but `curl`+`git` on a host receiving untrusted input is a nice exfil/download pair from a compromised service. Install when updating, purge when done, at Tier 3. |
| `rsyslog` | **no** | `journald` covers it; we ship logs via `systemd-journal-upload` instead. |
| `cron` / `anacron` | **no** | `systemd` timers do the same job with better logging and sandboxing (`docs/04` §8 uses timers). |
| `unattended-upgrades` | **yes** | Security-only, no automatic reboot (`docs/04` §9). |
| Desktop environment | **never** | See `docs/08` §5. |
| `sudo` alternatives (doas) | unnecessary | `sudo` with the drop-in in `docs/04` §1 is audited, logged, and understood. |
| Monitoring agent (vendor) | **container**, ideally | Or pull-based metrics; a push agent with root is a persistent backdoor by design. |
| Backups (`restic`, `borg`) | **yes, on host** | It must read the data; put the repository key offline and use append-only on the remote. See `docs/10` §5. |

## 4. Adding software safely — the workflow

```bash
# 1. What IS this package? Size, deps, files, and provenance.
apt-cache show <pkg> | grep -E '^(Package|Version|Depends|Recommends|Section|Priority)'
apt-get install --no-install-recommends -s <pkg> | grep -E '^Inst' | wc -l    # dependency count, dry run
apt-get install --no-install-recommends -s <pkg> | grep '^Inst'               # and WHO
grep -r '<pkg>' /etc/paranoid/package-justifications 2>/dev/null

# 2. Would it open a port, install a unit, add a setuid binary, or add a cron entry?
apt-get install --no-install-recommends -s <pkg> >/dev/null
dpkg-deb -c /var/cache/apt/archives/<pkg>*.deb 2>/dev/null | grep -E 'bin/|\.service|init|sudoers|cron'
dpkg-query -W -f='${Package}\n' <pkg> && find /usr/bin /usr/sbin -perm -4000 -newer /var/lib/dpkg/status

# 3. Install it, then answer "what changed?" before you walk away
sudo apt-get install --no-install-recommends <pkg>
sudo systemctl list-units --state=running --no-pager | tail -10      # new daemon? should be one you wanted
sudo ss -tulpn | grep -v '127.0.0.1\|::1'                            # new listener? DROP it or firewall it
sudo aa-status | tail -5
sudo nft list ruleset | grep -c <newport>

# 4. Record and baseline
echo "# $(date -u +%F) <pkg> — <one-line reason>" | sudo tee -a /etc/paranoid/package-justifications
sudo aide --update --config /etc/aide/aide.conf && sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

If step 3 shows a new listener you did not intend, either firewall it off (add a `drop` counter rule so
you see attempts) or remove the package. Do not "leave it for now" — that is how a hardened host
becomes an average one.

## 5. Removing software safely

```bash
sudo apt-get purge --auto-remove <pkg>          # purge, not remove: config files outlive 'remove'
sudo systemctl --now disable <pkg> 2>/dev/null || true
sudo find /etc -name '*<pkg>*' -print           # purge leftovers
sudo find /var -name '*<pkg>*' -print
sudo deborphan
# then rebuild the AIDE baseline, because "removed" is also a change worth detecting
sudo aide --update --config /etc/aide/aide.conf
```

Two gotchas that bite people:

- **Purging a library** can silently remove the reason a service worked. Check `apt-get purge -s` first
  and read the list of packages it wants to remove *with* it.
- **`--auto-remove`** can remove dependencies you *did* want, if they were pulled in only by the package
  you are deleting. Read the dry run.

## 6. Keeping the policy honest

The policy decays unless something checks it. Add these to the monthly routine (`docs/10` §4):

```bash
apt-mark showmanual | sort > /var/log/paranoid/pkgs-manual-$(date +%F).txt
diff <(cat /var/log/paranoid/pkgs-manual-*.txt | tail -1) <(apt-mark showmanual|sort) || true
sudo ss -tulpn | grep -v '127.0.0.1\|::1'            # compare against the list in docs/05 §7
ls -la /etc/systemd/system/*.d/ /etc/systemd/system/  # new drop-ins you did not write = a finding
```

`verify-hardening.sh --section packages` automates the comparison of the manual package list against
the approved list in this document, and flags both **additions** (drift) and **missing essentials**
(someone removed something load-bearing).

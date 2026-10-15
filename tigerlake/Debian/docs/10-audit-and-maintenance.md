# 10 — Operating the machine: audit and maintenance runbook

A hardened machine that nobody updates is a ticking clock. This is the cadence — pick the schedule and
put it in a calendar, because none of it happens by itself.

---

## 1. The cadence at a glance

| When | Task | Artefact / command |
|---|---|---|
| **Daily (automated)** | AIDE check, `debsums` check, journal seal check, boot-record append, cert expiry check | `aide-check.timer`, `debsums-check.timer`, `paranoid-boot-record.service`, `paranoid-cert-check.timer` |
| **Daily (5 min, human)** | Read the security log. Yes, actually read it. | `journalctl -p warning --since today`, `ausearch -ts today \| tail`, `modsec_audit.log` |
| **Weekly** | Security updates, service restarts, log growth, firewall drop review | §3 |
| **Monthly** | Firmware check, full package review, backup restore test, AIDE baseline review | §4 |
| **Quarterly** | Key rotation review, config review against this repo, restore drill, external scan | §5 |
| **After every change** | Re-run verification, re-baseline AIDE | `verify-hardening.sh` + `aide --update` |

## 2. Safety rules for doing any of this remotely

1. **Two shells minimum**: one in which you run changes, one sitting idle. If the first dies, the second
   is your escape.
2. **nftables**: `nft -c -f` before `nft -f`, and keep `/var/backups/nft.<stamp>.ruleset` regenerated
   after every working change (`docs/05` §2).
3. **sshd**: never reload/restart over the session you are using without a second shell verified as
   working. Test with `sudo sshd -t` first, and prefer `reload`.
4. **Apache**: `apache2ctl configtest` before `systemctl reload apache2`. The shipped
   `harden-apache.sh` does this and rolls back on failure — let it.
5. **Kernel/LUKS/systemd changes**: `systemd-analyze verify`, and reboot at a time you can reach the
   console or has an OOB path (`docs/07` §7).
6. The idle shell is not enough for a *lockout*: if nftables drops your IP, no shell helps. Know your
   recovery path (physical console, IPMI-less laptop = a person physically present, or a rescue ISO
   with the LUKS header USB).

## 3. Weekly routine (about 20 minutes)

```bash
# — 1. what does the update actually contain? —
sudo apt-get update
apt list --upgradable
sudo apt-listchanges --apt 2>/dev/null | head -50     # read the changelogs, not just the count
sudo apt-get --simulate upgrade | grep -E '^(Inst|Conf)' | wc -l

# — 2. security first, then the rest —
sudo unattended-upgrade -d                            # security-only, per docs/04 §9
sudo apt-get upgrade                                  # non-security, decided by you
sudo apt-get full-upgrade -s                          # remove/install changes: READ THIS before running it

# — 3. what needs restarting because of library updates? —
sudo needrestart -b
sudo systemctl list-units --state=failed
# restart in order of least risk; Apache last, and only after configtest
sudo systemctl restart <service>; sudo systemctl reload apache2

# — 4. did anything change in a way we care about? —
sudo aide --check --config /etc/aide/aide.conf | tail -20
sudo debsums -s 2>&1 | head
journalctl -p err --since '-7d' | grep -v -E 'audit|usbguard' | head -30
journalctl -k --since '-7d' | grep -i nft-drop | sort | uniq -c | sort -rn | head
sudo ausearch -k modules -ts week | tail
sudo ss -tulpn | grep -v '127.0.0.1\|::1'
df -h / /var /var/log; journalctl --disk-usage
```

Decide explicitly, every week, about **reboots**: a kernel or microcode update is not applied until
you reboot. `needrestart -b` tells you what is pending. Plan the reboot, verify afterwards with
`uptime -s` and `verify-hardening.sh`.

## 4. Monthly routine (about an hour)

```bash
# — 1. firmware (install-on-demand pattern, docs/09 §1 q4) —
sudo apt-get install --no-install-recommends fwupd
sudo fwupdmgr refresh --force && sudo fwupdmgr get-updates
sudo fwupdmgr update                    # includes Dell BIOS/EC and, if offered, the UEFI dbx revocation list
sudo systemctl reboot                   # firmware updates need a clean reboot; verify from the BIOS screen
sudo apt-get purge --auto-remove fwupd  # per policy: no daemon left behind

# — 2. package-list review (drift detection) —
apt-mark showmanual | sort > /var/log/paranoid/pkgs-manual-$(date +%F).txt
diff /var/log/paranoid/pkgs-manual-$(ls -1 /var/log/paranoid/pkgs-manual-*.txt | tail -2 | head -1) \
     /var/log/paranoid/pkgs-manual-$(date +%F).txt
grep -c '^[^#]' /var/log/paranoid/pkgs-manual-$(date +%F).txt

# — 3. listeners and units you did not create —
sudo ss -tulpn | grep -v '127.0.0.1\|::1'
ls -la /etc/systemd/system/ /etc/systemd/system/*.d/ | grep -v '^total'
systemd-delta --type=extended | head -40

# — 4. audit rules and apparmor still loaded/unchanged —
sudo auditctl -s | grep -E 'enabled|lost|backlog'
sudo aa-status | head -5
sudo apparmor_parser --skip-cache --skip-kernel-load -Q /etc/apparmor.d/usr.sbin.apache2 2>&1 | head

# — 5. TLS and certificates —
sudo certbot certificates
sudo certbot renew --dry-run
openssl s_client -connect 127.0.0.1:443 -servername <domain> </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates -issuer

# — 6. backups: an untested backup is not a backup (see §5) —
sudo restic snapshots --latest 3

# — 7. verify the build is still the build —
sudo bash scripts/verify-hardening.sh --tier 2
```

Anything `verify-hardening.sh` reports as FAIL is either (a) drift you must explain and revert, or
(b) a deliberate change that must be reflected in this repo and re-baselined. There is no third
category; "it's fine, I'll get to it" is how the machine stops matching the guide.

## 5. Backups (design, keys, and the drill)

**What to back up:** `/etc` (all of it — it *is* the configuration), `/etc/letsencrypt`, `/var/www`,
`/var/lib/<app>`, `/etc/paranoid`, and the **LUKS header backup** (stored offline, never in the backup
repository *if* the repository is remote). What not to back up: `/var/log` (ship it instead),
`/var/cache`, `/tmp`, anything reproducible via apt.

**How:** `restic` or `borg` to a **remote, append-only** repository (SFTP target or object storage with
object-lock). Append-only matters: ransomware and a compromised root can delete normal remote backups.

```bash
sudo apt-get install --no-install-recommends restic
sudo restic -r sftp:backup@host:/srv/restic-repo init         # run once, key goes offline immediately
sudo tee /etc/paranoid/backup.env >/dev/null <<'EOF'
# 0600 root:root. The repository password lives HERE and in your offline vault — nowhere else.
# RESTIC_PASSWORD_FILE=/root/.restic-pass
EOF
sudo chmod 0600 /etc/paranoid/backup.env
sudo cp files/etc/systemd/system/paranoid-backup.{service,timer} /etc/systemd/system/
sudo systemctl enable --now paranoid-backup.timer
```

**The drill (quarterly, non-negotiable):** restore `/etc` and one site into a *rootless VM* on this
machine (`docs/08` §4) or on your workstation, boot it, and confirm the site serves. Then delete the VM.
A restore you have never performed is a hypothesis.

## 6. Recovery procedures you must have written down (on paper, offline)

1. **Lost LUKS passphrase**: header backup + passphrase = only options. P2 (detached header): if the USB
   is gone, the data is gone — restore from backup and reinstall.
2. **Machine will not boot after a kernel update**: boot the previous kernel from the systemd-boot
   menu (or a rescue ISO), then `apt-get install --reinstall linux-image-<old>`, and re-sign the UKI.
3. **Locked out by nftables**: physical console → `sudo nft flush ruleset`, then restore from
   `/var/backups/nft.<stamp>.ruleset`.
4. **Locked out by sshd config**: physical console, or boot the rescue ISO and fix `/etc/ssh/sshd_config.d/`.
5. **Secure Boot keys lost**: firmware → clear Secure Boot keys, re-enrol from the offline backup in
   `files/keys/README.md`. Without the backup: reset the firmware to factory and start `docs/03` §2 again.
6. **Suspected compromise**: stop here and go to `docs/11`. Do **not** "clean" the machine.

Keep 1–6 printed, in the same place as the recovery USB, the LUKS header backup and the LUKS passphrase
(or its location). A runbook that only exists on the machine it repairs is not a runbook.

## 7. What "healthy" looks like (baseline snapshot)

Save this output after the build is complete; diff against it monthly.

```bash
{
  echo "== $(date -u +%FT%TZ) =="
  uptime -s ; cat /proc/cmdline ; uname -r
  cat /sys/kernel/security/lockdown
  sudo bootctl status | grep -iE 'secure boot|signer'
  sudo cryptsetup status cryptroot 2>/dev/null || sudo cryptsetup status $(lsblk -no NAME /dev/nvme0n1p3 | head -1)
  sudo nft list ruleset | sha512sum
  sudo ss -tulpn | grep -v '127.0.0.1\|::1'
  lsmod | awk '{print $1}' | sort
  dpkg -l | awk '/^ii/{print $2, $3}' | sort | sha512sum
  sudo systemd-analyze security apache2 | tail -3
  findmnt -o TARGET,FSTYPE,OPTIONS
  ls -l /etc/paranoid/ /var/log/paranoid/ 2>/dev/null
} | sudo tee /var/log/paranoid/baseline-$(date +%F).txt
```

That file plus the AIDE database plus the sealed journal are your three independent "what changed?"
witnesses. If all three agree nothing changed and a service is behaving oddly, look at the service; if
they disagree, look at the machine.

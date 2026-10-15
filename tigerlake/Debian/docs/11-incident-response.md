# 11 — Incident response (compromise, lockout, or "something is wrong")

Rules first, because they are counter-intuitive and you will be under pressure:

1. **Do not power off.** The memory of a running system is the best evidence you will ever have
   (processes, keys, network state, unlinked files). Powering off destroys it (and enables cold-boot
   attacks in the opposite direction only if the attacker is the one with physical access).
2. **Do not "clean" the machine.** Removing the obvious backdoor leaves the actual access path in place
   and tells the attacker you noticed. Rebuild is the default response to confirmed compromise.
3. **Do not trust tools on the machine** for the first pass. Use `busybox`-style statics on a USB or
   read-only media if you suspect `ls`, `ps`, `ss`, `auditd`, or the kernel itself are hooked.
4. **Preserve in order of volatility**: memory → network → processes → disk → logs → firmware.
5. **Write down timestamps and everything you did.** Your own actions become the confusing part of the
   timeline.

---

## 1. Triage — is it actually a compromise?

| Signal | Likely explanation | Investigate |
|---|---|---|
| Unexpected AIDE diff in `/usr/bin` | package upgrade (check `dpkg.log`) **or** tampering | `dpkg --verify`, `debsums -s`, `journalctl -u apt`, compare with the `.deb` in `/var/cache` |
| New listener on a public address | something you installed (`docs/09` §4 step 3) or a backdoor | `ss -tulpn` → owner PID → `/proc/<pid>/{cmdline,exe,maps,environ}` |
| `nft-drop-out` storm | misconfigured app trying to reach the internet **or** C2 attempts | `journalctl -k \| grep nft-drop-out \| tail -100` |
| auditd `execve` for root you cannot explain | legitimate admin action (did *you* do it?) or privesc | `ausearch -k root-exec -ts recent` |
| Kernel oops / spontaneous reboot | hardware, bad microcode, driver **or** deliberate crash-then-persist | `journalctl -b -1 -p err`, `dmesg`, `mcelog`/EDAC (`igen6_edac` is present on this box) |
| mod_security hits with 200s | CRS on legitimate traffic **or** an actual exploitation attempt | `modsec_audit.log`, correlate with access log and app logs |
| USBGuard block events you did not create | someone touched the machine | `journalctl -t usbguard`, `ausearch -k usbguard` |

The most common answer to "am I hacked?" is: no, it is a package upgrade, a log you did not read, or an
app you installed last month. Check those three before escalating.

## 2. If you decide it is a real incident — containment

Goal: stop the bleeding without destroying evidence.

```bash
# 1. free the evidence first: memory snapshot if you can get one out
sudo dd if=/proc/kcore of=/dev/null bs=1M   # (no-op placeholder: see note below)

# Realistic options on this hardware, in order of preference:
#  a) If you can reach the machine physically: use an external Linux with LiME/AVML on a USB,
#     or at minimum `eevdf`-safe collection: `sudo systemctl stop apache2` (freezes app state,
#     keeps memory), then image.
#  b) Network-only: capture traffic and state before cutting the network:
sudo ss -tulpn > /var/log/paranoid/ir-ss.txt
sudo ss -tanp >> /var/log/paranoid/ir-ss.txt
sudo lsof -nP -i >> /var/log/paranoid/ir-lsof.txt 2>/dev/null
sudo ps auxfww > /var/log/paranoid/ir-ps.txt
sudo cat /proc/*/cmdline | tr '\0' ' ' >> /var/log/paranoid/ir-cmdlines.txt 2>/dev/null
sudo iptables-save > /dev/null 2>&1; sudo nft list ruleset > /var/log/paranoid/ir-nft.txt
sudo cp /var/log/apache2/*.log /var/log/paranoid/ 2>/dev/null
sudo ausearch --start recent > /var/log/paranoid/ir-audit.txt
sudo journalctl --since '-7d' -o short-precise > /var/log/paranoid/ir-journal.txt
```

```bash
# 2. Contain the network WITHOUT losing access (allow your admin path, drop everything else)
sudo nft -f - <<'EOF'
table inet ir {
  chain input { type filter hook input priority -10; policy accept;
                ip saddr != 10.66.0.0/24 tcp dport 443 drop
                ip saddr != 10.66.0.0/24 tcp dport 80  drop }
  chain output { type filter hook output priority -10; policy accept;
                 ct state new ip daddr != 10.66.0.2 drop }
}
EOF
# this is a *temporary overlay*: it blocks the internet while leaving your WireGuard admin path alive.
# Once you have the evidence you need, the machine's own ruleset should be tightened further.
```

Then, in most cases: **rebuild**. The sequence:

1. Rotate everything the machine held — see §4.
2. Image the disk for forensics if you care about attribution (`dd` to external storage, or `dc3dd`).
3. Wipe and reinstall per `docs/02`, with the fixes for whatever let it in.
4. Restore *data only* from a backup predating the compromise. **Verify the date.** Restoring the
   infected `/var/www` is how the compromise survives the rebuild.
5. Re-baseline AIDE, re-check with `verify-hardening.sh`, and write down the root cause.

## 3. Investigation notes for this specific build

- **Where to look first**: `/var/log/apache2/*`, `modsec_audit.log`, the sealed journal, auditd
  (`ausearch -ts recent`), AIDE diffs, and `systemd-analyze security` changes.
- **The web root is not the only candidate**: a compromised *application* in a container/VM has its own
  logs. Check the container's `/var/log` and its process list (`machinectl`/`podman`), and remember the
  isolation means the host's `/var/www` may be untouched while the app is owned.
- **Check the egress log** (`nft-drop-out`). A compromised service that suddenly tries to reach a
  hardcoded IP is a *gift* — it tells you the C2 infrastructure and confirms the compromise. This is why
  egress filtering is in `docs/05` §4.
- **Check the MEI/Thunderbolt/USB state** for physical indicators (`docs/07` §7): `lsmod`, `usbguard
  list-devices`, `boltctl list`, `/var/log/paranoid/boots`.
- **Firmware-level persistence is the worst case.** If you find reason to believe ME/firmware was
  flashed: re-flash a known-good Dell BIOS (`fwupdmgr` from a *trusted* network or a BIOS recovery USB),
  then re-enroll Secure Boot keys from offline, then rebuild the OS. Do not trust any measurement taken
  *before* the re-flash.

## 4. Key rotation checklist (do this after any confirmed compromise)

| Secret | Rotate how | Also |
|---|---|---|
| TLS private key / cert | re-issue with `certbot` (new key: `--force-renewal` after revoking, or new ACME order), and revoke the old cert | check CT logs for unexpected issuance |
| SSH host keys | `rm /etc/ssh/ssh_host_*` + `ssh-keygen -A`, then update `known_hosts` on your admin machines | key-only auth means no password rotations needed |
| SSH user keys | generate new keys on **your** machines, replace `authorized_keys` | if you used a FIDO key, it did not leak |
| LUKS passphrase | `cryptsetup luksChangeKey` (and re-generate the detached header if P2) | verify the new passphrase boots the machine |
| WireGuard keys | `wg genkey` on both ends, new `wg0.conf` | Tunnel downtime is part of the cost. |
| ACME account & DNS API tokens | revoke/reissue at your DNS provider | audit what else that token could do |
| Backup repository password/key | `restic key add`/`key remove`, or new repository | verify a restore with the new key **before** removing the old |
| Secure Boot / MOK keys | regenerate with `sbctl`, re-enroll, re-sign the UKI | keep the offline copy in sync |
| Any app credentials, DB passwords, API keys | rotate at the source | assume everything on disk was read |
| GPG/signing keys on the machine | revoke + replace | if you signed anything with them, announce the revocation |

## 5. Post-incident: don't repeat it

Write a short document — five lines is fine:

1. **Timeline**: first known-bad event, detection, containment, rebuild.
2. **Root cause**: the actual one, not "the internet".
3. **What would have prevented it**: map to a control in `docs/01` §1 (T1–T11). If the answer is "none
   of them", the threat model needs updating, not the config.
4. **What detection would have caught it sooner**: usually log shipping, a tighter AIDE rule, or an
   egress alert. Add it.
5. **What you are changing in this repo**, so the fix is not just in your head: update the relevant
   `docs/*.md` and `files/*` here, then re-run `scripts/install-hardening.sh` and `verify-hardening.sh`
   on the rebuilt host.

## 6. Lockout (self-inflicted) — the other kind of incident

Different problem, same discipline: fix it from the console, then document the trap.

| Lockout | Fix from the physical console |
|---|---|
| nftables dropped your admin path | `sudo nft flush ruleset` (or `nft delete table inet ir` for the overlay), then restore `/var/backups/nft.*.ruleset` |
| sshd will not start | `sudo sshd -t` to see the error; comment the offending drop-in in `/etc/ssh/sshd_config.d/`; `systemctl start ssh` |
| Apache will not start | `apache2ctl configtest`; `harden-apache.sh` keeps `/var/backups/apache2-<stamp>/` — restore the failing file from it |
| Boot fails after Secure Boot signing | boot the old kernel from the systemd-boot menu, re-sign the UKI (`sbctl sign`), verify with `bootctl status` |
| LUKS token (P2) missing | boot from the header backup: rescue ISO → `cryptsetup open --header /media/usb/header.img /dev/nvme0n1p3 cryptroot` → mount and boot manually, or restore the header to disk if you decide to abandon P2 |
| firmware TPM/PCR change broke journal sealing | sealing degrades safely by design (`docs/04` §10); re-run `journalctl --setup-keys` if you want sealing back |

And the meta-rule: every lockout you cause becomes a note in `docs/10` §6, so the next person (possibly
future-you at 3 a.m.) has the fix written down.

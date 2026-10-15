# files/keys — your Secure Boot keys

`sbctl` stores keys in `/var/lib/sbctl`; this directory is for **documentation and offline storage
instruction**, not for storing private keys in the repo.

## Create and enrol (see `docs/03` §2 for context)

```bash
sudo apt-get install --no-install-recommends sbctl sbsigntool systemd-boot systemd-ukify efitools
# put the firmware in SETUP MODE first (Dell: Security -> Secure Boot -> Custom Mode)
sudo sbctl status
sudo sbctl create-keys
sudo sbctl enroll-keys --microsoft    # omit --microsoft if you do not need signed option ROMs/dbx
```

## Back up immediately (before you need it)

```bash
sudo mkdir -p /root/sbkeys-backup
sudo cp -a /var/lib/sbctl /root/sbkeys-backup/
sudo cp -a /usr/share/secureboot /root/sbkeys-backup/ 2>/dev/null || true
sudo tar -C /root -czf /root/sbkeys-$(date +%F).tar.gz sbkeys-backup
sudo sha512sum /root/sbkeys-*.tar.gz | tee /root/sbkeys.sha512
# copy /root/sbkeys-*.tar.gz + sbkeys.sha512 to TWO offline media (USB in a safe, encrypted archive)
# and record the PASSWORDS/hashes on paper. Then:
sudo shred -u /root/sbkeys-*.tar.gz /root/sbkeys.sha512
sudo rm -rf /root/sbkeys-backup
```

## Files you must never commit

- `PK.key`, `KEK.key`, `db.key` (from `/var/lib/sbctl/keys/`) — private platform keys.
- `*.auth` files (the signed enrolment updates) — less sensitive, but do not publish your GUIDs.

## Restore after a firmware reset

```bash
sudo systemctl stop systemd-boot-update 2>/dev/null || true
sudo mkdir -p /var/lib/sbctl
sudo tar -C / -xzf sbkeys-<date>.tar.gz var/lib/sbctl      # adjust paths to your archive layout
sudo sbctl status
sudo sbctl verify                # then re-sign anything reported as unsigned
```

## If the backup is lost

You cannot recover the keys. You can still get back to a working machine: clear Secure Boot keys in the
firmware, boot an unsigned install, re-run `docs/03` §2 from scratch to create a new key set, then
re-install and rebuild. Treat "keys lost" the same as "machine compromised" for planning purposes — it is
a full rebuild, which is exactly why the offline copy matters.

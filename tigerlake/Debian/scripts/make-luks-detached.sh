#!/usr/bin/env bash
# scripts/make-luks-detached.sh
#
# Converts a LUKS2 container from Profile P1 (header on disk) to Profile P2 (detached header on a
# separate USB token). See docs/03 §4. It is REVERSIBLE with --restore.
#
# What it does, in order - and it refuses to skip any step:
#   1. refuses to run unless the header backup file exists and OPENS THE DEVICE (passphrase-verified)
#   2. records the SHA512 of the header backup and writes a restore recipe next to it
#   3. zeroes ONLY the first 16 MiB of the container (the LUKS2 header region; the encrypted data
#      area starts at 16 MiB, so no filesystem byte is touched)
#   4. points /etc/crypttab at the header on the token and rebuilds the initramfs
#   5. prints the exact recovery command for the "token is lost/absent" case
#
# Usage:
#   sudo bash scripts/make-luks-detached.sh --device /dev/nvme0n1p3 \
#        --token /dev/disk/by-id/usb-TOKEN_SERIAL-0:0 --confirm-i-have-two-header-backups
#   sudo bash scripts/make-luks-detached.sh --restore /var/backups/luks/header.img \
#        --device /dev/nvme0n1p3 --confirm-restore
#
# Exit codes: 0 ok, 1 error, 2 refused by a safety check.

set -euo pipefail

DEVICE=""
TOKEN=""
BACKUP=""
CONFIRM_BACKUPS=0
CONFIRM_RESTORE=0
RESTORE_FROM=""
LIVE_OK=0
HEADER_SIZE_MIB=16          # LUKS2 default: 16 MiB metadata, data offset 16 MiB
BACKUP_DIR="/var/backups/luks"

RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
if [ -t 1 ]; then RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; NC=$'\033[0m'; fi
log()  { printf '%s[luks]%s %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '%s  ok  %s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s warn %s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%s fail %s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }
refuse(){ printf '%s refused %s %s\n' "$RED" "$NC" "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --device)   DEVICE="${2:-}"; shift ;;
        --device=*) DEVICE="${1#*=}" ;;
        --token)    TOKEN="${2:-}"; shift ;;
        --token=*)  TOKEN="${1#*=}" ;;
        --backup)   BACKUP="${2:-}"; shift ;;
        --restore)  RESTORE_FROM="${2:-}"; shift ;;
        --confirm-i-have-two-header-backups) CONFIRM_BACKUPS=1 ;;
        --confirm-restore) CONFIRM_RESTORE=1 ;;
        --i-understand-this-is-live) LIVE_OK=1 ;;
        -h|--help)  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v cryptsetup >/dev/null || die "cryptsetup not found"
[ -n "$DEVICE" ] || die "--device is required"
[ -b "$DEVICE" ] || die "$DEVICE is not a block device"

# ---------------------------------------------------------------------------
# Restore path: put a backed-up header back on the device
# ---------------------------------------------------------------------------
if [ -n "$RESTORE_FROM" ]; then
    [ "$CONFIRM_RESTORE" -eq 1 ] || refuse "refusing to write to $DEVICE without --confirm-restore"
    [ -f "$RESTORE_FROM" ] || die "header backup $RESTORE_FROM not found"
    log "verifying the backup opens the device BEFORE writing it back"
    cryptsetup open --test-passphrase --header "$RESTORE_FROM" "$DEVICE" \
        || die "the passphrase failed for that header - wrong backup, or wrong device"
    warn "restoring a header to $DEVICE overwrites the current header region (first ${HEADER_SIZE_MIB} MiB)"
    dd if="$RESTORE_FROM" of="$DEVICE" bs=1M count="$HEADER_SIZE_MIB" conv=fsync status=progress
    ok "header restored. Verify: cryptsetup luksDump $DEVICE"
    # Remove the header= option from crypttab if it points at a token, so the embedded header is used.
    if [ -f /etc/crypttab ] && grep -q 'header=' /etc/crypttab; then
        warn "remove the 'header=' option from /etc/crypttab, then: update-initramfs -u -k all"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# P1 -> P2 conversion
# ---------------------------------------------------------------------------
[ "$CONFIRM_BACKUPS" -eq 1 ] || refuse "read docs/03 §4 and re-run with --confirm-i-have-two-header-backups"
[ -n "$TOKEN" ] || die "--token is required (e.g. /dev/disk/by-id/usb-XXXX-0:0). Find it with: ls -l /dev/disk/by-id/"
[ -b "$TOKEN" ] || die "$TOKEN is not a block device (is the token plugged in?)"
[ "$TOKEN" != "$DEVICE" ] || die "--token and --device must differ. This script exists to separate them."

cryptsetup isLuks "$DEVICE" || die "$DEVICE is not a LUKS device"

# Refuse to run against a live, mounted volume unless the operator insists: zeroing the header of a
# mounted volume is safe *at runtime* but removes the ability to reboot without the token. That is
# the point of P2, but it must be a conscious choice.
if lsblk -nro NAME "$DEVICE" 2>/dev/null | tail -n +2 | grep -q . && [ "$LIVE_OK" -eq 0 ]; then
    refuse "$DEVICE appears to be in use (an open mapping/filesystem depends on it).
  Converting a live system to Profile P2 is fine *in principle* (the header is not needed while the
  volume is open) but you must be certain you have working backups and the token. Re-run with
  --i-understand-this-is-live if that is truly your situation - the recommended path is to run this
  from a rescue environment with the volume closed."
fi

install -d -m 0700 "$BACKUP_DIR"
BACKUP="${BACKUP:-${BACKUP_DIR}/header-$(basename "$DEVICE")-$(date -u +%Y%m%dT%H%M%SZ).img}"

log "1/5 backing up the header to ${BACKUP}"
cryptsetup luksHeaderBackup "$DEVICE" --header-backup-file "$BACKUP"
chmod 0600 "$BACKUP"
SIZE_H="$(stat -c %s "$BACKUP")"
[ "$SIZE_H" -ge $((HEADER_SIZE_MIB * 1024 * 1024)) ] || die "header backup is unexpectedly small (${SIZE_H} bytes)"
sha512sum "$BACKUP" | tee "${BACKUP}.sha512" >/dev/null

log "2/5 verifying the backup actually opens this device (this is the step that makes it safe)"
if [ -t 0 ]; then
    cryptsetup open --test-passphrase --header "$BACKUP" "$DEVICE" \
        || die "the backup header does NOT open $DEVICE - ABORTING, nothing was modified"
else
    die "no TTY: this step needs your passphrase interactively. Run it from a terminal."
fi
ok "backup header verified against the live container"

cat > "${BACKUP}.RECOVERY" <<EOF
LUKS header backup -- READ THIS IF THE MACHINE WILL NOT BOOT
===========================================================
device        : $DEVICE
header file   : $BACKUP
sha512        : $(cut -d' ' -f1 "${BACKUP}.sha512")
created (UTC)  : $(date -u +%FT%TZ)
container     : $(basename "$DEVICE") (LUKS2, header region = first ${HEADER_SIZE_MIB} MiB)

RESTORE THE EMBEDDED HEADER (undo the detached-header conversion):
  1. boot a rescue ISO (Debian netinst: "Advanced options -> Rescue mode")
  2. dd if=${BACKUP##*/} of=$DEVICE bs=1M count=${HEADER_SIZE_MIB} conv=fsync
  3. remove 'header=' from /etc/crypttab (chroot), update-initramfs -u -k all
  4. reboot; the passphrase now unlocks from the disk again

BOOT WITH THE DETACHED HEADER ON THE TOKEN (normal Profile P2 operation):
  * the token must be plugged in BEFORE boot; systemd-cryptsetup reads header= from /etc/crypttab
  * if the token is lost: restore the embedded header as above (step 2), boot, then re-run
    make-luks-detached.sh with a new token

TO OPEN MANUALLY FROM A RESCUE ENVIRONMENT:
  cryptsetup open --header /path/to/$(basename "$BACKUP") $DEVICE cryptroot
  mount /dev/mapper/vg0-root /mnt

THREAT NOTE: anyone who obtains BOTH this header file and your passphrase can decrypt the disk.
Store this file on media that is not the disk it decrypts, and ideally not in the same building as
a printed copy of the passphrase.
EOF
ok "3/5 wrote ${BACKUP}.RECOVERY (print it or copy it to the same offline media)"

log "4/5 zeroing the on-disk header region (first ${HEADER_SIZE_MIB} MiB of $DEVICE)"
warn "after this, $DEVICE no longer LOOKS like a LUKS container, and boot requires the token"
dd if=/dev/zero of="$DEVICE" bs=1M count="$HEADER_SIZE_MIB" conv=fsync status=progress
sync
if cryptsetup isLuks "$DEVICE" 2>/dev/null; then
    die "the device still reports as LUKS - the write did not take effect. STOP and investigate."
fi
ok "on-disk header removed; data area untouched (data starts at ${HEADER_SIZE_MIB} MiB)"

log "5/5 wiring /etc/crypttab to the token's header"
if [ ! -f /etc/crypttab ]; then
    warn "/etc/crypttab not found - create it (see files/etc/crypttab.example) with:"
    warn "  cryptroot $(blkid -s PARTUUID -o value "$DEVICE" 2>/dev/null || echo PARTUUID) none luks,header=$TOKEN"
else
    cp -a /etc/crypttab "/etc/crypttab.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    if grep -q '^[^#]*header=' /etc/crypttab; then
        warn "/etc/crypttab already has a header= option; edit it by hand to point at $TOKEN"
    else
        # Update the line whose device matches this container by PARTUUID (or by device path).
        PU="$(blkid -s PARTUUID -o value "$DEVICE" 2>/dev/null || true)"
        if [ -n "$PU" ] && grep -q "$PU" /etc/crypttab; then
            sed -i "s|^\([^#]*${PU}[^ ]*\) \([^ ]*\) \(.*\)|\1 \2 \3,header=${TOKEN}|" /etc/crypttab
        else
            warn "could not match the device line in /etc/crypttab automatically."
            warn "add ',header=$TOKEN' to the options of the cryptroot line by hand."
        fi
    fi
fi
warn "next: update-initramfs -u -k all  (and re-sign the UKI if you use Secure Boot own-keys)"
warn "then REBOOT WITH THE TOKEN PRESENT and confirm the machine comes up."

cat <<EOF

${GREEN}Done, but not finished:${NC}
  1. cp ${BACKUP} and ${BACKUP}.RECOVERY to TWO offline media (never the disk it decrypts)
  2. update-initramfs -u -k all   (and sbctl sign-all / kernel-install if you use a signed UKI)
  3. reboot and confirm: the passphrase prompt, then 'cryptsetup status root-mapping'
  4. boot again WITH THE TOKEN REMOVED and confirm it fails cleanly
  5. test the recovery path in a VM or with a rescue ISO - docs/03 §4, docs/10 §6
  6. re-baseline AIDE (docs/04 §8): /etc/crypttab changed, and that is worth detecting
EOF

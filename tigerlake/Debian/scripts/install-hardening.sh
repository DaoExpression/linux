#!/usr/bin/env bash
# scripts/install-hardening.sh
#
# Applies the artefacts in files/ to this machine. Idempotent, backup-first, and deliberately
# unwilling to lock you out silently.
#
# Usage:
#   sudo bash scripts/install-hardening.sh --dry-run --tier 2          # show every action
#   sudo bash scripts/install-hardening.sh --tier 2                    # apply
#   sudo bash scripts/install-hardening.sh --tier auto                 # use /etc/paranoid/tier
#   sudo bash scripts/install-hardening.sh --tier 2 --no-firewall      # skip the nftables load
#   sudo bash scripts/install-hardening.sh --tier 3 --unsafe-remount-boot
#
# Exit codes: 0 ok, 1 error, 2 refused-by-safety-check.
#
# WHAT THIS DOES NOT DO (deliberately - see docs/03):
#   * Secure Boot key enrolment (sbctl create-keys / enroll-keys) - it must be done by a human
#     looking at the firmware.
#   * LUKS detached header conversion (scripts/make-luks-detached.sh).
#   * WireGuard key generation (/etc/wireguard/wg0.conf needs YOUR keys).
#   * USBGuard rule generation (must come from your own attached devices).
# It prints the exact next commands for each of those at the end.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES_DIR="${REPO_DIR}/files"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="/var/backups/paranoid/${STAMP}"
PARANOID_DIR="/etc/paranoid"

TIER="2"
DRY_RUN=0
DO_APT=1
DO_FIREWALL=1
YES_FIREWALL=0
UNSAFE_REMOUNT_BOOT=0
ADMIN_USER="admin"

RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
if [ -t 1 ]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; NC=$'\033[0m'
fi

log()  { printf '%s[install]%s %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '%s  ok  %s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s warn %s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%s fail %s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }
refuse() { printf '%s refused %s %s\n' "$RED" "$NC" "$*" >&2; exit 2; }

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)              DRY_RUN=1 ;;
        --tier)                 TIER="${2:-}"; shift ;;
        --tier=*)               TIER="${1#*=}" ;;
        --no-apt)               DO_APT=0 ;;
        --no-firewall)          DO_FIREWALL=0 ;;
        --yes-firewall)         YES_FIREWALL=1 ;;
        --unsafe-remount-boot)  UNSAFE_REMOUNT_BOOT=1 ;;
        --admin-user)           ADMIN_USER="${2:-}"; shift ;;
        --admin-user=*)         ADMIN_USER="${1#*=}" ;;
        -h|--help)              usage ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
[ -d "$FILES_DIR/etc" ] || die "cannot find files/etc - run this from the repository root"

if [ "$TIER" = "auto" ]; then
    if [ -r "${PARANOID_DIR}/tier" ]; then
        TIER="$(tr -d '[:space:]' < "${PARANOID_DIR}/tier")"
        log "tier=auto -> ${TIER} (from ${PARANOID_DIR}/tier)"
    else
        warn "no ${PARANOID_DIR}/tier found; defaulting to tier 2"
        TIER="2"
    fi
fi
case "$TIER" in 1|2|3) ;; *) die "tier must be 1, 2, 3 or auto (got '${TIER}')" ;; esac

if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}" != "debian" ]; then
        warn "this repo targets Debian (found ID=${ID:-unknown}); continuing anyway"
    fi
    case "${VERSION_ID:-}" in
        13|14) : ;;
        "") warn "could not determine the Debian version" ;;
        *) warn "tested on Debian 13 'trixie'; you are on ${VERSION_ID}" ;;
    esac
fi

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  would: %s\n' "$*"
    else
        "$@"
    fi
}

# Install one file with the right mode, backing up whatever was there.
install_file() {
    local src="$1" rel target mode
    rel="${src#"${FILES_DIR}/"}"
    target="/${rel}"
    case "$rel" in
        # NOTE: order matters - specific patterns must come before the wildcards.
        etc/paranoid/README.md)                mode=0644 ;;
        etc/sudoers.d/*)                       mode=0440 ;;
        etc/paranoid/*)                        mode=0600 ;;
        etc/usbguard/rules.conf)               mode=0600 ;;
        etc/wireguard/*)                       mode=0600 ;;
        etc/audit/rules.d/*)                   mode=0640 ;;
        etc/apache2/instances/*.envvars)       mode=0640 ;;
        etc/kernel/postinst.d/*)               mode=0755 ;;
        usr/local/sbin/*)                      mode=0755 ;;
        etc/apparmor.d/local/*)                mode=0644 ;;
        *)                                     mode=0644 ;;
    esac

    # /etc/fstab is NEVER overwritten automatically: the shipped file contains placeholder UUIDs,
    # and a wrong fstab is an unbootable machine. Install it as a reference next to the real one.
    case "$rel" in
        etc/fstab)
            if [ "$DRY_RUN" -eq 0 ]; then
                install -m 0644 -o root -g root "$src" /etc/fstab.paranoid-example
                warn "installed /etc/fstab.paranoid-example - merge it into /etc/fstab BY HAND, then"
                warn "        verify with 'findmnt --verify' before rebooting (docs/04 §5)"
            else
                printf '  would: install -m 0644 %s /etc/fstab.paranoid-example (NOT /etc/fstab)\n' "$src"
            fi
            return 0 ;;
    esac

    if [ "$DRY_RUN" -eq 0 ] && [ -e "$target" ]; then
        install -d -m 0700 "$(dirname "${BACKUP_DIR}${target}")"
        cp -a "$target" "${BACKUP_DIR}${target}"
    fi
    run install -d -m 0755 "$(dirname "$target")"
    run install -m "$mode" -o root -g root "$src" "$target"
}

# ---------------------------------------------------------------------------
# 0. State directory and backups
# ---------------------------------------------------------------------------
log "backup directory: ${BACKUP_DIR} (roll back by copying files back)"
run install -d -m 0700 "$PARANOID_DIR" "$BACKUP_DIR"
# /etc/nftables.conf ends with an include glob; the directory must exist or 'nft -f' fails.
run install -d -m 0755 /etc/nftables.d
if [ "$DRY_RUN" -eq 0 ]; then
    printf '%s\n' "$TIER" > "${PARANOID_DIR}/tier"
    chmod 0644 "${PARANOID_DIR}/tier"
fi

# ---------------------------------------------------------------------------
# 1. Packages (tier-scoped, --no-install-recommends, auditable list)
# ---------------------------------------------------------------------------
BASE_PKGS=(
    intel-microcode firmware-linux-free firmware-misc-nonfree
    apparmor apparmor-utils auditd audispd-plugins aide debsums
    unattended-upgrades needrestart apt-listchanges
    chrony unbound sshguard nftables
    apache2 apache2-utils libapache2-mod-security2 modsecurity-crs libapache2-mod-macro
    ssl-cert openssl ca-certificates
    usbguard
)
TIER2_PKGS=(wireguard-tools)
TIER3_PKGS=(sbctl sbsigntool systemd-boot systemd-ukify dracut)

if [ "$DO_APT" -eq 1 ]; then
    log "installing packages (tier ${TIER})"
    pkgs=("${BASE_PKGS[@]}")
    [ "$TIER" -ge 2 ] && pkgs+=("${TIER2_PKGS[@]}")
    [ "$TIER" -ge 3 ] && pkgs+=("${TIER3_PKGS[@]}")
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  would: apt-get update && apt-get install --no-install-recommends %s\n' "${pkgs[*]}"
    else
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
    fi
else
    warn "skipping package installation (--no-apt)"
fi

# ---------------------------------------------------------------------------
# 2. Copy every artefact
# ---------------------------------------------------------------------------
log "installing configuration artefacts from files/etc/ and files/usr/"
count=0
while IFS= read -r -d '' src; do
    case "$src" in
        *.example) continue ;;     # reference material only: wg0.conf, crypttab, ...
    esac
    install_file "$src"
    count=$((count + 1))
done < <(find "${FILES_DIR}/etc" "${FILES_DIR}/usr" -type f -print0 2>/dev/null | sort -z)
ok "installed ${count} files (originals backed up under ${BACKUP_DIR})"

# ---------------------------------------------------------------------------
# 3. Users, root, sudoers
# ---------------------------------------------------------------------------
if getent passwd "$ADMIN_USER" >/dev/null; then
    log "hardening account '${ADMIN_USER}'"
    run usermod -aG sudo "$ADMIN_USER" || true
    ok "'${ADMIN_USER}' is in the sudo group"
else
    warn "user '${ADMIN_USER}' does not exist - fix /etc/sudoers.d/00-paranoid and"
    warn "        /etc/ssh/sshd_config.d/00-paranoid.conf BEFORE locking root, or you will lock yourself out"
fi

# The shipped sshd/sudoers artefacts name the admin user 'admin'. Rewrite them if yours differs -
# 'AllowUsers' with the wrong name is an instant SSH lockout.
if [ "$ADMIN_USER" != "admin" ] && [ "$DRY_RUN" -eq 0 ]; then
    log "rewriting the admin username to '${ADMIN_USER}' in sshd/sudoers artefacts"
    sed -i "s/^AllowUsers admin\$/AllowUsers ${ADMIN_USER}/" /etc/ssh/sshd_config.d/00-paranoid.conf
    sed -i "s/^admin ALL=/${ADMIN_USER} ALL=/" /etc/sudoers.d/00-paranoid
fi
if [ "$DRY_RUN" -eq 0 ]; then
    grep -q "^AllowUsers ${ADMIN_USER}\$" /etc/ssh/sshd_config.d/00-paranoid.conf \
        || warn "sshd AllowUsers does not list '${ADMIN_USER}' - CHECK BEFORE RELOADING SSH"
    if command -v sshd >/dev/null && ! sshd -t 2>/dev/null; then
        warn "sshd configuration test FAILED - fix it before 'systemctl reload ssh'"
    fi
fi

# Only lock root once we know an admin can get in.
if getent passwd "$ADMIN_USER" >/dev/null; then
    run passwd -l root
    ok "root password locked"
fi
if [ "$DRY_RUN" -eq 0 ] && command -v visudo >/dev/null; then
    visudo -c >/dev/null || die "sudoers syntax error - refusing to continue (fix /etc/sudoers.d/00-paranoid)"
    ok "sudoers syntax valid"
fi

# ---------------------------------------------------------------------------
# 4. PAM (faillock), limits, shell
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
    cat > /usr/share/pam-configs/paranoid-faillock <<'EOF'
Name: Paranoid lockout policy (pam_faillock)
Default: yes
Priority: 300
Auth-Type: Primary
Auth:
	[default=die]	pam_faillock.so authfail
	auth-sufficient	pam_faillock.so authsucc
Account-Type: Primary
Account:
	required	pam_faillock.so
EOF
fi
run pam-auth-update --enable paranoid-faillock --enable pwquality || warn "pam-auth-update returned non-zero (check the module names)"
run chmod 0644 /etc/profile.d/99-hardening.sh

# ---------------------------------------------------------------------------
# 5. Kernel: sysctl, modules, initramfs, bootloader
# ---------------------------------------------------------------------------
log "applying kernel parameters"
run sysctl --system
if [ "$DRY_RUN" -eq 0 ]; then
    ok "kernel.kptr_restrict=$(sysctl -n kernel.kptr_restrict 2>/dev/null || echo n/a) kernel.dmesg_restrict=$(sysctl -n kernel.dmesg_restrict 2>/dev/null || echo n/a)"
fi

log "rebuilding initramfs for module blacklists + microcode"
if [ "$DRY_RUN" -eq 0 ]; then
    if command -v update-initramfs >/dev/null; then update-initramfs -u -k all; fi
fi

if command -v sbctl >/dev/null && [ -d /sys/firmware/efi ]; then
    log "Secure Boot own-keys detected: regenerating and signing the UKI"
    if [ "$DRY_RUN" -eq 0 ]; then
        KVER="$(uname -r)"
        kernel-install add "$KVER" "/boot/vmlinuz-${KVER}" >/dev/null 2>&1 || warn "kernel-install failed - check /etc/kernel/install.conf (dracut present?)"
        sbctl sign-all >/dev/null 2>&1 || warn "sbctl sign-all failed; run 'sbctl verify' and sign by hand"
        sbctl verify 2>/dev/null | grep -i 'not signed' && warn "unsigned EFI files remain - fix before rebooting!" || ok "all EFI files signed"
    fi
elif command -v update-grub >/dev/null; then
    log "regenerating GRUB configuration"
    if [ "$DRY_RUN" -eq 0 ]; then
        if mountpoint -q /boot && findmnt -no OPTIONS /boot | grep -qw ro; then
            if [ "$UNSAFE_REMOUNT_BOOT" -eq 1 ]; then
                mount -o remount,rw /boot && update-grub && mount -o remount,ro /boot
            else
                warn "/boot is read-only; re-run with --unsafe-remount-boot (or remount rw yourself) if the kernel cmdline changed"
            fi
        else
            update-grub
        fi
    fi
else
    warn "neither sbctl nor update-grub found; the kernel command line was NOT applied - see docs/03 §3"
fi

# ---------------------------------------------------------------------------
# 6. Services and timers
# ---------------------------------------------------------------------------
log "enabling services and timers"
CORE_UNITS=(
    apparmor
    auditd
    chrony
    unbound
    unattended-upgrades
    aide-check.timer
    debsums-check.timer
    paranoid-boot-record.service
    paranoid-cert-check.timer
)
if [ "$TIER" -ge 2 ]; then
    CORE_UNITS+=( sshguard usbguard )
    # WireGuard can only come up once wg0.conf has real keys - do not enable a half-configured tunnel.
    if [ -r /etc/wireguard/wg0.conf ] && grep -qvE '<SERVER_PRIVATE_KEY>|^#|^$' /etc/wireguard/wg0.conf 2>/dev/null; then
        CORE_UNITS+=( wg-quick@wg0.service )
    else
        warn "not enabling wg-quick@wg0: /etc/wireguard/wg0.conf still has placeholder keys (docs/05 §5)"
    fi
fi
if [ "$TIER" -ge 3 ]; then
    CORE_UNITS+=( remount-boot-ro.service )
    warn "TIER 3: arm kernel-modules-lock.service with 'touch ${PARANOID_DIR}/modules-lock' only after"
    warn "        reading files/etc/systemd/system/kernel-modules-lock.service (it is irreversible in-flight)"
fi

if [ "$DRY_RUN" -eq 0 ]; then
    systemctl daemon-reload
    for u in "${CORE_UNITS[@]}"; do
        if systemctl list-unit-files "$u" >/dev/null 2>&1 && systemctl cat "$u" >/dev/null 2>&1; then
            if systemctl enable --now "$u" >/dev/null 2>&1; then ok "started $u"; else warn "could not start $u (check: systemctl status $u)"; fi
        else
            warn "unit $u not found (package missing? skipped)"
        fi
    done
fi

# resolv.conf: point the resolver at our local validating instance (docs/04 §11)
if [ "$DRY_RUN" -eq 0 ] && systemctl is-active --quiet unbound; then
    systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
    printf 'nameserver 127.0.0.1\noptions edns0 trust-ad\n' > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || warn "could not chattr +i /etc/resolv.conf (immutable flag)"
    ok "DNS now resolves through 127.0.0.1 (unbound, DNSSEC-validating)"
fi

# ---------------------------------------------------------------------------
# 7. nftables - LAST, and never silently through an SSH session
# ---------------------------------------------------------------------------
if [ "$DO_FIREWALL" -eq 1 ]; then
    if ! nft -c -f /etc/nftables.conf 2>/dev/null; then
        if [ "$DRY_RUN" -eq 0 ]; then
            nft -c -f /etc/nftables.conf || die "nftables ruleset FAILED to parse - not applying anything"
        fi
    else
        ok "nftables ruleset parses"
    fi

    if [ "$DRY_RUN" -eq 0 ]; then
        if [ -n "${SSH_CONNECTION:-}" ] && [ "$YES_FIREWALL" -eq 0 ]; then
            refuse "you are connected over SSH. The shipped ruleset binds SSH to wg0 only, so applying
  it now would cut this session. Either:
    * finish over the physical console:  sudo bash scripts/install-hardening.sh --tier ${TIER}
    * or verify WireGuard works and re-run with --yes-firewall
    * or use --no-firewall now and apply docs/05 §2 manually afterwards
  Nothing else was skipped; all other steps are already applied."
        fi
        nft -f /etc/nftables.conf
        systemctl enable --now nftables >/dev/null 2>&1 || true
        nft list ruleset > "/var/backups/nft.${STAMP}.ruleset"
        ok "firewall active; rollback point saved to /var/backups/nft.${STAMP}.ruleset"
    fi
else
    warn "firewall NOT applied (--no-firewall). Do it next: nft -c -f /etc/nftables.conf && nft -f /etc/nftables.conf"
fi

# ---------------------------------------------------------------------------
# 8. AIDE baseline
# ---------------------------------------------------------------------------
log "AIDE baseline"
if [ "$DRY_RUN" -eq 0 ]; then
    if command -v aideinit >/dev/null; then
        warn "taking the AIDE baseline NOW. Re-take it (docs/04 §8) once every remaining config change is done."
        aideinit -y -f >/dev/null 2>&1 || warn "aideinit failed - run it manually after finishing"
        [ -f /var/lib/aide/aide.db.new ] && mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db && ok "AIDE baseline installed"
    fi
fi

# ---------------------------------------------------------------------------
# 9. Manual steps this script will not do for you
# ---------------------------------------------------------------------------
cat <<EOF

${GREEN}Applied. Remaining steps are human-only (each has a document):${NC}

  1. Secure Boot own keys        docs/03 §2   (sudo sbctl create-keys; sudo sbctl enroll-keys)
  2. Sign the boot chain/UKI     docs/03 §2   (sbctl sign -s ...; then BOOT WITH sbsigntool verified files)
  3. WireGuard admin plane       docs/05 §5   (put real keys in /etc/wireguard/wg0.conf, then)
                                              systemctl enable --now wg-quick@wg0 && wg show
  4. Apache config + modules     docs/06 §2-3 (sudo bash scripts/harden-apache.sh)
  5. TLS certificates            docs/06 §4   (certbot with DNS-01)
  6. USBGuard rules              docs/07 §4   (usbguard generate-policy > /etc/usbguard/rules.conf)
  7. BIOS settings               docs/07 §1   (password, TB=User Authorization, camera/mic off, dGPU off)
  8. Verify everything           bash scripts/verify-hardening.sh --tier ${TIER}

Rollback: originals are in ${BACKUP_DIR} (same relative paths) and the firewall rollback point is
/var/backups/nft.${STAMP}.ruleset.
EOF

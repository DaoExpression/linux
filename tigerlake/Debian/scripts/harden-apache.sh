#!/usr/bin/env bash
# scripts/harden-apache.sh
#
# Applies docs/06: prunes useless Apache modules, enables the hardened config fragments, validates,
# and rolls back if the result does not start. Never leaves a broken web server behind.
#
# Usage:
#   sudo bash scripts/harden-apache.sh --dry-run
#   sudo bash scripts/harden-apache.sh                 # prune modules + install config + reload
#   sudo bash scripts/harden-apache.sh --prune-modules # only the module surgery
#   sudo bash scripts/harden-apache.sh --config-only   # only the config install
#   sudo bash scripts/harden-apache.sh --verify        # only validate/report what is loaded
#
# Exit codes: 0 ok, 1 error, 3 rolled back after a failed configtest.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES_DIR="${REPO_DIR}/files"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="/var/backups/paranoid/apache-${STAMP}"

DRY_RUN=0; DO_PRUNE=1; DO_CONFIG=1; DO_VERIFY=1

RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
if [ -t 1 ]; then RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; NC=$'\033[0m'; fi
log()  { printf '%s[apache]%s %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '%s  ok  %s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s warn %s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%s fail %s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)       DRY_RUN=1 ;;
        --prune-modules) DO_PRUNE=1; DO_CONFIG=0; DO_VERIFY=0 ;;
        --config-only)   DO_PRUNE=0; DO_CONFIG=1; DO_VERIFY=1 ;;
        --verify)        DO_PRUNE=0; DO_CONFIG=0; DO_VERIFY=1 ;;
        -h|--help)       sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v apache2ctl >/dev/null || die "apache2 is not installed (apt-get install --no-install-recommends apache2)"
command -v a2dismod  >/dev/null || die "a2dismod not found (apache2 package incomplete?)"

run() { if [ "$DRY_RUN" -eq 1 ]; then printf '  would: %s\n' "$*"; else "$@"; fi; }

# ---------------------------------------------------------------------------
# Modules to remove: each one is another parser reachable by strangers (docs/06 §2)
# ---------------------------------------------------------------------------
PRUNE_MODULES=(
    autoindex negotiation status info userdir cgi cgid imagemap include speling
    dav dav_fs dav_lock
    proxy proxy_http proxy_balancer proxy_connect proxy_ftp proxy_ajp proxy_fcgi proxy_scgi
    actions auth_digest
)
# NOTE: 'status' is pruned. If you want it, keep it and rely on the localhost-only <Location>
# block in conf-available/security-hardening.conf.
KEEP_MODULES=(ssl headers socache_shmcb http2 mpm_event rewrite macro security2 mime dir alias
              authz_core authz_host authn_core auth_basic setenvif unixd filter deflate reqtimeout
              log_config env)

# ---------------------------------------------------------------------------
# 1. Module surgery
# ---------------------------------------------------------------------------
if [ "$DO_PRUNE" -eq 1 ]; then
    log "pruning Apache modules"
    # mpm_event is the right MPM. mpm_prefork is only needed by mod_php, which we do not have.
    run a2dismod mpm_prefork mpm_worker 2>/dev/null || true
    run a2enmod mpm_event
    for m in "${PRUNE_MODULES[@]}"; do
        if [ -e "/etc/apache2/mods-enabled/${m}.load" ] || [ -e "/etc/apache2/mods-enabled/${m}.conf" ]; then
            run a2dismod "$m" || warn "could not disable ${m}"
        fi
    done
    for m in "${KEEP_MODULES[@]}"; do
        [ -e "/etc/apache2/mods-available/${m}.load" ] || [ -e "/etc/apache2/mods-available/${m}.conf" ] || continue
        run a2enmod "$m" >/dev/null || warn "could not enable ${m}"
    done
    ok "module set pruned (report: apache2ctl -M)"
fi

# ---------------------------------------------------------------------------
# 2. Config fragments
# ---------------------------------------------------------------------------
if [ "$DO_CONFIG" -eq 1 ]; then
    log "installing hardened Apache configuration (backup: ${BACKUP_DIR})"
    run install -d -m 0700 "$BACKUP_DIR"
    for rel in \
        etc/apache2/apache2.conf \
        etc/apache2/ports.conf \
        etc/apache2/conf-available/security-hardening.conf \
        etc/apache2/conf-available/headers-hardening.conf \
        etc/apache2/conf-available/tls-hardening.conf \
        etc/apache2/conf-available/mpm-tuning.conf \
        etc/apache2/sites-available/000-default.conf \
        etc/apache2/sites-available/example-hardened.conf \
        etc/apache2/mods-available/security2.conf \
        etc/modsecurity/modsecurity.conf \
        etc/modsecurity/crs/paranoid-crs.conf \
        etc/logrotate.d/apache2 \
        etc/logrotate.d/modsec
    do
        src="${FILES_DIR}/${rel}"; tgt="/${rel}"
        [ -f "$src" ] || { warn "missing artefact ${rel} - skipped"; continue; }
        if [ "$DRY_RUN" -eq 0 ] && [ -e "$tgt" ]; then
            install -d -m 0700 "$(dirname "${BACKUP_DIR}${tgt}")"
            cp -a "$tgt" "${BACKUP_DIR}${tgt}"
        fi
        run install -d -m 0755 "$(dirname "$tgt")"
        run install -m 0644 -o root -g root "$src" "$tgt"
    done
    # Enable the fragments.
    run a2enconf security-hardening headers-hardening tls-hardening mpm-tuning
    # The default vhost should not serve anything we did not intend.
    run a2ensite 000-default

    # Runtime dirs that mod_security and the sandboxed unit need.
    if [ "$DRY_RUN" -eq 0 ]; then
        install -d -m 0750 -o root -g root /var/cache/apache2/mod_security2
        install -d -m 0750 -o root -g adm  /var/log/apache2/audit /var/log/paranoid
        touch /var/log/apache2/modsec_audit.log
        chown root:adm /var/log/apache2/modsec_audit.log
        chmod 0640 /var/log/apache2/modsec_audit.log
    fi
    ok "configuration installed and fragments enabled"
fi

# ---------------------------------------------------------------------------
# 3. Validate, and roll back if the server would not start
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ] && [ "$DO_CONFIG" -eq 1 ]; then
    log "validating configuration"
    if ! apache2ctl configtest 2>/tmp/apache-configtest.$$; then
        warn "configtest FAILED:"
        sed 's/^/    /' /tmp/apache-configtest.$$ >&2 || true
        warn "rolling back to ${BACKUP_DIR}"
        (cd "$BACKUP_DIR" && find . -type f -print0 | while IFS= read -r -d '' f; do
            cp -a "$f" "/${f#./}"
        done) || warn "rollback copy hit an error - restore manually from ${BACKUP_DIR}"
        a2enconf security-hardening headers-hardening tls-hardening mpm-tuning >/dev/null 2>&1 || true
        rm -f /tmp/apache-configtest.$$
        die "rolled back; nothing was reloaded. Fix the artefact in files/ and re-run (exit 3)"
    fi
    sed 's/^/    /' /tmp/apache-configtest.$$ || true
    rm -f /tmp/apache-configtest.$$
    ok "configtest passed"

    log "reloading Apache"
    systemctl reload apache2 2>/dev/null || systemctl restart apache2
    sleep 1
    if systemctl is-active --quiet apache2; then
        ok "apache2 is active"
    else
        warn "apache2 is NOT active after reload:"
        systemctl status apache2 --no-pager -l | tail -20 >&2 || true
        warn "restore from ${BACKUP_DIR} and investigate before trying again"
        exit 3
    fi
fi

# ---------------------------------------------------------------------------
# 4. Report
# ---------------------------------------------------------------------------
if [ "$DO_VERIFY" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    echo
    log "loaded modules:"
    apache2ctl -M 2>/dev/null | sort | sed 's/^/    /'
    echo
    log "listening sockets (only 443 + your admin plane should appear):"
    ss -tulpn 2>/dev/null | grep -E 'apache2|:443|:80 ' | sed 's/^/    /' || true
    echo
    log "sandbox exposure (lower is better; target < 2.0):"
    systemd-analyze security apache2 2>/dev/null | tail -3 | sed 's/^/    /' || warn "systemd-analyze unavailable"
    echo
    log "Smoke tests to run yourself:"
    cat <<'EOF'
    sudo apache2ctl -S                                   # vhost map
    curl -sI https://<server>/ | grep -iE 'server|strict-transport|content-security'
    sslscan <server>:443 | head -20                      # TLS 1.3 suites only
    curl -sI https://<server>/../etc/passwd | head -1    # expect 400/404, never 200
    sudo certbot renew --dry-run
    sudo bash scripts/verify-hardening.sh --section apache
EOF
fi

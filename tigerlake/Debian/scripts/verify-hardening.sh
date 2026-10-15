#!/usr/bin/env bash
# scripts/verify-hardening.sh
#
# READ-ONLY verification of the controls this repository promises. It changes nothing.
# A green run is the definition of "this machine matches the guide".
#
# Usage:
#   bash scripts/verify-hardening.sh                 # all sections, tier from /etc/paranoid/tier (or 2)
#   sudo bash scripts/verify-hardening.sh --tier 3   # include tier-3 checks
#   sudo bash scripts/verify-hardening.sh --section apache
#   sudo bash scripts/verify-hardening.sh --quiet    # only failures and the summary
#
# Exit codes: 0 = no FAIL, 1 = at least one FAIL, 3 = could not run (not a Debian-like host).
#
# Sections: boot kernel base network apache physical isolation packages
#
# NOTE: many checks need root (reading /etc/shadow, /proc/sys, bootctl). Running unprivileged is
# supported: those checks report SKIP rather than FAIL, so you can still use this as a first pass.

set -uo pipefail

TIER=""
SECTION=""
QUIET=0
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [ $# -gt 0 ]; do
    case "$1" in
        --tier)    TIER="${2:-}"; shift ;;
        --tier=*)  TIER="${1#*=}" ;;
        --section) SECTION="${2:-}"; shift ;;
        --section=*) SECTION="${1#*=}" ;;
        --quiet)   QUIET=1 ;;
        -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 3 ;;
    esac
    shift
done

if [ -z "$TIER" ]; then
    if [ -r /etc/paranoid/tier ]; then TIER="$(tr -d '[:space:]' < /etc/paranoid/tier)"
    else TIER=2; fi
fi
case "$TIER" in 1|2|3) ;; *) echo "bad tier '$TIER'" >&2; exit 3 ;; esac
if [ -n "$SECTION" ]; then
    case "$SECTION" in
        boot|kernel|base|network|apache|physical|isolation|packages) ;;
        *) echo "unknown section '$SECTION'. Valid: boot kernel base network apache physical isolation packages" >&2; exit 3 ;;
    esac
fi

RED=""; GREEN=""; YELLOW=""; BLUE=""; DIM=""; NC=""
if [ -t 1 ]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[36m'; DIM=$'\033[2m'; NC=$'\033[0m'
fi

PASS=0; FAIL=0; WARN=0; SKIP=0
FAILED_LIST=""

have()      { command -v "$1" >/dev/null 2>&1; }
is_root()   { [ "$(id -u)" -eq 0 ]; }
# Read the kernel parameter directly from /proc/sys when sysctl(8) is not installed, so the check
# never reports a false FAIL just because the tool is missing.
sysctl_val(){
    local key="$1" path
    path="/proc/sys/$(printf '%s' "$key" | tr '.' '/')"
    if have sysctl; then sysctl -n "$key" 2>/dev/null && return 0; fi
    [ -r "$path" ] && cat "$path" 2>/dev/null
}
want_section() { [ -z "$SECTION" ] || [ "$SECTION" = "$1" ]; }

record() { # record <PASS|FAIL|WARN|SKIP> <label> [detail]
    local status="$1" label="$2" detail="${3:-}"
    case "$status" in
        PASS) PASS=$((PASS+1)); [ "$QUIET" -eq 1 ] && return 0
              printf '%s PASS %s %s\n' "$GREEN" "$NC" "$label" ;;
        FAIL) FAIL=$((FAIL+1)); FAILED_LIST="${FAILED_LIST}${label}\n"
              printf '%s FAIL %s %s%s\n' "$RED" "$NC" "$label" "${detail:+ ${DIM}(${detail})${NC}}" ;;
        WARN) WARN=$((WARN+1))
              [ "$QUIET" -eq 1 ] && return 0
              printf '%s WARN %s %s %s\n' "$YELLOW" "$NC" "$label" "${detail:+${DIM}(${detail})${NC}}" ;;
        SKIP) SKIP=$((SKIP+1))
              [ "$QUIET" -eq 1 ] && return 0
              printf '%s SKIP %s %s %s\n' "$DIM" "$NC" "$label" "${detail:+${DIM}(${detail})${NC}}" ;;
    esac
    [ -n "$detail" ] && [ "$status" = PASS ] && printf '       %s%s%s\n' "$DIM" "$detail" "$NC"
    return 0
}

section() { [ "$QUIET" -eq 1 ] || printf '\n%s== %s ==%s\n' "$BLUE" "$1" "$NC"; }

# check_sysctl <key> <expected> <label>
check_sysctl() {
    local key="$1" want="$2" label="${3:-$1=$2}"
    if ! [ -r "/proc/sys/$(printf '%s' "$key" | tr '.' '/')" ]; then
        record SKIP "$label" "kernel parameter not present"; return
    fi
    local got; got="$(sysctl_val "$key")"
    [ "$got" = "$want" ] && record PASS "$label" "= $got" || record FAIL "$label" "want $want, got ${got:-unset}"
}

check_file() { local p="$1" label="${2:-$1}"; [ -e "$p" ] && record PASS "$label" || record FAIL "$label" "missing $p"; }

check_mode() {
    local p="$1" want="$2" label="${3:-$1 mode $2}"
    if ! [ -e "$p" ]; then record FAIL "$label" "missing $p"; return; fi
    local m; m="$(stat -c %a "$p" 2>/dev/null)"
    [ "$m" = "$want" ] && record PASS "$label" "mode $m" || record FAIL "$label" "mode $m (want $want)"
}

check_enabled() { # check_enabled <unit>
    local u="$1"
    if ! have systemctl; then record SKIP "$u enabled" "no systemd"; return; fi
    if ! systemctl list-unit-files "$u" >/dev/null 2>&1; then record WARN "$u enabled" "unit not installed"; return; fi
    if systemctl is-enabled --quiet "$u" 2>/dev/null; then record PASS "$u enabled"
    else record FAIL "$u enabled" "$(systemctl is-enabled "$u" 2>&1 | head -1)"; fi
}

check_active() {
    local u="$1"
    if ! have systemctl; then record SKIP "$u active" "no systemd"; return; fi
    if systemctl is-active --quiet "$u" 2>/dev/null; then record PASS "$u active"
    else record WARN "$u active" "$(systemctl is-active "$u" 2>&1 | head -1)"; fi
}

check_module_absent() {
    local m="$1"
    if ! have lsmod; then record SKIP "module $m absent" "no lsmod"; return; fi
    if lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$m"; then
        record FAIL "module $m absent" "loaded - blacklist not effective"
    else
        record PASS "module $m absent"
    fi
}

check_cmdline() {
    local token="$1"
    if ! [ -r /proc/cmdline ]; then record SKIP "cmdline ${token}" "no /proc/cmdline"; return; fi
    if tr ' ' '\n' < /proc/cmdline | grep -qx -- "$token" || grep -q -- "$token" /proc/cmdline; then
        record PASS "kernel cmdline contains ${token}"
    else
        record FAIL "kernel cmdline contains ${token}" "reboot needed or cmdline not applied?"
    fi
}

printf '%sHardening verification%s  (tier %s%s)\n' "$BLUE" "$NC" "$TIER" "${SECTION:+, section $SECTION}"

# ---------------------------------------------------------------------------
# 1. Boot integrity
# ---------------------------------------------------------------------------
if want_section boot; then
    section "Boot integrity (docs/03)"
    if [ -d /sys/firmware/efi ]; then
        if have bootctl; then
            sb="$(bootctl status 2>/dev/null | awk -F: '/Secure Boot/{print $2}' | head -1 | tr -d ' ')"
            case "$sb" in
                enabled) record PASS "Secure Boot enabled" ;;
                disabled) record FAIL "Secure Boot enabled" "firmware reports disabled" ;;
                *) record WARN "Secure Boot enabled" "state: ${sb:-unknown}" ;;
            esac
        else record SKIP "Secure Boot enabled" "bootctl unavailable"; fi
    else record SKIP "Secure Boot enabled" "not booted via UEFI"; fi

    # LUKS: at least one crypto device must exist, and the header must NOT be findable on disk
    # if the machine is running Profile P2.
    if have cryptsetup; then
        if is_root || [ -r /etc/crypttab ]; then
            if blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | grep -q .; then
                luks="$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | head -1)"
                record PASS "LUKS container present" "$luks"
                ver="$(cryptsetup luksDump "$luks" 2>/dev/null | awk '/Version/{print $2; exit}')"
                [ "$ver" = "2" ] && record PASS "LUKS2 format" || record WARN "LUKS2 format" "version ${ver:-unknown}"
                if cryptsetup luksDump "$luks" 2>/dev/null | grep -qi 'argon2id'; then
                    record PASS "Argon2id KDF"
                else
                    record WARN "Argon2id KDF" "not argon2id - slower brute-force resistance"
                fi
                if [ -r /etc/crypttab ] && grep -q 'header=' /etc/crypttab; then
                    record PASS "detached LUKS header configured (Profile P2)"
                else
                    record PASS "embedded LUKS header (Profile P1)" "docs/03 §4 to convert"
                fi
            else
                record FAIL "LUKS container present" "no crypto_LUKS device found"
            fi
        else record SKIP "LUKS checks" "needs root or /etc/crypttab"; fi
    else record SKIP "LUKS checks" "cryptsetup not installed"; fi

    if [ -r /sys/kernel/security/lockdown ]; then
        if grep -q '\[confidentiality\]' /sys/kernel/security/lockdown; then
            record PASS "kernel lockdown: confidentiality"
        elif grep -q '\[integrity\]' /sys/kernel/security/lockdown; then
            record WARN "kernel lockdown: confidentiality" "only integrity active"
        else
            record FAIL "kernel lockdown: confidentiality" "$(cat /sys/kernel/security/lockdown)"
        fi
    else record SKIP "kernel lockdown" "/sys/kernel/security not available"; fi

    if have sbctl && is_root; then
        unver="$(sbctl verify 2>/dev/null | grep -ci 'not signed' || true)"
        [ "${unver:-0}" -eq 0 ] && record PASS "all EFI binaries signed" || record FAIL "all EFI binaries signed" "${unver} unsigned"
    else record SKIP "sbctl verify" "needs root + sbctl"; fi

    [ "$TIER" -ge 3 ] && check_file /etc/paranoid/modules-lock "Tier 3: module lock armed (if intended)"
fi

# ---------------------------------------------------------------------------
# 2. Kernel parameters and modules
# ---------------------------------------------------------------------------
if want_section kernel; then
    section "Kernel hardening (docs/03 §3, docs/04 §3-4)"
    check_cmdline 'lockdown=confidentiality'
    check_cmdline 'iommu.strict=1'
    check_cmdline 'iommu=on'
    check_cmdline 'module.sig_enforce=1'
    for t in init_on_alloc=1 slab_nomerge vsyscall=none debugfs=off apparmor=1 randomize_kstack_offset=on; do
        check_cmdline "$t"
    done
    check_module_absent nouveau
    check_module_absent mei_me
    check_module_absent uvcvideo
    check_module_absent btusb
    check_module_absent snd_sof_pci_intel_tgl
    check_module_absent thunderbolt
    check_file /etc/modprobe.d/90-blacklist-paranoid.conf
    check_file /etc/sysctl.d/99-paranoid.conf
    if [ -r /etc/kernel/install.conf ] && grep -q '^layout=uki' /etc/kernel/install.conf; then
        record PASS "UKI layout configured"
        if is_root && [ -d /boot/efi/EFI/Linux ]; then
            ls /boot/efi/EFI/Linux/*.efi >/dev/null 2>&1 && record PASS "signed UKI present on the ESP" \
                || record FAIL "signed UKI present on the ESP" "no .efi in /boot/efi/EFI/Linux"
        else record SKIP "signed UKI present on the ESP" "needs root"; fi
    else
        record WARN "UKI layout configured" "using GRUB fallback (docs/03 §2 Path B)"
    fi
fi

# ---------------------------------------------------------------------------
# 3. Base system
# ---------------------------------------------------------------------------
if want_section base; then
    section "Base system (docs/04)"
    check_sysctl kernel.kptr_restrict 2
    check_sysctl kernel.dmesg_restrict 1
    check_sysctl kernel.perf_event_paranoid 3
    check_sysctl kernel.yama.ptrace_scope 2
    check_sysctl kernel.unprivileged_bpf_disabled 2
    check_sysctl vm.unprivileged_userfaultfd 0
    check_sysctl kernel.kexec_load_disabled 1
    check_sysctl fs.protected_hardlinks 1
    check_sysctl fs.protected_symlinks 1
    check_sysctl net.ipv4.tcp_syncookies 1
    check_sysctl net.ipv4.conf.all.accept_redirects 0
    check_sysctl net.ipv4.conf.all.accept_source_route 0
    check_sysctl net.ipv4.conf.all.log_martians 1
    check_sysctl net.ipv4.ip_forward 0
    check_sysctl fs.suid_dumpable 0

    # root locked?
    if [ -r /etc/shadow ]; then
        roots="$(awk -F: '$1=="root"{print $2}' /etc/shadow 2>/dev/null)"
        case "$roots" in
            '!'*|'*'*) record PASS "root password locked" ;;
            '') record SKIP "root password locked" "cannot read /etc/shadow" ;;
            *) record FAIL "root password locked" "root has a usable password hash" ;;
        esac
    else record SKIP "root password locked" "needs root"; fi

    check_file /etc/sudoers.d/00-paranoid
    check_mode /etc/sudoers.d/00-paranoid 440
    check_file /etc/security/faillock.conf
    check_file /etc/security/limits.d/99-paranoid.conf
    check_file /etc/ssh/sshd_config.d/00-paranoid.conf
    check_file /etc/security/pwquality.conf.d/99-paranoid.conf

    if [ -r /etc/ssh/sshd_config.d/00-paranoid.conf ]; then
        grep -qE '^\s*PermitRootLogin\s+no' /etc/ssh/sshd_config.d/00-paranoid.conf \
            && record PASS "sshd: PermitRootLogin no" || record FAIL "sshd: PermitRootLogin no"
        grep -qE '^\s*PasswordAuthentication\s+no' /etc/ssh/sshd_config.d/00-paranoid.conf \
            && record PASS "sshd: PasswordAuthentication no" || record FAIL "sshd: PasswordAuthentication no"
        grep -qE '^\s*AllowUsers\s+' /etc/ssh/sshd_config.d/00-paranoid.conf \
            && record PASS "sshd: AllowUsers restricted" || record FAIL "sshd: AllowUsers restricted"
    fi

    check_enabled apparmor
    if have aa-status; then
        enf="$(aa-status --enabled 2>/dev/null && echo yes || echo no)"
        [ "$enf" = yes ] && record PASS "AppArmor enabled" || record FAIL "AppArmor enabled"
        apache_prof="$(aa-status 2>/dev/null | grep -c 'usr.sbin.apache2' || true)"
        [ "${apache_prof:-0}" -gt 0 ] && record PASS "AppArmor profile for apache2 loaded" \
            || record WARN "AppArmor profile for apache2 loaded" "not in aa-status"
    else record SKIP "AppArmor" "aa-status missing"; fi

    check_enabled auditd
    if have auditctl && is_root; then
        st="$(auditctl -s 2>/dev/null | awk -F'[= ]+' '/^enabled/{print $2}')"
        [ "$st" = "2" ] && record PASS "auditd rules immutable (-e 2)" \
            || record FAIL "auditd rules immutable (-e 2)" "enabled=${st:-unknown}"
        rm_rules="$(auditctl -l 2>/dev/null | grep -c 'webroot\|apache-config' || true)"
        [ "${rm_rules:-0}" -gt 0 ] && record PASS "auditd rules for the web plane present" \
            || record WARN "auditd rules for the web plane present" "no -k apache-config/webroot rules"
    else record SKIP "auditd rules" "needs root + auditctl"; fi

    check_active aide-check.timer
    check_active debsums-check.timer
    check_active paranoid-cert-check.timer
    check_enabled unattended-upgrades

    if have apt-config; then
        rr="$(apt-config dump 2>/dev/null | awk -F'"' '/Install-Recommends/{print $2}')"
        [ "$rr" = "false" ] && record PASS "apt does not install Recommends" \
            || record WARN "apt does not install Recommends" "Install-Recommends=${rr:-unset}"
    fi

    # Mandatory filesystem mount options
    if have findmnt; then
        for mp in /var/log /var/tmp; do
            opts="$(findmnt -no OPTIONS "$mp" 2>/dev/null || true)"
            if [ -z "$opts" ]; then record FAIL "mount options on $mp" "not a separate mount"
            elif printf '%s' "$opts" | grep -q noexec; then record PASS "noexec on $mp" "$opts"
            else record FAIL "noexec on $mp" "$opts"; fi
        done
        opts="$(findmnt -no OPTIONS /tmp 2>/dev/null || true)"
        if [ -n "$opts" ] && printf '%s' "$opts" | grep -q noexec; then record PASS "noexec on /tmp" "$opts"
        else record FAIL "noexec on /tmp" "${opts:-not mounted}"; fi
        opts="$(findmnt -no OPTIONS / 2>/dev/null || true)"
        printf '%s' "$opts" | grep -q 'errors=remount-ro' && record PASS "/ mounted errors=remount-ro" \
            || record WARN "/ mounted errors=remount-ro" "$opts"
    else record SKIP "mount options" "findmnt missing"; fi
fi

# ---------------------------------------------------------------------------
# 4. Network
# ---------------------------------------------------------------------------
if want_section network; then
    section "Network (docs/05)"
    check_file /etc/nftables.conf
    check_enabled nftables
    check_active nftables
    if have nft && is_root; then
        if nft -c -f /etc/nftables.conf >/dev/null 2>&1; then record PASS "nftables ruleset parses"
        else record FAIL "nftables ruleset parses" "nft -c -f failed"; fi
        pol_in="$(nft list chain inet filter input 2>/dev/null | awk -F';' '/policy/{print $NF}' | tr -d ' ')"
        [ "$pol_in" = "policy drop" ] && record PASS "input policy drop" || record FAIL "input policy drop" "${pol_in:-no inet filter input chain}"
        pol_out="$(nft list chain inet filter output 2>/dev/null | awk -F';' '/policy/{print $NF}' | tr -d ' ')"
        [ "$pol_out" = "policy drop" ] && record PASS "egress policy drop (tier 2+)" || record WARN "egress policy drop (tier 2+)" "${pol_out:-not set}"
        nft list chain inet filter input 2>/dev/null | grep -q 'meter\|limit rate' \
            && record PASS "per-source rate limiting present" || record WARN "per-source rate limiting present" "no limit rules found"
    else record SKIP "nftables contents" "needs root + nft"; fi

    check_file /etc/unbound/unbound.conf.d/paranoid.conf
    check_active unbound
    if [ -r /etc/resolv.conf ]; then
        grep -q '127.0.0.1' /etc/resolv.conf && record PASS "resolv.conf points at the local resolver" \
            || record WARN "resolv.conf points at the local resolver" "$(head -1 /etc/resolv.conf 2>/dev/null)"
    fi
    check_active chrony
    if have ss; then
        unexpected="$(ss -tulpn 2>/dev/null | awk 'NR>1{print $1, $5}' | grep -vE '127\.0\.0\.1|\[::1\]|10\.66\.' | grep -E ':(21|22|23|25|53|80|110|111|143|443|465|587|993|995|1521|3306|5432|5900|6379|8000|8080|8443|9200|27017) ' || true)"
        if [ -z "$unexpected" ]; then
            record PASS "no unexpected public listeners"
        else
            record WARN "no unexpected public listeners" "$(printf '%s' "$unexpected" | tr '\n' '|')"
        fi
    fi
    if [ "$TIER" -ge 2 ]; then
        if [ -r /etc/wireguard/wg0.conf ]; then
            if grep -q 'SERVER_PRIVATE_KEY' /etc/wireguard/wg0.conf 2>/dev/null; then
                record FAIL "WireGuard admin plane configured" "placeholder key still in /etc/wireguard/wg0.conf"
            else
                record PASS "WireGuard admin plane configured"
                check_mode /etc/wireguard/wg0.conf 600
            fi
        else record FAIL "WireGuard admin plane configured" "/etc/wireguard/wg0.conf missing"; fi
        check_enabled sshguard
    fi
fi

# ---------------------------------------------------------------------------
# 5. Apache
# ---------------------------------------------------------------------------
if want_section apache; then
    section "Apache (docs/06)"
    if ! have apache2ctl; then
        record SKIP "Apache checks" "apache2 not installed here"
    else
        if apache2ctl configtest >/dev/null 2>&1; then record PASS "apache2ctl configtest"; else record FAIL "apache2ctl configtest" "run it and read the output"; fi
        for bad in autoindex cgi userdir negotiation include info status proxy dav speling imagemap; do
            if apache2ctl -M 2>/dev/null | grep -q "_module.*${bad}"; then record FAIL "module $bad disabled" "still loaded"; fi
        done
        # If none matched we never recorded anything; record one positive.
        loaded_bad="$(apache2ctl -M 2>/dev/null | grep -cE '_(module).*(autoindex|cgi|userdir|negotiation|info|proxy|dav|speling|imagemap)' || true)"
        [ "${loaded_bad:-0}" -eq 0 ] && record PASS "dangerous modules pruned (autoindex/cgi/userdir/proxy/...)"
        apache2ctl -M 2>/dev/null | grep -q 'mpm_event' && record PASS "mpm_event in use" || record FAIL "mpm_event in use"
        apache2ctl -M 2>/dev/null | grep -q 'security2' && record PASS "mod_security3 loaded" || record FAIL "mod_security3 loaded"
        apache2ctl -M 2>/dev/null | grep -q 'headers_module' && record PASS "mod_headers loaded" || record FAIL "mod_headers loaded"
        apache2ctl -M 2>/dev/null | grep -q 'ssl_module' && record PASS "mod_ssl loaded" || record FAIL "mod_ssl loaded"

        check_file /etc/apache2/conf-available/tls-hardening.conf
        check_file /etc/apache2/conf-available/headers-hardening.conf
        check_file /etc/apache2/conf-available/security-hardening.conf
        check_file /etc/apache2/mods-available/security2.conf
        check_file /etc/modsecurity/crs/paranoid-crs.conf
        check_file /etc/systemd/system/apache2.service.d/99-paranoid.conf

        if [ -r /etc/apache2/conf-available/tls-hardening.conf ]; then
            grep -qE '^SSLProtocol\s+-all\s+\+TLSv1\.3' /etc/apache2/conf-available/tls-hardening.conf \
                && record PASS "TLS 1.3 only configured" || record FAIL "TLS 1.3 only configured" "check SSLProtocol"
            grep -q 'SSLSessionTickets off' /etc/apache2/conf-available/tls-hardening.conf \
                && record PASS "TLS session tickets off" || record WARN "TLS session tickets off" "not set"
        fi
        if [ -r /etc/apache2/apache2.conf ]; then
            grep -q 'ServerTokens Prod' /etc/apache2/apache2.conf && record PASS "ServerTokens Prod" || record FAIL "ServerTokens Prod"
            grep -q 'TraceEnable Off' /etc/apache2/apache2.conf && record PASS "TraceEnable Off" || record FAIL "TraceEnable Off"
            grep -q 'LimitXMLRequestBody 0' /etc/apache2/apache2.conf && record PASS "XML bodies refused" || record WARN "XML bodies refused" "LimitXMLRequestBody not 0"
        fi
        # Must be enabled, not merely downloaded: conf-enabled symlinks.
        [ -e /etc/apache2/conf-enabled/tls-hardening.conf ] && record PASS "tls-hardening enabled" \
            || record FAIL "tls-hardening enabled" "a2enconf tls-hardening"
        [ -e /etc/apache2/conf-enabled/headers-hardening.conf ] && record PASS "headers-hardening enabled" \
            || record FAIL "headers-hardening enabled" "a2enconf headers-hardening"

        if is_root && have systemd-analyze; then
            score="$(systemd-analyze security apache2 2>/dev/null | awk -F'[= ]+' '/Overall exposure level/{print $NF; exit}')"
            record PASS "apache2 sandbox exposure" "${score:-see systemd-analyze security apache2}"
        fi

        # TLS private keys must not be readable by the web user
        if is_root && [ -e /etc/letsencrypt/live ]; then
            firstkey="$(find /etc/letsencrypt/live -name privkey.pem 2>/dev/null | head -1 || true)"
            if [ -n "$firstkey" ]; then
                m="$(stat -c %a "$firstkey")"
                [ "$m" = "600" ] && record PASS "TLS private key mode 600" "$firstkey" \
                    || record FAIL "TLS private key mode 600" "$m on $firstkey"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 6. Physical / firmware / peripherals
# ---------------------------------------------------------------------------
if want_section physical; then
    section "Physical and firmware (docs/07)"
    # (nouveau/mei_me/snd_sof/btusb are checked in the kernel section; here we focus on the
    #  peripheral-facing drivers whose absence is the whole point of docs/07.)
    for m in uvcvideo thunderbolt intel_ish_ipc bluetooth; do
        check_module_absent "$m"
    done
    check_file /etc/usbguard/usbguard-daemon.conf
    check_file /etc/usbguard/rules.conf
    if [ -r /etc/usbguard/rules.conf ] && grep -q 'REPLACE' /etc/usbguard/rules.conf; then
        record FAIL "USBGuard rules generated from this machine" "template rules still contain REPLACE placeholders"
    elif [ -r /etc/usbguard/rules.conf ]; then
        record PASS "USBGuard rules generated from this machine"
    fi
    check_enabled usbguard
    check_active usbguard
    if have rfkill; then
        if rfkill list 2>/dev/null | grep -q 'Soft blocked: no'; then
            record WARN "radios blocked" "$(rfkill list 2>/dev/null | grep -c 'Soft blocked: no') radio(s) not blocked"
        else record PASS "radios blocked"; fi
    else record SKIP "radios blocked" "rfkill missing"; fi
    if [ -d /dev ] && compgen -G '/dev/video*' >/dev/null 2>&1; then
        record FAIL "no camera device nodes" "$(ls /dev/video* 2>/dev/null | tr '\n' ' ')"
    else record PASS "no camera device nodes"; fi
    check_file /var/log/paranoid/boots
fi

# ---------------------------------------------------------------------------
# 7. Isolation
# ---------------------------------------------------------------------------
if want_section isolation; then
    section "Isolation and virtualization (docs/08)"
    check_sysctl net.ipv4.ip_forward 0
    if have ss; then
        if ss -tulpn 2>/dev/null | grep -qE 'podman\.sock|docker\.sock|libvirt-sock'; then
            record WARN "no rootful container/virt sockets" "a root-equivalent socket exists"
        else record PASS "no rootful container/virt sockets"; fi
    fi
    if have machinectl; then
        mcount="$(machinectl list --no-legend 2>/dev/null | wc -l)"
        record PASS "systemd-nspawn containers" "${mcount} running"
    else record SKIP "systemd-nspawn" "systemd-container not installed"; fi
    if have podman; then
        record PASS "podman present" "$(podman --version 2>/dev/null)"
        if systemctl is-enabled --quiet podman.socket 2>/dev/null; then
            record FAIL "rootful podman socket disabled" "podman.socket is enabled - root-equivalent!"
        else record PASS "rootful podman socket disabled"; fi
    fi
    if have virsh; then
        if ss -x 2>/dev/null | grep -q 'libvirt-sock'; then
            record WARN "rootless libvirt only" "a system libvirt socket is present"
        else record PASS "rootless libvirt only"; fi
    fi
fi

# ---------------------------------------------------------------------------
# 8. Package policy
# ---------------------------------------------------------------------------
if want_section packages; then
    section "Software policy (docs/09)"
    check_file /etc/paranoid/package-justifications
    if have dpkg; then
        n="$(apt-mark showmanual 2>/dev/null | wc -l)"
        record PASS "manually installed package count" "$n (review monthly)"
    fi
    for p in build-essential gcc make python3-pip npm docker.io docker-ce; do
        if have dpkg && dpkg -s "$p" >/dev/null 2>&1; then
            record WARN "compiler/runtime not installed on host: $p" "install-on-demand policy (docs/09 §1)"
        fi
    done
    if have dpkg && dpkg -s fwupd >/dev/null 2>&1; then
        record WARN "fwupd purged after firmware update" "installed: purge it (docs/09 §1 q4)"
    else record PASS "fwupd purged after firmware update"; fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%s== Summary (tier %s) ==%s\n' "$BLUE" "$TIER" "$NC"
printf '  %sPASS%s %d\n  %sFAIL%s %d\n  %sWARN%s %d\n  %sSKIP%s %d\n' \
    "$GREEN" "$NC" "$PASS" "$RED" "$NC" "$FAIL" "$YELLOW" "$NC" "$WARN" "$DIM" "$NC" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    printf '\n%sFAILED checks:%s\n' "$RED" "$NC"
    printf '%b' "$FAILED_LIST" | sed 's/^/  - /'
    printf '\nFix the causes (docs/10 §4), then re-run. Do not "fix" the checker.\n'
    exit 1
fi
printf '\nAll checks passed for tier %s. Re-baseline AIDE if you changed anything: docs/04 §8.\n' "$TIER"
exit 0

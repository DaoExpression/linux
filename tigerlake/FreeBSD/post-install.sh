#!/bin/sh
# post-install.sh — run as root ON THE INSTALLED FREEBSD SYSTEM (not during bsdinstall).
# Merges files from this directory into the running system:
#   rc.conf, loader.conf, sysctl.conf, doas.conf, xorg.conf, pf.conf
# Backs up every original before touching it; never overwrites user-set keys.
# Target hardware: i7-11390H (Tiger Lake) with Iris Xe, AX201 Wi-Fi, I219 Ethernet, HDA audio.

set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
BAK="/root/conf-backup-$TS"
mkdir -p "$BAK"

log() { printf '==> %s\n' "$*"; }

backup() {
    f="$1"
    if [ -f "$f" ]; then
        mkdir -p "$BAK$(dirname "$f")"
        cp -p "$f" "$BAK$f"
        log "backed up $f -> $BAK$f"
    fi
}

# Append a line to a config file only if it is not already present (by first token).
append_missing() {
    f="$1"; line="$2"
    key="$(printf '%s' "$line" | sed 's/=.*//; s/^ *//')"
    # strip possible quotes the key may carry when values include = (rare)
    if [ ! -f "$f" ] || ! grep -q "^[[:space:]]*${key}=" "$f"; then
        printf '\n# added by post-install.sh %s\n%s\n' "$TS" "$line" >> "$f"
        log "appended to $f: $line"
    else
        log "already set in $f: $key (left untouched)"
    fi
}

# ---------- /etc/rc.conf ----------
backup /etc/rc.conf
append_missing /etc/rc.conf 'hostname="freebsd-desktop"'
append_missing /etc/rc.conf 'keymap="pt"'
append_missing /etc/rc.conf 'kld_list="i915kms"'
append_missing /etc/rc.conf 'ifconfig_em0="DHCP"'
append_missing /etc/rc.conf 'wlans_iwlwifi0="wlan0"'
append_missing /etc/rc.conf 'create_args_wlan0="wlandev iwlwifi0"'
append_missing /etc/rc.conf 'ifconfig_wlan0="WPA SYNCDHCP"'
append_missing /etc/rc.conf 'defaultroute_delay="0"'
append_missing /etc/rc.conf 'dbus_enable="YES"'
append_missing /etc/rc.conf 'moused_enable="YES"'
append_missing /etc/rc.conf 'powerd_enable="YES"'
append_missing /etc/rc.conf 'powerd_flags="-a hiadaptive -b adaptive -n adaptive"'
append_missing /etc/rc.conf 'sddm_enable="YES"'
append_missing /etc/rc.conf 'pf_enable="YES"'
append_missing /etc/rc.conf 'pf_rules="/etc/pf.conf"'
append_missing /etc/rc.conf 'pflog_enable="YES"'
append_missing /etc/rc.conf 'cloned_interfaces="bridge0"'
append_missing /etc/rc.conf 'ifconfig_bridge0="inet 10.0.100.1/24 descr jailbridge"'

# ---------- /boot/loader.conf ----------
backup /boot/loader.conf
append_missing /boot/loader.conf 'zfs_load="YES"'
append_missing /boot/loader.conf 'kern.geom.label.gptid.enable="0"'
append_missing /boot/loader.conf 'autoboot_delay="3"'

# ---------- /etc/sysctl.conf (only keys that exist on this system) ----------
backup /etc/sysctl.conf
add_sysctl_if_exists() {
    key="$1"; val="$2"
    if sysctl -n "$key" >/dev/null 2>&1; then
        append_missing /etc/sysctl.conf "${key}=${val}"
    else
        log "sysctl $key not present on this kernel — skipped"
    fi
}
add_sysctl_if_exists kern.sched.preempt_thresh 224
add_sysctl_if_exists kern.ipc.shmmax 134217728
add_sysctl_if_exists kern.ipc.shmall 32768
add_sysctl_if_exists kern.ipc.maxsockbuf 4194304
add_sysctl_if_exists net.inet.tcp.recvbuf_max 2097152
add_sysctl_if_exists net.inet.tcp.sendbuf_max 2097152
add_sysctl_if_exists net.inet.tcp.delayed_ack 0
add_sysctl_if_exists net.local.dgram.maxdgram 16384
add_sysctl_if_exists net.local.dgram.recvspace 65536
add_sysctl_if_exists net.local.stream.sendspace 65536
add_sysctl_if_exists net.local.stream.recvspace 65536
add_sysctl_if_exists net.inet.icmp.icmplim 200

# ---------- pf firewall ----------
if [ -f /etc/pf.conf ]; then
    backup /etc/pf.conf
    if cmp -s "$SRC/pf.conf" /etc/pf.conf; then
        log "/etc/pf.conf already matches; nothing to do"
    else
        install -m 644 "$SRC/pf.conf" /etc/pf.conf.new
        if pfctl -nf /etc/pf.conf.new 2>/dev/null; then
            mv /etc/pf.conf.new /etc/pf.conf
            log "installed validated /etc/pf.conf"
        else
            log "WARNING: shipped pf.conf failed pfctl -nf on this system."
            log "         Kept your old /etc/pf.conf; the new one is /etc/pf.conf.new"
        fi
    fi
else
    install -m 644 "$SRC/pf.conf" /etc/pf.conf
    log "installed /etc/pf.conf"
fi

# ---------- jail.conf (base-system jails; walkthrough in JAILS.txt) ----------
if [ -f /etc/jail.conf ]; then
    backup /etc/jail.conf
    if cmp -s "$SRC/jail.conf" /etc/jail.conf; then
        log "/etc/jail.conf already matches; nothing to do"
    else
        install -m 644 "$SRC/jail.conf" /etc/jail.conf.new
        if jail -f /etc/jail.conf.new -e : >/dev/null 2>&1; then
            mv /etc/jail.conf.new /etc/jail.conf
            log "installed validated /etc/jail.conf"
        else
            log "WARNING: shipped jail.conf failed jail(8) parse on this system."
            log "         Kept your old /etc/jail.conf; the new one is /etc/jail.conf.new"
        fi
    fi
else
    install -m 644 "$SRC/jail.conf" /etc/jail.conf
    log "installed /etc/jail.conf (jails stay OFF until jail_enable=YES; see JAILS.txt)"
fi

# ---------- doas ----------
install -d /usr/local/etc
if [ ! -f /usr/local/etc/doas.conf ]; then
    install -m 640 "$SRC/doas.conf" /usr/local/etc/doas.conf
    log "installed /usr/local/etc/doas.conf (edit: set your user)"
else
    log "/usr/local/etc/doas.conf exists — left untouched"
fi

# ---------- Xorg ----------
install -d /usr/local/etc/X11
if [ ! -f /usr/local/etc/X11/xorg.conf ]; then
    install -m 644 "$SRC/xorg.conf" /usr/local/etc/X11/xorg.conf
    log "installed /usr/local/etc/X11/xorg.conf (delete it anytime — Xorg autodetects)"
else
    log "/usr/local/etc/X11/xorg.conf exists — left untouched"
fi

# ---------- Packages (graphics, wifi firmware, desktop basics) ----------
if command -v pkg >/dev/null 2>&1; then
    pkg update
    pkg install -y drm-kmod gpu-firmware-intel-kmod-tigerlake \
        wifi-firmware-iwlwifi-kmod \
        sddm dbus doas \
        powertop
else
    log "WARNING: pkg not found; install packages manually (see README.md)"
fi

log "Done. Review $BAK for originals, then reboot."
log "After login: set Wi-Fi in /etc/wpa_supplicant.conf; pf is active"
log "(check with:  pfctl -si   |   log: tcpdump -n -e -i pflog0 )."

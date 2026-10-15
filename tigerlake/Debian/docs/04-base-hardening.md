# 04 — Base system hardening

Everything here ships as an artefact under `files/`; `scripts/install-hardening.sh` installs it.
This document explains **what** each file does, **why**, and how to verify it.

---

## 1. Users, root, and sudo

| Action | Command | Rationale |
|---|---|---|
| Lock root login | `sudo passwd -l root` | No direct root login. `sudo` attributes and logs every action. |
| Force sudo re-auth | `Defaults timestamp_timeout=0` in `files/etc/sudoers.d/00-paranoid` | An unlocked terminal cannot be used to `sudo` 15 minutes later. |
| Require a TTY and a PTY | `Defaults requiretty` (where usable) + `Defaults use_pty` | Kills stdin/stdout hijacking tricks; `use_pty` is the modern, portable part. |
| Log sudo to its own file | `Defaults logfile=/var/log/sudo.log` (mode 0600 root:root) | Survives log tampering attempts better when combined with remote shipping. |
| Reset the environment | `Defaults env_reset, secure_path=...` | No poisoned `PATH`/`LD_*` from an administrative session. |
| Three password tries, tell nobody why | `Defaults passwd_tries=3, !lecture` | No hints in the failure output. |
| Add admin to `sudo`, nothing else | `sudo adduser admin sudo` then remove `admin` from `adm` if you do not want it reading logs | Least privilege, one account. |
| Disable unused system accounts | `sudo usermod -L daemon bin sys games` etc. | Any account with a shell is a pivot; `nologin` them. |
| Password policy | `files/etc/security/pwquality.conf.d/99-paranoid.conf` + the PAM wiring in `files/etc/pam.d/README.md` | Enforced length (≥ 16) and quality on the *admin* password, applied by PAM, not by convention. |
| Lockout after failures | `files/etc/security/faillock.conf` (`deny=5`, `unlock_time=900`, `root_unlock_time=60`) and the `pam_faillock` line in PAM | Brute force against the console/sudo dies quickly. **Keep a tested root-console recovery path in mind** — this is why `root_unlock_time` is short. |
| No core dumps for logins | `files/etc/security/limits.d/99-paranoid.conf`: `hard core 0`, `nofile`, `nproc`, `maxlogins 2` | A core dump of a privileged process is a credential leak. |
| Shell hygiene | `files/etc/profile.d/99-hardening.sh`: `umask 027`, `TMOUT=600`, `HISTCONTROL=ignoreboth:erasedups`, `HISTIGNORE` for commands containing `pass`/`key`/`token` | New files are not world-readable, idle sessions die, and secrets do not end up in history. |

```bash
sudo cp -a files/etc/sudoers.d/00-paranoid /etc/sudoers.d/00-paranoid
sudo chmod 0440 /etc/sudoers.d/00-paranoid && sudo visudo -c
sudo cp files/etc/security/pwquality.conf.d/99-paranoid.conf /etc/security/pwquality.conf.d/
sudo cp files/etc/security/faillock.conf /etc/security/faillock.conf
sudo cp files/etc/security/limits.d/99-paranoid.conf /etc/security/limits.d/
sudo cp files/etc/profile.d/99-hardening.sh /etc/profile.d/ && sudo chmod 0644 /etc/profile.d/99-hardening.sh
sudo passwd -l root
```

`pam_faillock` needs the PAM stack to include it in `auth` and `account` (the how-to matters):
`files/etc/pam.d/README.md` in this repo shows the exact lines to add to `common-auth`/`common-account`
for Debian's `pam-auth-update`-managed files, and you re-run `sudo pam-auth-update --enable faillock`.

## 2. SSH (the admin plane's cryptosystem)

`files/etc/ssh/sshd_config.d/00-paranoid.conf` is a drop-in (Debian's `Include
/etc/ssh/sshd_config.d/*.conf` is already at the top of `sshd_config`). Highlights and why:

```
PermitRootLogin no                  # no root over the wire
PasswordAuthentication no           # keys only; passwords cannot be brute-forced if they are never accepted
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2
PermitEmptyPasswords no
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 20                   # shrinks the unauthenticated window; a DoS trade-off, accepted
AllowAgentForwarding no
AllowTcpForwarding no               # admin tunnelling must use the WireGuard plane instead
X11Forwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no
UsePAM yes
StrictModes yes
LogLevel VERBOSE                    # logs key fingerprints -> tells you *which* key was used
PidFile /run/sshd.pid
```

Modern cryptography, explicitly pinned (no `default` surprises):

```
HostKey /etc/ssh/ssh_host_ed25519_key        # delete the RSA host keys after verifying clients can connect
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com
PubkeyAcceptedAlgorithms ssh-ed25519,sk-ssh-ed25519@openssh.com
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
```

`sntrup761x25519-sha512@openssh.com` is the post-quantum hybrid KEX (OpenSSH ≥ 9.0; trixie has 10.x).
`AllowUsers admin` and `DenyUsers *` in the config keep unknown accounts out even if one appears.

**Hardware keys:** if you own a FIDO2 token, put `sk-ssh-ed25519@openssh.com` keys in
`~/.ssh/authorized_keys` **and** set `required` … actually the portable way is a line in
`authorized_keys`:

```
sk-ssh-ed25519@openssh.com AAAAH... admin@fido
```

with touch required by default. That is the single best SSH upgrade available: it makes stolen
laptop keys useless.

```bash
sudo sshd -t                                  # syntax check (must print nothing)
sudo systemctl reload ssh
sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication|kexalgorithms|ciphers|allowusers'
sudo journalctl -u ssh -n 20                  # confirm the reload, then test in a SECOND session before closing the first
```

**[TIER 2]** Bind SSH to the WireGuard interface only (see `docs/05` §5): move the `ListenAddress` to
the tunnel address and let nftables drop 22 on the WAN. Then the SSH service is not
internet-reachable at all.

## 3. Kernel parameters — `files/etc/sysctl.d/99-paranoid.conf`

Grouped, with the reasoning that actually matters:

```ini
# — information leaks —
kernel.dmesg_restrict = 1        # unprivileged users cannot read the ring buffer (addresses, device info)
kernel.kptr_restrict = 2         # %pK prints nothing to unprivileged users
kernel.perf_event_paranoid = 3   # perf is a known info-leak/side-channel tool; only root may use it
kernel.unprivileged_bpf_disabled = 2   # BPF is a powerful primitive; nobody unprivileged needs it
net.core.bpf_jit_harden = 2      # hardens the BPF JIT against spray attacks
vm.unprivileged_userfaultfd = 0  # userfaultfd was a common exploit primitive
kernel.yama.ptrace_scope = 2     # only root may ptrace non-children
kernel.io_uring_disabled = 2     # io_uring has a heavy CVE history and nothing here needs it
dev.tty.ldisc_autoload = 0       # no on-demand TTY line-discipline loading

# — memory/exec integrity —
kernel.randomize_va_space = 2
kernel.kexec_load_disabled = 1   # kexec is a boot-integrity bypass; we never use it
kernel.sysrq = 0                 # no magic SysRq on a server
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# — network —
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1 ; net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0 ; net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0 ; net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.arp_ignore = 1 ; net.ipv4.conf.all.arp_announce = 2
net.ipv6.conf.all.accept_redirects = 0 ; net.ipv6.conf.all.accept_ra = 0   # we use static/routed IPv6 only
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.all.use_tempaddr = 2       # privacy addresses for outbound
net.ipv4.ip_forward = 0                  # [docs/08] set to 1 ONLY if you build internal VM bridges
net.ipv4.conf.all.forwarding = 0
```

Deliberate omissions, so you know they were considered and why they are **not** in the artefact:

- `user.max_user_namespaces=0` / `kernel.unprivileged_userns_clone=0` — would break rootless
  containers and `usbguard`'s namespace use. Instead we rely on the LSM restrictions of the
  specific services. The comment in the file says exactly this, so no one "helpfully" adds it later.
- `net.ipv4.tcp_timestamps=0` — breaks PAWS and worsens retransmits for negligible benefit.
- `fs.suid_dumpable=0` — already covered by `hard core 0` in limits; both is fine, add if you like.
- `net.ipv6.conf.all.disable_ipv6=1` — only if you truly have no IPv6 clients. Then also delete the
  `ip6` table from `nftables.conf` (the file tells you how).

```bash
sudo cp files/etc/sysctl.d/99-paranoid.conf /etc/sysctl.d/
sudo sysctl --system | tail -5
sudo sysctl -a 2>/dev/null | grep -E 'kernel.kptr_restrict|kernel.perf_event_paranoid|unprivileged_bpf'
```

## 4. Kernel modules — what loads and what refuses to

- `files/etc/modprobe.d/90-blacklist-paranoid.conf` — the blacklist built from `docs/00` §2, with a
  comment per module naming the device it kills.
- `files/etc/modules-load.d/00-paranoid.conf` — deliberately **empty** (comment only). Nothing here
  loads on demand at boot; if you need to add a module, you write it down and you can audit it.
- `files/etc/modprobe.d/95-options-paranoid.conf` — `options iwlwifi disable_11ax=0` only if Wi-Fi
  is retained; plus hardening options for `usb-storage` (`quirks=`) if you keep it. Every option has
  a comment; there are no unexplained lines.

The **strong** version of "no more modules" is `kernel.modules_disabled=1`, applied as late in boot
as possible:

```bash
# files/etc/systemd/system/kernel-modules-lock.service  (shipped, DISABLED by default)
[Unit]
Description=Freeze the module table (Tier 3)
ConditionPathExists=/etc/paranoid/modules-lock
After=local-fs.target network-online.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 1 > /proc/sys/kernel/modules_disabled'
[Install]
WantedBy=multi-user.target
```

Enable it only after everything you will *ever* need is loaded: it breaks `fwupd`, libvirt's
kernel modules, USB keyboards attached later, and cannot be undone without a reboot. That is exactly
why it is opt-in via `/etc/paranoid/modules-lock`. Verify it is never enabled with a warning inside
`verify-hardening.sh` if you have it on but also have fwupd installed.

## 5. Mounts — `files/etc/fstab`

```fstab
# <file system>            <mount point> <type> <options>                                        <dump> <pass>
UUID=<esp-uuid>            /boot/efi     vfat   umask=0077,shortname=winnt,noexec,nosuid,nodev      0      2
UUID=<boot-uuid>           /boot         ext4   defaults,nosuid,nodev                            0      2
/dev/vg0/root              /             ext4   defaults,nodev,errors=remount-ro,noatime          0      1
/dev/vg0/var               /var          ext4   defaults,nosuid,nodev,noatime                    0      2
/dev/vg0/varlog            /var/log      ext4   defaults,nosuid,nodev,noexec,noatime             0      2
/dev/vg0/vartmp            /var/tmp      ext4   defaults,nosuid,nodev,noexec,noatime             0      2
/dev/vg0/home              /home         ext4   defaults,nosuid,nodev,noexec,noatime             0      2
/dev/vg0/srv               /srv          ext4   defaults,nosuid,nodev,noatime                    0      2
/dev/vg0/swap              none          swap   sw                                               0      0
tmpfs                      /tmp          tmpfs  rw,nosuid,nodev,noexec,relatime,size=2G,mode=1777  0      0
tmpfs                      /dev/shm      tmpfs  rw,nosuid,nodev,noexec,size=512M,mode=1777        0      0
```

- `noexec` on `/var/log` and `/var/tmp` is the important one: attackers love those directories
  because they are writable and historically executable.
- `/tmp` on tmpfs with `noexec` is fast, size-bounded, and wiped at reboot. For a web server, that
  also means a compromised service cannot leave a payload behind after a reboot.
- `/srv` is deliberately **not** `noexec` — if your vhost serves CGI in an isolated instance
  (`docs/06` §7), you may need execution there. If you do not, add `noexec`.
- **[TIER 3]** `/boot` read-only: change `defaults` to `ro` and remount rw only for kernel
  operations: `sudo mount -o remount,rw /boot && sudo apt full-upgrade && sudo mount -o remount,ro /boot`.
  The shipped `files/etc/systemd/system/remount-boot-ro.service` does this automatically at boot.
- **[TIER 3]** `/usr` read-only via the `systemd` `usr` overlay is another option but it breaks apt's
  upgrade path in ways most people do not want. Not shipped; mentioned so you know it exists.

```bash
sudo findmnt --verify                 # fstab syntax/sanity
sudo findmnt -o TARGET,OPTIONS | grep -E 'tmp|var|boot'
sudo mount -o remount /tmp 2>/dev/null || true   # after editing fstab, reboot is cleanest
```

## 6. LSM stack: AppArmor (+ landlock/yama from the cmdline)

`files/etc/apparmor.d/local/usr.sbin.apache2` is a `local/` include — it **adds** to Debian's own
Apache profile without fighting it during package upgrades. It denies write access to everything
except `/var/www/<site>` paths, and denies capability use outright. See `docs/06` §6 for the full
Apache-side story.

`files/etc/apparmor.d/tunables/paranoid-home.d/99-paranoid` pins `@{HOME}` handling so profiles do
not silently inherit a wrong home.

```bash
sudo cp -a files/etc/apparmor.d/. /etc/apparmor.d/
sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.apache2   # reload after edits
sudo aa-status --verbose | head -40
sudo aa-enforce /etc/apparmor.d/usr.sbin.apache2
cat /sys/kernel/security/apparmor/profiles | grep -c enforce    # count of enforcing profiles
```

Landlock and yama are activated by the `lsm=`/`yama.ptrace_scope=2` settings already applied in §3
and `docs/03`. Confirm the stack order:

```bash
cat /sys/kernel/security/lsm
```

## 7. auditd — `files/etc/audit/rules.d/99-paranoid.rules`

Design goals: (a) catch changes to the trust roots, (b) catch the syscalls that turn a bug into a
compromise, (c) never drown the log. The rule set does exactly three things:

1. **Identity/auth**: `-w /etc/passwd -p wa`, `/etc/shadow`, `/etc/gshadow`, `/etc/group`,
   `/etc/sudoers`, `/etc/sudoers.d`, `/etc/pam.d`, `/etc/ssh/sshd_config`, `/etc/security`.
2. **Execution/changes to binaries and modules**: `-a always,exit -F arch=b64 -S
   init_module,finit_module,delete_module -k modules`,
   `-a always,exit -F arch=b64 -S execve -F euid=0 -F auid!=unset -k root-exec` (only *root* execs =
   low volume, high signal),
   `-a always,exit -F arch=b64 -S ptrace,bpf -k primitives`,
   `-a always,exit -F arch=b64 -S setuid,setgid,setreuid,setregid -F auid>=1000 -F auid!=unset -k priv-esc`,
   `-w /usr/bin -p wa -k binaries` and `-w /usr/sbin -p wa -k binaries`.
3. **The web/service plane**: `-w /etc/apache2 -p wa -k apache-config`,
   `-w /etc/ssl/private -p rwa -k tls-keys`,
   `-w /var/www -p wa -k webroot`,
   `-a always,exit -F arch=b64 -S connect -F a0=2 -k net-out` — **[TIER 3]** only, it is noisy.

Plus: `-e 2` (immutable rules), `--backlog_wait_time`, and `max_log_file_action=keep_logs` with
rotation handled by `auditd.conf` (both shipped). Immutability means **you cannot change the rules
without a reboot** — deliberate, and it is why the rule file is a drop-in that you edit offline.

```bash
sudo cp files/etc/audit/rules.d/99-paranoid.rules /etc/audit/rules.d/
sudo cp files/etc/audit/auditd.conf /etc/audit/auditd.conf
sudo augenrules --load
sudo auditctl -l | head -20
sudo auditctl -s | grep -E 'enabled|failure'      # enabled=2 = immutable, failure=1
```

Ship events off-host (`audispd-plugins` is in the install list):

```bash
# files/etc/audit/plugins.d/au-remote.conf + audisp-remote.conf are shipped with sane TLS defaults
sudo sed -i 's/^active = no/active = yes/' /etc/audit/plugins.d/au-remote.conf
# remote_server/port/transport in /etc/audit/audisp-remote.conf, then:
sudo systemctl restart auditd
sudo ausearch -k apache-config -ts recent | head
```

## 8. File integrity: AIDE + debsums

- `files/etc/aide/aide.conf.d/99_paranoid.conf` adds a strict ruleset for `/etc`, `/bin`, `/sbin`,
  `/usr/{bin,sbin,lib}`, `/var/www` (contents: `p+i+n+u+g+s+m+c+sha512`), while excluding volatile
  paths (`/var/log`, `/var/cache`, `/run`, `/proc`).
- The **baseline must be taken last**, after all your config is final. Otherwise every check is noise.

```bash
sudo cp files/etc/aide/aide.conf.d/99_paranoid.conf /etc/aide/aide.conf.d/
sudo aideinit && sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
sudo cp files/etc/systemd/system/aide-check.{service,timer} /etc/systemd/system/
sudo systemctl enable --now aide-check.timer
sudo cp files/etc/systemd/system/debsums-check.{service,timer} /etc/systemd/system/
sudo systemctl enable --now debsums-check.timer
sudo systemctl list-timers aide-check.timer debsums-check.timer
```

Both timers write results to `/var/log/paranoid/` (mode 0750, root:adm) and, at Tier 2, are expected
to also email or push the diff off-host. The `debsums -s` check answers a different question than
AIDE ("did any *packaged* file change?") and is cheap enough to run daily.

## 9. apt and updates — the part everyone gets wrong

`files/etc/apt/apt.conf.d/99-paranoid`:

```
APT::Get::AllowUnauthenticated "false";
APT::Get::Install-Recommends "false";        # the "install only necessary software" policy, enforced
APT::Get::Install-Suggests "false";
Acquire::AllowInsecureRepositories "false";
Acquire::Check-Valid-Until "true";
Acquire::Max-ValidTime "604800";             # refuse stale metadata (7 days)
Acquire::https::Verify-Peer "true";
Acquire::https::Verify-Host "true";
Acquire::Retries "3";
Binary::apt::APT::Keep-Downloaded-Packages "false";
AP::Sanitize-Environment "true";
DPkg::Pre-Install-Pkgs { "/usr/sbin/dpkg-preconfigure --apt || true"; };
DPkg::Post-Invoke { "/usr/local/sbin/sign-uki-hook || true"; };
```

Notes on what is **not** here and why:

- No repo pinning to a private mirror: you would need one, and pinning a mirror you do not control is
  theatre. Instead **restrict sources to `main` + `non-free-firmware`** and prefer `deb` over `http`
  where the mirror supports TLS (`https://deb.debian.org`). `docs/09` covers the mirror question.
- `unattended-upgrades` is configured for `-security` **only** (`files/etc/apt/apt.conf.d/50unattended-upgrades`),
  with `Automatic-Reboot "false"` and `Automatic-Reboot-Time` unset — a kernel/reboot decision on a
  server is yours, not apt's. `needrestart` is set to `list` (not auto-restart) at Tier 2 so you see
  what will bounce; `docs/10` §3 is the weekly reboot/restart procedure.
- `apt-listchanges` is enabled so you read what the update claims to do before it lands.

```bash
sudo cp files/etc/apt/apt.conf.d/99-paranoid /etc/apt/apt.conf.d/
sudo cp files/etc/apt/apt.conf.d/50unattended-upgrades /etc/apt/apt.conf.d/
sudo cp files/etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/
sudo apt-get update 2>&1 | tail -3
sudo unattended-upgrade --dry-run -d 2>&1 | tail -20
apt-config dump | grep -E 'Install-Recommends|AllowUnauthenticated|Check-Valid-Until'
```

## 10. systemd, journald, coredumps

`files/etc/systemd/coredump.conf.d/99-paranoid.conf` → `Storage=none`, `ProcessSizeMax=0`: no core
dumps are written at all. `files/etc/systemd/journald.conf.d/99-paranoid.conf` →
`Storage=persistent`, `Compress=yes`, `SystemMaxUse=512M`, `SystemMaxFileSize=64M`, `RateLimit*`
tightened, `ForwardToSyslog=no` (we do not run rsyslog), `Audit=yes`, and `Seal=yes` **[Tier 2,
degrades safely without a TPM]** so tampering with the journal is detectable.

`files/etc/systemd/system.conf.d/99-paranoid.conf` sets tighter defaults
(`DefaultTimeoutStopSec=20s`, `DumpCore=no`, `CtrlAltDelBurstAction=none` — no accidental reboots from
an attached keyboard).

```bash
sudo mkdir -p /etc/systemd/{coredump.conf.d,journald.conf.d,system.conf.d}
sudo cp files/etc/systemd/coredump.conf.d/99-paranoid.conf /etc/systemd/coredump.conf.d/
sudo cp files/etc/systemd/journald.conf.d/99-paranoid.conf /etc/systemd/journald.conf.d/
sudo cp files/etc/systemd/system.conf.d/99-paranoid.conf /etc/systemd/system.conf.d/
sudo systemctl daemon-reexec && sudo systemctl restart systemd-journald
journalctl --disk-usage
cat /proc/sys/kernel/core_pattern          # should be '|/bin/false' per the artefact, or empty+Storage=none
sudo systemd-analyze security --offline=true apache2 | tail -5   # reports the unit's exposure score
```

## 11. Time and DNS

**Time** (`files/etc/chrony/chrony.conf`): NTS (RFC 8915) via `nts` sources
(`server <host> iburst nts`), `makestep 1.0 3`, `rtcsync`, `minsources 2`, and **no** `allow`
directive (this machine is not a time server for others). Correct time matters because TLS, audit
timestamps, and certificate validity all depend on it.

**DNS** (`files/etc/unbound/unbound.conf.d/paranoid.conf`): a local **validating** resolver on
`127.0.0.1` with:

```
server:
  interface: 127.0.0.1
  port: 53
  access-control: 127.0.0.0/8 allow
  do-ip6: no                     # unless you have IPv6 upstream connectivity
  hide-identity: yes
  hide-version: yes
  harden-glue: yes
  harden-dnssec-stripped: yes
  harden-below-nxdomain: yes
  harden-referral-path: yes
  qname-minimisation: yes
  aggressive-nsec: yes
  prefetch: yes
  rrset-roundrobin: yes
  minimal-responses: yes
  val-log-level: 2
  auto-trust-anchor-file: "/var/lib/unbound/root.key"
  tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"
  do-not-query-localhost: yes
  private-address: 10.0.0.0/8 ... (RFC1918 + link-local)   # blocks DNS-rebind into your LAN
forward-zone:
  name: "."
  forward-tls-upstream: yes      # DNS-over-TLS upstream, then DNSSEC-validated locally
  forward-addr: 1.1.1.1@853#cloudflare-dns.com
  forward-addr: 9.9.9.9@853#dns.quad9.net
```

Why a resolver at all instead of plain `/etc/resolv.conf`: (a) DNSSEC validation happens on *your*
box, (b) DNS-over-TLS hides queries from the local network, (c) `private-address` blocks rebinding
attacks aimed at your LAN, (d) all DNS becomes local-only traffic so the nftables egress allowlist
can be one line instead of "whatever port 53 to anywhere".

```bash
sudo apt-get install --no-install-recommends unbound chrony
sudo cp files/etc/unbound/unbound.conf.d/paranoid.conf /etc/unbound/unbound.conf.d/
sudo unbound-checkconf
sudo systemctl restart unbound && sudo systemctl restart chrony
# make the system use it (and make sure nothing else is managing resolv.conf)
echo 'nameserver 127.0.0.1' | sudo tee /etc/resolv.conf
sudo chattr +i /etc/resolv.conf 2>/dev/null || true
sudo systemctl disable --now systemd-resolved 2>/dev/null || true
dig +dnssec debian.org @127.0.0.1 | grep -E 'flags|ad;'
chronyc tracking && chronyc sources -v | head
```

## 12. Verification for this document

```bash
sudo pwck -r ; sudo grpck -r              # no orphaned accounts/groups
sudo passwd -S root                       # -> L (locked)
sudo -l -U admin                          # exactly the intended privilege set
sudo sysctl -a 2>/dev/null | grep -cE '= *[01]' >/dev/null   # (spot-check the artefact instead)
sudo apparmor_status --enabled && sudo aa-status | head -5
sudo auditctl -s
sudo aide --check --config /etc/aide/aide.conf | tail -5
sudo systemctl is-enabled unattended-upgrades auditd apparmor unbound chrony
bash scripts/verify-hardening.sh --tier 2
```

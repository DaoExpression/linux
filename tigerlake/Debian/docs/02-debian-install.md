# 02 — Installing Debian (minimal, encrypted, offline-first)

Target: **Debian 13 "trixie", amd64**, netinst or full CD ISO verified by signature.
Reference hardware: see `docs/00`. No desktop environment will be installed, ever.

> Verify the ISO before writing it. This first step is the one people skip.
> ```bash
> gpg --keyserver keyring.debian.org --recv-keys 0x<keyid from https://www.debian.org/CD/verify>
> sha512sum debian-13.x.y-amd64-netinst.iso
> gpg --verify SHA512SUMS.sign SHA512SUMS
> ```

## 1. Before you boot the installer (firmware prep)

1. **Flash the latest Dell BIOS first**, from Dell's site, over a trusted network, before any OS
   exists. Note the version string; `docs/00` §7 covers keeping it current with `fwupd`.
2. Set a **BIOS password** (long, distinct from every other password you own) and lock firmware
   settings so an attacker with 5 minutes cannot flip Secure Boot off or boot foreign media.
   Enable **Kernel DMA Protection** and set **Thunderbolt Security = User Authorization**.
3. **Disable**: camera, microphone, Bluetooth, WWAN (if present), Wake-on-LAN, "enable legacy ROM
   option", PXE/network boot, USB boot *after* the install is complete.
4. Decide Wi-Fi vs Ethernet **now**:
   - Wired Ethernet available → during install, do not load `iwlwifi`; blacklist it later
     (`docs/00` §2). Simplest and best.
   - Wi-Fi only → you will need `firmware-iwlwifi` from `non-free-firmware` at install time, and you
     accept that radio firmware is unaudited. Strongly prefer a USB-Ethernet adapter instead.
5. Decide your **profile** (`docs/03` §1): P1 embedded LUKS header (recommended, simplest) or
   P2 detached header (maximum, boot requires a USB token).

## 2. Interactive install — the exact choices

Boot the netinst. Choose **"Advanced options → Expert install"** (not graphical). Expert mode is
what lets you turn *off* the parts that add packages.

| Installer step | Choice | Why |
|---|---|---|
| Language/locale | `en_US.UTF-8` only, do not install additional locales | fewer files, fewer surprises |
| Keyboard | your layout, no dead keys | |
| Network | **disable autoconfiguration if you have a local mirror**, else keep DHCP | no unnecessary services |
| Hostname | a *boring* name, e.g. `srv-01` (not `mail`, not `db`) | hostname leaks role to scanners via banners |
| Domain | leave empty or use a non-public name | |
| Root password | **set a long passphrase now**; it will be locked in `docs/04` | installers require it; we lock it after |
| User | full name, username `admin`, **strong passphrase**. Do not reuse your LUKS passphrase | single unprivileged admin account |
| Clock | UTC, NTP later via `chrony` + NTS | |
| Partitioning | **Manual** → see §3 | necessary for the layout we want |
| Package manager | your mirror; enable `main`, `non-free-firmware`; **disable `contrib`** | `contrib` pulls non-free userland rarely needed |
| Tasksel | **uncheck everything** — including "standard system utilities" **[TIER 3]** | tier 3 = truly minimal; tier 2 keeps standard utils for a workable console |
| Install GRUB | **no** if you plan Secure Boot with your own keys + `systemd-boot` (`docs/03`). Yes = fallback path | grub-efi is signed by Debian, not by you |
| Popularity contest | **no** | |
| Snapshots/backports | **no** | |

> If you keep "standard system utilities": it brings ~120 packages (less, vim-tiny, apt-utils,
> cron, logrotate, isc-dhcp-client, openssh-client, …). That is acceptable at Tier 2 and is assumed
> by the rest of this repo — several artefacts use `rsync`, `less`, `curl`. At Tier 3 uncheck it and
> install only what you truly use; `verify-hardening.sh` will list what it expects.

## 3. Partitioning (manual, encrypted)

Layout used throughout this repo. Sizes assume a 512 GB NVMe; scale down but keep `/var/log`
separate and keep swap present (small).

```
/dev/nvme0n1
  p1  1 GiB   FAT32   EFI System Partition   /boot/efi   (umask=0077, ro after setup)
  p2  1 GiB   ext4    /boot                  (Tier 2: rw, remounted ro for updates;
                                              Tier 3: ro permanently)
  p3  rest    (nothing)  → LUKS2 container, no filesystem
       └─ crypt   LVM VG "vg0"
            ├─ root   24 GiB  ext4  /
            ├─ var    16 GiB  ext4  /var
            ├─ varlog  6 GiB  ext4  /var/log
            ├─ vartmp  4 GiB  ext4  /var/tmp
            ├─ home    4 GiB  ext4  /home        (barely used, but keeps tools happy)
            ├─ swap    4 GiB  swap               (no hibernate; justified below)
            └─ srv    rest    ext4  /srv         (may be where vhost data lives)
```

Rules that matter:

- **`/boot/efi` 1 GiB, `/boot` 1 GiB.** A separate `/boot` is *required* for our read-only-`/boot`
  tier and makes signing/UKI handling far cleaner. `/boot/efi` > 512 MiB because UKIs + backups add
  up quickly on FAT32.
- **Do not encrypt `/boot`.** It must be readable by firmware. It is protected by Secure Boot
  (signature) and by measurement, not by secrecy. Accept that.
- **Swap is on the encrypted LVM** — it is therefore never plaintext. Keep it small: with 8–16 GB
  RAM, 4 GB swap is enough to avoid OOM panics and does not tempt hibernation.
- **`/var/tmp` is its own LV, not tmpfs** — a 4 GB tmpfs on a RAM-constrained machine is a
  self-inflicted OOM. It gets `noexec,nosuid,nodev`.
- **No separate `/tmp` LV**: `/tmp` is `tmpfs` with `noexec,nosuid,nodev,size=2G,mode=1777` (fstab
  artefact provided).
- At the partitioner, when it asks about the encrypted volume: **LUKS2**, cipher
  `aes-xts-plain64`, 512-bit key, hash `sha512`, and a **long passphrase** (≥ 6 random words).
  Do not preseed/reuse it anywhere else. Never store it in a file on this machine.

If you are doing **P2 (detached header)** you cannot use the installer's partitioner for `p3`;
install with the embedded header first (P1) and convert in place afterwards using the audited
procedure in `docs/03` §4. That conversion is deliberate: it is far less error-prone than a
hand-built LUKS stack from the installer's TTY2, and it is reversible.

## 4. First boot after install

```bash
# 1. confirm the crypto stack is what you think it is
sudo cryptsetup luksDump /dev/nvme0n1p3 | head -30   # LUKS2, argon2id, aes-xts-plain64
sudo lvs && lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS

# 2. bring the repo onto the box (USB, or scp over the LAN, your choice)
sudo apt-get install --no-install-recommends git   # only if you will clone; otherwise rsync the tree
# USB route (preferred: no network needed):
#   mount -o ro,noexec /dev/sdX1 /mnt && cp -a /mnt/debian-hardened-apache ~/ && umount /mnt

cd ~/debian-hardened-apache
sudo bash scripts/install-hardening.sh --dry-run --tier 2   # see EXACTLY what will change
sudo bash scripts/install-hardening.sh --tier 2             # now do it
sudo reboot
```

Then follow, in order: `docs/03` (boot integrity) → `docs/05` (network, **last**) →
`docs/06` (Apache). Read `docs/10` §"Order-of-operations safety" before doing anything over SSH.

## 5. Minimal-but-complete package set

This is the *entire* host package list the build target needs at Tier 2. Everything else must be
justified per `docs/09`.

```
# integrity of the OS itself
intel-microcode firmware-linux-free firmware-misc-nonfree
apparmor apparmor-utils auditd audispd-plugins aide debsums unattended-upgrades needrestart
apt-listchanges chrony unbound sshguard

# serving
apache2 apache2-utils libapache2-mod-security2 modsecurity-crs libapache2-mod-macro
ssl-cert openssl ca-certificates

# admin plane (Tier 2)
wireguard-tools nftables usbguard
```

Notes / justifications:

- `unbound` here is a **local validating resolver** on `127.0.0.1` (DNSSEC), not a public resolver.
  It replaces whatever `resolv.conf` you have and removes cleartext DNS as an exfil/poisoning path.
  If you prefer `systemd-resolved` with DNS-over-TLS instead, that works too — `docs/05` §4.
- `sshguard` (a ~100 KB C daemon) is chosen over `fail2ban` (Python + a daemon with a config
  language) purely for surface area. Both are acceptable; fail2ban is documented in `docs/05` §6.
- `apache2-utils` brings `htpasswd`, `ab`, `apache2ctl`. Keep it: `apache2ctl configtest` is a
  safety net. `ab` is harmless but if you want it gone: `apt-mark auto apache2-utils`.
- `fwupd` is intentionally **not** in the list. Install it only when you are doing a firmware
  update (`apt-get install --no-install-recommends fwupd`, update, then `apt-get purge --auto-remove fwupd`).
  This is the "install only necessary software" policy in practice.
- `python3` is pulled in by `unattended-upgrades`/`needrestart`/`usbguard`/`apparmor-utils` on
  Debian. Accept it (it is the dependency graph, not a choice) but do **not** install `python3-pip`,
  `build-essential`, `git`, `curl` on the host unless the task needs it — a compiler on a web server
  turns a memory-corruption bug into trivial code execution.

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends \
  intel-microcode firmware-linux-free firmware-misc-nonfree apparmor apparmor-utils \
  auditd audispd-plugins aide debsums unattended-upgrades needrestart apt-listchanges \
  chrony unbound sshguard nftables usbguard wireguard-tools \
  apache2 apache2-utils libapache2-mod-security2 modsecurity-crs libapache2-mod-macro \
  ssl-cert openssl ca-certificates
```

`install-hardening.sh` runs exactly this list, so you do not have to paste it.

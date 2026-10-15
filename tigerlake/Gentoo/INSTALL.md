# Gentoo installation manual — Dell Tiger Lake laptop

This is the step-by-step procedure to install Gentoo on the machine described in
`TigerLake_PCI.txt`. It is **documentation only**: nothing in this repository has
been built or executed. Every `emerge`, `make` and installer command below is for
*you* to run, in order, on the laptop.

It installs a **UEFI, OpenRC, ext4, no-initramfs** system with the **i3** window
manager, using the config files that already exist in this directory:

| File in this repo | Where it goes on the target | Done in step |
| --- | --- | --- |
| `make.conf` | `/etc/portage/make.conf` | [8](#8--portage-configuration) |
| `sysctl.conf` | `/etc/sysctl.d/99-tigerlake.conf` | [13](#13--kernel-runtime-hardening-sysctl) |
| `tigerlake.config` | kernel config fragment (two ways) | [9](#9--kernel) |
| `apply-config.sh` | used next to `tigerlake.config` | [9](#9--kernel) |
| `TigerLake_PCI.txt` | reference only (verify hardware) | [17](#17--verify-the-install) |

## Assumptions and locked-in decisions

These are not open questions — they are already fixed by the config files in this
directory. Change them only if you deliberately edit those files.

| Decision | Value | Why |
| --- | --- | --- |
| Init system | **OpenRC** | `make.conf`/kernel config are OpenRC (`-systemd`) |
| Portage profile | `default/linux/amd64/23.0/desktop` | `make.conf.md`; desktop, no GNOME/KDE |
| Root filesystem | **ext4**, no initramfs | `CONFIG_EXT4_FS=y` in `tigerlake.config` |
| Bootloader | **GRUB, UEFI** (`efi-64`) | `GRUB_PLATFORMS="efi-64"` |
| GPU stack | Mesa `intel` + `nouveau` | `VIDEO_CARDS="intel nouveau"` |
| Desktop | **X11 + i3**, login via `startx` | `make.conf.md` world baseline |
| Filesystem layout | GPT, ESP + swap + single ext4 root | this manual ([4](#4--partition-the-nvme)) |

A second computer or phone to read these steps is strongly recommended while the
laptop is being installed. **Back up anything already on the NVMe first** — this
procedure wipes the disk.

---

## 1 — Write the installation medium

On another machine, download the **amd64 minimal installation CD** (or the
*livegui* image if you prefer a graphical installer environment):

- <https://www.gentoo.org/downloads/amd64/>

Verify it before use:

```sh
# from the directory holding the .iso and its .DIGESTS / .sig files
sha512sum -c install-amd64-minimal-*.iso.sha512
gpg --verify install-amd64-minimal-*.iso.sig install-amd64-minimal-*.iso
```

Write it to a USB stick (replace `sdX` — **double-check the device**):

```sh
lsblk                       # identify the USB stick
dd if=install-amd64-minimal-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
sync
```

Optionally copy this whole directory onto a second partition of the stick (or a
separate key) so the config files are available in the live environment.

---

## 2 — Firmware settings and boot

On the laptop, enter the BIOS/UEFI setup (F2 on Dell):

- Set boot mode to **UEFI** (disable legacy/CSM).
- **Disable Secure Boot** (the stock kernel is unsigned; re-enabling it later
  requires signing your own kernel).
- Leave the NVMe controller in **AHCI/NVMe** mode.
- Boot the USB stick from the UEFI boot menu (F12).

Confirm you booted in UEFI mode once the live shell is up:

```sh
ls /sys/firmware/efi            # must exist; if not, you booted in legacy mode
```

Bring up the network:

```sh
# Wired (dock/adaptor):
dhcpcd

# Wi-Fi — the AX201 firmware is on the minimal ISO:
ip link                                   # find the wlan interface name
rfkill unblock wifi
net-setup wlan0                           # interactive, handles WPA2
```

Verify connectivity and set the clock:

```sh
ping -c3 gentoo.org
chronyd -q 'server pool.ntp.org iburst'   # or: ntpd -q -g
date
```

---

## 3 — Identify the NVMe

The target is the **ADATA IM2P33F3 NVMe** at `3a:00.0`:

```sh
lspci -nnk | grep -A3 -i nvme
lsblk -o NAME,SIZE,MODEL
nvme list                                 # if available; confirms /dev/nvme0n1
```

Throughout this manual the disk is **`/dev/nvme0n1`**. Adjust if yours differs.

---

## 4 — Partition the NVMe

This guide uses a **GPT** table with a pure-UEFI layout (no BIOS boot partition
needed). Use `parted`:

```sh
parted -a optimal /dev/nvme0n1 -- mklabel gpt
parted -a optimal /dev/nvme0n1 -- mkpart ESP fat32 1MiB 513MiB
parted -a optimal /dev/nvme0n1 -- set 1 esp on
parted -a optimal /dev/nvme0n1 -- mkpart swap linux-swap 513MiB 16.5GiB
parted -a optimal /dev/nvme0n1 -- mkpart root ext4 16.5GiB 100%
parted -a optimal /dev/nvme0n1 -- print
```

Resulting layout (matches the documented partition numbering in step [10](#10--fstab)):

| Device | Size | Type | Mount | Notes |
| --- | --- | --- | --- | --- |
| `/dev/nvme0n1p1` | 512 MiB | FAT32 / ESP (`ef00`) | `/efi` | GRUB and the kernel image |
| `/dev/nvme0n1p2` | ~16 GiB | swap (`8200`) | — | equals RAM (16 GiB) so **hibernation** can work |
| `/dev/nvme0n1p3` | remainder | ext4 (`8300`) | `/` | root, built into the kernel |

Adjust the swap size if the machine does **not** have 16 GiB of RAM (see
`sysctl.conf`, which assumes 16 GiB). If you never hibernate, 8 GiB is enough.

> **Optional — full-disk encryption.** `tigerlake.config` enables
> `DM_CRYPT`/`CRYPTO_XTS`. A LUKS root is possible but **requires an initramfs**
> (e.g. `sys-kernel/dracut`), unlike the plain ext4 layout above. If you want it,
> create an extra unencrypted partition for `/boot` and unlock the LUKS container
> from a dracut initramfs; that path is out of scope for this default guide.

---

## 5 — Create filesystems and mount

```sh
mkfs.fat -F32 /dev/nvme0n1p1
mkswap    /dev/nvme0n1p2
mkfs.ext4 /dev/nvme0n1p3

swapon /dev/nvme0n1p2

mount /dev/nvme0n1p3 /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount /dev/nvme0n1p1 /mnt/gentoo/efi
lsblk -f                                   # sanity check
```

---

## 6 — Install the stage3 tarball

The **OpenRC** stage3 for amd64 (2026 layout):

- `https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-openrc/`

Since this machine runs the **desktop** profile, the prebuilt
`stage3-amd64-desktop-openrc` tarball is the better fit — it ships with the
desktop profile already selected and saves a large rebuild. The plain
`stage3-amd64-openrc` tarball is the handbook-standard fallback.

```sh
cd /mnt/gentoo
base=https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-desktop-openrc

# List the current files, then download the tarball plus its signature/checksum
curl -s "$base/" | grep -o 'stage3-[^"]*' | sort -u
STAMP=20260913T163055Z                          # substitute a real stamp from the listing
wget "$base/stage3-amd64-desktop-openrc-$STAMP.tar.xz" \
     "$base/stage3-amd64-desktop-openrc-$STAMP.tar.xz.asc" \
     "$base/stage3-amd64-desktop-openrc-$STAMP.tar.xz.sha512"

# Verify before extracting
gpg --verify stage3-amd64-desktop-openrc-$STAMP.tar.xz.asc
sha512sum -c stage3-amd64-desktop-openrc-$STAMP.tar.xz.sha512

tar xpvf stage3-amd64-desktop-openrc-$STAMP.tar.xz \
    --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo
```

Set the DNS resolver for the chroot:

```sh
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
```

---

## 7 — Chroot into the new system

```sh
mount --types proc  /proc /mnt/gentoo/proc
mount --rbind       /sys  /mnt/gentoo/sys
mount --make-rslave      /mnt/gentoo/sys
mount --rbind       /dev  /mnt/gentoo/dev
mount --make-rslave      /mnt/gentoo/dev
mount --bind        /run  /mnt/gentoo/run
mount --make-slave       /mnt/gentoo/run

chroot /mnt/gentoo /bin/bash
source /etc/profile
export PS1="(chroot) ${PS1}"
```

---

## 8 — Portage configuration

### 8.1 Sync and read the news

```sh
emerge-webrsync            # first sync from a signed snapshot
emerge --sync              # rsync/git sync from here on
eselect news read
```

### 8.2 Select the profile

```sh
eselect profile list       # confirm default/linux/amd64/23.0/desktop exists
eselect profile set default/linux/amd64/23.0/desktop
```

(`make.conf.md` explains why `desktop` — not `desktop/gnome` or `desktop/plasma`
— is correct for i3, and keeps OpenRC.)

### 8.3 Install `make.conf` from this repo

Copy the `make.conf` from this directory to `/etc/portage/make.conf`. It sets
`-march=native`, hardening flags, `MAKEOPTS="-j8 -l8"`, the firmware license set,
the session `USE` flags, `CPU_FLAGS_X86`, `VIDEO_CARDS="intel nouveau"` and
`GRUB_PLATFORMS="efi-64"`.

### 8.4 Enable signed repository sync (recommended)

In `/etc/portage/repos.conf/gentoo.conf`:

```ini
[gentoo]
sync-verify-signature = true
```

### 8.5 Reconcile CPU flags and rebuild the base

```sh
emerge --ask app-portage/cpuid2cpuflags
cpuid2cpuflags                       # confirm it matches make.conf's CPU_FLAGS_X86
```

Apply the profile/flags to the whole base system:

```sh
emerge --ask --verbose --update --deep --newuse @world
```

This is the longest rebuild of the install (hours on 4 cores); it compiles the
toolchain and the desktop-profile base. Re-read news and re-sync if it advises.

---

## 9 — Kernel

Two supported routes. **Neither has been run** — choose one.

### Option A — `gentoo-sources` + `apply-config.sh` (explicit, recommended here)

```sh
emerge --ask sys-kernel/gentoo-sources
eselect kernel list
eselect kernel set 1                 # point /usr/src/linux at the new tree

cd /usr/src/linux
/path/to/this/repo/apply-config.sh . # defconfig + merge fragment + olddefconfig
```

`apply-config.sh` backs up any existing `.config` to `.config.bak`, merges
`tigerlake.config` with `scripts/kconfig/merge_config.sh -m`, and resolves it with
`make olddefconfig`. Then build and install:

```sh
make menuconfig                      # optional review (see the audio note below)
make -j8
make modules_install
make install                         # installs vmlinuz + System.map into /boot
```

The root filesystem is **built in** (`CONFIG_EXT4_FS=y`), so no initramfs is
required for an ext4 root.

> **Audio codec to confirm on first boot.** The PCI dump does not name the
> HDA/SoundWire codec, so the fragment enables both
> `SND_SOC_INTEL_SKL_HDA_DSP_GENERIC_MACH` and
> `SND_SOC_INTEL_SOUNDWIRE_SOF_MACH`. After the first boot, check which binds
> (`aplay -l`; `dmesg | grep -iE 'sof|sdw|rt7|alc'`) and drop the unused machine
> driver in `make menuconfig`.

### Option B — `sys-kernel/gentoo-kernel` (lowest friction)

Gentoo's binary/auto-built kernel applies every `*.config` in
`/etc/kernel/config.d/` on top of its base config:

```sh
mkdir -p /etc/kernel/config.d
cp tigerlake.config /etc/kernel/config.d/10-tigerlake.config
emerge --ask sys-kernel/gentoo-kernel
```

Use the binary kernel (`sys-kernel/gentoo-kernel-bin`) instead if you want no
local compile at all. Install `sys-kernel/installkernel` with the `grub` USE flag
so the bootloader is refreshed automatically after each kernel install.

### Firmware and microcode

The kernel is only half of it. Install the firmware blobs the GPU, Wi-Fi, SOF
audio and MEI need, plus Intel CPU microcode:

```sh
emerge --ask sys-kernel/linux-firmware
emerge --ask sys-firmware/sof-firmware media-sound/alsa-ucm-conf
# microcode loaded early by GRUB:
echo 'sys-firmware/intel-microcode initramfs' >> /etc/portage/package.use/microcode
emerge --ask sys-firmware/intel-microcode
```

Firmware files that matter on this laptop (from `README.md`): i915 GuC/HuC
(`i915/tgl_*`), `iwlwifi-QuZ-*`/`iwlwifi-so-*` (AX201), `nvidia/tu117_*`
(MX450), `intel/sof/` + `intel/sof-tplg/` (audio).

---

## 10 — fstab

Write `/etc/fstab` (tab- or space-separated, one line each):

```
/dev/nvme0n1p1   /efi   vfat   umask=0077,shortname=winnt   0 2
/dev/nvme0n1p2   none   swap   sw                           0 0
/dev/nvme0n1p3   /      ext4   defaults,noatime             0 1
```

Tip: use partition labels (`blkid`) or `/dev/disk/by-uuid/...` for stability if
you ever add disks.

---

## 11 — Base system settings

```sh
# Hostname
echo tigerlake > /etc/hostname

# Timezone
ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime    # pick your region
echo 'Europe/Madrid' > /etc/timezone
emerge --ask --config sys-libs/timezone-data

# Locale
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
eselect locale set en_US.utf8
env-update && source /etc/profile
```

Create your user and grant sudo:

```sh
emerge --ask app-admin/sudo
visudo                              # uncomment: %wheel ALL=(ALL:ALL) ALL
passwd                              # set root password
useradd -m -G users,wheel,audio,video,input,usb,portage -s /bin/bash <yourname>
passwd <yourname>
```

---

## 12 — Bootloader (GRUB / UEFI)

Install GRUB and register it with the firmware:

```sh
emerge --ask sys-boot/grub:2
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=Gentoo
```

Review `/etc/default/grub` (add e.g. `quiet` if you like; the kernel already has
`INTEL_IOMMU_DEFAULT_ON` so no `intel_iommu=on` is needed). Generate the config:

```sh
grub-mkconfig -o /boot/grub/grub.cfg
```

`grub-mkconfig` picks up the installed `vmlinuz`, and the early Intel microcode
image if `intel-microcode` was built with the `initramfs` USE flag.

> **Alternative — EFI stub, no GRUB.** `CONFIG_EFI_STUB=y` lets the firmware boot
> the kernel directly. Copy the kernel onto the ESP and create a boot entry:
>
> ```sh
> mkdir -p /efi/EFI/Gentoo
> cp /boot/vmlinuz-*-gentoo /efi/EFI/Gentoo/bzImage.efi
> cp /boot/intel-uc.img    /efi/EFI/Gentoo/ 2>/dev/null || true   # if USE=initramfs
> efibootmgr --create --disk /dev/nvme0n1 --part 1 \
>   --label "Gentoo" --loader '\EFI\Gentoo\bzImage.efi' \
>   --unicode 'root=/dev/nvme0n1p3 rw initrd=\EFI\Gentoo\intel-uc.img'
> ```

---

## 13 — Kernel runtime hardening (sysctl)

Install `sysctl.conf` from this repo as a drop-in and apply it now and at boot:

```sh
cp sysctl.conf /etc/sysctl.d/99-tigerlake.conf
sysctl --system                      # apply now, without rebooting
```

OpenRC's `sysctl` init script is **enabled by default** and runs `sysctl --system`
at boot, so `/etc/sysctl.d/99-tigerlake.conf` is picked up automatically. Confirm
it is active with `rc-update show -v | grep sysctl` (and, if it were disabled,
`rc-update add sysctl boot`).

Every key in that file is backed by an option in `tigerlake.config` (Yama, BPF,
io_uring, IPv6, IPv4 hardening). Relax the ones marked `TRADEOFF` only if you need
to (e.g. `kernel.yama.ptrace_scope=0` for uninhibited `gdb`/`strace`).

---

## 14 — Networking

`make.conf`'s world baseline uses **NetworkManager**:

```sh
emerge --ask net-misc/networkmanager net-wireless/wpa_supplicant
rc-update add NetworkManager default
```

After reboot, connect with `nmtui` (or `nmcli`). The AX201 needs
`linux-firmware` (step 9) — without it, `iwlwifi` will not load.

---

## 15 — X11 and the i3 desktop

```sh
# X server, input, graphics (Mesa drives both Intel and nouveau)
emerge --ask x11-base/xorg-server x11-drivers/xf86-input-libinput \
             media-libs/mesa x11-apps/xinit

# i3 and companions
emerge --ask x11-wm/i3 x11-misc/i3status x11-misc/dmenu x11-misc/rofi \
             x11-terms/xterm x11-misc/xsetroot x11-misc/xss-lock

# Session, audio, notifications
emerge --ask sys-auth/elogind sys-auth/polkit \
             media-video/pipewire media-video/wireplumber media-sound/pavucontrol \
             x11-misc/dunst x11-misc/picom
```

`elogind` must be running for session/power management without systemd:

```sh
rc-update add elogind boot
rc-update add dbus default
```

Start i3 with `startx` — create `~/.xinitrc` containing `exec i3`. Install
`x11-drivers/xf86-video-intel` is **not** required; use the modesetting driver
with Mesa, as noted in `README.md`.

---

## 16 — Finalize and reboot

```sh
# From inside the chroot:
exit
cd /
umount -lR /mnt/gentoo
swapoff --all
reboot
```

Remove the USB stick so the laptop boots from the ESP.

---

## 17 — Verify the install

After the first boot (and after logging in to the new user), compare the live
hardware to the reference dump:

```sh
lspci -nnk > /tmp/lspci-now.txt
diff -u TigerLake_PCI.txt /tmp/lspci-now.txt    # "Kernel driver in use" lines should match

# Per-subsystem spot checks:
dmesg | grep -iE 'i915|nouveau|iwlwifi|nvme|sof|thunderbolt'
ip -br a                     # iwlwifi link present?
aplay -l                     # SOF/HDA codecs enumerated
dmesg | grep -i microcode    # early microcode revision loaded?
sensors                      # if sys-apps/lm-sensors installed
```

Expected drivers, straight from the PCI dump: `i915` (Iris Xe), `nouveau`
(MX450), `iwlwifi` (AX201), `nvme` (ADATA), `sof-audio-pci-intel-tgl` (audio),
`xhci_hcd` + `thunderbolt` (USB4/TB4), `intel_vsec`, `mei_me`, `intel_ish_ipc`,
`i801_smbus`, `intel-lpss`, `proc_thermal`, `igen6_edac`.

---

## Appendix A — Device map (from `TigerLake_PCI.txt`)

| PCI | Device | In-tree driver | Kernel symbol |
| --- | --- | --- | --- |
| `00:00.0` | Host bridge / DRAM | `igen6_edac` | `EDAC_IGEN6` |
| `00:02.0` | Iris Xe Graphics | `i915` | `DRM_I915` |
| `00:04.0` | Dynamic Tuning | `proc_thermal` | `INT340X_THERMAL` |
| `00:07.0` / `00:0d.0` / `00:0d.2` | Thunderbolt 4 / USB4 | `thunderbolt`, `xhci_hcd` | `USB4`, `USB_XHCI_HCD` |
| `00:0a.0` | Telemetry aggregator | `intel_vsec` | `INTEL_VSEC` |
| `00:12.0` | Integrated Sensor Hub | `intel_ish_ipc` | `INTEL_ISH_HID` |
| `00:14.0` | USB 3.2 xHCI | `xhci_hcd` | `USB_XHCI_HCD` |
| `00:14.3` | Wi-Fi 6 AX201 | `iwlwifi` | `IWLWIFI`, `IWLMVM` |
| `00:15.x` | Serial IO I2C (LPSS) | `intel-lpss` | `MFD_INTEL_LPSS_PCI`, `PINCTRL_TIGERLAKE` |
| `00:16.0` | Management Engine | `mei_me` | `INTEL_MEI_ME` |
| `00:1f.3` | SOF Smart Sound audio | `sof-audio-pci-intel-tgl` | `SND_SOC_SOF_TIGERLAKE` |
| `00:1f.4` | SMBus | `i801_smbus` | `I2C_I801` |
| `00:1f.5` | SPI controller | — | `SPI_INTEL_PCI` |
| `01:00.0` | NVIDIA MX450 (TU117M) | `nouveau` | `DRM_NOUVEAU` |
| `3a:00.0` | ADATA IM2P33F3 NVMe | `nvme` | `NVME_CORE`, `BLK_DEV_NVME` |

## Appendix B — Emergency boot helpers

- **No network in the live ISO:** the minimal ISO ships firmware for the AX201;
  if `net-setup` fails, try `wpa_supplicant`/`iwd` manually, or a USB-ethernet
  dock (`USB_RTL8152` / `AX88179` are enabled in the kernel).
- **GRUB drops to a shell:** `ls (hd0,gpt1)/EFI/Gentoo`, then `set root=(hd0,gpt1)`
  and `chainloader /EFI/Gentoo/grubx64.efi` / `boot` by hand; then re-run
  `grub-install` from the chroot.
- **`iwlwifi` "no firmware":** install/refresh `sys-kernel/linux-firmware` and
  confirm the `iwlwifi-*.ucode` files exist under `/lib/firmware`.
- **No audio:** verify `sof-firmware` + `alsa-ucm-conf` are installed and check
  which machine driver bound (step 9 note), then adjust in `menuconfig`.

## Appendix C — Scope note

This guide deliberately does **not** build, compile, partition, or modify
anything by itself. It is the human-run procedure for this specific machine; the
kernel fragment it references was validated separately (see `README.md`,
"Verification performed").

# FreeBSD Desktop — Intel i7-11390H (Tiger Lake) laptop setup

Files in this directory configure a normal desktop experience for:

| Component | Model | FreeBSD driver |
|---|---|---|
| CPU | 11th Gen Core i7-11390H (Tiger Lake-H, 4C/8S) | native + `powerd` |
| GPU | Intel Iris Xe (Gen12, Raptor-id `0x9A49` family) | `i915kms` via **drm-kmod** |
| Wi-Fi | Intel AX201 (CNVi) | `iwlwifi(4)` + firmware package |
| Ethernet | Intel I219-V (em0) | `em(4)` (native) |
| Audio | Intel HDA | `snd_hda` (native, kernel module) |
| Battery/ACPI | Standard | `acpi` (native) |

## Files

- `freebsd-tigerlake-etc/rc.conf` → `/etc/rc.conf`
- `freebsd-tigerlake-etc/loader.conf` → `/boot/loader.conf`
- `freebsd-tigerlake-etc/sysctl.conf` → `/etc/sysctl.conf`
- `freebsd-tigerlake-etc/doas.conf` → `/usr/local/etc/doas.conf`
- `post-install.sh` → applies everything (backup first, never overwrites)
- `jail.conf` → `/etc/jail.conf` — classic + thin jails, base system only
- `JAILS.txt` → howto: build/start/update jails without bastille or iocage

## Install steps

1. Download the memstick image (`FreeBSD-14.3-RELEASE-amd64-memstick.img`) from
   <https://www.freebsd.org/where/>, burn it to USB, boot it, and install with `bsdinstall`.
   Use ** Desktop + Base** or plain install; the script adds the rest.
2. Log in as `root` on the new system. Copy this folder over
   (e.g. `scp -r freebsd-tigerlake-etc post-install.sh root@<ip>:/root/`).
3. Run it:
   ```sh
   chmod +x post-install.sh
   ./post-install.sh
   ```
4. **Wi-Fi**: edit `/etc/wpa_supplicant.conf` and add your network:
   ```
   network={
       ssid="YourNetworkName"
       psk="YourPassword"
   }
   ```
5. Edit `/usr/local/etc/doas.conf` to permit your real user instead of `:wheel`-only.
6. Reboot. SDDM gives you the graphical login on the Intel Iris Xe (Wayland/X both fine).

## Desktop environment

The script installs the display manager but **not** a full DE, so you choose. Pick one:

```sh
pkg install -y plasma6-sddm-kde        # KDE Plasma 6 (heaviest, most polished)
pkg install -y xfce                    # XFCE (lightweight, very stable)
pkg install -y mate                    # MATE
```

Wait for a few seconds the first time i915 loads during boot; the console will switch
to a KMS framebuffer and then SDDM appears.

## Verify afterwards

```sh
# GPU
ls /dev/dri            # should show card0 / drm0 (or similar)
kldstat | grep i915
# Wi-Fi
ifconfig wlan0         # up, associated
# Audio
cat /dev/sndstat
```

If the GPU fails: check `dmesg | tail` — note whether the Tiger Lake GPU firmware package
matches (`gpu-firmware-intel-kmod-tigerlake`) and whether `kld_list` contains `i915kms`.

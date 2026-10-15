# Portage setup — i3 desktop on Tiger Lake (OpenRC)

Companion notes for `make.conf`. Copy it to the target as
`/etc/portage/make.conf`.

## Profile choice

```sh
eselect profile set default/linux/amd64/23.0/desktop
```

23.0 is the current profile version for amd64, and `desktop` is the
DE-agnostic desktop sub-profile. Per the Gentoo wiki's *Portage/Profiles*,
desktop profiles "are to be used for any graphical installation, whether using
a desktop environment, **window manager**, xorg, wayland, etc." — so `desktop`
is exactly right for i3, and it "only provides the bare minimum for desktop
system usage."

Why this is the secure, low-risk choice:

* It is a **stable** profile (CI-validated dependency graph), unlike the `exp`
  and `dev` profiles.
* It is **overly exclusive with the DEs**: `desktop/gnome` and `desktop/plasma`
  are separate sub-profiles, and we select neither, so no GNOME/Plasma stack is
  pulled in. The `USE` block additionally hard-off's `gnome`, `kde`, `plasma`.
* It stays on **OpenRC** (no `systemd` qualifier), matching the kernel config
  already in this directory (`-systemd` is also pinned in `USE`).

### If you want the hardened toolchain

There is no built-in *hardened desktop* profile; the wiki's
[Hardened Desktop Profiles](https://wiki.gentoo.org/wiki/Hardened_Desktop_Profiles)
page documents combining them via a local profile that inherits both
`gentoo:default/linux/amd64/23.0/hardened` and `gentoo:targets/desktop`. That
route is recommended only if you specifically need Hardened Gentoo (it has
usage constraints and a heavier toolchain). This make.conf already applies the
standard hardening flags — `-fstack-protector-strong`, `-fno-plt`, and full
RELRO + bind-now — so you get most of the benefit without the hardened
profile's constraints.

## What is set and why

| Variable | Value / rationale |
| --- | --- |
| `COMMON_FLAGS` | `-O2 -pipe -march=native` — the documented "sane" baseline. |
| `CFLAGS/CXXFLAGS` | adds `-fstack-protector-strong -fno-plt` (hardening). |
| `LDFLAGS` | `-Wl,-O1 -Wl,--as-needed -Wl,-z,relro,-z,now` (full RELRO, bind-now). |
| `MAKEOPTS` | `-j8 -l8` for 4 cores / 8 threads; formula `min(threads, RAM/2GiB)`. |
| `EMERGE_DEFAULT_OPTS` | 4 parallel package builds, load-gated. |
| `ACCEPT_LICENSE` | `-* @FREE @BINARY-REDISTRIBUTABLE` — free software plus the firmware blobs the GPU/Wi-Fi need; EULAs stay rejected. |
| `USE` | session bits (`elogind`, `dbus`, `policykit`, `udisks`, `upower`) and `-systemd -gnome -kde -plasma`. |
| `CPU_FLAGS_X86` | Tiger Lake feature set (client parts have no AVX-512). |
| `VIDEO_CARDS` | `intel` (Iris Xe) + `nouveau` (Turing MX450). |

`CHOST` is intentionally absent — profile 23.0 sets it and overriding it is
unsupported.

## Steps after dropping the file in place

```sh
# 1. Profile
eselect profile set default/linux/amd64/23.0/desktop

# 2. Regenerate CPU flags on the real CPU and reconcile with the value above
emerge --ask app-portage/cpuid2cpuflags

# 3. Apply the new global flags to the toolchain/world
emerge --ask --update --deep --changed-use @world
```

### Secure sync (separate from make.conf)

Enable OpenPGP verification of the ebuild repository so a tampered mirror can't
feed you modified ebuilds, in `/etc/portage/repos.conf/gentoo.conf`:

```ini
[gentoo]
sync-verify-signature = true
```

## Suggested i3 world baseline

```sh
# X server + input + graphics
emerge --ask x11-base/xorg-server x11-drivers/xf86-input-libinput media-libs/mesa

# i3 and friends
emerge --ask x11-wm/i3 x11-misc/i3status x11-misc/dmenu x11-misc/xss-lock \
             x11-terms/xterm x11-misc/xsetroot x11-misc/rofi

# Session, audio, networking, notifications
emerge --ask sys-auth/elogind sys-auth/polkit net-misc/networkmanager \
             media-sound/pipewire media-video/wireplumber \
             x11-misc/dunst x11-misc/picom
```

Start i3 via `startx` (add `exec i3` to `~/.xinitrc`) or a lightweight display
manager. With `elogind` and `dbus` enabled, suspend/power and session
management work without systemd.

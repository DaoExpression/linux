# 07 — Physical access, firmware, and peripherals

Everything in `docs/03`–`docs/06` assumes an attacker who is *inside* the OS boundary. This document
is about the boundary itself: firmware, the Management Engine, DMA-capable ports, and USB.

---

## 1. BIOS/UEFI checklist (Dell, Tiger Lake)

Do these on the physical console, and re-check them after every firmware update — Dell firmware
updates have been known to reset security settings.

| Setting | Value | Why |
|---|---|---|
| Admin/Setup password | strong, unique, **not** stored on the machine | Anyone with 5 minutes could otherwise flip Secure Boot off. |
| BIOS update from | Dell's site over a trusted network, or `fwupdmgr` (signed LVFS metadata) | Never from a random mirror; UEFI firmware is the root of trust. |
| Secure Boot | **enabled**, own keys enrolled (`docs/03` §2) | Boot integrity. |
| Boot order | internal NVMe only; USB/optical/PXE **disabled after install** | Removes live-USB attacks. Keep a BIOS password so this cannot be changed. |
| Firmware TPM (PTT) | enabled if you want journal sealing/IMA; irrelevant to LUKS here | `docs/03` §5. |
| Kernel DMA Protection | **enabled** | Pre-boot + early-boot DMA blocked for TB3/4. |
| Thunderbolt security | **User Authorization**, "no security" never | `docs/00` §3. |
| Thunderbolt boot / pre-boot DMA | disabled | Stops a malicious dock from loading a ROM before your IOMMU policy applies. |
| Discrete graphics | **disabled** if the menu offers it | Removes the NVIDIA MX450 (`01:00.0`) entirely. |
| Camera / Microphone | **disabled** | Hardware kill beats a driver blacklist. |
| Bluetooth / WWAN | **disabled** | Unused radios are attack surface. |
| Wake-on-LAN / Wake on USB / Wake on AC | disabled | No remote/adjacent wake events; also blocks some cold-boot tricks. |
| Legacy ROM / CSM | disabled | No legacy BIOS code paths. |
| CPU settings | VT-d on, VT-x on, Trusted Execution on, hyperthreading: your call (Tier 3 disables it) | `docs/00`/`docs/03`. |
| Chassis/Kensington | lock the machine; in an office, a cable lock is not theatre | Obvious, and it is the cheapest control on the list. |

Verify what the OS can see (it cannot see everything the BIOS did):

```bash
sudo dmidecode -t bios -t system | grep -E 'Vendor|Version|Release Date|Product|Serial'
sudo mokutil --sb-state                     # SecureBoot enabled (or bootctl status)
sudo fwupdmgr get-devices 2>/dev/null | head -40
cat /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | xxd | tail -1
```

## 2. Intel Management Engine — residual risk, stated honestly

Tiger Lake fuses Boot Guard and signs the ME region, so `me_cleaner` is **not** a safe operation on
this machine: at best it does nothing, at worst it bricks the platform or invalidates the boot policy
that your Secure Boot keys depend on. We do not pretend the ME can be removed. We do:

1. **Blacklist the OS-side interface** (`mei_me`, `mei`) — see `files/etc/modprobe.d/90-blacklist-paranoid.conf`.
   This removes a privileged, DMA-capable device from the kernel's reachable device list and is
   verifiable (`lsmod | grep -c mei_me` → 0, `ls /dev/mei*` → nothing).
2. **Disable what the firmware lets you** — AMT/vPro/"Capability Licensing" in the BIOS menu if it
   exists (`sudo dmidecode -t 2` to learn your exact model). On consumer SKUs this is usually absent,
   which is fine: no AMT means no remote ME network stack to attack.
3. **Keep the ME firmware current** via BIOS updates: ME firmware ships inside the Dell UEFI image,
   and ME CVEs are patched there. This is why `docs/10` puts firmware on a monthly cadence.
4. **Accept and record the residual risk** (that CE is unavailable against a state-level ME
   compromise). If your threat model includes that adversary, the correct answer is not a software
   setting; it is different hardware (a machine with a neutralised ME or a CPU without one).

```bash
lsmod | grep -E '^mei' || echo "OK: no MEI modules loaded"
ls /dev/mei* 2>/dev/null || echo "OK: no MEI device nodes"
sudo dmesg | grep -iE 'mei|ME is' | head
```

## 3. Thunderbolt and DMA

Firmware settings in §1 do most of the work. The OS-side complement:

```bash
# If Thunderbolt is genuinely unused (racked/wired machine): blacklist it. Already in the artefact.
lsmod | grep -c thunderbolt          # 0 == not loaded

# If you need TB ports, keep the driver and manage authorization explicitly:
sudo apt-get install --no-install-recommends bolt
boltctl list                          # authorized devices only
boltctl monitor                       # watch an authorization in real time while you plug something in
```

Rules of engagement for a dock: you, personally, plug it in; you check `boltctl list` after; anything
you did not authorize gets unplugged and the machine is treated as suspect (`docs/11`) if it
appeared already authorized. Also note the IOMMU cannot protect you from a device that is *allowed*
to be there — "authorized dock" is a trust decision, not a security boundary.

DMA protection posture to confirm:

```bash
sudo dmesg | grep -iE 'DMAR|IOMMU' | head -20     # expect DMAR-IR and per-device domains
ls /sys/kernel/iommu_groups/ | wc -l              # groups exist (see docs/00: 17 listed)
cat /proc/cmdline | tr ' ' '\n' | grep -E 'iommu|intremap'
```

## 4. USB — USBGuard with a deny-by-default policy

`files/etc/usbguard/usbguard-daemon.conf` + `files/etc/usbguard/rules.conf`:

```conf
# usbguard-daemon.conf (essentials)
ImplicitPolicyTarget=block           # unknown devices are BLOCKED, not allowed
PresentDevicePolicy=apply-policy
PresentControllerPolicy=keep
InsertedDevicePolicy=apply-policy
AuthorizedDefault=none
RestoreControllerDeviceState=false
DeviceRulesWithPort=false
IPCAllowedUsers=root
IPCAllowedGroups=root
IPCAccessControlFiles=yes
AuditBackend=LinuxAudit          # every decision lands in auditd
```

```conf
# rules.conf — the important property is that this file is TINY and each line is explainable
allow id 1d6b:0002 serial "0000:00:14.0" name "xHCI Host Controller" hash "..." parent-hash "..."
allow id 1d6b:0003 serial "0000:00:14.0" name "xHCI Host Controller" hash "..." parent-hash "..."
# internal keyboard/touchpad (HID over I2C/USB) — generate these from your own machine, do not copy
allow id 046d:c31c serial "" name "USB Keyboard" hash "..." parent-hash "..."
block
```

Generate the ruleset **from your own hardware**, in `--dry-run` mode first:

```bash
sudo apt-get install --no-install-recommends usbguard
sudo usbguard generate-policy > /tmp/usbguard.rules          # with ONLY trusted devices attached
sudo usbguard generate-policy --no-hash > /tmp/usbguard.nohash.rules   # hashes are the strong form
sudo diff -u /tmp/usbguard.rules files/etc/usbguard/rules.conf    # review before installing!
sudo cp /tmp/usbguard.rules /etc/usbguard/rules.conf
sudo chmod 0600 /etc/usbguard/rules.conf
sudo usbguard-daemon -d -P -c /etc/usbguard/usbguard-daemon.conf   # foreground test, if unsure
sudo systemctl enable --now usbguard
sudo usbguard list-devices
```

Practical warnings:

- **Hashes matter.** `--no-hash` rules allow any device that claims the same VID/PID/serial — trivially
  spoofable. Prefer with-hash. But a firmware update to the keyboard changes its hash; re-generate
  after any peripheral firmware change.
- **Test with a second console** (physical, and if possible a spare keyboard). A bad ruleset that
  blocks your only keyboard is a very annoying brick, and the fix requires reaching the machine.
- Use `usbguard`'s `--permanent` for policy and `usbguard allow-device <id>` for one-off authorization
  **while someone is watching**. Never leave an unlimited allow rule in place "for now".
- Complement with the kernel knob if you want belt and braces — but read the warning:
  `usbcore.authorized_default=0` in the kernel cmdline blocks new USB devices at the kernel level,
  including a keyboard plugged in after boot. Acceptable only on a racked machine with serial console.
- Tier 3: also blacklist `usb_storage`/`uas` (in the artefact, commented) so a rogue USB stick is not
  even a block device.

## 5. Radios

```bash
sudo rfkill list                       # confirm wifi/bt state
sudo rfkill block wifi bluetooth       # block at the kernel level
sudo systemctl mask --now wpa_supplicant NetworkManager 2>/dev/null || true
# persist: files/etc/modprobe.d/90-blacklist-paranoid.conf blacklists btusb/btintel/bluetooth
# and (if wired-only) iwlwifi entirely.
```

If the machine is wired-only, blacklisting `iwlwifi` removes the AX201 from the picture completely,
and you can also drop `firmware-iwlwifi` from the install list (`docs/02` §5). Do this only if you have
a working alternative path to the machine.

## 6. Cameras, microphones, sensors

- BIOS kill switches (best) **plus** driver blacklist (`uvcvideo`, `intel_ish_ipc`, audio modules) —
  both are in the artefact, and both are verified by `verify-hardening.sh`.
- There is no legitimate reason for a headless HTTPS server to have a microphone. If your BIOS does not
  offer a mic kill switch, this is where the blacklist is genuinely load-bearing.

```bash
ls /dev/video* 2>/dev/null || echo "OK: no video devices"
lsof /dev/snd/* 2>/dev/null | head || true
lsmod | grep -cE 'snd_sof|snd_hda_intel|uvcvideo'   # 0
```

## 7. Tamper detection and physical response

You cannot detect everything physical. What you *can* do:

| Indicator | Where to look |
|---|---|
| Uptime reset (pulled power, case opened, cold boot) | `uptime -s`, `journalctl --list-boots`, and a boot-counter file you append to at every boot |
| Secure Boot turned off | `bootctl status`, checked daily by `verify-hardening.sh` |
| New USB/TB device appeared | `usbguard list-devices`, `boltctl list`, both in the audit trail |
| Firmware version changed unexpectedly | `dmidecode -t bios` captured to `/var/log/paranoid/firmware-state` and diffed monthly |
| Header USB missing/replaced | boot fails; that is the signal |
| LUKS passphrase change | `cryptsetup luksDump` shows keyslot changes; AIDE+auditd watch the header region; `paranoid-boot-record` logs the keyslot count on every boot (`/usr/local/sbin/paranoid-boot-record` is the implementation, and it prints its own record when run by hand) |

`files/etc/systemd/system/paranoid-boot-record.service` calls
`/usr/local/sbin/paranoid-boot-record` on every start, appending one line to `/var/log/paranoid/boots`:

```
2026-10-14T17:44:02Z boot=8d915368-… kernel=6.12.9-amd64 sb=enabled lockdown=confidentiality luks=/dev/nvme0n1p3 keyslots=1
```

so a boot you did not perform is visible in the log and in the sealed journal. The logic lives in a
script rather than in `ExecStart` for a concrete reason: a `%` inside a unit file is a systemd
specifier, and an inline `printf "%s"` makes the unit refuse to start entirely — `systemd-analyze
verify` catches that, and `make lint`/`bash -n` catch script-level mistakes. Test it without waiting
for a reboot:

```bash
sudo PARANOID_LOGDIR=/tmp/br /usr/local/sbin/paranoid-boot-record && cat /tmp/br/boots
systemd-analyze verify /etc/systemd/system/paranoid-boot-record.service
```

**Watchdog:** if you have a hardware/out-of-band path (a smart plug you can power-cycle remotely, or a
second machine that can reach the PDU), tie the "machine is down" alarm to it. A server that reboots
into a broken state with nobody watching is indistinguishable from a compromised one. Set
`RuntimeWatchdogSec=20` in `files/etc/systemd/system.conf.d/99-paranoid.conf` only if your hardware
supports it reliably — a spurious watchdog reset on an unsupported platform is a self-inflicted outage.

## 8. Verification

```bash
bash scripts/verify-hardening.sh --section physical
lsmod | grep -cE 'mei|thunderbolt|uvcvideo|snd_sof|bluetooth|nouveau'   # expect 0
sudo usbguard list-devices | head
sudo rfkill list | head
sudo dmidecode -t bios | grep -E 'Version|Release Date'
sudo fwupdmgr get-updates 2>/dev/null | head -20 || echo "run fwupdmgr manually during the monthly cycle"
sudo journalctl -t usbguard --since '-7d' | tail
```

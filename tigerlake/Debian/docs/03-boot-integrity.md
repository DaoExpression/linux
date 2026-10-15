# 03 — Boot integrity: Secure Boot (your keys), UKI, LUKS

Goal: an attacker who modifies your kernel, initramfs, or `/boot` contents **cannot boot the
machine**, and an attacker who steals the disk gets nothing but ciphertext.

Note the order: **do this before the network hardening**. Doing it wrong can leave the machine
unbootable, and you want a working console when that happens.

---

## 1. Choose your LUKS profile

| | **P1 — Embedded header (default)** | **P2 — Detached header (maximum)** |
|---|---|---|
| Header lives | on the NVMe, in the partition | on a **USB token**, disk has zero LUKS metadata |
| Boot needs a USB device | no | **yes, every boot** |
| Attacker with disk only | sees LUKS2, can attempt offline KDF | sees unpartitioned-looking entropy |
| Crypto-erase | `cryptsetup luksErase` / destroy keyslots | cut the USB (but keep the backup!) |
| Failure mode | lose passphrase → restore from backup | lose the USB **and** passphrase → total loss |
| Fits this laptop | yes | yes, if you accept a dongle at every boot |

Both use the same underlying crypto. P2 is a strictly better *offline adversary* posture and a
strictly worse *availability* posture. Start with P1 (installed in `docs/02`), then convert if you
want P2 — §4 shows how, verified and reversible.

Verify your P1 parameters right now:

```bash
sudo cryptsetup luksDump /dev/nvme0n1p3 | grep -E 'Version|Cipher|PBKDF|Memory|Time cost|Label'
# expect: LUKS2, aes-xts-plain64, argon2id, memory ~1GiB, time cost 3-5
sudo cryptsetup luksHeaderBackup /dev/nvme0n1p3 --header-backup-file luks-header-$(date +%F).img
sha512sum luks-header-*.img    # record this hash offline, on paper
```

**Store the header backup on two physically separate offline devices** (e.g. a USB stick in a safe
and encrypted paper/QR in a drawer). The header is worthless without the passphrase, but without the
header (P2) the data is gone.

## 2. Secure Boot with your own keys

Two supported paths.

### Path A — own keys, `systemd-boot`, signed Unified Kernel Image (recommended)

This is the strongest chain on this hardware: firmware boots `systemd-boot` from the ESP, which
loads a **single signed UKI** (kernel + initramfs + cmdline + os-release in one PE binary).

```bash
# 1. tooling
sudo apt-get install --no-install-recommends systemd-boot systemd-ukify sbsigntool sbctl dracut

# 2. firmware must be in SETUP MODE (Dell: Security → Secure Boot → "Custom Mode"/"Setup Mode")
sudo bootctl status | grep -i 'secure boot'
sudo sbctl status                 # shows Setup Mode: Enabled, Secure Boot: Disabled

# 3. create and enrol YOUR keys  (do this offline, then back up /var/lib/sbctl + /usr/share/secureboot)
sudo sbctl create-keys
sudo sbctl enroll-keys --microsoft      # only if you want signed option ROMs/dbx update to keep working
#                                    # use --microsoft if the machine has an NVIDIA/dGPU option ROM you plan to use;
#                                    # otherwise plain `enroll-keys` is stricter. We blacklist the dGPU anyway.

# 4. ctrl-file: put sbctl in "sign everything I tell it to" mode
sudo sbctl verify            # lists unsigned EFI binaries it can see

# 5. sign the boot chain (paths depend on your install; the script below does the discovery)
sudo sbctl sign -s /boot/efi/EFI/systemd/systemd-bootx64.efi
sudo sbctl sign -s /boot/efi/EFI/BOOT/BOOTX64.EFI
sudo sbctl list-files
```

Now the UKI. `files/etc/kernel/cmdline` and `files/etc/kernel/install.conf` configure
`kernel-install` to emit a UKI per kernel version:

```bash
sudo cp files/etc/kernel/cmdline /etc/kernel/cmdline
sudo cp files/etc/kernel/install.conf /etc/kernel/install.conf
sudo kernel-install add "$(uname -r)" /boot/vmlinuz-"$(uname -r)"
ls -l /boot/efi/EFI/Linux/            # one <machine-id>-<version>.efi per kernel
sudo sbctl sign -s /boot/efi/EFI/Linux/<machine-id>-<version>.efi
sudo bootctl list                     # confirm the UKI entry is what will boot
```

Add a **`sbctl` pacman-hook equivalent** so future kernel updates sign automatically — on Debian
that is a `kernel-install` plugin plus an apt hook. This repo ships
`files/etc/kernel/postinst.d/zz-sign-uki` and `files/etc/apt/apt.conf.d/99-paranoid` (which calls it
via `DPkg::Post-Invoke`) so you cannot forget. Verify after the first kernel upgrade:

```bash
sudo apt-get install --reinstall linux-image-amd64
sudo sbctl verify | grep -i 'not signed'    # must print nothing
```

### Path B — Debian shim + MOK (fallback)

If firmware Setup Mode is not exposed (some Dell consumer BIOSes), boot Debian's signed shim and
sign your own kernel with a **MOK** key (`mokutil --import`). Weaker: you still trust
Microsoft's CA and the vendor shim, and any MOK-enrolled key can be added by whoever reaches the
MOK Manager at boot. If you must use this, also set a **firmware "Boot Menu / MOK" password** if the
BIOS offers one, and re-check `mokutil --list-enrolled` after every firmware update.

## 3. Kernel lockdown and module policy

`files/etc/default/grub` (and the UKI cmdline, kept identical) adds:

```
lockdown=confidentiality module.sig_enforce=1 iommu=on iommu.strict=1 intremap=on iommu.passthrough=0
init_on_alloc=1 init_on_free=1 slab_nomerge page_alloc.shuffle=1 randomize_kstack_offset=on
vsyscall=none debugfs=off oops=panic panic=-1 panic_on_oops=1
lsm=landlock,lockdown,yama,integrity,apparmor,bpf apparmor=1 security=apparmor
audit=1 audit_backlog_limit=8192
module_blacklist=nouveau,nvidia,nvidia_drm,nvidia_modeset,btusb,bluetooth,intel_ish_ipc
```

What each cluster buys you:

- `lockdown=confidentiality` — kernel refuses `kexec`, `/dev/mem` access, unsigned module loading,
  and most raw PCI/IO access from userspace while Secure Boot is on. This is the single highest-value
  boot param on a laptop with a TPM-free threat model.
- `module.sig_enforce=1` — **[TIER 3]** every module must be signed by a key in the kernel keyring.
  All Debian stock modules are signed by Debian, so this works out of the box; it only breaks
  out-of-tree modules you build yourself (you would sign them with your own key and enroll it).
  Combined with `lockdown`, this removes the "load a rootkit module" step.
- `iommu=on iommu.strict=1 intremap=on` — see `docs/00` §3. `iommu.strict=1` forces an IOTLB flush
  after every map/unmap instead of batching. Slower, meaningfully stronger against DMA races.
- `init_on_alloc=1 init_on_free=1 slab_nomerge` — zero-fill memory on alloc/free and stop slab
  merging: kills a large class of uninitialised-memory info leaks and heap-shaping primitives.
  Measurable throughput cost (~3–8%) — a defensible price.
- `vsyscall=none debugfs=off` — removes legacy kernel entry points. `debugfs=off` also makes a
  debugfs-based rootkit noticeably harder.
- `oops=panic panic=-1 panic_on_oops=1` — a kernel oops reboots rather than limping on, and reboots
  forever rather than sitting at a prompt. On a headless server this converts "silently
  half-compromised" into "visibly down". Combine with a hardware/cloud watchdog if you have one.
- `randomize_kstack_offset=on`, `page_alloc.shuffle=1` — cheap entropy gains.
- `audit=1 audit_backlog_limit=8192` — auditd must never drop events at boot.
- **[TIER 3]** `mitigations=auto,nosmt` — on a 4-core/8-thread TGL part this costs real capacity but
  closes SMT-based side channels. Only add it if your workload tolerates ~30% less CPU.
- **[TIER 3]** `init_on_free=1` also slows things; drop it to `init_on_alloc=1` only if you need speed.

Apply and verify:

```bash
sudo cp files/etc/default/grub /etc/default/grub
sudo cp files/etc/kernel/cmdline /etc/kernel/cmdline   # keep the two synthetic-identical
sudo update-grub 2>/dev/null || sudo update-initramfs -u -k all
# if using UKI (Path A), regenerate the UKI instead and sign it:
#   sudo kernel-install add "$(uname -r)" /boot/vmlinuz-"$(uname -r)" && sudo sbctl sign -s <the .efi>
sudo reboot
cat /sys/kernel/security/lockdown          # -> [integrity] confidentiality  (confidentiality active)
sudo dmesg | grep -iE 'IOMMU|DMAR'         # DMAR-IR, strict mode
cat /proc/cmdline
```

## 4. P1 → P2 conversion (detached LUKS header), verified and reversible

`scripts/make-luks-detached.sh` implements this. Read it before running it; here is the reasoning.

The LUKS2 header occupies the **first 16 MiB** of the container; the encrypted data area starts
*after* it. So a header backup can be moved to a USB token and the on-disk copy wiped without
touching a single byte of your filesystem. Safety properties of the script:

1. It refuses to run unless the header backup file exists, is ≥ 16 MiB, and **successfully opens the
   device** with `cryptsetup open --test-passphrase --header <backup>`.
2. It records the backup's SHA512 and writes a restore recipe next to it.
3. It only zeroes the first 16 MiB *after* step 1 passes.
4. It updates `/etc/crypttab` to `header=/dev/disk/by-id/<usb>` and regenerates the initramfs.
5. It prints the exact recovery command for the case where the USB is lost.

```bash
sudo bash scripts/make-luks-detached.sh --device /dev/nvme0n1p3 \
     --token /dev/disk/by-id/usb-YOUR_TOKEN-0:0 --confirm-i-have-two-header-backups
```

Grub/UKI must no longer need to find the header on disk — with systemd's cryptsetup generator, the
`header=` field in `/etc/crypttab` is honoured (`files/etc/crypttab.example`). **Test the recovery
path** before you rely on it: boot with the token removed and confirm you get a clean "cannot find
header" and can boot with `cryptsetup open --header /path/to/backup.img` from a rescue ISO.

## 5. TPM2 — what we do and do not use it for

This machine exposes **Intel PTT** (firmware TPM), visible in the BIOS as `PTT` / `Security Device
Support`. Our stance:

- **Not** for disk unlock. A firmware TPM's PCR values are only as trustworthy as the firmware that
  extends them, and a laptop with no discrete TPM and no attestation service cannot detect a
  firmware-level attacker. A 6-word passphrase is stronger here.
- **Optional, for sealing audit state**: journald FSS sealing (`Seal=yes`) and IMA measurement
  logging. These use the TPM to make tampering with *logs* detectable; if the TPM is absent or
  cleared, sealing degrades to "no sealing" rather than blocking boot.
- If you insist on convenience (unattended reboot), use
  `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 --tpm2-with-pin=yes`. The **PIN** is what
  makes this defensible; without it, a thief who takes the whole laptop gets a system that boots
  itself. Document it as an explicit downgrade.

Check the state:

```bash
sudo apt-get install --no-install-recommends tpm2-tools
sudo tpm2_getcap properties-fixed 2>/dev/null | grep -iE 'MANUFACTURER|VENDOR' # expect IFX / INTC
cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null                        # 2
```

## 6. IMA / measurement (optional, Tier 2+)

`auditd` + AIDE cover "did files change". IMA covers "was this binary measured before it executed".
On this hardware, enable only the appraisal-light configuration — full `ima_appraise=enforce` will
break package upgrades and unattended reboots if keys are wrong:

```bash
sudo cp files/etc/default/ima-policy /etc/ima/ima-policy    # provided; measurement-only by default
sudo systemctl enable --now ima-measure.service 2>/dev/null || true
```

Do not enable enforcement until you have run a full update cycle with measurement-only and read
`/sys/kernel/security/ima/ascii_runtime_measurements` yourself. Be honest about the value: on a
machine where you cannot verify the TPM's PCRs against a known-good quote, IMA mainly adds *audit
evidence*, not prevention.

## 7. Verification checklist for this document

```bash
sudo bootctl status                       # Secure Boot: enabled, signer = your key
sgdisk -p /dev/nvme0n1                    # 3 partitions: ESP, boot, LUKS
sudo cryptsetup luksDump /dev/nvme0n1p3   # LUKS2/argon2id   (P2: "Device is not a valid LUKS device" after wipe — expected)
cat /proc/cmdline                         # lockdown=confidentiality present
cat /sys/kernel/security/lockdown
findmnt /boot /boot/efi -o TARGET,OPTIONS # /boot ro (tier3) or rw; /boot/efi umask=0077
sudo sbctl verify | grep -ci 'not signed' # 0
```

Then run `bash scripts/verify-hardening.sh` — it checks all of the above automatically and exits
non-zero if any of it has drifted.

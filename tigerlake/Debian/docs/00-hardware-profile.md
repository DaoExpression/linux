# 00 — Hardware profile of *this* machine

Source: [`TigerLake_PCI.txt`](../TigerLake_PCI.txt) (`lspci -nnk`, unprivileged user, so
`Capabilities: <access denied>` — that line is a *permissions* artifact, not a device property).

## 1. What the dump says

| Address | Device | Driver in use | Keep? |
|---|---|---|---|
| `00:00.0` | 11th Gen Core Host Bridge/DRAM (`igen6_edac`) | — | keep (EDAC error reporting) |
| `00:02.0` | **Iris Xe Graphics** TigerLake-LP GT2 | `i915` | keep (console only) or blacklist if fully headless |
| `00:04.0` | Dynamic Tuning Processor Participant (DPTF) | `proc_thermal` | **keep** — thermal control, removing it risks throttling/burn |
| `00:06.0` | PCIe controller → NVIDIA dGPU | `pcieport` | keep the bridge, kill the dGPU (below) |
| `00:07.0` | **Thunderbolt 4 Root Port #0** | `pcieport` | keep + lock down (seen below) |
| `00:08.0` | **GNA Scoring Accelerator** (AI gadget) | *none* | **blacklist** — unnecessary attack surface |
| `00:0a.0` | Telemetry Aggregator (`intel_vsec`) | `intel_vsec` | blacklist **[TIER 2]** — telemetry/PMT bus exposed to OS |
| `00:0d.0` | **TB4 xHCI USB controller** | `xhci_hcd` | keep only if you need USB-C; otherwise blacklist |
| `00:0d.2` | **TB4 NHI (USB4 host interface)** | `thunderbolt` | **blacklist + BIOS disable** |
| `00:12.0` | **Integrated Sensor Hub** | `intel_ish_ipc` | **blacklist** — sensors are not needed on a server |
| `00:14.0` | USB 3.2 xHCI (main) | `xhci_hcd` | keep (keyboard/console, USBGuard) |
| `00:14.2` | Shared SRAM | — | none |
| `00:14.3` | **Wi-Fi 6 AX201** | `iwlwifi` | keep only if wired Ethernet is impossible |
| `00:15.0/1` | Serial IO I²C #0/#1 | `intel-lpss` | blacklist if no touchpad needed |
| `00:16.0` | **Intel Management Engine interface** | `mei_me` | **blacklist** (see §4) |
| `00:1c.0` | PCIe Root Port → NVMe | `pcieport` | keep |
| `00:1f.0` | LPC controller | — | keep (essential) |
| `00:1f.3` | Smart Sound audio | `sof-audio-pci-intel-tgl` | **blacklist** (no audio on a server) |
| `00:1f.4` | SMBus | `i801_smbus` | blacklist **[TIER 2]** — SMBus is a classic side channel |
| `00:1f.5` | **SPI controller** | *none* | keep unbound — do **not** load `intel-spi`/`spi-intel` |
| `01:00.0` | **NVIDIA TU117M [GeForce MX450]** | `nouveau` | **blacklist + BIOS disable** |
| `3a:00.0` | ADATA IM2P33F3 NVMe (DRAM-less) | `nvme` | keep, wrap in LUKS |

Two useful facts fall straight out of this dump:

- **`IOMMU group N` is printed for every device** → VT-d is on and usable. Groups are granular
  (the NVMe is alone in group 16, the dGPU alone in group 15), so passthrough/isolation is clean.
- The machine is a **Dell** with **Intel PTT firmware TPM** (not a discrete TPM — no TPM header on
  a laptop like this). This drives the LUKS/TPM decision in `docs/03`.

The host bridge subsystem string `Dell Tiger Lake-UP3/H35 4 cores` means: **4 physical cores**
(8 threads), 11th-gen UP3 part. Expect ~8–16 GB RAM in this class — size the swap LV accordingly.

## 2. Drivers to remove — the artefact

`files/etc/modprobe.d/90-blacklist-paranoid.conf` implements §1. Summary of what it does and why:

- `nouveau` + `nvidia*` — a discrete GPU on a server is pure liability: extra firmware, extra
  kernel attack surface, DMA master, and its `Expansion ROM` is a boot-time code path. Disable it in
  the Dell BIOS (**Video → disable switchable/Optimus graphics**) *and* blacklist it. Belt and braces.
- `snd_sof_pci_intel_tgl`, `snd_hda_intel`, `snd_hda_codec*` — no audio. Removes a whole ALSA/SOF
  attack surface and 2 devices from the DMA picture.
- `mei_me`, `mei`, `mei_hdcp` — the kernel modules that talk to the Management Engine. See §4.
- `bluetooth`, `btusb`, `btintel` — no radio management daemons, no pairing, no BNEP.
- `intel_ish_ipc` — sensor hub; also often the source of noisy ACPI/AML code paths.
- `intel_gna`, `intel_vsec`, `pmt_telemetry` — vendor "value-add" engines. **[TIER 2]** Only add
  `intel_vsec` to the blacklist if `processor_thermal_device` still loads correctly (check
  `dmesg | grep -i thermal` after reboot); DPTF needs it on some firmware revisions.
- `uvcvideo`, `videobuf2_*`, `v4l2*` — webcam. Also covered by the BIOS camera/mic switch.
- `thunderbolt`, `thunderbolt_net` — see §3.
- `uvcvideo`/`i2c_i801`/`intel_lpss_pci` — **[TIER 2]**
- `usb_storage`, `uas`, `firewire*` — **[TIER 3]**, only if the machine is racked and you never plug
  in storage. Otherwise USBGuard (see `docs/07`) is the right control — you still want USB for
  install media and a console keyboard.

Keep the module **loaded for i915** unless the machine truly has no console use: on a Dell, the
internal panel + `efifb` handoff is also your recovery console if SSH dies. If you *do* blacklist
`i915`, keep `efifb` (`video=efifb:off` is not set) so you still get boot messages.

## 3. Thunderbolt 4 — the single biggest physical attack surface

`00:07.0` + `00:0d.2` = full TB4/USB4 with DMA-capable PCIe tunneling. On this class of machine,
**Thunderbolt is the easiest way to root the OS from a malicious dock** (DMA before the IOMMU policy
settles, or PCIe device spoofing).

Do all four:

1. BIOS: **Thunderbolt → Security Level = "User Authorization"** (never "No Security"), and enable
   **Kernel DMA Protection**. Disable "Thunderbolt Boot Support" and "Pre-boot DMA".
2. `blacklist thunderbolt` in `90-blacklist-paranoid.conf` if the machine is permanently wired.
3. If you need TB ports, keep the driver and run `boltctl` — only pre-authorized devices appear;
   `boltctl monitor` in an audit session shows what gets attached. Never click "authorize" for
   something you did not plug in yourself.
4. Independent of TB: `iommu=on iommu.strict=1` (in `files/etc/default/grub` and `files/etc/kernel/cmdline`)
   makes the IOMMU flush after *every* DMA mapping instead of lazily. This is the real DMA-attack
   mitigation for a machine with a firmware TPM and no believable attestation.

## 4. Intel Management Engine (`00:16.0`)

The ME is a separate CPU with its own network access to the chipset, running unauditable firmware,
reachable over the same PCI device you see at `00:16.0`.

- Loaded driver today: `mei_me`. **Blacklisting it removes the OS↔ME communication path** for the
  parts ME exposes to the OS (AMT HECI, HDCP, etc.). Note honestly: this does **not** stop the ME
  from running — it only stops *your OS* talking to it. It is still worth doing: it removes a
  privileged, memory-mapped interface from the kernel's device list.
- BIOS: **disable AMT / vPro / Capability Licensing Service** if the menu exposes it (Dell business
  models often do; consumer models hide it). Check `sudo dmidecode -t 2` for the exact model.
- `me_cleaner` can shrink/neutralise the ME region on **some** SKUs. On Tiger Lake with Boot Guard
  fused in, **the ME region is signed and cannot be neutralised** — attempting it bricks the
  machine or, worse, silently trips the Boot Guard fuse policy and stops your Secure Boot keys from
  working. **[TIER 3 / NOT RECOMMENDED]** Skip `me_cleaner` here. Document the residual risk instead:

> Residual risk R-ME: an attacker with persistent ME firmware access (obtained via a vendor
> toolchain or a compromised BIOS update) is outside our detection boundary. Compensating
> controls: firmware locked with a BIOS password, `fwupd` verified updates, Guard Extension /
> Boot Guard enabled, and the OS-side MEI driver disabled.

## 5. Storage: ADATA DRAM-less NVMe — crypto notes

`3a:00.0 ADATA IM2P33F3 NVMe SSD (DRAM-less)`:

- **Do not trust its self-encryption (OPAL/TCG)**, even if `nvme id-ctrl` reports it. DRAM-less
  consumer drives have repeated firmware-key-handling vulnerabilities, and the controller can be
  coerced into revealing the media key. Use **LUKS2** (`docs/03`) and treat the drive as a dumb
  block device.
- Consequences for LUKS parameters: DRAM-less drives have poor sustained random write throughput,
  so keep `--iter-time` sane (3000–5000 ms) and **do not** use `--pbkdf argon2id` with absurd
  memory cost; the default in `scripts/make-luks-detached.sh` is `--pbkdf-memory 1048576` (1 GiB)
  which is a good balance. Verify unlock time after install — it must stay under ~10 s.
- **No `discard` for LUKS and no `fstrim`** on encrypted volumes: TRIM on a full-disk-encrypted
  volume reveals which filesystem regions are in use, weakening plausible deniability and leaking
  structure. The trade-off is slower writes over time; accept it, or enable `discard` only if you
  understand you are trading away a real (if modest) secrecy property.
- `/etc/fstab` therefore uses `noatime` (fewer metadata writes) plus `nosuid,nodev,noexec` on the
  usual directories, and `errors=remount-ro` on `/`.

## 6. Firmware packages (trixie: `non-free-firmware` is enabled by default)

| Package | Why here |
|---|---|
| `intel-microcode` | **mandatory.** Tiger Lake has a long CVE history; without current microcode, mitigations like `verw`/`eIBRS` behaviour are wrong. Loads early via initramfs. |
| `firmware-misc-nonfree` | `i915` GuC/HuC firmware (needed for a stable console on TGL) and other misc blobs. |
| `firmware-linux-free` | free firmware for the remaining in-use devices. |
| `firmware-iwlwifi` | **only if you must use Wi-Fi** (`00:14.3`). Skip it and blacklist `iwlwifi` if the machine is wired. |
| `firmware-sof-signed` | **skip** — audio is blacklisted. |
| `fwupd` | Dell publishes BIOS/EC/Thunderbolt/USB-C dock firmware to LVFS. `fwupdmgr refresh && fwupdmgr get-updates` before any hardening is declared done. Keep it installed for ongoing firmware updates, but `fwupd` pulls `polkit` — see `docs/09` for the trade-off and tighter alternative (`fwupdtool`, run manually, no daemon). |

Verify what is actually needed instead of guessing:

```bash
sudo dmesg | grep -iE 'firmware|microcode|i915.*(firmware|GuC|HuC)'
sudo apt-get install --no-install-recommends firmware-linux-free firmware-misc-nonfree intel-microcode
sudo update-initramfs -u -k all
sudo reboot
dmesg | grep -i microcode          # must show an early microcode revision newer than BIOS
```

## 7. Microcode, mitigations and the BIOS update loop

`intel-microcode` + `fwupd` are the two things that must never drift:

```bash
grep -m1 microcode /proc/cpuinfo
sudo dmesg | grep -i 'microcode: updated early'
sudo fwupdmgr refresh --force && sudo fwupdmgr get-updates
```

If `fwupdmgr` offers a **UEFI dbx** update, apply it — it revokes known-bad bootloader hashes and is
part of keeping your Secure Boot chain meaningful (`docs/03`).

## 8. Quick sanity commands used to build this profile

```bash
lspci -nnk                       # what was captured in TigerLake_PCI.txt
sudo dmidecode -t system -t bios # Dell model, BIOS version/date, Secure Boot capability
sudo dmesg | grep -iE 'iommu|DMAR|VT-d'
ls /sys/kernel/iommu_groups/ -d1 | wc -l
sudo lspci -vv -s 00:0d.2 | grep -i -A2 kernel     # who drives TB4
cat /sys/firmware/efi/efivars/SecureBoot-* | xxd | tail -1   # 01 = on
sudo bootctl status                                # firmware, bootloader, Secure Boot signer
```

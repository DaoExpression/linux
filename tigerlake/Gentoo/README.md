# Gentoo kernel configuration for the Tiger Lake laptop

These files configure a Linux kernel for the machine described in
`TigerLake_PCI.txt`: a Dell laptop based on an Intel 11th Gen Core
(Tiger Lake-UP3/H35) with Intel Iris Xe graphics, an NVIDIA GeForce MX450,
Thunderbolt 4, an Intel Wi-Fi 6 AX201 and an ADATA NVMe SSD.

| File | Purpose |
| --- | --- |
| `INSTALL.md` | Full step-by-step Gentoo installation manual for this machine. |
| `tigerlake.config` | Kernel config fragment (hardware + workstation subsystems). |
| `apply-config.sh` | Merges the fragment into a kernel source tree and resolves it. |
| `TigerLake_PCI.txt` | The original `lspci -nnk` dump this config is derived from. |

Target assumptions (change them if they do not match your machine):

* NVIDIA MX450 handled by the in-tree **nouveau** driver.
* Init system is **OpenRC**.

## What the fragment enables

Derived one-for-one from the PCI dump (device → driver → `CONFIG_*`):

* **CPU/platform** – `X86_NATIVE_CPU` (optimize for this machine; on pre-6.11
  trees the fragment also lists `MCORE2`, which those trees use instead).
* **Graphics** – `DRM_I915` (Iris Xe, `00:02.0`) and `DRM_NOUVEAU`
  (`TU117M [GeForce MX450]`, `01:00.0`).
* **Storage** – `NVME_CORE` / `BLK_DEV_NVME` (ADATA IM2P33F3, `3a:00.0`).
* **Wireless/BT** – `IWLWIFI` / `IWLMVM` (AX201, `00:14.3`) and
  `BT_HCIBTUSB` / `BT_INTEL`.
* **USB/Thunderbolt** – `USB_XHCI_HCD` + `USB4` (Tiger Lake-LP TB4 and the
  xHCI controllers, `00:07.0`, `00:0d.0`, `00:0d.2`, `00:14.0`).
* **Audio** – SOF (`SND_SOC_SOF_TIGERLAKE`, `sof-audio-pci-intel-tgl`, `00:1f.3`),
  HDA link/codec support, plus the generic HDA and SoundWire machine drivers.
* **Input** – `I2C_HID_ACPI` (touchpad via `00:15.x` LPSS), `PINCTRL_TIGERLAKE`,
  `MFD_INTEL_LPSS_PCI`, `MOUSE_PS2`, `KEYBOARD_ATKBD`.
* **Sensors/platform** – `INTEL_ISH_HID` (`00:12.0`), `INTEL_MEI[_ME/_HDCP/_GSC]`
  (`00:16.0`), `I2C_I801` (`00:1f.4`), `SPI_INTEL_PCI` (`00:1f.5`).
* **Power/thermal** – `INT340X_THERMAL` (Dynamic Tuning, `00:04.0`),
  `INTEL_RAPL`, `INTEL_POWERCLAMP`, `ACPI_*`.
* **Telemetry** – `INTEL_VSEC` (`00:0a.0`), `INTEL_PMT_TELEMETRY`, `INTEL_PMC_CORE`.
* **IOMMU** – `INTEL_IOMMU` + `INTEL_IOMMU_DEFAULT_ON` (every device is in an
  IOMMU group; also needed if you pass GPUs through or use `intel_iommu`).
* **EDAC** – `EDAC_IGEN6` (`00:00.0`, `igen6_edac`).
* **Dell extras** – `X86_PLATFORM_DRIVERS_DELL`, `DELL_LAPTOP`, `DELL_WMI`,
  `DELL_SMBIOS`, `DELL_RBTN` (with `DCDBAS` built in so the chain can be `=y`).
* **Extras** – dm-crypt/AES-NI, EFI stub, devtmpfs, cgroups.

On top of the device-specific options above, the fragment also builds out the
subsystems a usable workstation needs. These are *additions on top of
`defconfig`*, because an unmodified `defconfig` has none of them:

* **Network stack** – `NET`/`INET`/`IPV6`, `INET_DIAG` (`ss`), `PACKET`, `UNIX`.
* **Firewall** – `NETFILTER`, both nftables (`NF_TABLES*`) and legacy
  `ip(6)tables` (`NETFILTER_XTABLES_LEGACY`, `IP_NF_IPTABLES_LEGACY`, filter/NAT/
  mangle/raw, `BRIDGE_NETFILTER`). Docker and libvirt need the NAT/bridge bits.
* **Virtual networking** – `TUN`, `VETH`, `BRIDGE`, `MACVLAN`, `IPVLAN`,
  `VXLAN`, `GENEVE`, `WIREGUARD` (VPN, VMs, containers).
* **Virtualization host** – `KVM` + `KVM_INTEL`, `VHOST_NET`, `VHOST_VSOCK`,
  `VIRTIO_*`, `VFIO`/`VFIO_PCI` (GPU passthrough), `SCSI_VIRTIO`, `VSOCKETS`.
* **Containers / sandboxes** – `USER_NS`, `MEMCG`, `CGROUP_BPF`,
  `CHECKPOINT_RESTORE`, `BPF_SYSCALL`/`BPF_JIT`, `OVERLAY_FS`, `SECCOMP_FILTER`.
* **Filesystems** – `EXT4_FS=y` (root, no initramfs needed) plus `XFS`, `BTRFS`,
  `F2FS`, `JFS`, `EXFAT`, `NTFS3`, `ISO9660`, `UDF`, `SQUASHFS`, `OVERLAY_FS`,
  `FUSE`, `AUTOFS`, `NFS`, `CIFS`, `EFIVAR_FS`, and UTF-8 NLS for USB drives.
* **Media / USB** – `USB_VIDEO_CLASS` (webcam), MMC/SD card readers,
  USB ethernet (`USB_RTL8152`, `AX88179`), `TYPEC_UCSI`, `SND_USB_AUDIO`, zram.

Optional filesystems and drivers are built as modules (`=m`); only the root
filesystem, core networking and subsystems that force built-in are `=y`. The
virtio guest drivers (`VIRTIO_PCI`/`BLK`/`NET`, `DRM_VIRTIO_GPU`) are kept
built-in so the same kernel also boots as a QEMU/KVM guest for testing.

## How to apply

### Option A – build from `sys-kernel/gentoo-sources` (or any source tree)

```sh
cd /usr/src/linux        # or /usr/src/linux-<version>
/path/to/apply-config.sh .
make -j"$(nproc)"
make modules_install
make install
```

`apply-config.sh` starts from `make defconfig`, merges the fragment with
`scripts/kconfig/merge_config.sh`, then runs `make olddefconfig` so the result
matches your kernel version. If a `.config` already exists it is backed up to
`.config.bak` first. Review the result with `make menuconfig`.

### Option B – `sys-kernel/gentoo-kernel` config fragments

`gentoo-kernel` applies every `*.config` file found in `/etc/kernel/config.d/`
on top of its own base config. This is the lowest-friction route:

```sh
mkdir -p /etc/kernel/config.d
cp tigerlake.config /etc/kernel/config.d/10-tigerlake.config
emerge --ask sys-kernel/gentoo-kernel
```

## Firmware and userspace notes

The kernel config is only half of it; install `sys-kernel/linux-firmware`
(and, for the GPU, `x11-drivers/xf86-video-intel` is *not* required – use
modesetting with Mesa `media-libs/mesa`):

* **i915** – GuC/HuC firmware (`i915/tgl_*`).
* **iwlwifi** – `iwlwifi-9000-pu-b0-jf-b0-*` / AX201 (`iwlwifi-QuZ-*` / `iwlwifi-so-*`).
* **nouveau** – `nvidia/tu117_*` firmware.
* **SOF** – `intel/sof/` and `intel/sof-tplg/` topologies.
* **Intel ISH / MEI** – ISH and ME firmware blobs.

Audio uses SOF; you also need `media-sound/alsa-ucm-conf` (or
`sys-firmware/sof-firmware`) for the UCM profiles so the codecs are routed
correctly.

### One thing to confirm on the real machine

The PCI dump does not name the HD-audio/SoundWire codec, so the fragment enables
both common machine drivers (`SND_SOC_INTEL_SKL_HDA_DSP_GENERIC_MACH` and
`SND_SOC_INTEL_SOUNDWIRE_SOF_MACH`). After the first boot, check which one binds:

```sh
aplay -l
dmesg | grep -i -E 'sof|snd|sdw|rt7|alc'
```

If a specific codec is reported, keep the matching machine driver and drop the
other one in `make menuconfig`.

## Verification performed

The fragment was merged into a fresh `linux-7.2.10` tree with
`make defconfig` + `scripts/kconfig/merge_config.sh -m` + `make olddefconfig`.
Every `CONFIG_*=y` **and** `CONFIG_*=m` line in the fragment resolved to exactly
that value, with one intentional exception: `CONFIG_MCORE2` does not exist on
x86_64 in current kernels (it was replaced by `X86_NATIVE_CPU`), so it is
dropped there and only takes effect on older trees. `make olddefconfig` exits 0.

Kernel symbols are not stable across releases, so the fragment was reconciled
against the tree and these moves were found and fixed:

* legacy `ip(6)tables` now sits behind `NETFILTER_XTABLES_LEGACY` /
  `IP_NF_IPTABLES_LEGACY`;
* `nf_tables` table families (`NF_TABLES_INET`, `..._NETDEV`, `..._IPV4`, ...)
  are `bool` and auto-select each other, so they are `=y`, not `=m`;
* `bcachefs` is not in this tree and `NFS_V4_1` no longer exists;
* the Realtek USB NIC is `USB_RTL8152` (not `USB_NET_R8152`);
* `USB_VIDEO_CLASS` requires `VIDEO_DEV`; USB NICs require `USB_USBNET`.

A positive re-audit confirmed the network stack, firewall, virtualization,
container and filesystem options are all present after resolution, and that no
previously working hardware option regressed.

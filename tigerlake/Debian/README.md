# Paranoid Debian + Apache Server — Build, Harden, Verify

Target machine: **Dell laptop, Intel 11th Gen (Tiger Lake-UP3/H35, 4 cores)** as reported by
`lspci` in [`TigerLake_PCI.txt`](TigerLake_PCI.txt).

Role: **single-purpose, headless HTTPS server** (Apache httpd). No GUI, no desktop, no
development toolchain on the host, no unrelated daemons.

This repository contains two things:

1. **A guide** (`docs/`) — do this, in this order, and why.
2. **The actual artefacts** (`files/`, `preseed/`, `scripts/`) — every config file, rule set,
   profile and script the guide references. Nothing in the guide asks you to "create a file"
   by hand; the file already exists here.

---

## 1. The security model in one page

**Threats we take seriously**

| # | Threat | Primary control |
|---|--------|-----------------|
| T1 | Offline theft of the disk/laptop | LUKS2 full-disk encryption, Argon2id, **detached header**, no TPM auto-unlock |
| T2 | Evil-maid / bootkit (modified kernel or initramfs) | Secure Boot with **your own keys**, signed Unified Kernel Image, kernel lockdown `confidentiality` |
| T3 | Remote compromise of the web service | Minimal attack surface (few modules), TLS 1.3 only, mod_security3 + OWASP CRS, per-service sandboxing, AppArmor, nftables ingress + egress filtering |
| T4 | Compromise of the host *from* the web service | systemd sandboxing of the Apache unit, per-security-domain users, AppArmor, no shell for the web user, read-only root, no compiler on host |
| T5 | Malicious/rogue PCIe or Thunderbolt device (DMA attack) | Intel VT-d + IOMMU strict mode, Thunderbolt security level + `boltctl` authorization, NVIDIA dGPU bound away/disabled, unused devices blacklisted |
| T6 | Malicious USB device | USBGuard in `deny` default policy, `usbcore` authorization, no X11/automount, unused USB controllers blacklisted if the machine is racked |
| T7 | Firmware/Management Engine persistence | BIOS password + firmware lock, `fwupdmgr` updates, **Intel ME interface driver disabled and ME disabled via `me_cleaner` (optional, high risk)**, microcode from `intel-microcode` |
| T8 | Supply chain / driver abuse | `module.sig_enforce=1`, no `testing`/`sid`, `--no-install-recommends` only, apt signature + `Valid-Until` checks, AIDE + debsums integrity monitoring |
| T9 | Privilege escalation on the host | `noexec,nosuid,nodev` mounts, sysctl/tier-1 hardening, auditd rules, sudo hardening, `kernel.perf_event_paranoid`, userns/bpf restrictions |
| T10 | Data exfiltration by a compromised service | Egress firewall allowlist, Apache in its own namespace/user, per-vhost separation, outbound DNS pinned to local validating resolver |
| T11 | Third-party software demanding host privileges | **Virtualization/isolation instead of host packages** — see `docs/09` |

**What we explicitly refuse to do (and why)**

- No TPM-based disk unlock on this machine: it only has **Intel PTT (firmware TPM)** — see the
  hardware profile. Passphrase + detached header on a separate physical token is stronger against
  the threats that matter here. TPM2 is still used for *sealing audit/IMA state*, which is optional.
- No Secure Boot using Microsoft's third-party CA and Debian's shim in "trust whatever MOK"
  mode: we own the platform keys. The shim path is documented as a fallback only.
- No Docker/podman daemon running as root, no rootful libvirt, no host PHP/Python/Node.
- No `discard`/`fstrim` on encrypted volumes (leaks allocation patterns), no hibernate
  (cold-boot + swap-exposure risk), no `nosmt` unless you accept the ~30% capacity loss.
- No `testing`, no `sid`, no backports for anything security-relevant.

**The cost of this posture** — state it plainly before you start:

- Losing the LUKS header USB key **and** the passphrase = total data loss. Keep the header backup.
- Losing your custom Secure Boot keys = you must clear the firmware and re-enrol; on a Dell that
  means a BIOS reset. Keep `keys/` offline.
- Egress filtering means package installs are manual and annoying. That is the point.
- Some paranoia tiers (`mitigations=auto,nosmt`, strict egress, module signing) cost performance
  or convenience. Each is labelled **[TIER 2]** or **[TIER 3]** so you can decide deliberately.

---

## 2. Directory layout

```
README.md                        this file
hardened-debian-apache.html      the whole guide + every artefact in ONE offline dark-theme page
tools/                           generator for that page (markdown converter, annotations, HTML shell)
docs/
  00-hardware-profile.md         what YOUR machine has, what to keep/blacklist, firmware
  01-threat-model.md             assets, adversaries, assumptions, explicit non-goals
  02-debian-install.md           debian installer walkthrough (encrypted, minimal, offline-first)
  03-boot-integrity.md           Secure Boot own-keys, UKI, LUKS detached header, TPM stance
  04-base-hardening.md           sysctl, modules, users, sudo, PAM, AppArmor, auditd, AIDE, apt
  05-network-and-firewall.md     nftables ingress+egress, DNS, SSH, WireGuard admin plane
  06-apache-hardening.md         Apache hardening, TLS 1.3, mod_security3+CRS, sandboxing, CLI ACME
  07-physical-and-firmware.md    BIOS, ME, Thunderbolt, USBGuard, sensors/camera/mic
  08-isolation-and-virtualization.md  KVM/nspawn/podman patterns for anything not essential
  09-software-policy.md          "install only what is necessary" decision procedure
  10-audit-and-maintenance.md    daily/weekly/monthly/quarterly runbook + verification
  11-incident-response.md        compromise response, key rotation, recovery drills
files/etc/…                      the artefacts (drop-in ready)
files/usr/local/sbin/…           helper scripts the units call (boot record, cert check)
files/keys/README.md             how to create and store your Secure Boot keys
preseed/paranoid-preseed.cfg     unattended encrypted+minimal install (fully hands-off)
scripts/
  install-hardening.sh           idempotent: copies files/, enables everything
  harden-apache.sh               Apache module prune + config install + validation
  verify-hardening.sh            read-only checker: PASS/FAIL/WARN per control (run this!)
  make-luks-detached.sh          detached-header LUKS setup helper used by the installer
  Makefile                       make help / dry-run / install / verify
```

Every file under `files/` mirrors the absolute path it belongs at. `scripts/install-hardening.sh`
walks that tree and installs it, so paths never drift.

## 2b. The offline single-file reference

`hardened-debian-apache.html` is a self-contained dark-theme page that presents all 13 documents as
separate pages **and** embeds all 72 configuration artefacts with per-option annotations
(`⟵ why this matters`). It needs no network and no server: open it with a browser, from a USB stick,
from the machine you are building. Nothing is fetched at runtime — a browser refuses to read local
files from a `file://` page, which is why the content is embedded at build time.

```bash
python3 tools/build-docs-html.py          # rebuild after changing any doc or artefact
make -f scripts/Makefile docs-html        # same thing
make -f scripts/Makefile docs-html-verify # fails if the committed page is stale
```

The build **fails** rather than silently degrading: it recomputes the fence and table counts of every
document and compares them with what was rendered. Change a document, rebuild, and the page cannot
drift from the repository.

---

## 3. Order of operations

0. Read `docs/01-threat-model.md`. Decide your tier (1 = pragmatic paranoia, 2 = recommended,
   3 = maximum, with real convenience costs).
1. `docs/00-hardware-profile.md` — know what you are disabling before you disable it.
2. `docs/02-debian-install.md` — install (interactive or `preseed/paranoid-preseed.cfg`).
3. `docs/03-boot-integrity.md` — Secure Boot own keys, UKI, verify LUKS header is detached.
4. `bash scripts/install-hardening.sh --dry-run` then without `--dry-run`.
5. `docs/05-network-and-firewall.md` — nftables last, or you will lock yourself out.
6. `docs/06-apache-hardening.md` + `bash scripts/harden-apache.sh`.
7. `docs/07-physical-and-firmware.md` — BIOS/ME/Thunderbolt/USBGuard.
8. `docs/10-audit-and-maintenance.md` — install timers, run `scripts/verify-hardening.sh`.
9. Anything else you want → `docs/09-software-policy.md`, then `docs/08-isolation-and-virtualization.md`.

**Safe-mode rule:** do all of steps 4–7 over the physical console or an
`ssh -o ServerAliveInterval=15` session with a second root shell already open. Every network step in
this repo applies rules with `nft -f` only after `nft -c -f` (check) passes.

---

## 4. Verification

```bash
bash scripts/verify-hardening.sh          # full read-only audit, exits non-zero on FAIL
bash scripts/verify-hardening.sh --tier 1 # only checks the tier you chose
sudo systemd-analyze security apache2 nftables
sudo lynis audit system                   # optional extra opinion, not required
```

`verify-hardening.sh` checks the guide's own claims (LUKS header location, Secure Boot state,
sysctl values, module blacklists, Apache directives, nftables policy, timers, file modes).
A green run is the definition of "this build matches the guide".

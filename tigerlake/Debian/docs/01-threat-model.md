# 01 — Threat model

Scope: one physical machine in a non-datacenter location (a laptop sitting in an office or home),
serving HTTPS on 443 to the internet.

## 1. Assets, in priority order

| Asset | Impact if lost | Where it lives |
|---|---|---|
| TLS private keys (`/etc/ssl/private`) | Impersonation of every site on the box; forged certs for your users | encrypted root, mode 0600 root:root |
| Application data / user data under `/var/www` | Confidentiality + integrity liability | encrypted `/var` |
| The OS itself | Persistence, botnet, use as a pivot | encrypted root + signed boot chain |
| Audit logs | Loss of non-repudiation, no forensics | `/var/log`, shipped off-host |
| LUKS header backup + Secure Boot keys | Total, unrecoverable loss | offline (paper + two USB devices) |
| Availability | Downtime | not the priority here — security is |

## 2. Adversaries we design against

1. **Opportunistic internet scanner** — automated HTTP/SSH exploit attempts. Nearly 100% of real
   traffic to a new public IP. Controlled by minimal surface + updates + rate limits.
2. **Skilled remote attacker** targeting your web stack — needs a real vulnerability in Apache, a
   module, or the app. Controlled by module pruning, mod_security/CRS, per-service sandboxing,
   AppArmor, and **egress filtering** so a shell cannot phone home.
3. **Physical/offline attacker** with the powered-off laptop. Controlled by LUKS + Secure Boot
   own keys + BIOS password; the reason we do **not** trust the firmware TPM for unlock.
4. **Malicious peripheral** (USB stick, Thunderbolt dock, PCIe device). Controlled by IOMMU strict
   mode, USBGuard, TB "User Authorization", disabled unused controllers.
5. **Malicious insider / stolen credentials.** Controlled by key-only SSH, no shared accounts,
   per-action sudo logging, OOB admin plane on WireGuard.
6. **Supply chain** (a bad package or driver update). Controlled by pinned repos, signature
   checks, `module.sig_enforce`, AIDE/debsums, and a staged update procedure.

## 3. Explicit assumptions

- The machine's **firmware and ME are trusted enough**: we cannot audit them and cannot meaningfully
  neutralise ME on TGL (see `docs/00` §4). We reduce OS-side exposure and update firmware; we do not
  claim to defend against a compromised ME.
- Physical access *before* your first boot is assumed hostile — hence Secure Boot key enrollment
  yourself, and re-flashing the BIOS from a trusted source before you start.
- The site's **application** is out of scope for this repo; this repo secures the platform. An
  insecure PHP app on an otherwise perfect host is still an insecure service (see `docs/09`).
- You have at least one **second machine** to hold backups and keys, and a **second network path**
  (a phone hotspot is enough) to fix a remote-lockout mistake.

## 4. Non-goals (be honest with yourself)

- Not anti-forensics. `make noatime`, no TRIM, and LUKS do not hide the *existence* of the OS.
- Not deniable encryption against a state-level adversary who can image both the disk and the USB
  header. It raises cost; it is not magic.
- Not covert: a hidden Tor/I2P host, an exit node, or a censorship-circumvention endpoint would need
  a different design (bridges, traffic shaping, and an entirely different legal review).
- Not a hardened multi-tenant platform. If you need tenants, you need separate VMs per tenant
  (`docs/08`) and probably separate hardware.

## 5. Security tiers — pick one deliberately

Every hardening item in this repo is labelled. You **must** state your tier now, because
`scripts/verify-hardening.sh` and the install script behave differently per tier.

| Tier | Name | What it means | Costs |
|---|---|---|---|
| **1** | Pragmatic | All integrity/confidentiality controls, no performance sacrifice, no fragile tricks | Almost none. Default. |
| **2** | Recommended | Adds egress allowlist, stricter sysctls, `iommu.strict=1`, upstream repo pinning, USBGuard deny-all, TPM2 sealing of audit state | Manual package installs (egress), occasional friction |
| **3** | Maximum | Adds `mitigations=auto,nosmt`, `module.sig_enforce=1` with own-signed modules, `/boot` read-only, USB storage blacklisted, detached LUKS header, single-user mode disabled, watchdog auto-recovery after tamper | ~30% CPU loss, no hibernation, boot requires the header USB, kernel updates require re-signing |

**This repo's default is Tier 2** (the sweet spot for the threat list above). Tier 3 items are all
marked `[TIER 3]`; do not enable one "for fun" without reading its cost line.

## 6. Attack-path walkthrough (why the order in the README matters)

```
Internet
  │  ① nftables inet filter: default DROP, only 443 (and SSH on wg0) reachable
  ▼
Apache httpd  ──② sandboxed systemd unit: no caps, strict fs, syscall filter, AppArmor
  │            ③ TLS 1.3 only, mod_security3 + CRS, headers, per-vhost user
  ▼
Application  ──④ runs as www-data, no shell, no home, cannot write outside /var/www/<site>
  │            ⑤ even if RCE: egress allowlist blocks C2, /tmp noexec+tmpfs
  ▼
Kernel/host  ──⑥ no compiler, no python, minimal packages, auditd watching /etc and execve
  │            ⑦ LSM stack: landlock, yama, apparmor; sysctl hardening; user namespaces tightened
  ▼
Boot chain   ──⑧ Secure Boot (own keys) → signed UKI → LUKS2 (Argon2id) → locked kernel
  │            ⑨ firmware/BIOS password, MEI disabled, TB locked, USBGuard
  ▼
Data at rest
```

Each numbered control has a section in `docs/04`–`docs/07` and an artefact under `files/`.
If a control is missing at verification time, `verify-hardening.sh` says so and exits non-zero.

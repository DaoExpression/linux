# /etc/paranoid — the state and policy directory for this build

Everything here is created and read by the artefacts in this repo. It exists so the machine's
security posture is **inspectable**: you can read, in one place, what has been decided and what has
drifted.

| Path | Purpose | Mode |
|---|---|---|
| `README.md` | this file | 0644 |
| `package-justifications` | one line per package that is not obviously load-bearing, with the reason and date (docs/09 §1) | 0600 |
| `modules-lock` | if this file exists, `kernel-modules-lock.service` freezes the module table at boot (Tier 3). Touch to arm, remove to disarm | 0600 |
| `backup.env` | repository URL + where the restic password file lives (never the password itself) | 0600 |
| `restic-pass` | the restic repository password. Copy it OFFLINE too. | 0600 |
| `tier` | the tier you chose (`1`, `2`, or `3`) — read by `scripts/install-hardening.sh --tier auto` and by `verify-hardening.sh` | 0644 |
| `baseline/` | saved "healthy" snapshots (docs/10 §7), the output of `verify-hardening.sh`, and firmware state dumps | 0700 |
| `lsmod-baseline` | module list captured when you decided to arm `modules-lock` | 0600 |
| `local-overrides.md` | **your** notes: what you changed from this repo and why. If `verify-hardening.sh` fails and this file explains it, that is a legitimate answer — but it must be written down here, not remembered | 0600 |

## Files that must NEVER live here

- Private keys (Secure Boot, TLS, WireGuard, SSH). Keys live where their daemon requires them, with
  0600 root:root and, for the highest-value ones, an offline copy.
- Passwords in plaintext other than `restic-pass` (which is itself a key, and the documented reason
  it exists is that backups must be restorable without any single other secret).
- The LUKS header backup. That stays on offline media; the recovery procedure is in docs/03 §4 and
  docs/10 §6.

## Conventions

- `tier` is authoritative. Run `bash scripts/install-hardening.sh --tier auto` to apply the tier this
  machine already documents, so a rebuild cannot silently drop to Tier 1.
- Every change made by `install-hardening.sh` is backed up to `/var/backups/paranoid/<timestamp>/`
  before it is applied, and the script prints how to roll back. Use it.
- If a control here conflicts with something you need, change it **in this repo** and re-run
  `install-hardening.sh`, then `verify-hardening.sh`. Editing files in `/etc` directly is how a
  hardened machine becomes an undocumented one.

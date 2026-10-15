# 08 — Isolation and virtualization instead of host installs

The rule that overrides convenience in this build:

> **Anything that is not essential to serving HTTPS does not belong in the host's package set.**
> If you need it anyway, run it isolated: a service-sandboxed container (`systemd-nspawn`), a rootless
> container (podman), or a rootless VM (QEMU/libvirt *session*). The host stays minimal; the risk
> stays in a box you can throw away.

Why this is not paranoia theatre: `docs/04`+`docs/06` make host privilege escalation from the web
service expensive — but every extra host package is a new set of parsers, a new setuid binary
candidate, a new systemd unit, and a new CVE stream you must track. A container's CVE does not
automatically become *your* root.

---

## 1. Choosing the isolation level

| Need | Best tool | Why not something else |
|---|---|---|
| Run a small unprivileged network service (a stats page, a PHP app, a DB) | **`systemd-nspawn`** | It is `systemd` + namespaces + `seccomp` + LSM, ships with `systemd-container`, and reuses the hardening directives you already know. No daemon, no rootful mgmt stack. |
| Run a CLI tool / build environment / odd runtime | **rootless `podman`** | No root daemon at all (unlike rootful Docker), OCI images are reproducible and disposable, and the host's firewall is not silently rewritten. |
| Run a service that needs a *different kernel* or full kernel-level isolation | **rootless QEMU/libvirt session** | Strongest separation; slower and heavier. Use when the guest itself is untrusted. |
| One-shot tool you will use once (firmware updater, PDF tool) | **container, then delete** | Keeps the host list static. |

Costs, stated plainly: containers share the kernel, so a kernel-level bug escapes them all — the host
kernel hardening in `docs/03`/`docs/04` is what you are trusting. VMs are heavier (RAM, CPU overcommit,
storage), need their own update cadence, and a rootless VM image is not automatically minimal.

## 2. Prefer `systemd-nspawn` for the "one small service" case

Minimal, daemon-free, and every isolation knob is a systemd directive you can read:

```bash
sudo apt-get install --no-install-recommends systemd-container debootstrap
sudo mkdir -p /var/lib/machines
sudo debootstrap --variant=minbase --include=ca-certificates,openssl trixie \
     /var/lib/machines/app01 https://deb.debian.org/debian
sudo systemd-nspawn -D /var/lib/machines/app01 --setenv=TERM=xterm passwd root
```

`files/etc/systemd/nspawn/app01.nspawn` (installed to `/etc/systemd/nspawn/`) is the isolation policy:

```ini
[Exec]
Boot=yes
Capability=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID CAP_CHOWN CAP_DAC_OVERRIDE CAP_KILL
PrivateUsers=pick                     # maps the container's root to an unprivileged host uid
NotifyReady=yes
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete @mount @debug @cpu-raw-io
RestrictNamespaces=~user

[Files]
Private=yes
ReadOnly=yes                         # container rootfs is read-only...
Volatile=state                       # ...with /var as a per-instance writable tmpfs on disk
BindReadOnly=/etc/ssl/certs:/etc/ssl/certs

[Network]
Private=yes                          # its own netns, and NO address unless you add one
# Zone=internal                      # optional: put it in a firewalld zone (we do not run firewalld)
# Port=tcp:8443:443                  # only if you deliberately publish a port

[Security]
NoNewPrivileges=yes
```

Key properties to keep:

- `Private=yes` in `[Files]` + `ReadOnly=yes`: the container cannot see `/etc`, `/root`, or the
  webroot. Bind-mount **only** the specific directory it needs, read-only if possible.
- `Private=yes` in `[Network]` + no `Port=` line = no network at all. Add the *narrowest* possible
  publication when you need one; never `Port=` a management port to the WAN.
- `PrivateUsers=pick` maps container root to an unprivileged host uid. **If the service must bind a
  low port**, that is a design smell — listen high inside, and redirect/publish from the host.
- The container has its **own update story**: `sudo systemd-nspawn -D /var/lib/machines/app01 -- \
  bash -c 'apt-get update && apt-get -y upgrade'`. It is in `docs/10`'s weekly routine. A container
  nobody updates is just a nicer-looking vulnerable service.

Start and inspect:

```bash
sudo systemctl enable --now systemd-nspawn@app01
sudo machinectl list
sudo systemctl status systemd-nspawn@app01
sudo nsenter -t $(machinectl show app01 -p Leader --value) -n ss -tulpn   # what it listens on
```

## 3. Rootless `podman`, if you want OCI images

```bash
sudo apt-get install --no-install-recommends podman slirp4netns fuse-overlayfs
sudo loginctl enable-linger app              # a dedicated unprivileged user
sudo -u app podman run --rm -it docker.io/library/debian:trixie bash
```

Hardened run defaults, kept in `files/etc/containers/containers.conf` (installed from the repo):

```ini
[containers]
default_capabilities = ["CAP_NET_BIND_SERVICE"]   # drop everything else
no_hosts = true                                    # /etc/hosts is not mounted
ipcns = "private"
pidns = "private"
utsns = "private"
userns = "auto"
cgroupns = "private"
default_sysctls = [
  "net.ipv4.ping_group_range=0 0",
  "net.ipv4.ip_unprivileged_port_start=0",
]
env_host = false
init = true
seccomp_profile = "default"
```

And the image discipline that makes this worth it:

- **Pin by digest, not tag**: `podman run docker.io/library/nginx@sha256:...`. Tags move; digests do not.
- **Rootless only.** Never start `podman.service` (the rootful socket) and never hand it to a web app
  (`/run/podman/podman.sock` is root-equivalent). Put this in your head as an absolute.
- **No `--privileged`, no `-v /:/host`, no `/dev` passthrough.** Each of those turns a container into
  a host root shell. If your image *requires* them, the image is the problem.
- **Own the storage**: put container volumes on the encrypted `/srv` or `/var` LVs, with the same
  `nosuid,nodev` mount options.
- **Egress**: rootless podman with `slirp4netns`/`pasta` is subject to your host egress rules. That is
  the desired behaviour — a container cannot bypass `docs/05` §4.

> **Interaction with `docs/04` §3:** `user.max_user_namespaces=0` and
> `kernel.unprivileged_userns_clone=0` are deliberately *not* set, because rootless containers need
> them. If you choose to set them (Tier 3 "no unprivileged namespaces"), you must give up rootless
> podman/nspawn. Decide once, and let `verify-hardening.sh` enforce the pair consistently instead of
> letting the two settings contradict each other.

## 4. Rootless VMs (`qemu:///session`), when you need a real kernel boundary

```bash
sudo apt-get install --no-install-recommends qemu-system-x86 qemu-utils libvirt-daemon-system \
     virtinst libosinfo-bin
# Use the SESSION (rootless) instance, not the system one:
virsh --connect qemu:///session list --all
```

Policy for this host:

- **`qemu:///session` only.** The system instance puts a root daemon (`libvirtd`/`virtqemud`) in your
  trust boundary and makes `/var/run/libvirt/libvirt-sock` root-equivalent. Not on a paranoid host.
- **Disk encryption per guest**: give each VM its own LV (`/dev/vg0/vm-<name>`) and put LUKS inside it, or
  rely on the host's LUKS for the datastore. Either is defensible; document which you chose.
- **No USB/TB passthrough** unless the use case demands it, and then only a specific device by
  `vendor:product` and only while needed (`docs/07` §3).
- **Networking**: `-netdev user` (slirp) by default = NAT with no inbound and no bridge. A bridge
  (`virbr0`) requires `net.ipv4.ip_forward=1` and the explicit forward rules in `docs/05` §3 — re-enable
  them *only* for the guest subnets you name.
- **Resources**: cap guests (`MemoryMax=`, `CPUQuota=`) in their systemd units so a runaway guest
  cannot DoS the web server. The host's job is serving HTTPS; everything else is a guest.
- **The guest's own hardening** is a separate install (`docs/02`+`docs/04` apply inside it). Use it to
  *test* this repo's preseed before ever running it on bare metal — that is the ideal use of a VM here
  and the reason `preseed/paranoid-preseed.cfg` is safe to iterate on:

```bash
# inside the rootless VM, exercise the preseed end-to-end
qemu-img create -f qcow2 /var/lib/libvirt/images/test.qcow2 20G
virt-install --connect qemu:///session --name test --memory 4096 --vcpus 2 \
  --disk path=/var/lib/libvirt/images/test.qcow2,format=qcow2 \
  --cdrom ~/debian-13-netinst.iso --network user --graphics none --console pty \
  --extra-args "auto=true priority=critical url=file:///cdrom/paranoid-preseed.cfg"
```

## 5. What must never run on this host (regardless of isolation)

- A **rootful container daemon** (Docker/podman socket) — root-equivalent and it rewrites nftables.
- A **CI runner** (GitLab/GitHub runner, Jenkins) — arbitrary code execution by design.
- Anything that listens on a **management port exposed to the internet** (webmin, cPanel, Jupyter,
  panels). If you need a UI, it goes behind the WireGuard plane and mTLS (`docs/06` §5).
- **Build toolchains** (`build-essential`, `pip`, `npm`, `cargo`) — do the build in a throwaway
  container and ship the artifact. A compiler on a web host converts memory bugs into `system()`
  calls.
- A **desktop stack** (X11/Wayland, NetworkManager, bluez, PulseAudio) — each one grew up assuming
  single-user local use.
- **Monitoring agents from vendors** unless *you* audited the binary; prefer pulling metrics
  (node_exporter is small but still a host binary — run it in a container with a read-only mount of
  `/proc` and no network beyond the scrape target, or skip it and read `journalctl`+`sysstat`).

## 6. Verification

```bash
machinectl list                                  # containers you expect, and only those
systemctl is-enabled systemd-nspawn@app01        # enabled if you use it
sudo -u app podman ps --format '{{.Names}} {{.Image}}'
sudo ss -tulpn | grep -E 'podman|docker|libvirt'  # expect: nothing listening on a public address
sudo ss -x | grep -c libvirt-sock                 # rootful libvirt would show here
sysctl net.ipv4.ip_forward                        # 0 unless you built a bridge on purpose
sudo nft list chain inet filter forward | tail -5 # policy drop + only your explicit guest rules
bash scripts/verify-hardening.sh --section isolation
```

If `ip_forward=1` or a `virbr0` exists and you did **not** intend a bridge, that is a finding: some
libvirt/virt-manager default installation flipped it. Turn it off and re-check `docs/05` §3.

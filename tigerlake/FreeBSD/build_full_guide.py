#!/usr/bin/env python3
# build_full_guide.py — full-HTML rewrite of INSTALL-GUIDE.html:
#   * styled by article.css (do not change its values)
#   * config files: exact code, one line per <code>…<br>
#   * txt guides: converted to structured HTML
#       - features     → <strong>   (bold)
#       - options      → <span class="opt">  (italic)
#       - tips         → <span class="tip">  (underlined)
#   * no "file talk": content presented as steps, files referenced only
#     by the files themselves being embedded where needed.
import html as _h
from pathlib import Path

ROOT = Path(__file__).parent

def esc(s): return _h.escape(s)

def code_lines(name: str) -> str:
    return "\n".join(f"<code>{esc(l)}<br></code>"
                     for l in (ROOT / name).read_text().splitlines())

def cfg(name, title, why):
    return f"""
<h2 id="cfg-{Path(name).stem}">{title}</h2>
<p>{why}</p>
{code_lines(name)}
"""

def step(n, title, body):
    return f'<div class="step-{n}"><h2 id="step{n}"><span class="stepnum">Step&nbsp;{n}.</span> {title}</h2>\n{body}</div>'

# ======================================================================
# HTML skeleton, importing article.css (extra here: nav & small helpers)
# ======================================================================
HEAD = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link rel="stylesheet" href="article.css">
<style>
  /* extra-only additions; article.css values stand */
  .step { margin-top: .8em; }
  nav.toc { columns: 2; column-gap: 2em; font-size: .95em; }
  nav.toc a { display: block; padding: .15em 0; }
  .kbd { font-family: "DejaVu Sans Mono", monospace; font-size: .88em;
         border: 1px solid var(--line); border-radius: 3px; padding: 0 .4em;
         background: #f1efe9; }
  .pill { display: inline-block; font-size: .78em; padding: .05em .6em;
          border-radius: 10px; background: #ece9e0; color: var(--soft);
          margin-left: .5em; }
  blockquote { border-left: 4px solid var(--line); margin: 1em 0; padding: .3em 1em; color: var(--soft); }
  .finish td:nth-child(2) { width: 58%; }
</style>
</head>
<body>
"""

TOC = """
<h1>Your FreeBSD Laptop — From Nothing to Locked-Down Desktop</h1>
<p><em>Total journey: ten steps. You bring the laptop and an empty USB
stick; the guide brings everything else. <span class="opt">Every option you
might skip is marked in italics</span>; <u>every tip worth remembering
appears underlined</u>; <strong>FreeBSD features are bold</strong>.</em></p>
<nav class="toc">
 <a href="#intro">Step 0 — what you will end up with</a>
 <a href="#step1">Step 1 — make the install stick</a>
 <a href="#step2">Step 2 — install (ZFS + encryption)</a>
 <a href="#step3">Step 3 — root system files (rc.conf)</a>
 <a href="#cfg-loader.conf">Step 4 — bootloader (loader.conf)</a>
 <a href="#cfg-sysctl.conf">Step 5 — kernel tuning (sysctl.conf)</a>
 <a href="#cfg-doas.conf">Step 6 — admin rights (doas.conf)</a>
 <a href="#cfg-pf.conf">Step 7 — firewall (pf.conf)</a>
 <a href="#cfg-xorg.conf">Step 8 — graphics recipe (xorg.conf)</a>
 <a href="#step9">Step 9 — driver installer (post-install.sh)</a>
 <a href="#step10">Step 10 — software for the desktop</a>
 <a href="#extra-filesystems">Appendix A — disks, images &amp; files</a>
 <a href="#extra-zfs">Appendix B — living on ZFS</a>
 <a href="#extra-privacy">Appendix C — privacy layer</a>
 <a href="#extra-capabilities">Appendix D — what makes FreeBSD FreeBSD</a>
 <a href="#extra-security">Appendix E — logs &amp; monitoring</a>
 <a href="#extra-lockdown">Appendix F — lock it all down</a>
 <a href="#finish">Finish — proof of work checklist</a>
</nav>
"""

INTRO = step(0, "what you will end up with", """
<p>At the end of this guide the laptop runs <strong>FreeBSD</strong>, a
complete operating system assembled as <strong>one coherent base</strong> —
kernel, drivers and tools versioned together — plus a desktop of your
choosing, behind a <strong>pf firewall</strong>, on a
<strong>ZFS</strong> disk with TRIM, using
<strong>doas</strong> for admin powers instead of logging in as root ever
again, and finally <strong>locked</strong> so that no one can change it
without the admin password — not even by booting another kernel.</p>

<p><span class="opt">This machine's parts are FreeBSD-friendly: the
Intel Iris Xe graphics work through the i915kms module, the AX201 Wi-Fi
through iwlwifi, the I219-V network chip through em — all native or
one-package-away</span>. Keep that doubt row for later reading when you
wonder why something is fast or slow:</p>

<table>
<tr><th>Hardware</th><th>What FreeBSD does with it</th></tr>
<tr><td>i7-11390H, 8 threads</td><td><strong>native support</strong>; powerd governs clocks</td></tr>
<tr><td>Iris Xe graphics</td><td><strong>drm-kmod</strong> package → i915kms</td></tr>
<tr><td>AX201 Wi-Fi 6</td><td><strong>iwlwifi(4)</strong> driver + firmware pkg</td></tr>
<tr><td>I219-V ethernet</td><td><strong>em(4)</strong>, fully native</td></tr>
<tr><td>NVMe SSD</td><td><strong>ZFS</strong> with native TRIM + compression</td></tr>
</table>

<div class="warn"><strong>The only unrecoverable step is Step 1:
everything currently on the laptop's disk will be erased.</strong>
<u>Move what matters to another machine or cloud account before
continuing.</u></div>
""")

STEP1 = step(1, "make the install stick", """
<ol>
<li><strong>Download</strong> the
<a class="external" href="https://www.freebsd.org/where/">current RELEASE memstick image</a>
— pick <em>amd64-memstick.img.xz</em>. <span class="opt">A RELEASE build is
the stable-and-patched choice; newer experimental branches exist and are
covered in Appendix D.</span></li>

<li><strong>Write the image to a USB stick</strong> of 4&nbsp;GB or more
(everything on it is lost). From any Windows machine use
<a class="external" href="https://etcher.balena.io/">balenaEtcher</a>;
from a Linux one:
<pre><code>unxz FreeBSD-14.3-RELEASE-amd64-memstick.img.xz<br>
dd if=FreeBSD-14.3-RELEASE-amd64-memstick.img of=/dev/sdX bs=1M conv=sync status=progress</code></pre>
<u>Always point dd at the whole stick</u> (<code>/dev/sdX</code>), never at a
partition like <code>/dev/sdX1</code>.</li>

<li><strong>Verify the copy:</strong> <code>cmp /dev/sdX image.img</code> —
<u>a silent cmp is the difference between a working installer and a random
hang halfway through</u>. On this laptop that check costs 2 minutes.</li>

<li><strong>Boot it:</strong> power on with the stick in, tap the boot-menu
key (<span class="kbd">F12</span>/<span class="kbd">F2</span>/<span class="kbd">ESC</span>),
choose the <em>UEFI:</em> USB entry. The official
<a class="external" href="https://docs.freebsd.org/en/books/handbook/install/">Handbook installation chapter</a>
has imagery for every screen you will see.</li>
</ol>
""")

STEP2 = step(2, "install: root filesystem on ZFS, encrypted", """
<ol>
<li>Installer menu: <strong>Install</strong>.</li>
<li>Keyboard: your layout — <em>pt</em> was set in the prepared rc.conf to
match, so make both agree.</li>
<li>Hostname: <em>freebsd-desktop</em> — <u>use a neutral hostname</u>; a
real name appearing in every network scan log is a needless fingerprint
(Appendix C).</li>
<li>Partitioning: <strong>ZFS</strong>. It is what turns the SSD into a
self-healing, snapshotable, encrypted root — <span class="opt">optionally
UFS exists for exotic cases, but a modern desktop wants ZFS</span>. Choose
<strong>Stripe</strong> (your single SSD; a mirror needs two drives) and
<strong>enable encryption with a passphrase</strong> — this is the
foundation of Appendix F.</li>
<li>Target disk: the internal NVMe <em>only</em>. <u>The USB stick itself
also appears as a disk (da0) — selecting it would destroy the installer;
double-check the listing before confirming.</u></li>
<li>Root password; then <strong>add your user to the wheel group</strong> —
wheel is what doas.conf will authorize (Step 6).</li>
<li>Networking: enter your Wi-Fi's name and password; the installer writes
<strong>wpa_supplicant.conf</strong> for you. <span class="opt">Cable users
pick em0 instead; both are configured in Step 3's rc.conf.</span></li>
<li>Reboot and remove the stick.</li>
</ol>
""")

STEP3 = cfg("rc.conf", '<span class="stepnum">Step&nbsp;3.</span> root system settings — rc.conf',
"""<p>The <strong>rc.conf file is FreeBSD's switchboard</strong>: one line per
service, interface, and behavior. This copy is pre-written for a desktop
laptop of your model. Copy the whole guide directory onto the machine (USB
stick or SSH) and merge this file with the helper script in Step 9 — or
paste the lines into <code>/etc/rc.conf</code> by hand and learn each one
as you go:</p>""")

STEP4 = cfg("loader.conf", '<span class="stepnum">Step&nbsp;4.</span> boot-time settings — loader.conf',
"""<p><strong>loader.conf runs before the kernel</strong>: it loads modules
too early to load later and sets cache sizes. Two values here matter most
for you — <strong>zfs_load</strong> (your root filesystem) and the console
framebuffer that makes early boot readable. <span class="opt">ARC cap
(Removed: now a sysctl-time knob for 8 GB on a 16 GB machine) and the
loader password both also live here when you reach Appendices B and F.</span></p>""")

STEP5 = cfg("sysctl.conf", '<span class="stepnum">Step&nbsp;5.</span> kernel behavior — sysctl.conf',
"""<p><strong>Sysctls are kernel knobs</strong>, most adjustable without any
reboot (and <code>sysctl -n key</code> prints the current value). This set
sizes network buffers for the AX201's Wi-Fi 6 speeds, loosens
shared-memory limits so browsers and GIMP can't hit ceilings, and keeps
interaction snappy. <span class="opt">When you adopt jails later
(Appendix D), forwarding and bridge-filtering knobs are waiting,
commented, at the bottom.</span></p>""")

STEP6 = cfg("doas.conf", '<span class="stepnum">Step&nbsp;6.</span> admin rights without root logins — doas.conf',
"""<p><strong>doas is how you'll exercise admin power</strong> — prefix a
command with <code>doas</code>, enter *your* password once per session,
and the command runs as root. This file authorizes the
<strong>wheel</strong> group. <u>Create no habit of staying root; doas is
audit-friendly: every use lands in auth.log</u> (Appendix E).</p>""")

STEP7 = cfg("pf.conf", '<span class="stepnum">Step&nbsp;7.</span> the firewall — pf.conf',
"""<p><strong>pf is a stateful firewall in the kernel</strong>; this ruleset
allows every outbound connection quietly, refuses and <em>logs</em>
inbound attempts, and — as comments, ready to uncomment — contains complete
<strong>jail networking scenarios</strong>: bridged onto LAN, hidden behind
NAT, jail-to-jail-DMZ, and VNET. <u>Study the numbered comments when you
build your first jail; the numbers in §10 are the debugging commands that
save you when a rule misfires.</u> <span class="opt">The default state is
already correct for a laptop: nothing to uncomment on day one.</span></p>""")

STEP8 = cfg("xorg.conf", '<span class="stepnum">Step&nbsp;8.</span> graphics recipe — xorg.conf',
"""<p><strong>Xorg autodetects this laptop's Iris Xe perfectly</strong> —
<span class="opt">this file is therefore optional, and disposable</span>.
It exists to pin the good behaviors in place: <strong>glamor
acceleration, DRI 3, TearFree</strong> for the desktop, DPMS timings for
blanking, and touchpad tap. <u>Keep it around for the day you want to
experiment (varying TearFree, or a VRR tweak) — then it's a one-line
edit.</u></p>""")

STEP9 = cfg("post-install.sh", '<span class="stepnum">Step&nbsp;9.</span> apply everything — post-install.sh',
"""<p><strong>One script applies Steps 3–8 to the live system safely</strong>:
it backs up every existing file to <code>/root/conf-backup-…</code>,
appends only the keys that are missing (your hand-edits are never
overwritten), <em>validates</em> the pf ruleset with
<code>pfctl&nbsp;-nf</code> and each sysctl against your running kernel
before writing it, and installs all driver/firmware packages the hardware
needs. Run it from the directory as root:</p>""")

STEP10 = step(10, "software for the desktop", """
<p>Drivers are on; a desktop is still an empty room. Install the programs
you listed — <strong>every one exists as a FreeBSD package</strong>:</p>
<pre><code>doas pkg install -y i3 chromium firefox gimp vlc keepassxc<br>
    leafpad vim tmux curl newsboat irssi calcurse git tig<br>
    libva-intel-media-driver libva-utils mesa-demos</code></pre>

<p><strong>Chromium's one FreeBSD quirk:</strong> it needs the
<strong>fdescfs</strong> pseudo-filesystem mounted at /dev/fd before it
will start — <u>this trips more first-time desktop installs than any other
single thing</u>:</p>
<pre><code>echo 'fdesc /dev/fd fdescfs rw 0 0' | doas tee -a /etc/fstab<br>
doas mount -t fdescfs fdesc /dev/fd</code></pre>

<p><strong>GPU decode for video</strong> (Iris Xe has excellent VP9/H.264
hardware decoding) needs the VA-API driver — already in the install line
above. <u>Verify it once and you'll never wonder why YouTube fans the CPU:</u></p>
<pre><code>vainfo | grep -E 'H264|HEVC|VP9'</code></pre>

<p><span class="opt">Add more from the package ocean at
freshports.org — thunderbird, htop, conky, dmenu, fonts; the Appendix A
list has the direct one-liners.</span> Reboot once more now, because the
firewall and power settings snap in fully active:</p>
<pre><code>ls /dev/dri &amp;&amp; kldstat | grep i915 &amp;&amp; pfctl -si</code></pre>
""")

# ======================================================================
# APPENDIX content — the .txt guides converted to HTML prose
# ======================================================================
APPX_A = f"""
<h2 id="extra-filesystems"><span class="stepnum">Appendix&nbsp;A.</span> disks, foreign filesystems &amp; image files</h2>
<p><strong>The base system already reads FAT, ISO9660 and UDF natively</strong>:</p>
<pre><code>doas mount -t msdosfs /dev/da0s1 /mnt<br>
mount_cd9660 -C UTF-8 /dev/cd0 /mnt</code></pre>
<p><strong>NTFS</strong> (Windows disks): the <strong>ntfs-3g</strong> driver
mounts read/write — install <code>pkg install fusefs-ntfs</code>, then
<code>ntfs-3g /dev/da0s1 /mnt/ntfs</code>. <u>Windows "Fast Startup" leaves
NTFS dirty and ntfs-3g will refuse to write; disable it in Windows or mount
read-only once.</u> <code>ntfsfix /dev/da0s1</code> clears most dirty bits.</p>
<p><strong>ext4</strong> (Linux disks): <strong>ext4fuse</strong> reads
extents, encryption and modern layouts — <code>pkg install
fusefs-ext4fuse</code>, then <code>ext4fuse /dev/ada1p2 /mnt/ext4 -o ro</code>
.<span class="opt">No stable read-write ext4 exists on FreeBSD; when you
need to write into a Linux disk, run Linux in a bhyve VM
(Appendix D) with the disk passed through.</span></p>
<p><strong>exFAT</strong> (big USB sticks, cameras): <code>pkg install
fusefs-exfat exfat-utils</code>; mount with <code>mount.exfat /dev/da0
/mnt</code>, create with <code>mkexfatfs /dev/da0</code>. <u>FAT32 stops at
4&nbsp;GB per file — any modern device wants exFAT.</u></p>
<p><strong>Disk images — the base system creates, mounts and converts
them with mdconfig, makefs, dd and truncate:</strong></p>
<pre><code>mdconfig -a -t vnode -f disk.img           # attach image as md0<br>
gpart create -s gpt md0 &amp;&amp; gpart add -t freebsd-ufs md0<br>
newfs /dev/md0p1 &amp;&amp; mount /dev/md0p1 /mnt   # use it, then:<br>
umount /mnt &amp;&amp; mdconfig -d -u md0           # detach (data persists)<br>
makefs -t cd9660 -o isolevel=3 mycd.iso ./dir/   # ISO from a directory<br>
truncate -s 20G sparse.img                       # instant sparse image</code></pre>
<p><strong>qemu-img</strong> (<code>pkg install qemu-img</code>) converts
between <strong>qcow2/vdi/vhd/raw</strong> virtual disk formats. <u>For
whole-disk bit backups, dd with bs=4M and status=progress — or, on a ZFS
root, prefer a zfs send snapshot (Appendix B): it's faster and
smaller.</u> <span class="opt">mtools (FAT image editors that never mount),
cdrtools (classic mkisofs), and e2fsprogs round out the imaging toolkit.</span></p>
"""

APPX_B = f"""
<h2 id="extra-zfs"><span class="stepnum">Appendix&nbsp;B.</span> living on ZFS — the must-dos and the joys</h2>
<p><strong>Three things capture most of ZFS-on-SSD value; do them once:</strong></p>
<p>1. <strong>TRIM</strong> keeps the SSD healthy and fast:
<code>zpool set autotrim=on zroot</code> (once), then schedule
<code>zpool trim zroot</code> monthly. <u>Check the pool never crosses
~80% full</u> (<code>zpool list</code>, CAP column) — SSDs slow
themselves by design when nearly full.</p>
<p>2. <strong>Compression</strong> is effectively free on this CPU and
usually <em>reduces</em> latency by writing fewer bytes:
<code>zfs set compression=lz4 zroot</code> or the stronger
<code>zstd-3</code>. <span class="opt">Existing data stays as it is; only
new writes compress — set it before bulk copying.</span></p>
<p>3. <strong>ARC cap</strong> — ZFS caches in RAM by default; on a
16 GB desktop cap it so browsers keep room:
<code>vfs.zfs.arc_max="8G"</code> in loader.conf, reboot. Watch hit rates
with <code>sysctl kstat.zfs.misc.arcstats.size</code>.</p>
<p><strong>What these enable next</strong> — features that feel like magic
the first time:</p>
<ul>
<li><strong>bectl boot environments</strong>: <code>bectl create
before-big-change</code>; if anything goes wrong, the exact prior system
boots again from the menu. <u>freebsd-update and major upgrades create
their own boot environments — list them with bectl list.</u></li>
<li><strong>Snapshots are instant and free</strong>: <code>zfs snapshot
zroot/usr/home@now</code>. <span class="opt">Every dataset hides a .zfs
directory where snapshots are browsable: copy acquisitions straight out of
the past without mounting anything.</span></li>
<li><strong>zfs diff</strong> shows precisely what changed between two
snapshots — <u>after a weird system change, it's the fastest truth
available</u>.</li>
<li><strong>Native encryption</strong> per dataset:
<code>zfs create -o encryption=on -o keyformat=passphrase zroot/private</code>
— this is the layer Appendix F builds on.</li>
<li><strong>zfs send/recv</strong> moves whole filesystem histories to a
USB pool or a second machine: <code>zfs send -R zroot/usr/home@snap | zfs
recv backup/home</code>. <span class="opt">sanoid (pkg) automates the
rotation; zpool checkpoint gives a one-shot pre-migration rollback
point.</span></li>
</ul>
<p><u>Monthly five-minute health ritual: zpool status -v, zpool list CAP,
zpool scrub, and smartctl -a on the NVMe for remaining SSD
life.</u> <span class="opt">arc_summary (in base) prints a full cache
report when you're curious.</span></p>
"""

APPX_C = f"""
<h2 id="extra-privacy"><span class="stepnum">Appendix&nbsp;C.</span> privacy — what phones home (spoiler: nothing)</h2>
<p><strong>FreeBSD's base system performs zero unsolicited reporting</strong>:
<strong>periodic</strong> digests go to root's local mail,
<strong>pkg</strong> only downloads, and it announces itself as nothing
more than <em>pkg/&lt;version&gt;</em> when it does;
<strong>freebsd-update</strong> only fetches patches when you run it.
<u>The honest leaks on a laptop are DNS queries, browser behavior, and
wireless identity — none of which FreeBSD imposes on you.</u></p>
<p><strong>DNS — the big one</strong>: your resolver sees every hostname
you visit. The strong fix is a local recursive resolver over encrypted
DNS:</p>
<pre><code>pkg install unbound<br>
# in /usr/local/etc/unbound/unbound.conf:<br>
server:<br>
&nbsp;&nbsp;tls-cert-bundle: /etc/ssl/certs<br>
forward-zone:<br>
&nbsp;&nbsp;name: "."<br>
&nbsp;&nbsp;forward-tls-upstream: yes<br>
&nbsp;&nbsp;forward-addr: 1.1.1.1@853#cloudflare-dns.com<br>
sysrc unbound_enable=YES &amp;&amp; service unbound start</code></pre>
<p>then point <code>/etc/resolv.conf</code> at 127.0.0.1 and —
<strong>pin it with pf</strong> so nothing leaks past your local resolver
(blocks plain DNS bypasses): see the pf.conf Step 7 rules for the two
<code>block drop out … port 53</code> lines to uncomment.
<span class="opt">Browsers can carry their own DoH: Firefox's
network.trr.mode=2, Chromium's "Use secure DNS" toggle.</span></p>
<p><strong>Wireless identity</strong>: FreeBSD doesn't rotate MACs
automatically, but you can pin a locally-administered
(<code>02:…</code>) address per network in rc.conf:
<code>create_args_wlan0="wlandev iwlwifi0 wlanaddr 02:11:22:33:44:55"</code> —
<u>the real hardware MAC then never leaves the network's imagination.</u></p>
<p><strong>Local-only visibility sysctls</strong> (already in Step 5's
sysctl.conf): <strong>see_other_uids=0</strong> and friends stop one user
from listing another's processes; <strong>tcp/udp blackhole</strong> makes
port scans see void. <span class="opt">rpcbind, NFS and sendmail submits
should stay off — the prepared rc.conf already has them that way.</span></p>
<p><strong>Browsers do the heavy lifting</strong>: Firefox's
<strong>privacy.resistFingerprinting</strong> plus
<strong>network.cookie.cookieBehavior&nbsp;5</strong> ranks among the
strongest defaults anywhere; <u>keep malware-safebrowsing enabled — hashed
URL checks are worth the check-in</u>. <span class="opt">Prefer Firefox
for unfamiliar sites; its per-site processes and sandboxing are the
strongest on FreeBSD.</span></p>
<p><strong>Jail isolation is not a privacy boundary</strong> when the
misconfigured jail is yours; it shares the host kernel. <u>For genuinely
untrusted binaries, boot a bhyve VM — a different kernel entirely.</u></p>
"""

APPX_D = f"""
<h2 id="extra-capabilities"><span class="stepnum">Appendix&nbsp;D.</span> what makes FreeBSD FreeBSD</h2>
<p><strong>The base system is one coherent whole</strong> — kernel, libc,
ssh, compiler — versioned together, patched atomically by
<strong>freebsd-update</strong> <em>with rollback</em>. <span class="opt">No
repo math when you patch; that's why old FreeBSD servers have quiet uptake
stories.</span></p>
<p><strong>ZFS</strong> — a filesystem with snapshotting, self-healing
checksums, native compression/encryption, and boot environments (Appendix B
is its whole story). <strong>Jails</strong> — the original containers, in
the base system: a real OS boot sharing your kernel, needing no daemon and
no layers; <em>you manage them with iocage or bastille (pkg)</em>; the pf
Step 7 scenarios were written for them. <strong>bhyve</strong> — the base
system's hypervisor for a fully separate kernel: <u>this is what you want
for reading/writing ext4 disks or running genuinely untrusted
software</u>. <strong>DTrace</strong> — production-safe introspection: it
answers "why is this slow?" in the running system, without stopping
anything. <strong>GELI</strong> — disk-key encryption integrated with UFS
and ZFS. <strong>Capsicum</strong> — capability-sandboxing, in which many
base tools (tcpdump for years) already run. <strong>GEOM</strong> — the
storage framework on which gmirror (RAID1) and gpart are built.</p>
<p><span class="opt">Whether this laptop should use RELEASE,
STABLE or —CURRENT: RELEASE (what you installed) is patched-only; STABLE
gets new features quarterly; CURRENT moves daily and breaks occasionally —
laptops live happily on RELEASE and only touch CURRENT for hardware so new
it lacks drivers.</span></p>
<p><u>When you're ready to build your own packages for other machines,
poudriere is the FreeBSD-native factory</u>: it compiles from a ports tree
into a signed repository your machines point at. The
<a class="external" href="https://www.freebsd.org/en/books/porters-handbook/">Porter's Handbook</a>
takes you further.</p>
<p><strong>Documentation culture</strong> is the reason this guide fits in
one page: the <a class="external" href="https://docs.freebsd.org/en/books/handbook/">Handbook</a>
details every step it summarizes, <a class="external" href="https://man.freebsd.org/">man pages</a>
explain every command, and the <a class="external" href="https://forums.freebsd.org/">forums</a>
are where decades of experience answer politely. <strong>apropos</strong>
finds commands you didn't know existed.</p>
"""

APPX_E = f"""
<h2 id="extra-security"><span class="stepnum">Appendix&nbsp;E.</span> root tooling, logs &amp; monitoring</h2>
<p><strong>Tools worth installing, all in packages:</strong></p>
<pre><code>pkg install pftop btop lnav fail2ban rkhunter lynis</code></pre>
<p><strong>pftop</strong> — a live window into the pf firewall:
<span class="opt"><code>pftop -v rules</code> shows per-rule hit
counters</span> — <u>when a service seems unreachable, this tells you which
rule said no.</u> <strong>btop</strong> — CPU/temps/network/battery in one
screen. <strong>lnav</strong> — reads and cross-highlights logs; runs
SQL over them. <strong>fail2ban</strong> — watches auth.log for
password-guessing, inserts <strong>pf bans</strong> automatically into its
anchors (verify with <code>pfctl -s Anchors</code>). <strong>rkhunter</strong>
— rootkit sanity scanner; <code>rkhunter --propupd</code> establishes the
baseline the day the system is fresh. <strong>lynis</strong> — point audit
producing a list of hardening test-IDs; <u>run it, fix the easy findings,
re-run until the score plateaus.</u></p>
<p><strong>Where logs live</strong>: <code>/var/log/messages</code> (the
main one), <code>/var/log/auth.log</code> (logins, doas, failed attempts),
<code>/var/log/pflog</code> (firewall drops, binary) — read live:
<code>tcpdump -n -e -ttt -i pflog0</code>. <span class="opt">periodic(8)
writes daily/weekly digests into that same local mail — <code>doas
mail</code> — and it never transmits them anywhere (Appendix C).</span></p>
<p><strong>Free ways to audit:</strong> <strong>accounting</strong>
(<code>sysrc accounting_enable=YES</code> → <code>lastcomm</code>),
<strong>listeners check</strong> after every upgrade (<code>sockstat -l4 -l6</code>),
<strong>integrity baseline</strong> with <strong>mtree</strong>:
<code>mtree -c -K sha256digest -p /etc &gt; /root/etc.mtree</code> and later
<code>mtree -f /root/etc.mtree -p /etc</code> — <u>it reports exactly which
config files differ and how.</u> <span class="opt">aide (pkg) scales this
to whole systems.</span></p>
"""

APPX_F = f"""
<h2 id="extra-lockdown"><span class="stepnum">Appendix&nbsp;F.</span> lock the system — no admin, no single-user tricks</h2>
<p><strong>The realistic threats</strong> on a laptop: someone at the
keyboard when you've stepped away, or someone rebooting hoping for the
classic <em>single-user root shell</em>. <span class="opt">Chip-off and
DMA attacks are hardware territory — for those the answers are BIOS
passwords and full-disk encryption, addressed below.</span></p>
<p><strong>First: close single-user mode.</strong> Boot menu →
<em>Boot Single User</em> normally hands out a root shell with no password.
Change one word in <strong>/etc/ttys</strong> — the console line's last
field from <code>secure</code> to <code>insecure</code> — and single-user
now requires the root password. Apply live: <code>kill -HUP 1</code>.
<u>Test by rebooting; "Give root password" must appear.</u></p>
<p><strong>Then: password the bootloader.</strong> In loader.conf:
<code>password="MyLoaderPass"</code> — the menu (and with it
<code>boot&nbsp;-s</code>) is unreachable without it, while normal boots
proceed untouched. <span class="opt">The stronger
<code>bootlock_password</code> locks <em>every</em> boot including
unattended restarts — only sensible for servers.</span></p>
<p><strong>Then: make the config files immutable.</strong>
<strong>chflags schg</strong> sets the "cannot be changed, even by root"
flag:</p>
<pre><code>chflags schg /boot/loader.conf /etc/ttys /etc/rc.conf /etc/pf.conf<br>
# verify: ls -lo (flags column);  undo when needed: chflags noschg …</code></pre>
<p><strong>And seal the deal with securelevel</strong> — a kernel-wide
switch rc.conf raises at boot (<code>kern_securelevel_enable="YES"</code>,
<code>kern_securelevel="1"</code>): at level&nbsp;1, immutable flags cannot
be cleared even by root, raw disks stay write-protected, pf rules only get
stricter. <u>Enable it only after everything else works — level 1 stops
X11's hardware access path too, so test display with it ON before making
it permanent.</u> <span class="opt">Level 2 adds /dev/mem locking and
rw-mount restrictions — the headless-server setting.</span></p>
<p><strong>The outer wall: full-disk encryption</strong>, chosen back in
Step 2. <u>The passphrase is asked before any kernel loads — a USB mini-OS
boot sees only noise; the portable disk can't be read even in another
machine.</u> <span class="opt">Store the passphrase somewhere safe: an
encrypted laptop with a lost passphrase is a paperweight.</span></p>
<p><strong>The daily layer</strong>: screen-lock everywhere —
<code>i3lock</code> for i3, <code>physlock</code> (pkg) for all virtual
consoles at once. <strong>BIOS/UEFI</strong>: supervisor password +
disable USB boot = <u>the three clicks that defeat the boot-from-stick
class entirely.</u></p>
<p><strong>Proof of work — test each lock:</strong></p>
<ul>
<li>reboot → boot menu → Single User → <strong>demands root password</strong></li>
<li>as root: <code>chflags noschg /etc/rc.conf</code> → <strong>fails</strong> (securelevel 1)</li>
<li>Your user runs <code>doas chflags noschg /etc/ttys</code> → <strong>works</strong> (you're the admin)</li>
<li><code>grep -c authentication /var/log/auth.log</code> — a number you now know grows by 1 per admin act</li>
</ul>
"""

FINISH = f"""
<h2 id="finish"><span class="stepnum">Finish.</span> proof-of-work checklist</h2>
<table class="finish">
<tr><th>✓</th><th>You know it worked because…</th></tr>
<tr><td>☐</td><td><code>cmp</code> was silent — the stick was good (Step 1)</td></tr>
<tr><td>☐</td><td><code>zfs get encryption zroot</code> answers; boot asks the passphrase (Step 2)</td></tr>
<tr><td>☐</td><td>rc.conf lines live: <code>kldstat | grep i915</code>, <code>ifconfig wlan0</code> up (Step 3)</td></tr>
<tr><td>☐</td><td><code>pfctl -si</code> prints <em>Status: Enabled</em> (Step 7)</td></tr>
<tr><td>☐</td><td>post-install.sh reported zero failures (Step 9)</td></tr>
<tr><td>☐</td><td>chromium starts; <code>ls /dev/fd</code> lists entries (Step 10)</td></tr>
<tr><td>☐</td><td><code>vainfo</code> lists H264/HEVC/VP9 profiles (Step 10)</td></tr>
<tr><td>☐</td><td><code>zpool get autotrim zroot</code> → <em>on</em>; ARC capped (Appendix B)</td></tr>
<tr><td>☐</td><td>Single-user mode asks the root password (Appendix F)</td></tr>
<tr><td>☐</td><td><code>chflags noschg</code> fails at securelevel 1 (Appendix F)</td></tr>
</table>
<div class="ok"><strong>The laptop is yours — installed, tuned, defended,
and locked.</strong> <u>Read <code>/var/log/periodic.weekly</code> on
Mondays</u>; <span class="opt">the appendices above are the same guides
that live in the files of this directory, kept for your terminal-side
reading.</span></div>
</body>
</html>
"""

NAV_INTOC = TOC.replace('<a href="#intro">', '<a href="#intro">')  # unchanged

# Assemble
HTML = (HEAD + TOC + INTRO + STEP1 + STEP2 + STEP3 + STEP4 + STEP5
        + STEP6 + STEP7 + STEP8 + STEP9 + STEP10
        + APPX_A + APPX_B + APPX_C + APPX_D + APPX_E + APPX_F
        + FINISH)

(ROOT / "INSTALL-GUIDE.html").write_text(HTML)
print(f"written: {len(HTML):,} bytes, {len(HTML.splitlines()):,} lines")

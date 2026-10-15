#!/usr/bin/env python3
"""Build one self-contained HTML file from this repository's docs and configuration artefacts.

Usage:  python3 tools/build-docs-html.py [-o hardened-debian-apache.html]

Why a generator instead of a hand-written page: a browser refuses to fetch local files from a
file:// document, so a "single HTML file" must EMBED the markdown and the configuration text.
Hand-maintaining 12 documents plus 70 artefacts inside one page is not possible; generating it
means the page can never drift from the repository.

The build fails loudly (exit 1) if a document's fence or table counts do not survive conversion,
if an artefact is missing, or if an annotation regex fails to compile - a documentation build that
silently degrades is worse than no build.
"""

from __future__ import annotations

import argparse
import fnmatch
import html
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import annotations as ann          # noqa: E402
import md2html                     # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = os.path.join(ROOT, "files")
DOCS = os.path.join(ROOT, "docs")

# ---------------------------------------------------------------------------
# Page order and titles. README first, then the numbered chapters.
# ---------------------------------------------------------------------------
PAGES = [
    ("README", "Overview &amp; threat model", "README.md"),
    ("00-hardware-profile", "00 · Hardware profile", "docs/00-hardware-profile.md"),
    ("01-threat-model", "01 · Threat model", "docs/01-threat-model.md"),
    ("02-debian-install", "02 · Debian install", "docs/02-debian-install.md"),
    ("03-boot-integrity", "03 · Boot integrity", "docs/03-boot-integrity.md"),
    ("04-base-hardening", "04 · Base hardening", "docs/04-base-hardening.md"),
    ("05-network-and-firewall", "05 · Network &amp; firewall", "docs/05-network-and-firewall.md"),
    ("06-apache-hardening", "06 · Apache hardening", "docs/06-apache-hardening.md"),
    ("07-physical-and-firmware", "07 · Physical / firmware", "docs/07-physical-and-firmware.md"),
    ("08-isolation-and-virtualization", "08 · Isolation / VM", "docs/08-isolation-and-virtualization.md"),
    ("09-software-policy", "09 · Software policy", "docs/09-software-policy.md"),
    ("10-audit-and-maintenance", "10 · Audit &amp; maintenance", "docs/10-audit-and-maintenance.md"),
    ("11-incident-response", "11 · Incident response", "docs/11-incident-response.md"),
]

# Which artefacts belong to which chapter (fnmatch patterns, ``files/`` relative).
DOC_FILES = {
    "00-hardware-profile": ["etc/modprobe.d/*", "etc/modules-load.d/*"],
    "02-debian-install": [],
    "03-boot-integrity": ["etc/kernel/*", "etc/kernel/postinst.d/*", "etc/default/grub",
                          "etc/crypttab.example", "keys/README.md"],
    "04-base-hardening": ["etc/sysctl.d/*", "etc/security/*", "etc/security/*/*", "etc/sudoers.d/*",
                          "etc/profile.d/*", "etc/ssh/sshd_config.d/*", "etc/fstab", "etc/apt/*/*",
                          "etc/aide/*/*", "etc/apparmor.d/*", "etc/apparmor.d/*/*", "etc/audit/*",
                          "etc/audit/*/*", "etc/pam.d/*", "etc/systemd/journald.conf.d/*",
                          "etc/systemd/coredump.conf.d/*", "etc/systemd/system.conf.d/*"],
    "05-network-and-firewall": ["etc/nftables.conf", "etc/nftables.d/*", "etc/unbound/*/*",
                                "etc/chrony/*", "etc/wireguard/*"],
    "06-apache-hardening": ["etc/apache2/apache2.conf", "etc/apache2/ports.conf",
                            "etc/apache2/conf-available/*", "etc/apache2/mods-available/*",
                            "etc/apache2/sites-available/*", "etc/modsecurity/*", "etc/modsecurity/*/*",
                            "etc/logrotate.d/*", "etc/systemd/system/apache2.service.d/*"],
    "07-physical-and-firmware": ["etc/usbguard/*"],
    "08-isolation-and-virtualization": ["etc/systemd/nspawn/*", "etc/containers/*",
                                        "etc/apache2/instances/*", "etc/systemd/system/apache2@.service"],
    "09-software-policy": ["etc/paranoid/README.md"],
    "10-audit-and-maintenance": ["etc/systemd/system/*.timer", "usr/local/sbin/*",
                                 "etc/systemd/system/paranoid-*"],
    "11-incident-response": [],
    "README": ["etc/nftables.conf", "etc/paranoid/README.md", "usr/local/sbin/*"],
}
DOC_FILES["04-base-hardening"] += ["etc/kernel/cmdline"]
DOC_FILES["10-audit-and-maintenance"] += ["etc/systemd/system/aide-check.service",
                                          "etc/systemd/system/aide-check.timer",
                                          "etc/systemd/system/debsums-check.service",
                                          "etc/systemd/system/debsums-check.timer",
                                          "etc/systemd/system/kernel-modules-lock.service",
                                          "etc/systemd/system/remount-boot-ro.service",
                                          "etc/systemd/system/paranoid-boot-record.service",
                                          "etc/systemd/system/paranoid-cert-check.service",
                                          "etc/systemd/system/paranoid-cert-check.timer",
                                          "etc/systemd/system/paranoid-backup.service",
                                          "etc/systemd/system/paranoid-backup.timer"]

# Case-insensitive lookup table so a link like files/etc/sysctl.d/99-paranoid.conf resolves even if
# a document spells a path slightly differently.
COMMENT_PREFIX = {"//": ["etc/apt/"], ";": [], "#": []}


def rel_files() -> list[str]:
    out = []
    for base, _dirs, names in os.walk(FILES):
        for name in names:
            full = os.path.join(base, name)
            out.append(os.path.relpath(full, FILES).replace(os.sep, "/"))
    return sorted(out)


def comment_prefix(path: str) -> str:
    if path.startswith("etc/apt/"):
        return "//"
    if path.endswith("ima-policy") or path.endswith("kernel/cmdline"):
        return "\x00"      # no comments in these files: every line is effective
    return "#"


def annotate(path: str, content: str) -> tuple[str, list[dict]]:
    """Return (rendered_lines_payload, annotations). Only effective (non-comment) lines annotate."""
    rules = ann.rules_for(path)
    compiled = []
    for pattern, why in rules:
        try:
            compiled.append((re.compile(pattern), why))
        except re.error as exc:                              # pragma: no cover
            raise SystemExit("bad annotation regex %r in %s: %s" % (pattern, path, exc))
    prefix = comment_prefix(path)
    lines = content.split("\n")
    notes = []
    for idx, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or (prefix != "\x00" and stripped.startswith(prefix)):
            continue
        for rx, why in compiled:
            if rx.search(line):
                notes.append({"n": idx, "why": why})
                break
    return content, notes


def build_artifact_index(artefacts: dict) -> list[dict]:
    """Group artefacts by their top-level area for the appendix page."""
    groups: dict[str, list[str]] = {}
    for path in artefacts:
        parts = path.split("/")
        if path.startswith("etc/apache2") or path.startswith("etc/modsecurity"):
            key = "Apache + WAF (docs/06)"
        elif path.startswith("etc/systemd"):
            key = "systemd units, timers and drop-ins"
        elif path.startswith("etc/audit"):
            key = "auditd (docs/04, docs/10)"
        elif path.startswith("etc/sysctl.d") or path.startswith("etc/modprobe.d") or path.startswith("etc/modules-load.d"):
            key = "Kernel: parameters, modules, boot cmdline (docs/00, docs/03, docs/04)"
        elif path.startswith("etc/security") or path.startswith("etc/pam.d") or path.startswith("etc/sudoers.d"):
            key = "Accounts, PAM, sudo (docs/04)"
        elif path.startswith("etc/nftables") or path.startswith("etc/unbound") or path.startswith("etc/chrony") or path.startswith("etc/wireguard"):
            key = "Network, DNS, time, admin tunnel (docs/05)"
        elif path.startswith("etc/apt"):
            key = "Packages and updates (docs/04, docs/09)"
        elif path.startswith("etc/apparmor"):
            key = "AppArmor (docs/04, docs/06)"
        elif path.startswith("etc/usbguard"):
            key = "USB policy (docs/07)"
        elif path.startswith("etc/containers") or path.startswith("etc/systemd/nspawn"):
            key = "Container isolation (docs/08)"
        elif path.startswith("etc/kernel") or path.startswith("etc/default/grub") or path.startswith("etc/crypttab"):
            key = "Boot chain and encryption (docs/03)"
        elif path.startswith("etc/aide"):
            key = "File integrity (docs/04, docs/10)"
        elif path.startswith("usr/local/sbin"):
            key = "Helper scripts run by systemd units"
        elif path.startswith("etc/paranoid") or path.startswith("keys"):
            key = "Policy state and key handling (docs/03, docs/09)"
        elif path.startswith("etc/logrotate.d"):
            key = "Log rotation (docs/10)"
        else:
            key = "Other (" + parts[0] + ")"
        groups.setdefault(key, []).append(path)
    order = [
        "Kernel: parameters, modules, boot cmdline (docs/00, docs/03, docs/04)",
        "Boot chain and encryption (docs/03)",
        "Network, DNS, time, admin tunnel (docs/05)",
        "Accounts, PAM, sudo (docs/04)",
        "AppArmor (docs/04, docs/06)",
        "auditd (docs/04, docs/10)",
        "File integrity (docs/04, docs/10)",
        "Packages and updates (docs/04, docs/09)",
        "Apache + WAF (docs/06)",
        "USB policy (docs/07)",
        "Container isolation (docs/08)",
        "systemd units, timers and drop-ins",
        "Helper scripts run by systemd units",
        "Log rotation (docs/10)",
        "Policy state and key handling (docs/03, docs/09)",
        "Other (etc)",
    ]
    rest = [k for k in groups if k not in order]
    return [{"title": k, "files": sorted(groups[k])} for k in order + rest if k in groups]


CONTROL_MATRIX = [
    ("T1 Offline disk theft", "LUKS2 + Argon2id, no TPM unlock, optional detached header",
     "etc/crypttab.example, etc/kernel/cmdline, etc/default/grub",
     "cryptsetup luksDump /dev/nvme0n1p3"),
    ("T2 Bootkit / evil maid", "Secure Boot with your own keys, signed UKI, kernel lockdown=confidentiality",
     "etc/kernel/install.conf, etc/kernel/postinst.d/zz-sign-uki, etc/default/grub",
     "bootctl status; sbctl verify; cat /sys/kernel/security/lockdown"),
    ("T3 Remote compromise of the service", "TLS 1.3 only, module pruning, mod_security3+CRS, rate limits, no port 80",
     "etc/apache2/**, etc/modsecurity/**, etc/nftables.conf",
     "apache2ctl configtest; sslscan <host>:443"),
    ("T4 Compromise of the host from the service", "systemd sandbox, AppArmor, per-instance users, no shell/interpreters",
     "etc/systemd/system/apache2.service.d/99-paranoid.conf, etc/apparmor.d/local/usr.sbin.apache2",
     "systemd-analyze security apache2; aa-status"),
    ("T5 Malicious PCIe / Thunderbolt device", "Kernel DMA Protection + TB User Authorization, iommu.strict=1, dGPU removed",
     "etc/kernel/cmdline, etc/modprobe.d/90-blacklist-paranoid.conf",
     "dmesg | grep -i DMAR; cat /proc/cmdline"),
    ("T6 Malicious USB device", "USBGuard deny-by-default, USB storage blacklisted (Tier 3), no automount",
     "etc/usbguard/**, etc/modprobe.d/90-blacklist-paranoid.conf",
     "usbguard list-devices; journalctl -t usbguard"),
    ("T7 Firmware / Management Engine persistence", "BIOS password + firmware lock, fwupd updates, MEI driver disabled, microcode current",
     "etc/modprobe.d/90-blacklist-paranoid.conf, docs/00 §4",
     "lsmod | grep mei; grep microcode /proc/cpuinfo"),
    ("T8 Supply chain / driver abuse", "module.sig_enforce, main+non-free-firmware only, apt signature + Valid-Until, AIDE + debsums",
     "etc/apt/apt.conf.d/99-paranoid, etc/aide/aide.conf.d/99_paranoid.conf",
     "apt-config dump; debsums -s; aide --check"),
    ("T9 Privilege escalation on the host", "noexec/nosuid/nodev mounts, sysctl hardening, auditd primitives, sudo lockdown",
     "etc/fstab, etc/sysctl.d/99-paranoid.conf, etc/audit/rules.d/99-paranoid.rules",
     "findmnt -o TARGET,OPTIONS; auditctl -s"),
    ("T10 Data exfiltration by a compromised service", "Egress allowlist in nftables, local resolver, per-vhost isolation",
     "etc/nftables.conf, etc/unbound/unbound.conf.d/paranoid.conf",
     "nft list chain inet filter output"),
    ("T11 Third-party software demanding host privileges", "Install-on-demand policy, rootless containers, rootless VMs",
     "docs/08, docs/09, etc/containers/containers.conf, etc/systemd/nspawn/app01.nspawn",
     "bash scripts/verify-hardening.sh --section isolation"),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--output", default=os.path.join(ROOT, "hardened-debian-apache.html"))
    args = ap.parse_args()

    artefact_paths = rel_files()
    if not artefact_paths:
        print("no artefacts found under files/", file=sys.stderr)
        return 1

    artefacts: dict[str, dict] = {}
    for path in artefact_paths:
        with open(os.path.join(FILES, path), "r", encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
        if not raw.strip():
            continue
        # Markdown artefacts are documentation, not configuration: annotating their prose would be
        # noise, and the page already states their purpose. The ~70 configuration files are the
        # ones getting per-option annotations.
        if path.endswith(".md"):
            notes = []
        else:
            _, notes = annotate(path, raw)
        artefacts[path] = {
            "path": path,
            "content": raw,
            "lines": raw.count("\n") + 1,
            "purpose": ann.PURPOSE.get(path, ""),
            "notes": notes,
            "annPrefix": comment_prefix(path),
            "isDoc": path.endswith(".md"),
        }

    by_lower = {p.lower(): p for p in artefacts}

    page_by_base = {os.path.basename(rel).lower(): slug for slug, _t, rel in PAGES}

    def link_resolver(page_slug: str):
        def resolve(href: str):
            if href.startswith(("http://", "https://", "mailto:", "#")):
                return href
            target = href.split("#", 1)[0]
            if not target:
                return href
            if target.endswith(".md"):
                base = os.path.basename(target).lower()
                if base in page_by_base:
                    return "#/page/" + page_by_base[base]
            for probe in (target, target.lstrip("/"), target[2:] if target.startswith("./") else target):
                key = probe.lstrip("/").lower()
                if key.startswith("files/"):
                    key = key[len("files/"):]
                if key in by_lower:
                    return "#/file/" + by_lower[key]
            # Local path that this single-file build cannot contain (scripts/, preseed/, the PCI
            # dump, keys/): mark it resolvable-as-text rather than leaving a broken link.
            return None
        return resolve

    # Doc prose refers to artefacts as inline code far more often than as Markdown links, so the
    # rendered HTML is post-processed to turn known paths inside <code> spans into viewer links.
    pre_re = re.compile(r'<pre class="code".*?</pre>', re.S)
    code_re = re.compile(r"<code>([^<]+)</code>")

    def autolink(body: str) -> str:
        stash: list[str] = []

        def hold(m):
            stash.append(m.group(0))
            return "\x01%d\x01" % (len(stash) - 1)

        body = pre_re.sub(hold, body)

        def repl(m):
            text = m.group(1).strip()
            probe = text.lstrip("/")
            if probe.startswith("files/"):
                probe = probe[len("files/"):]
            key = probe.lower()
            if key in by_lower:
                return '<a href="#/file/%s"><code>%s</code></a>' % (by_lower[key], m.group(1))
            if text.endswith(".md"):
                base = os.path.basename(text).lower()
                if base in page_by_base:
                    return '<a href="#/page/%s"><code>%s</code></a>' % (page_by_base[base], m.group(1))
            return m.group(0)

        body = code_re.sub(repl, body)
        return re.sub(r"\x01(\d+)\x01", lambda m: stash[int(m.group(1))], body)

    pages = []
    total_fences = total_tables = 0
    for slug, title, rel in PAGES:
        full = os.path.join(ROOT, rel)
        if not os.path.isfile(full):
            print("missing document: %s" % rel, file=sys.stderr)
            return 1
        with open(full, "r", encoding="utf-8") as fh:
            md = fh.read()

        heading_ids: list[tuple[int, str, str]] = []
        body = autolink(md2html.to_html(md, link_resolver(slug), heading_ids))

        # Structural self-check: conversions must not silently swallow content.
        want_fences, want_tables = md2html.count_fences(md), md2html.count_tables(md)
        got_fences = body.count('<pre class="code')
        got_tables = body.count("<table>")
        total_fences += want_fences
        total_tables += want_tables
        if want_fences != got_fences or want_tables != got_tables:
            print("structural mismatch in %s: fences %d/%d, tables %d/%d"
                  % (rel, got_fences, want_fences, got_tables, want_tables), file=sys.stderr)
            return 1

        page_files = []
        for pattern in DOC_FILES.get(slug, []):
            for path in artefacts:
                if fnmatch.fnmatch(path, pattern) and path not in page_files:
                    page_files.append(path)

        pages.append({
            "slug": slug, "title": title, "html": body, "files": page_files,
            "toc": [{"lvl": lvl, "id": hid, "text": txt} for lvl, hid, txt in heading_ids],
            "fences": want_fences, "tables": want_tables,
        })

    payload = {
        "pages": pages,
        "artefacts": artefacts,
        "appendix": build_artifact_index(artefacts),
        "controls": CONTROL_MATRIX,
        "generated": "generated from README.md, docs/*.md and files/**",
    }

    blob = json.dumps(payload, ensure_ascii=False)
    # Safety: a literal "</script" or "<!--" inside embedded JSON would break out of the tag.
    blob = blob.replace("</", "<\\/").replace("<!--", "<\\!--")

    shell = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shell.html")
    with open(shell, "r", encoding="utf-8") as fh:
        template = fh.read()

    doc_count = len(pages)
    file_count = len(artefacts)
    line_count = sum(a["lines"] for a in artefacts.values()) + sum(
        len(p["html"].split("\n")) for p in pages)
    out = (template
           .replace("/*__PAYLOAD__*/", blob)
           .replace("__DOC_COUNT__", str(doc_count))
           .replace("__FILE_COUNT__", str(file_count))
           .replace("__LINE_COUNT__", "{:,}".format(line_count))
           .replace("__ANN_COUNT__", "{:,}".format(sum(len(a["notes"]) for a in artefacts.values())))
           .replace("__GEN__", __import__("datetime").date.today().isoformat()))

    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write(out)

    size = os.path.getsize(args.output)
    print("wrote %s" % os.path.relpath(args.output, ROOT))
    print("  documents embedded : %d (%d code fences, %d tables)"
          % (doc_count, total_fences, total_tables))
    print("  artefacts embedded : %d files, %d lines"
          % (file_count, sum(a["lines"] for a in artefacts.values())))
    print("  annotations        : %d"
          % sum(len(a["notes"]) for a in artefacts.values()))
    print("  size               : %.0f KiB" % (size / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())

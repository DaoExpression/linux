#!/bin/ksh
#
#	lint-config.sh - offline checks on this configuration tree
#
#	Runs anywhere (only awk, grep and a POSIX shell are needed), which is the
#	point: the real validators - pfctl -nf, httpd -n, smtpd -n,
#	unbound-checkconf, nsd-checkconf - only exist on an OpenBSD host.  This
#	script catches, before anything is copied anywhere, the class of mistakes
#	those tools would have caught for you.
#
#	It checks:
#	  1. every $macro referenced in a pf.conf is defined in that same file
#	  2. braces balance in the block-based configs
#	  3. zone files and table files referenced by configs exist in the tree
#	  4. no un-filled placeholder markers (REPLACE-ME is reported, not fatal)
#	  5. vmd switches and their veb interfaces line up with hostname.*, and
#	     every guest known to provision-vm.sh has a tree here
#
#	usage: scripts/lint-config.sh [-v]
#
#	exit status: 0 clean, 1 findings, 2 cannot run

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 2
[ -d "$ROOT/host/etc" ] || { echo "lint: no host/etc under $ROOT" >&2; exit 2; }

# Findings are accumulated in a file rather than in shell variables: every
# check below feeds a pipeline, and a pipeline runs in a subshell, so a counter
# incremented inside one would be lost.  (Doing it the other way is how a
# linter ends up always printing "clean".)
FINDINGS=$(mktemp "${TMPDIR:-/tmp}/lint.XXXXXX") || exit 2
trap 'rm -f "$FINDINGS"' EXIT INT TERM

err()  { echo "ERROR|$*" >> "$FINDINGS"; }
warn() { echo "WARN|$*" >> "$FINDINGS"; }
note() { [ "${VERBOSE:-no}" = yes ] && echo "  $*"; return 0; }

VERBOSE=no
[ "${1:-}" = "-v" ] && VERBOSE=yes

section() { echo; echo "== $*"; }

# ------------------------------------------------------------------ 1. pf macros
section "pf(4) macro references"

# Fragments (the examples/ directory) are not complete rulesets: they are
# drafts to paste into pf.conf, so their macros are defined by the file they
# will be pasted into.  Skipping them avoids reporting their macros as
# undefined.
find "$ROOT" \( -name 'pf.conf' -o -name 'pf.conf.example-*' \) -type f |
	grep -v '/examples/' | sort |
while IFS= read -r f; do
	rel=${f#"$ROOT"/}

	# Definitions look like "name = value" or "name=value" at the start of a
	# line.  The value itself may contain =, so only the first field matters.
	defs=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)[ \t]*=.*/\1/p' "$f")

	# References are $name in code, not in comments: a quoted example inside a
	# comment ("pass in ... from $guest_net") is documentation, and treating it
	# as a real reference produces a finding that cannot be fixed.
	refs=$(sed 's/#.*//' "$f" | grep -o '\$[A-Za-z_][A-Za-z0-9_]*' |
		sed 's/^\$//' | sort -u)

	for r in $refs; do
		if ! printf '%s\n' "$defs" | grep -qx "$r"; then
			echo "ERROR|$rel: undefined macro \$$r" >> "$FINDINGS"
		fi
	done
done
note "checked every pf.conf in the tree"

# ------------------------------------------------------------------ 2. braces
section "brace balance"

for f in \
	host/etc/vm.conf \
	host/etc/httpd.conf \
	host/etc/relayd.conf \
	vms/dns/etc/unbound.conf \
	vms/mail/etc/dovecot/dovecot.conf \
	vms/mon/etc/collectd.conf \
	vms/web/etc/httpd.conf \
	vms/web/etc/examples/nginx.conf
do
	[ -f "$ROOT/$f" ] || continue
	# Strip comments and quoted strings, then sum the brace difference.
	diff=$(awk '
		{ line = $0
		  sub(/#.*/, "", line)
		  gsub(/"[^"]*"/, "", line)
		  o += gsub(/{/, "", line)
		  o -= gsub(/}/, "", line)
		}
		END { print o }
	' "$ROOT/$f")
	if [ "$diff" != "0" ]; then
		echo "ERROR|$f: braces do not balance (off by $diff)" >> "$FINDINGS"
	fi
done
note "checked the block-based config files"

# ------------------------------------------------------------------ 3. references
section "referenced files exist"

# nsd zone files, relative to the daemon's zonesdir (/var/nsd/zones).
if [ -f "$ROOT/host/etc/nsd.conf" ]; then
	grep -o 'zonefile: *"[^"]*"' "$ROOT/host/etc/nsd.conf" |
		sed 's/.*"\(.*\)"/\1/' | while IFS= read -r z; do
		[ -f "$ROOT/host/var/nsd/zones/$z" ] ||
			echo "ERROR|host/etc/nsd.conf references zonefile $z, not present in host/var/nsd/zones/" >> "$FINDINGS"
	done
fi

# Table files (smtpd "table x file:/path") - the path is absolute on the
# deployed host, so any leading directory is stripped and matched inside the
# tree that owns the config.
for cfg in host/etc/smtpd.conf vms/mail/etc/smtpd.conf; do
	[ -f "$ROOT/$cfg" ] || continue
	# The path in the config is absolute on the deployed host (/etc/mail/aliases),
	# so strip the leading slash and match it inside the tree that owns the
	# config (host/ or vms/<name>/).
	base=${cfg%/etc/*}
	grep -o 'file:[^ "]*' "$ROOT/$cfg" | sed 's/^file://' | while IFS= read -r t; do
		rel=${t#/}
		if [ ! -e "$ROOT/$base/$rel" ]; then
			# A warning, not an error: some tables are legitimately created on
			# the host rather than committed (credentials with password
			# hashes, most obviously).
			echo "WARN|$cfg references table file $t (expected at $base/$rel)" >> "$FINDINGS"
		fi
	done
done

# Every guest with an autoinstall file must also have a config tree.
for f in "$ROOT"/vms/*/install.conf; do
	[ -e "$f" ] || continue
	g=${f#"$ROOT"/vms/}; g=${g%/install.conf}
	[ -d "$ROOT/vms/$g/etc" ] ||
		echo "ERROR|vms/$g has install.conf but no etc/ tree" >> "$FINDINGS"
done

# Every guest provision-vm.sh knows about must exist, and vice versa.
if [ -f "$ROOT/scripts/provision-vm.sh" ]; then
	for g in bastion dns db storage mon web mail; do
		[ -d "$ROOT/vms/$g" ] || echo "ERROR|vms/$g is missing" >> "$FINDINGS"
	done
fi

# ------------------------------------------------------------------ 4. placeholders
section "placeholders and markers"

placeholders=$(grep -rIl 'REPLACE-ME' "$ROOT" 2>/dev/null | wc -l | tr -d ' ')
echo "  $placeholders file(s) still contain REPLACE-ME placeholders (expected before deployment)"

# NOTE: a bare "XXX" is not in this list on purpose — mktemp(1) templates are
# made of X's ("pfban.XXXXXX"), and matching those produces a finding that no
# edit can fix.  The markers below are unambiguous.
for marker in 'REPLACE_ME' 'FIXME' '<<<<<<<' '>>>>>>>'; do
	grep -rIn -w -- "$marker" "$ROOT" 2>/dev/null |
		grep -v '/\.git/' | grep -v 'lint-config.sh' |
		while IFS= read -r hit; do
			echo "ERROR|leftover marker: ${hit#"$ROOT"/}" >> "$FINDINGS"
		done
done

# ------------------------------------------------------------------ 5. names
section "interface, switch and guest names"

if [ -f "$ROOT/host/etc/vm.conf" ]; then
	# Each switch block names a veb interface that must be configured.
	grep -o 'interface *veb[0-9]*' "$ROOT/host/etc/vm.conf" | awk '{print $2}' | sort -u |
		while IFS= read -r i; do
			[ -f "$ROOT/host/etc/hostname.$i" ] ||
				echo "ERROR|host/etc/vm.conf uses $i but host/etc/hostname.$i is missing" >> "$FINDINGS"
		done

	# Each switch referenced by a VM must be declared.
	declared=$(awk '/^switch/{gsub(/[^A-Za-z0-9_-]/, "", $2); print $2}' "$ROOT/host/etc/vm.conf")
	awk '{
		while (match($0, /switch "[^"]*"/)) {
			s = substr($0, RSTART + 8, RLENGTH - 9)
			print s
			$0 = substr($0, RSTART + RLENGTH)
		}
	}' "$ROOT/host/etc/vm.conf" | sort -u | while IFS= read -r s; do
		printf '%s\n' "$declared" | grep -qx "$s" ||
			echo "ERROR|host/etc/vm.conf refers to switch \"$s\", which is never declared" >> "$FINDINGS"
	done
fi

# Every interface with a hostname.* file must be referenced somewhere, and
# every interface referenced in pf.conf must have one.
if [ -f "$ROOT/host/etc/pf.conf" ]; then
	for f in "$ROOT"/host/etc/hostname.*; do
		[ -e "$f" ] || continue
		i=${f##*/hostname.}
		# An interface is accounted for if pf.conf names it or if another
		# hostname.* file references it (vlan40 is a member of veb0, for
		# instance, and carries no address of its own).
		if ! grep -q "\"$i\"" "$ROOT/host/etc/pf.conf" &&
		   ! grep -lq "[ \t]$i\$" "$ROOT"/host/etc/hostname.* 2>/dev/null; then
			echo "WARN|host/etc/hostname.$i is not referenced by pf.conf or another interface file" >> "$FINDINGS"
		fi
	done
fi

# ------------------------------------------------------------------ 6. shell syntax
section "shell syntax"

# Every script that gets deployed, plus rc.local.  sh -n is a parse only: it is
# the cheapest way to catch the class of bug that bash tolerates and ksh does
# not (unquoted case patterns with spaces, brace groups missing their
# terminating ";").
for s in "$ROOT"/scripts/* "$ROOT"/host/etc/rc.local "$ROOT"/vms/*/etc/rc.local; do
	[ -f "$s" ] || continue
	sh -n "$s" 2>/dev/null ||
		echo "ERROR|${s#"$ROOT"/}: shell syntax error (sh -n)" >> "$FINDINGS"
done
note "parsed every script and rc.local"

# ------------------------------------------------------------------ summary
# Findings are printed here rather than as they are found, so that the output
# reads as "these sections passed, these did not" instead of being interleaved
# with progress lines.
errors=0
warnings=0
echo
[ -s "$FINDINGS" ] && echo "== findings"
if [ -s "$FINDINGS" ]; then
	while IFS='|' read -r kind rest; do
		case "$kind" in
		ERROR) errors=$((errors + 1)); echo "ERROR: $rest" ;;
		WARN)  warnings=$((warnings + 1)); echo "WARN:  $rest" ;;
		esac
	done < "$FINDINGS"
fi

echo
if [ "$errors" -gt 0 ]; then
	echo "lint: $errors error(s), $warnings warning(s)"
	exit 1
fi
echo "lint: clean ($warnings warning(s))"
exit 0

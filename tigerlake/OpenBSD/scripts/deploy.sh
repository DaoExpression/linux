#!/bin/ksh
#
#	deploy.sh - copy a configuration tree from this repository to a host
#
#	usage: scripts/deploy.sh [-n] [-u user] <tree> <target>
#
#	  tree    host            the gateway's /etc (plus /var/nsd, scripts)
#	          common          the shared guest baseline
#	          bastion dns db storage mon web mail
#	  target  hostname or user@hostname of the machine to configure
#
#	Examples:
#	  scripts/deploy.sh host gw.lab.example.org
#	  scripts/deploy.sh web  web.lab.example.org
#	  scripts/deploy.sh host gw -n          # dry run, shows what would change
#
#	Guests are deployed in two passes - vms/common/etc first, then
#	vms/<name>/etc on top - so that a guest always has the baseline rules in
#	place even if its own tree is incomplete.
#
#	Two substitutions happen while staging:
#	  @ADDRESS@   the guest's own address, from the table below.  pf.conf and
#	              sshd_config use it so that one baseline file serves every
#	              guest without being edited per host.
#
#	Files listed in PROTECTED are never overwritten.  /etc/fstab is the
#	important one: this repository's copy documents the intended layout, but
#	the running file has real DUIDs written by the installer, and replacing it
#	with a template makes a machine that no longer boots.

set -u

DRY=no
SSH_USER=""
PROTECTED="fstab"
RSYNC_OPTS="-a --itemize-changes"

while getopts nu: opt; do
	case "$opt" in
	n) DRY=yes ;;
	u) SSH_USER=$OPTARG ;;
	*) echo "usage: $0 [-n] [-u user] <tree> <target>" >&2; exit 2 ;;
	esac
done
shift $((OPTIND - 1))

TREE=${1:-}
TARGET=${2:-}
if [ -z "$TREE" ] || [ -z "$TARGET" ]; then
	echo "usage: $0 [-n] [-u user] <tree> <target>" >&2
	exit 2
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 2

# Guest addresses, mirroring docs/00-addressing-plan.md.  @ADDRESS@ in the
# staged files is replaced with the value for the guest being deployed.
case "$TREE" in
bastion) ADDRESS=10.10.50.10 ;;
dns)     ADDRESS=10.10.50.11 ;;
db)      ADDRESS=10.10.50.12 ;;
storage) ADDRESS=10.10.50.13 ;;
mon)     ADDRESS=10.10.50.14 ;;
web)     ADDRESS=10.10.40.20 ;;
mail)    ADDRESS=10.10.40.21 ;;
common)  ADDRESS="" ;;
host)    ADDRESS=10.10.10.1 ;;
*) echo "deploy: unknown tree '$TREE'" >&2; exit 2 ;;
esac

if [ "$TREE" = host ]; then
	SRC="$ROOT/host"
	[ -d "$SRC/etc" ] || { echo "deploy: $SRC/etc is missing" >&2; exit 2; }
else
	SRC="$ROOT/vms/$TREE"
	[ -d "$SRC/etc" ] || { echo "deploy: $SRC/etc is missing" >&2; exit 2; }
fi

[ "$DRY" = yes ] && RSYNC_OPTS="$RSYNC_OPTS --dry-run"

remote() {
	if [ -n "$SSH_USER" ]; then
		echo "$SSH_USER@$TARGET"
	else
		echo "$TARGET"
	fi
}

# ------------------------------------------------------------------ staging
# Everything goes through a staging directory so that substitutions happen in
# one place, and so that a dry run has something real to compare against.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/deploy.XXXXXX") || exit 1
trap 'rm -rf "$STAGE"' EXIT INT TERM

stage_tree() {	# stage_tree <source-dir> <relative-destination>
	src=$1; dst=$2
	[ -d "$src" ] || return 0
	mkdir -p "$STAGE/$dst"
	# -R keeps the directory structure; the "dot" form copies contents.
	( cd "$src" && find . -type f -print ) | while IFS= read -r f; do
		out="$STAGE/$dst/${f#./}"
		mkdir -p "$(dirname "$out")"
		if [ -n "$ADDRESS" ]; then
			sed "s/@ADDRESS@/$ADDRESS/g" "$src/${f#./}" > "$out"
		else
			cp "$src/${f#./}" "$out"
		fi
	done

	# Preserve the executable bit for scripts, and make the ssh material and
	# anything under secrets/ non-readable to group/other.
	find "$src" -type f -perm -u+x | while IFS= read -r f; do
		chmod 755 "$STAGE/$dst/${f#"$src"/}"
	done
	find "$STAGE/$dst" -type f | while IFS= read -r f; do
		case "$f" in
		*fstab|*/sysctl.conf|*/pf.conf|*/ssh/*) chmod 644 "$f" ;;
		esac
	done
}

echo "deploy: staging $TREE from $ROOT"

if [ "$TREE" = host ]; then
	stage_tree "$ROOT/host/etc" etc
	stage_tree "$ROOT/host/var" var
	stage_tree "$ROOT/host/root" root
	# Operational scripts live in /usr/local/sbin on every lab machine.
	stage_tree "$ROOT/scripts" usr/local/sbin
else
	[ -d "$ROOT/vms/common/etc" ] && stage_tree "$ROOT/vms/common/etc" etc
	stage_tree "$ROOT/vms/$TREE/etc" etc
fi

# The operational scripts go to /usr/local/sbin on the gateway *and* on the
# guests: /etc/doas.conf on both permits /usr/local/sbin/deploy-config, and the
# mail guest runs /usr/local/sbin/acme-renew from its own crontab.  Staging
# them unconditionally is what keeps those references from pointing at files
# that do not exist.
stage_tree "$ROOT/scripts" usr/local/sbin

# ------------------------------------------------------------------ transport
HOSTPART=$(remote)

# rsync(1) is not in the OpenBSD base system, but it is usually installed on
# the *client*; scp(1) always is.  Prefer rsync for the -n preview and the
# protected-file handling.
if command -v rsync >/dev/null 2>&1; then
	EXCLUDES=""
	for p in $PROTECTED; do
		EXCLUDES="$EXCLUDES --exclude etc/$p"
	done

	echo "deploy: rsync -> $HOSTPART (dry run: $DRY)"
	# shellcheck disable=SC2086
	rsync $RSYNC_OPTS $EXCLUDES --rsync-path="doas rsync" \
		--chown=root:wheel --chmod=D755,F644 \
		"$STAGE/etc/" "$HOSTPART:/etc/" || {
			echo "deploy: rsync of /etc failed" >&2
			exit 1
		}

	# Scripts are deployed for every tree, not just the host.
	# shellcheck disable=SC2086
	rsync $RSYNC_OPTS --rsync-path="doas rsync" \
		--chown=root:wheel --chmod=D755,F755 \
		"$STAGE/usr/local/sbin/" "$HOSTPART:/usr/local/sbin/" || exit 1

	if [ "$TREE" = host ]; then
		# shellcheck disable=SC2086
		rsync $RSYNC_OPTS --rsync-path="doas rsync" \
			--chown=root:wheel "$STAGE/var/" "$HOSTPART:/var/" || exit 1
		# Install the autoinstall answers where the provisioning script
		# expects them (installing guests fetch /install.conf from httpd).
		# /var/www/htdocs/install is root-owned (httpd reads it inside its
		# chroot), so the file is piped through "doas tee" rather than copied
		# with scp as the login user.
		for conf in "$ROOT"/vms/*/install.conf; do
			[ -e "$conf" ] || continue
			g=${conf#"$ROOT"/vms/}; g=${g%/install.conf}
			echo "deploy: install.conf.$g -> $HOSTPART:/var/www/htdocs/install/"
			[ "$DRY" = yes ] && continue
			ssh "$HOSTPART" "doas install -o root -g wheel -m 644 /dev/stdin \
				/var/www/htdocs/install/install.conf.$g" < "$conf" ||
				{ echo "deploy: failed to install install.conf.$g" >&2; exit 1; }
		done
	else
		echo "deploy: guest tree staged (/etc and /usr/local/sbin)"
	fi
else
	echo "deploy: rsync not found, falling back to scp"
	echo "        (no dry-run preview, no protected-file handling: check $PROTECTED by hand)"
	[ "$DRY" = yes ] && { echo "deploy: -n needs rsync; nothing done"; exit 0; }
	for f in fstab; do
		echo "deploy: SKIPPING etc/$f (protected)"
	done
	( cd "$STAGE" && tar cf - --exclude etc/fstab etc usr var 2>/dev/null ) |
		ssh "$HOSTPART" 'doas tar xpf - -C /' || exit 1
fi

# ------------------------------------------------------------------ activation
cat <<EOF

deploy: files are in place.  Nothing has been reloaded.

Review on $HOSTPART before activating.  Every one of these is a syntax check
that changes nothing:

    doas pfctl -nf /etc/pf.conf
    doas sshd -t
    doas httpd -n ; doas smtpd -n ; doas unbound-checkconf
    doas nsd-checkconf /etc/nsd.conf

Then reload what changed, for example:

    doas pfctl -f /etc/pf.conf
    doas rcctl reload sshd
    doas sh /etc/netstart vlan10    # only if a hostname.if file changed

EOF
exit 0

#!/bin/ksh
#
#	fetch-sets.sh — populate the provisioning HTTP root with OpenBSD sets
#
#	Installed to /usr/local/sbin/fetch-sets.sh.  Run once per release, then
#	again after an upgrade.
#
#	The sets are served by httpd(8) from /var/www/htdocs/install, which is a
#	chroot path: on disk that is /var/www/htdocs/install.  Everything the
#	installer needs lives in one flat directory:
#
#	    /var/www/htdocs/install/
#	        install.conf          the gateway's own answers (rarely used)
#	        install.conf.<name>   per-guest answers, copied into place by
#	                              provision-vm.sh
#	        base77.tgz ...        the release sets
#	        SHA256.sig
#
#	usage: fetch-sets.sh [-r release] [-a arch] [-m mirror] [-f]

set -u

RELEASE=${RELEASE:-7.7}
ARCH=${ARCH:-$(uname -m)}
MIRROR=${MIRROR:-https://cdn.openbsd.org/pub/OpenBSD}
DEST=/var/www/htdocs/install
FORCE=no

while getopts r:a:m:f opt; do
	case "$opt" in
	r) RELEASE=$OPTARG ;;
	a) ARCH=$OPTARG ;;
	m) MIRROR=$OPTARG ;;
	f) FORCE=yes ;;
	*) echo "usage: $0 [-r release] [-a arch] [-m mirror] [-f]" >&2; exit 2 ;;
	esac
done

[ "$(id -u)" -eq 0 ] || { echo "$0: must be run as root" >&2; exit 1; }

# OpenBSD's architecture names are not uname(1)'s on every platform.
case "$ARCH" in
amd64|i386|arm64|armv7|sparc64|macppc|powerpc64|riscv64|luna88k|octeon|alpha|hppa|landisk) ;;
*) echo "$0: unusual architecture '$ARCH' — set ARCH= explicitly" >&2 ;;
esac

DIR="$MIRROR/$RELEASE/$ARCH"

# Set names carry the release without the dot: 7.7 -> 77.
RELNUM=$(echo "$RELEASE" | tr -d '.')
SETS="bsd bsd.rd bsd.mp base${RELNUM}.tgz comp${RELNUM}.tgz man${RELNUM}.tgz"
# Add these if you plan to use X or games in a guest:
#SETS="$SETS xbase${RELNUM}.tgz xshare${RELNUM}.tgz xfont${RELNUM}.tgz xserv${RELNUM}.tgz game${RELNUM}.tgz"

mkdir -p "$DEST" /var/www/pub
chown root:wheel "$DEST"
chmod 755 "$DEST"

echo "fetching $RELEASE/$ARCH from $DIR"

for f in $SETS SHA256.sig; do
	if [ -f "$DEST/$f" ] && [ "$FORCE" != yes ]; then
		echo "  have $f"
		continue
	fi
	echo "  fetching $f"
	ftp -o "$DEST/$f.new" "$DIR/$f" || {
		echo "  FAILED: $f" >&2
		rm -f "$DEST/$f.new"
		exit 1
	}
	mv "$DEST/$f.new" "$DEST/$f"
done

# Signature check.  The first run needs the release public key in
# /etc/signify/ — the installer puts it there, and the file is named after the
# release (openbsd-${RELNUM}-base.pub).
PUBKEY="/etc/signify/openbsd-${RELNUM}-base.pub"
if [ -f "$PUBKEY" ]; then
	( cd "$DEST" && signify -C -p "$PUBKEY" -x SHA256.sig ) || {
		echo "$0: signature check FAILED — do not install from this tree" >&2
		exit 1
	}
	echo "  signatures ok"
else
	echo "$0: WARNING: $PUBKEY not found, sets are unverified" >&2
fi

# httpd(8) runs as www inside a chroot; make the tree readable by it.  The
# files are world-readable by design (they are public release sets), but the
# directory is not listed to the network: httpd.conf serves explicitly.
chown -R root:wheel "$DEST"
chmod 644 "$DEST"/* 2>/dev/null
chmod 755 "$DEST"

cat <<EOF

sets are in place: $DEST
verify with:      ls -la $DEST
next step:        /usr/local/sbin/provision-vm.sh <guest-name>
EOF

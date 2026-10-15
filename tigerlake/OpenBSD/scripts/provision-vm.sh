#!/bin/ksh
#
#	provision-vm.sh — create a guest disk and autoinstall it
#
#	Installed to /usr/local/sbin/provision-vm.sh.
#
#	usage: provision-vm.sh [-s size] [-m memory] [-c cpus] [-n] <name>
#	       provision-vm.sh -f <name>      finish: stop it, report next steps
#	       provision-vm.sh -w <name>      wipe an existing disk (asks first)
#
#	How the install works, and why it is not the "vmctl -L" recipe:
#
#	  * The guest is started with bsd.rd as its kernel and one interface
#	    attached to the vmd(8) switch "install" (veb2, 10.10.99.0/24).
#	  * dhcpd(8) answers on that subnet with next-server 10.10.99.1 and the
#	    boot file "auto_install".  A lease whose boot file is named
#	    "auto_install" is what makes the kernel start the installer
#	    unattended, so no prompt is ever answered by hand.
#	  * The installer fetches /install.conf from httpd(8) on 10.10.99.1 and
#	    the sets from the same place (scripts/fetch-sets.sh put them there).
#
#	Using our own DHCP server instead of vmd's local interfaces ("-L") is
#	deliberate: vmd hands out 100.64.<id>.2 addresses that depend on the VM's
#	runtime ID, which would make install.conf — and therefore the whole
#	provisioning step — non-deterministic.
#
#	The install.conf answers describe the *install-time* network (dhcp on the
#	install subnet).  The guest's real configuration — static address, switch,
#	services — is deployed afterwards from this repository with
#	/usr/local/sbin/deploy.sh, which overwrites /etc/hostname.vio0.

set -u

NAME=""
SIZE=20G
MEM=
CPUS=2
MODE=start
DEST=/var/www/htdocs/install
VMMDIR=/var/vmm

usage() {
	cat >&2 <<'EOF'
usage: provision-vm.sh [-s size] [-m memory] [-c cpus] [-n] <name>
       provision-vm.sh -f <name>
       provision-vm.sh -w <name>
EOF
	exit 2
}

while getopts s:m:c:nfw opt; do
	case "$opt" in
	s) SIZE=$OPTARG ;;
	m) MEM=$OPTARG ;;
	c) CPUS=$OPTARG ;;
	n) MODE=start ;;
	f) MODE=finish ;;
	w) MODE=wipe ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))
NAME=${1:-}
[ -n "$NAME" ] || usage

[ "$(id -u)" -eq 0 ] || { echo "$0: must be run as root" >&2; exit 1; }

# Guests are named after their role; keep them in sync with vm.conf.
case "$NAME" in
bastion)	DEFMEM=1G ;  DEFSIZE=12G ;;
dns)		DEFMEM=512M; DEFSIZE=12G ;;
db)		DEFMEM=2G ;  DEFSIZE=40G ;;
storage)	DEFMEM=1G ;  DEFSIZE=40G ;;
mon)		DEFMEM=1G ;  DEFSIZE=20G ;;
web)		DEFMEM=1G ;  DEFSIZE=20G ;;
mail)		DEFMEM=2G ;  DEFSIZE=20G ;;
*)		echo "$0: unknown guest '$NAME' (known: bastion dns db storage mon web mail)" >&2
		exit 2 ;;
esac
MEM=${MEM:-$DEFMEM}
SIZE=${SIZE:-$DEFSIZE}

DISK="$VMMDIR/$NAME.qcow2"
INSTALL_CONF_SRC="$DEST/install.conf.$NAME"

# The VM is *not* started under the name in vm.conf during provisioning: that
# entry attaches it to the srv/dmz switch, and the installer must see the
# install switch instead.  A temporary name keeps the two roles separate.
INSTALL_NAME="$NAME-install"

log() { logger -t provision-vm "$*"; echo "$*"; }

case "$MODE" in
wipe)
	[ -f "$DISK" ] || { echo "$0: no such disk: $DISK" >&2; exit 1; }
	echo "This deletes $DISK (all data on the guest '$NAME')."
	printf 'Type the guest name again to confirm: '
	read -r confirm
	[ "$confirm" = "$NAME" ] || { echo "aborted"; exit 1; }
	vmctl stop -f "$NAME" 2>/dev/null
	vmctl stop -f "$INSTALL_NAME" 2>/dev/null
	rm -f "$DISK"
	log "removed $DISK"
	exit 0
	;;

finish)
	# The installer reboots into the fresh system; the guest is now running
	# on the install network with a DHCP address.  Stop it so the real
	# configuration can be deployed, then start it from vm.conf.
	log "stopping $INSTALL_NAME"
	vmctl stop -w "$INSTALL_NAME" 2>/dev/null || vmctl stop -w "$NAME" 2>/dev/null
	cat <<EOF

The disk $DISK now holds an installed system.

Next, from the machine that holds this repository:

    1. deploy the guest's configuration (static address, switch, services):
           scripts/deploy.sh $NAME $NAME.lab.example.org

    2. start it the normal way, attached to its real switch:
           vmctl start $NAME
           vmctl console $NAME        # leave with "~."

EOF
	exit 0
	;;
esac

# ---------------------------------------------------------------- pre-flight
[ -c /dev/vmm ] || log "warning: /dev/vmm missing — is vmm(4) attached? (dmesg | grep -i vmx)"
[ -d "$VMMDIR" ] || { log "creating $VMMDIR"; mkdir -p "$VMMDIR"; chmod 700 "$VMMDIR"; }

if [ ! -f "$INSTALL_CONF_SRC" ]; then
	echo "$0: missing $INSTALL_CONF_SRC" >&2
	echo "      deploy it first:  scripts/deploy.sh $NAME ..." >&2
	exit 1
fi

if [ ! -f "$DEST/bsd.rd" ]; then
	echo "$0: $DEST/bsd.rd is missing — run /usr/local/sbin/fetch-sets.sh" >&2
	exit 1
fi

if [ -f "$DISK" ]; then
	echo "$0: $DISK already exists; use -w to rebuild it or -f to finish it" >&2
	exit 1
fi

rcctl check vmd >/dev/null 2>&1 || { log "starting vmd"; rcctl start vmd; }
rcctl check dhcpd >/dev/null 2>&1 || { log "starting dhcpd"; rcctl start dhcpd; }
rcctl check httpd >/dev/null 2>&1 || { log "starting httpd"; rcctl start httpd; }

# The installer fetches the generic name; the per-guest file is what we keep
# in the repository, so installs are reproducible without editing anything.
cp "$INSTALL_CONF_SRC" "$DEST/install.conf" || {
	echo "$0: cannot install $DEST/install.conf" >&2
	exit 1
}
chown root:wheel "$DEST/install.conf"
chmod 644 "$DEST/install.conf"

# ---------------------------------------------------------------- disk + boot
log "creating a $SIZE qcow2 disk at $DISK"
vmctl create -s "$SIZE" "$DISK" || exit 1

# The freshly created image needs a disklabel before the installer can use it,
# but bsd.rd performs that itself: it offers the empty disk as SD0 and the
# autoinstall answers take the whole disk with the default layout.

log "starting $INSTALL_NAME from bsd.rd (memory $MEM, cpus $CPUS)"
vmctl start -m "$MEM" -p "$CPUS" -n install -b /bsd.rd -d "$DISK" "$INSTALL_NAME" || exit 1

cat <<EOF

$INSTALL_NAME is booting.  Watch the unattended install with:

    vmctl console $INSTALL_NAME        # leave the console with "~."

The installer will partition the disk, fetch the sets from 10.10.99.1 and
reboot into the new system by itself.  When it has finished (it will be sitting
at a login prompt on the install network), stop it and deploy its real
configuration:

    vmctl stop -w $INSTALL_NAME
    scripts/deploy.sh $NAME $NAME.lab.example.org
    vmctl start $NAME

or simply:

    provision-vm.sh -f $NAME

EOF

log "provisioning started for $NAME"
exit 0

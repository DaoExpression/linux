#!/bin/ksh
#
#	pf-ban.sh — maintain the pf(4) <bruteforce> table
#
#	Installed to /usr/local/sbin/pf-ban.sh.  The table itself is declared in
#	/etc/pf.conf:
#	    table <bruteforce> persist
#	    block drop in log quick from <bruteforce> to any
#
#	The table is ephemeral: "persist" survives a ruleset reload, but not a
#	reboot.  Expiry times live in $DB, which is the source of truth, and the
#	table is rebuilt from it, so the two can never drift apart.
#
#	usage: pf-ban.sh ban <ip> [ttl_seconds]
#	       pf-ban.sh unban <ip>
#	       pf-ban.sh expire             # drop everything past its TTL
#	       pf-ban.sh list
#	       pf-ban.sh save               # write table -> DB (before reboot)
#	       pf-ban.sh restore            # DB -> table (at boot)
#	       pf-ban.sh watch              # read new authlog lines, ban repeat offenders
#
#	Crontab (installed in /etc/crontab):
#	    */5 * * * * root /usr/local/sbin/pf-ban.sh expire
#	    22  4 * * * root /usr/local/sbin/pf-ban.sh save
#	    @reboot      root /usr/local/sbin/pf-ban.sh restore
#	    *   * * * * root /usr/local/sbin/pf-ban.sh watch
#
#	Everything is configurable from the environment (see /etc/pf-ban.conf,
#	sourced below if present) so the same script can be used on the guests.

set -u

PFCTL=${PFCTL:-/sbin/pfctl}
TABLE=${PF_BAN_TABLE:-bruteforce}
DB=${PF_BAN_DB:-/var/db/pfban.tsv}
OFFSET_FILE=${PF_BAN_OFFSET:-/var/db/pfban.offset}
AUTHLOG=${PF_BAN_AUTHLOG:-/var/log/authlog}
TTL=${PF_BAN_TTL:-3600}			# default ban length, seconds
THRESHOLD=${PF_BAN_THRESHOLD:-5}	# failures before a ban
WINDOW=${PF_BAN_WINDOW:-600}		# seconds the failures must fall inside
MAX_BAN=${PF_BAN_MAX:-86400}		# cap on repeated-offender bans
LOCKDIR=${PF_BAN_LOCKDIR:-/var/run}

[ -f /etc/pf-ban.conf ] && . /etc/pf-ban.conf

PROG=$(basename "$0")
LOCK="$LOCKDIR/$PROG.lock"

log() {
	logger -t "$PROG" -p auth.warning "$*"
	echo "$PROG: $*" >&2
}

die() {
	log "$*"
	exit 1
}

# ------------------------------------------------------------------ helpers

# pfctl(8) needs the rule table to exist.  "persist" keeps it alive between
# reloads, but after a fresh boot with no ruleset loaded there is nothing to
# operate on, and pfctl would fail with "Table does not exist".
table_exists() {
	"$PFCTL" -t "$TABLE" -T show >/dev/null 2>&1
}

valid_ip() {
	case "$1" in
	'') return 1 ;;
	esac
	# IPv4 dotted quad.  grep -E does support intervals (the constraint above is
	# specific to awk), and this pattern still has to be permissive enough to
	# let the octet check below produce the error message.  Add an inet6
	# pattern here if you extend pf.conf to ban IPv6 addresses.
	echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
	# reject octets above 255 without pulling in a real parser
	echo "$1" | awk -F. '{ for (i=1; i<=4; i++) if ($i > 255) exit 1 }'
}

# Source of truth: TSV of "address<TAB>expiry_epoch", one per line.
db_read() {
	[ -f "$DB" ] && cat "$DB"
	return 0
}

db_replace() {
	# stdin: new TSV contents
	umask 077
	cat > "$DB.new" || die "cannot write $DB.new"
	mv "$DB.new" "$DB" || die "cannot replace $DB"
}

# Push the current DB into pf(4).  -T replace takes the whole list at once,
# which avoids a window where the table is half-populated.
db_sync() {
	tmplist=$(mktemp "${TMPDIR:-/tmp}/pfban.XXXXXX") || die "cannot create temp file"
	db_read | awk -F'\t' 'NF >= 1 && $1 != "" { print $1 }' > "$tmplist"
	if [ -s "$tmplist" ]; then
		"$PFCTL" -t "$TABLE" -T replace -f "$tmplist" \
			|| log "warning: pfctl -T replace failed for table <$TABLE>"
	else
		# An empty file would make pfctl complain; flush instead.
		"$PFCTL" -t "$TABLE" -T kill 2>/dev/null
	fi
	rm -f "$tmplist"
}

now() {
	date +%s
}

# ------------------------------------------------------------------ commands

cmd_ban() {
	ip=${1:-}
	ttl=${2:-$TTL}
	valid_ip "$ip" || die "not an IPv4 address: '$ip'"
	case "$ttl" in
	''|*[!0-9]*) die "ttl must be a number of seconds, got '$ttl'" ;;
	esac

	exp=$(( $(now) + ttl ))
	# Replace any existing entry for this address, keep the rest.
	{
		db_read | awk -F'\t' -v ip="$ip" '$1 != ip'
		printf '%s\t%s\n' "$ip" "$exp"
	} | db_replace

	if table_exists; then
		"$PFCTL" -t "$TABLE" -T add "$ip" >/dev/null 2>&1
	else
		log "table <$TABLE> is not loaded yet; ban recorded, will apply on restore"
	fi
	log "banned $ip for ${ttl}s (expires $(date -r "$exp" '+%Y-%m-%dT%H:%M:%S'))"
}

cmd_unban() {
	ip=${1:-}
	valid_ip "$ip" || die "not an IPv4 address: '$ip'"
	db_read | awk -F'\t' -v ip="$ip" '$1 != ip' | db_replace
	table_exists && "$PFCTL" -t "$TABLE" -T delete "$ip" >/dev/null 2>&1
	log "unbanned $ip"
}

cmd_expire() {
	[ -f "$DB" ] || return 0
	n=$(now)
	before=$(db_read | wc -l | tr -d ' ')
	db_read | awk -F'\t' -v now="$n" '$2 > now' | db_replace
	after=$(db_read | wc -l | tr -d ' ')
	if [ "$before" != "$after" ]; then
		db_sync
		log "expired $((before - after)) ban(s); $after active"
	fi
}

cmd_list() {
	if [ ! -f "$DB" ]; then
		echo "no bans"
		return 0
	fi
	printf '%-18s %-20s %s\n' ADDRESS EXPIRES REMAINING
	db_read | while IFS="$(printf '\t')" read -r ip exp; do
		[ -n "${ip:-}" ] || continue
		rem=$(( exp - $(now) ))
		if [ "$rem" -le 0 ]; then
			state="expired"
		else
			state="${rem}s"
		fi
		printf '%-18s %-20s %s\n' "$ip" "$(date -r "$exp" '+%Y-%m-%dT%H:%M:%S')" "$state"
	done
}

cmd_save() {
	# Table -> DB.  Entries already in the DB keep their original expiry so a
	# save/restore cycle cannot extend a ban indefinitely.
	pfctl_list=$("$PFCTL" -t "$TABLE" -T show 2>/dev/null | grep -E '^[0-9]')
	[ -n "$pfctl_list" ] || { log "save: table <$TABLE> is empty"; return 0; }
	n=$(now)
	{
		echo "$pfctl_list" | while read -r ip; do
			old=$(db_read | awk -F'\t' -v ip="$ip" '$1 == ip { print $2; exit }')
			[ -n "$old" ] || old=$(( n + TTL ))
			printf '%s\t%s\n' "$ip" "$old"
		done
	} | db_replace
	log "saved $(echo "$pfctl_list" | wc -l | tr -d ' ') ban(s) to $DB"
}

cmd_restore() {
	[ -f "$DB" ] || return 0
	cmd_expire >/dev/null 2>&1
	db_sync
	log "restored bans from $DB"
}

# Read only the part of authlog we have not seen, count failures per source
# address, and ban anything over the threshold.
cmd_watch() {
	[ -r "$AUTHLOG" ] || die "cannot read $AUTHLOG"

	umask 077
	offset=0
	[ -f "$OFFSET_FILE" ] && offset=$(cat "$OFFSET_FILE")

	size=$(wc -c < "$AUTHLOG" | tr -d ' ')
	if [ "$offset" -gt "$size" ]; then
		# Log rotated underneath us: start from the beginning of the new file.
		offset=0
	fi

	tmp=$(mktemp "${TMPDIR:-/tmp}/pfban-watch.XXXXXX") || die "cannot create temp file"
	tail -c +$((offset + 1)) "$AUTHLOG" > "$tmp"
	echo "$size" > "$OFFSET_FILE"

	# sshd(8) records these for every rejected authentication attempt:
	#   Failed password / Failed publickey / Invalid user ... from <addr>
	#   Connection closed by authenticating user ... <addr>
	#   Unable to negotiate ... <addr>
	# NOTE: the address patterns are spelled out instead of using interval
	# expressions ("[0-9]{1,3}\.[0-9]{1,3}...").  Classic awk - including the
	# version shipped in the OpenBSD base system - does not reliably support
	# "{n,m}": with it, this pattern matches nothing at all, and the watcher
	# silently never bans anybody.  That is exactly the kind of failure that
	# looks like "the feature works, there just is not any abuse".
	awk -v now="$(now)" -v window="$WINDOW" '
		/from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {
			for (i = 1; i <= NF; i++) {
				if ($i == "from" && $(i+1) ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
					hits[$(i+1)]++
					break
				}
			}
		}
		END { for (ip in hits) print hits[ip], ip }
	' "$tmp" | while read -r count ip; do
		[ "$count" -ge "$THRESHOLD" ] || continue
		# Escalate: an address that keeps coming back gets a longer ban, up
		# to MAX_BAN, so the table does not churn every few minutes.
		prev=$(db_read | awk -F'\t' -v ip="$ip" '$1 == ip { print $2; exit }')
		ttl=$TTL
		if [ -n "$prev" ]; then
			ttl=$(( TTL * 2 ))
			[ "$ttl" -gt "$MAX_BAN" ] && ttl=$MAX_BAN
		fi
		cmd_ban "$ip" "$ttl"
	done

	rm -f "$tmp"
}

# ------------------------------------------------------------------ main

[ "$(id -u)" -eq 0 ] || die "must be run as root"

# One instance at a time: a slow "watch" racing a "ban" would interleave the
# read-modify-write of the DB and lose entries.
if ! mkdir "$LOCK" 2>/dev/null; then
	# Stale lock from a killed run?  Anything older than 10 minutes is junk.
	if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -mmin +10 2>/dev/null)" ]; then
		rmdir "$LOCK" 2>/dev/null
		mkdir "$LOCK" 2>/dev/null || die "another instance is running"
	else
		die "another instance is running (lock $LOCK)"
	fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

case "${1:-}" in
ban)		shift; cmd_ban "$@" ;;
unban)		shift; cmd_unban "$@" ;;
expire)		cmd_expire ;;
list)		cmd_list ;;
save)		cmd_save ;;
restore)	cmd_restore ;;
watch)		cmd_watch ;;
*)
	echo "usage: $PROG {ban <ip> [ttl] | unban <ip> | expire | list | save | restore | watch}" >&2
	exit 2
	;;
esac

exit 0

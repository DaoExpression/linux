# /etc/profile.d/99-hardening.sh
# Session hygiene for interactive logins. Sourced by /etc/profile via /etc/profile.d.
# Deliberately short: nothing here should surprise someone unfamiliar with the machine.

# New files are not world-readable by default.
umask 027

# Do not sit on an unattended root/admin shell forever.
TMOUT=600
readonly TMOUT
export TMOUT

# History: no duplicates, no leading-space commands, and never record obvious secrets.
HISTCONTROL=ignoreboth:erasedups
HISTIGNORE='ls:ll:cd:pwd:exit:history:clear'
HISTFILESIZE=5000
HISTSIZE=5000
# Commands containing these strings are not written to history at all.
export HISTIGNORE="$HISTIGNORE:*passwd*:*--password*:*token*:*secret*:*apikey*:*api_key*:*PRIVATE*:*wireguard*:*wg genkey*"
shopt -s histappend cmdhist checkwinsize
export PROMPT_COMMAND="history -a; history -n"

# Do not send commands to an X server (there should not be one, but be explicit).
[ -n "$DISPLAY" ] && unset DISPLAY

# No mail-check surprises from a mail daemon that is not installed.
unset MAILCHECK

case "$-" in
  *i*) : ;;
esac

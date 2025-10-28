#!/bin/bash
declare -a ISO=("af" "au" "al" "dz" "aq" "br" "ar" "cn" "lb" "my" "ly" "lr" "la" "jp" "jm" "jo" "kz" "ke" "hk" "ml" "mx" "fm" "md" "mc" "mn" "ms" "ma" "mz" "mm" "nr" "na" "np" "nl" "an" "nc" "nz" "ni" "ne" "ng" "nu" "nf" "mp" "no" "om" "pk" "pw" "pa" "pg" "py" "pe" "ph" "pn" "pl" "pt" "pr" "qa" "re" "ro" "ru" "rw" "kn" "lc" "vc" "ws" "sm" "st" "sn" "sa" "sc" "sl" "sg" "sk" "si" "sb" "so" "za" "gs" "es" "lk" "sh" "pm" "sd" "sr" "sj" "sz" "se" "ch" "sy" "tw" "tj" "tz" "th" "tg" "tk" "to" "tt" "tn" "tr" "tm" "tc" "tv" "ug" "ua" "ae" "gb" "um" "uy" "uz" "vu" "ve" "vn" "vg" "vi" "wf" "eh" "ye" "yu" "zm" "zw" "ie" "in" "il" "ir" "hn" )
declare -a zone_file_names_ext=()

# remove any old list that might exist from previous runs of this script
#find /opt/tmp -name '*.zone' -or -name '*.zone.1' | xargs rm

for i in "${ISO[@]}"
do
    zone_file_names_ext+=( "$i.zone" )
    ipset flush
    ipset -N "$i" hash:net
    # Pull the latest IP set for All Countries
    wget -P . http://www.ipdeny.com/ipblocks/data/countries/"$i.zone" -P /opt/tmp
done

for filename in /opt/tmp/*.zone; do
	file=${filename#*"/opt/tmp/"}
    for i in $(cat "$filename" ); do ipset -A "${file%.*}" "$i"; done
done

# Restore iptables
/sbin/iptables-restore < /etc/iptables/rules.v4

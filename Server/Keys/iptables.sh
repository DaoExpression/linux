#!/bin/bash
# Oscar FM 
# STK Server Rules 

# Delete all existing rules
iptables -F

#  Set default chain policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Block a specific ip-address
#BLOCK_THIS_IP="x.x.x.x"
#iptables -A INPUT -s "$BLOCK_THIS_IP" -j DROP

# Allow ALL incoming SSH
iptables -A INPUT -i enp2s0 -p tcp --dport 22 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -o enp2s0 -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT

# Allow incoming HTTP
iptables -A INPUT -i enp2s0 -p tcp --dport 80 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -o enp2s0 -p tcp --sport 80 -m state --state ESTABLISHED -j ACCEPT

# Allow incoming HTTPS
iptables -A INPUT -i enp2s0 -p tcp --dport 443 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -o enp2s0 -p tcp --sport 443 -m state --state ESTABLISHED -j ACCEPT

# MultiPorts (Allow incoming SSH, HTTP, and HTTPS)
iptables -A INPUT -i enp2s0 -p tcp -m multiport --dports 22,80,443 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -o enp2s0 -p tcp -m multiport --sports 22,80,443 -m state --state ESTABLISHED -j ACCEPT

# Allow outgoing SSH
iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name ssh
iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 30 --hitcount 10 --rttl --name ssh -j DROP
iptables -A INPUT -p tcp --dport 22 -m limit --limit 2/s -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -m connlimit --connlimit-above 5 -j DROP

# Allow outgoing HTTPS
iptables -A OUTPUT -o enp2s0 -p tcp --dport 443 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A INPUT -i enp2s0 -p tcp --sport 443 -m state --state ESTABLISHED -j ACCEPT

#  Load balance incoming HTTPS traffic
#iptables -A PREROUTING -i enp2s0 -p tcp --dport 443 -m state --state NEW -m nth --counter 0 --every 3 --packet 0 -j DNAT --to-destination 192.168.1.101:443
#iptables -A PREROUTING -i enp2s0 -p tcp --dport 443 -m state --state NEW -m nth --counter 0 --every 3 --packet 1 -j DNAT --to-destination 192.168.1.102:443
#iptables -A PREROUTING -i enp2s0 -p tcp --dport 443 -m state --state NEW -m nth --counter 0 --every 3 --packet 2 -j DNAT --to-destination 192.168.1.103:443

#  Ping from inside to outside
iptables -A OUTPUT -p icmp --icmp-type echo-request -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT

#  Allow loopback access
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow outbound DNS
iptables -A OUTPUT -p udp -o enp2s0 --dport 53 -j ACCEPT
iptables -A INPUT -p udp -i enp2s0 --sport 53 -j ACCEPT

# Allow Sendmail or Postfix
iptables -A INPUT -i enp2s0 -p tcp --dport 25 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -o enp2s0 -p tcp --sport 25 -m state --state ESTABLISHED -j ACCEPT

# Prevent DoS attack
iptables -A INPUT -p tcp --dport 80 -m limit --limit 25/minute --limit-burst 100 -j ACCEPT

# already established in-/outgoing connections
iptables -A INPUT    -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -I OUTPUT 1 -m state --state RELATED,ESTABLISHED -j ACCEPT

# log and ban portscans
iptables -A INPUT   -m recent --name portscan --rcheck --seconds 86400 -j DROP
iptables -A FORWARD -m recent --name portscan --rcheck --seconds 86400 -j DROP
iptables -A INPUT   -m recent --name portscan --remove
iptables -A FORWARD -m recent --name portscan --remove

iptables -A INPUT   -p tcp -m tcp --dport 139 -m recent --name portscan --set -j LOG --log-prefix "Portscan:"
iptables -A INPUT   -p tcp -m tcp --dport 139 -m recent --name portscan --set -j DROP
iptables -A FORWARD -p tcp -m tcp --dport 139 -m recent --name portscan --set -j LOG --log-prefix "Portscan:"
iptables -A FORWARD -p tcp -m tcp --dport 139 -m recent --name portscan --set -j DROP


# drop LAN/Multicast IP's (RFC1918)
iptables -A INPUT -s 10.0.0.0/8     -j DROP
iptables -A INPUT -s 169.254.0.0/16 -j DROP
iptables -A INPUT -s 172.16.0.0/12  -j DROP
iptables -A INPUT -s 127.0.0.0/8    -j DROP


# Log dropped packets
iptables -N LOGGING
iptables -A INPUT -j LOGGING
iptables -A LOGGING -m limit --limit 2/min -j LOG --log-prefix "IPTables Packet Dropped: " --log-level 7
iptables -A LOGGING -j DROP



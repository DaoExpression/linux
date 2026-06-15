#!/bin/bash
# Oscar FM 
# STK Server Rules 

# Delete all existing rules
iptables -F
iptables -Z
iptables -X 

# Set default chain policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow loopback access
iptables -A INPUT -s 127.0.0.1/32 -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Ping from inside to outside
iptables -A OUTPUT -p icmp --icmp-type echo-request -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT

# Block a specific ip-address
#BLOCK_THIS_IP="x.x.x.x"
#iptables -A INPUT -s "$BLOCK_THIS_IP" -j DROP

# Allow incoming SSH only from a specific network
#iptables -A INPUT -i enp2s0 -p tcp -s 192.168.200.0/24 --dport 22 -m state --state NEW,ESTABLISHED -j ACCEPT
#iptables -A OUTPUT -o enp2s0 -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT

# Allow outgoing SMTP 
iptables -A OUTPUT -o enp2s0 -p tcp --dport 25 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A INPUT -i enp2s0 -p tcp --sport 25 -m state --state ESTABLISHED -j ACCEPT

# Allow outbound DNS
iptables -A OUTPUT -p udp -o enp2s0 --dport 53 -j ACCEPT
iptables -A INPUT -p udp -i enp2s0 --sport 53 -j ACCEPT

# Allow incoming HTTP
iptables -A INPUT -i enp2s0 -p tcp --dport 80 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -o enp2s0 -p tcp --sport 80 -m state --state ESTABLISHED -j ACCEPT
# Allow incoming SSL 
iptables -A INPUT -i enp2s0 -p tcp --dport 443 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -o enp2s0 -p tcp --sport 443 -m state --state ESTABLISHED -j ACCEPT
# Prevent DoS attack
iptables -A INPUT -p tcp --dport 80 -m limit --limit 25/minute --limit-burst 100 -j ACCEPT
# Allow outgoing HTTP
iptables -A OUTPUT -o enp2s0 -p tcp --dport 80 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A INPUT -i enp2s0 -p tcp --sport 80 -m state --state ESTABLISHED -j ACCEPT
# Allow outgoing SSL 
iptables -A OUTPUT -o enp2s0 -p tcp --dport 443 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A INPUT -i enp2s0 -p tcp --sport 443 -m state --state ESTABLISHED -j ACCEPT

# Allow Incomming NTP
iptables -A INPUT -i enp2s0 -p udp --dport 123 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -o enp2s0 -p udp --sport 123 -m state --state ESTABLISHED -j ACCEPT

# Allow Local Reverse Proxy from Apache2 
#iptables -A INPUT -i enp2s0 -p tcp --dport 5000 -m state --state NEW,ESTABLISHED -j ACCEPT
#iptables -A OUTPUT -o enp2s0 -p tcp --sport 5000 -m state --state ESTABLISHED -j ACCEPT

# Allow Local-network IP to connect to 1panel
iptables -A INPUT -i enp2s0 -p tcp -d 192.168.1.133/24 --dport 9200 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -o enp2s0 -p tcp --sport 9200 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i enp2s0 -p tcp --dport 9200 -m state --state NEW -j DROP 

iptables -A INPUT -i enp2s0 -p tcp -d 192.168.1.133/24 --dport 55000 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -o enp2s0 -p tcp --sport 55000 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i enp2s0 -p tcp --dport 55000 -m state --state NEW -j DROP 

iptables -A INPUT -i enp2s0 -p tcp -d 192.168.1.133/24 --dport 30443 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -o enp2s0 -p tcp --sport 30443 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i enp2s0 -p tcp --dport 30443 -m state --state NEW -j DROP 
# Allow Local-network IP to connect to 1panel
# iptables -A INPUT -i enp2s0 -p tcp -d 192.168.1.133/24 --dport 30443 -m state --state NEW,ESTABLISHED -j ACCEPT
# iptables -A OUTPUT -o enp2s0 -p tcp --sport 30443 -m state --state ESTABLISHED -j ACCEPT
# iptables -A INPUT -i enp2s0 -p tcp --dport 30443 -m state --state NEW -j DROP 

# MultiPorts (Allow incoming SSH, HTTP, and HTTPS)
iptables -A INPUT -i enp2s0 -p tcp -m multiport --dports 22,80,443 -m state --state NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -o enp2s0 -p tcp -m multiport --sports 22,80,443 -m state --state ESTABLISHED -j ACCEPT

# Allow outgoing SSH only to a specific network
# iptables -A OUTPUT -o enp2s0 -p tcp -d 192.168.1.133/24 --dport 22 -m state --state NEW,ESTABLISHED -j ACCEPT
# iptables -A INPUT -i enp2s0 -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT

# Allow Webmin Access from Local Network
#iptables -A INPUT -i enp2s0 -p tcp --dport 10000 -m state --state NEW,ESTABLISHED -j ACCEPT
#iptables -A OUTPUT -o enp2s0 -p tcp --dport 10000 -m state --state NEW,ESTABLISHED -j ACCEPT

# Load balance incoming HTTPS traffic
# iptables -t nat -A PREROUTING -p tcp --dport 22 -m state --state NEW -m statistic --mode nth --every 2 --packet 0 -j DNAT --to-destination 192.168.1.131
# iptables -t nat -A PREROUTING -p tcp --dport 80 -m state --state NEW -m statistic --mode nth --every 2 --packet 0 -j DNAT --to-destination 192.168.1.131
# iptables -t nat -A PREROUTING -p tcp --dport 443 -m state --state NEW -m statistic --mode nth --every 2 --packet 0 -j DNAT --to-destination 192.168.1.131

#  Allow all outbound traffic - you can modify this to only allow certain traffic
iptables -A OUTPUT -j ACCEPT

#  Log iptables denied calls
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "iptables denied: " --log-level 7

#  Drop all other inbound - default deny unless explicitly allowed policy
iptables -A INPUT -j DROP
iptables -A FORWARD -j DROP

# Save IPTables State
/etc/init.d/netfilter-persistent save
/etc/init.d/netfilter-persistent reload

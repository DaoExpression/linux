#!/bin/bash
# Oscar FM 
# STK Server Rules 

# Delete all existing rules
iptables -F
iptables -Z
iptables -X 

# Set default chain policies
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Allow loopback access
iptables -A INPUT -s 127.0.0.1/32 -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT


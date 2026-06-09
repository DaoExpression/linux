#!/bin/bash

# ==============================================================================
# Paranoid Desktop IPTables Script
# Purpose: Block all inbound, Anti-Scan, Log all drops, strict outbound access.
# Allowed Outbound: DNS (53), HTTP (80), HTTPS (443), IMAP (143), IMAPS (993)
# ==============================================================================

# 1. Flush existing rules and delete custom chains
iptables -F
iptables -X
iptables -t nat -F
iptables -t mangle -F

# 2. Set default policies to DROP EVERYTHING
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# ==============================================================================
# 3. CUSTOM LOGGING CHAIN
# ==============================================================================
# Create a dedicated chain for logging and dropping.
# We limit logging to 10 entries per minute with a burst of 5 to prevent disk exhaustion.
iptables -N LOG_AND_DROP
iptables -A LOG_AND_DROP -m limit --limit 10/min --limit-burst 5 -j LOG --log-prefix "IPT_PARANOID_DROP: " --log-level 4
iptables -A LOG_AND_DROP -j DROP

# ==============================================================================
# 4. CRITICAL SYSTEM TRAFFIC
# ==============================================================================
# Allow Loopback (Localhost) - Crucial for local desktop applications
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Stateful Inspection: Allow traffic ONLY if it is part of a connection YOU started
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ==============================================================================
# 5. ANTI-SCAN & MALFORMED PACKET DEFENSE (INBOUND)
# ==============================================================================
# Drop and log inherently invalid packets
iptables -A INPUT -m conntrack --ctstate INVALID -j LOG_AND_DROP

# Drop and log suspicious TCP flags (Defends against XMAS, NULL, and FIN scans)
iptables -A INPUT -p tcp --tcp-flags ALL NONE -j LOG_AND_DROP
iptables -A INPUT -p tcp --tcp-flags ALL ALL -j LOG_AND_DROP
iptables -A INPUT -p tcp ! --syn -m conntrack --ctstate NEW -j LOG_AND_DROP

# Anti-Port Scan mechanism
# Tracks IPs creating NEW connections. If an IP hits us more than 10 times in 60 seconds, drop and log.
iptables -A INPUT -p tcp -m conntrack --ctstate NEW -m recent --set --name PORTSCAN
iptables -A INPUT -p tcp -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 10 --name PORTSCAN -j LOG_AND_DROP

# ==============================================================================
# 6. ALLOWED DESKTOP SERVICES (OUTBOUND ONLY)
# ==============================================================================
# DHCP (67) - Required to resolve URLs. Without this, HTTP/HTTPS will not work.
iptables -A OUTPUT -p udp --dport 67 -m conntrack --ctstate NEW -j ACCEPT
iptables -A OUTPUT -p tcp --dport 67 -m conntrack --ctstate NEW -j ACCEPT

# DNS (53) - Required to resolve URLs. Without this, HTTP/HTTPS will not work.
iptables -A OUTPUT -p udp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -m conntrack --ctstate NEW -j ACCEPT

# HTTP (80) & HTTPS (443) - Web Browsing
iptables -A OUTPUT -p tcp --dport 80 -m conntrack --ctstate NEW -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT

# IMAP (143) & IMAPS (993) - Receiving Email
iptables -A OUTPUT -p tcp --dport 143 -m conntrack --ctstate NEW -j ACCEPT
iptables -A OUTPUT -p tcp --dport 993 -m conntrack --ctstate NEW -j ACCEPT

# Optional: SMTP Submission (587) - Uncomment if you need to SEND email from a desktop client!
# iptables -A OUTPUT -p tcp --dport 587 -m conntrack --ctstate NEW -j ACCEPT

# ==============================================================================
# 7. CATCH-ALL DROPS
# ==============================================================================
# Anything that hasn't matched an ACCEPT rule by now gets routed to the log & drop chain.
iptables -A INPUT -j LOG_AND_DROP
iptables -A OUTPUT -j LOG_AND_DROP
iptables -A FORWARD -j LOG_AND_DROP


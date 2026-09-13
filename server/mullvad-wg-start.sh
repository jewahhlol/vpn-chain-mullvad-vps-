#!/bin/bash
# Start Mullvad WG on VPS with safe routing (SSH/AWG stay alive)
set -e

ORIG_GW=$(ip route | grep 'default via' | grep -v mullvad | head -1 | awk '{print $3}')
ORIG_IF=$(ip route | grep 'default via' | grep -v mullvad | head -1 | awk '{print $5}')
ENDPOINT=$(grep Endpoint /etc/wireguard/mullvad.conf | awk '{print $3}' | cut -d: -f1)

echo "Original gateway: $ORIG_GW via $ORIG_IF"

# Route to Mullvad server endpoint through original gateway
ip route add $ENDPOINT/32 via $ORIG_GW dev $ORIG_IF 2>/dev/null || true

# Bring up Mullvad WG
wg-quick up mullvad 2>&1 | grep -v "^#"

# Policy routing: AWG clients (10.9.9.0/24) exit through Mullvad (table 42)
ip rule add from 10.9.9.0/24 table 42 priority 100 2>/dev/null || true

# MASQUERADE AWG traffic through Mullvad
DEFAULT_IF=$(ip route | grep 'default via' | grep -v mullvad | head -1 | awk '{print $5}')
iptables -t nat -D POSTROUTING -o $DEFAULT_IF -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -o mullvad -j MASQUERADE 2>/dev/null || true

sleep 2
MULLVAD_IP=$(curl -s --connect-timeout 5 --interface mullvad ifconfig.me 2>/dev/null)
echo "Mullvad WG up. Exit IP: $MULLVAD_IP"
echo "SSH still works on $(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null)"

#!/bin/bash
# Stop Mullvad WG on VPS, restore direct AWG routing
ip rule del from 10.9.9.0/24 table 42 2>/dev/null || true
iptables -t nat -D POSTROUTING -o mullvad -j MASQUERADE 2>/dev/null || true
wg-quick down mullvad 2>/dev/null
DEFAULT_IF=$(ip route | grep 'default via' | head -1 | awk '{print $5}')
iptables -t nat -A POSTROUTING -o $DEFAULT_IF -j MASQUERADE 2>/dev/null || true
VPS_IP=$(ip -4 addr show $(ip route | grep 'default via' | head -1 | awk '{print $5}') | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Mullvad WG stopped. AWG clients exit through VPS directly ($VPS_IP)"

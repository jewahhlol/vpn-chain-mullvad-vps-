#!/bin/bash
# Stop Mullvad WG on VPS, restore direct AWG routing
ip rule del from 10.9.9.0/24 table 42 2>/dev/null || true
iptables -t nat -D POSTROUTING -o mullvad -j MASQUERADE 2>/dev/null || true
wg-quick down mullvad 2>/dev/null
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || true
echo "Mullvad WG stopped. AWG clients exit through VPS directly (132.243.162.177)"

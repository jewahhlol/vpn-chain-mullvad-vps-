#!/bin/bash
# Mullvad server rotation for reverse chain
# Usage: mullvad-rotate [country-code] [city-code]
# Examples:
#   mullvad-rotate              - show current + list countries
#   mullvad-rotate us           - random US server
#   mullvad-rotate de ber       - Berlin server
#   mullvad-rotate ch zrh       - Zurich server
#   mullvad-rotate list us      - list all US servers

GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; RED="\e[31m"; RESET="\e[0m"
SERVERS="/etc/wireguard/mullvad-servers.json"
CONF="/etc/wireguard/mullvad.conf"
PRIVKEY=$(cat /etc/wireguard/mullvad_private.key)
ADDRESS=$(grep Address /etc/wireguard/mullvad.conf | awk '{print $3}')

if [ ! -f "$SERVERS" ]; then
    echo -e "${RED}Server list not found. Downloading...${RESET}"
    curl -s https://api.mullvad.net/www/relays/wireguard/ | python3 -c '
import json,sys
data = json.load(sys.stdin)
with open("'$SERVERS'","w") as f:
    json.dump([{"host":r["hostname"],"ip":r["ipv4_addr_in"],"pubkey":r["pubkey"],"country":r["country_name"],"city":r["city_name"]} for r in data if r["active"]], f, indent=2)
print(f"Downloaded {len(data)} servers")
'
fi

show_current() {
    if wg show mullvad 2>/dev/null | grep -q "latest handshake"; then
        CURRENT_EP=$(wg show mullvad endpoints | awk '{print $2}' | cut -d: -f1)
        CURRENT_HOST=$(python3 -c "
import json
for s in json.load(open('$SERVERS')):
    if s['ip']=='$CURRENT_EP':
        print(f\"{s['host']} ({s['country']}, {s['city']})\")
        break
" 2>/dev/null)
        MULLVAD_IP=$(curl -s --connect-timeout 5 --interface mullvad ifconfig.me 2>/dev/null)
        echo -e "${GREEN}Current: $CURRENT_HOST${RESET}"
        echo -e "${GREEN}Exit IP: $MULLVAD_IP${RESET}"
    else
        echo -e "${YELLOW}Mullvad WG: not connected${RESET}"
    fi
}

list_countries() {
    python3 -c "
import json
servers = json.load(open('$SERVERS'))
countries = {}
for s in servers:
    code = s['host'].split('-')[0]
    if code not in countries:
        countries[code] = s['country']
for code in sorted(countries):
    print(f'  {code:4s} {countries[code]}')
"
}

list_servers() {
    FILTER="$1"
    python3 -c "
import json
for s in json.load(open('$SERVERS')):
    if s['host'].startswith('$FILTER'):
        print(f\"  {s['host']:25s} {s['ip']:16s} {s['country']}, {s['city']}\")
"
}

rotate_to() {
    COUNTRY="$1"
    CITY="$2"

    SERVER=$(python3 -c "
import json, random
servers = json.load(open('$SERVERS'))
filtered = [s for s in servers if s['host'].startswith('$COUNTRY')]
if '$CITY':
    city_filtered = [s for s in filtered if '-$CITY-' in s['host']]
    if city_filtered:
        filtered = city_filtered
if not filtered:
    print('NONE')
else:
    s = random.choice(filtered)
    print(f\"{s['ip']}|{s['pubkey']}|{s['host']}|{s['country']}, {s['city']}\")
")

    if [ "$SERVER" = "NONE" ]; then
        echo -e "${RED}No servers found for: $COUNTRY $CITY${RESET}"
        return 1
    fi

    IP=$(echo "$SERVER" | cut -d'|' -f1)
    PUBKEY=$(echo "$SERVER" | cut -d'|' -f2)
    HOST=$(echo "$SERVER" | cut -d'|' -f3)
    LOCATION=$(echo "$SERVER" | cut -d'|' -f4)

    echo -e "${CYAN}Switching to: $HOST ($LOCATION)${RESET}"

    # Stop current
    wg-quick down mullvad 2>/dev/null

    # Remove old endpoint route
    ip route del $(grep Endpoint $CONF | awk '{print $3}' | cut -d: -f1)/32 2>/dev/null

    # Write new config
    cat > $CONF << CONF
[Interface]
PrivateKey = $PRIVKEY
Address = $ADDRESS
DNS = 100.64.0.3
Table = 42

[Peer]
PublicKey = $PUBKEY
Endpoint = $IP:51820
AllowedIPs = 0.0.0.0/0
CONF

    # Add route to new endpoint
    ORIG_GW=$(ip route | grep 'default via' | grep -v mullvad | head -1 | awk '{print $3}')
    ip route add $IP/32 via $ORIG_GW dev eth0 2>/dev/null

    # Start
    wg-quick up mullvad 2>&1 | grep -v "^#"

    # Re-apply policy routing for AWG clients
    ip rule add from 10.9.9.0/24 table 42 priority 100 2>/dev/null
    iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null
    iptables -t nat -A POSTROUTING -o mullvad -j MASQUERADE 2>/dev/null

    sleep 2
    MULLVAD_IP=$(curl -s --connect-timeout 5 --interface mullvad ifconfig.me 2>/dev/null)
    echo -e "${GREEN}New exit IP: $MULLVAD_IP${RESET}"
}

case "$1" in
    "")
        show_current
        echo ""
        echo "Countries:"
        list_countries
        echo ""
        echo "Usage: mullvad-rotate <country> [city]"
        ;;
    list)
        list_servers "$2"
        ;;
    update)
        curl -s https://api.mullvad.net/www/relays/wireguard/ | python3 -c '
import json,sys
data = json.load(sys.stdin)
with open("'$SERVERS'","w") as f:
    json.dump([{"host":r["hostname"],"ip":r["ipv4_addr_in"],"pubkey":r["pubkey"],"country":r["country_name"],"city":r["city_name"]} for r in data if r["active"]], f, indent=2)
print(f"Updated: {len(data)} servers")
'
        ;;
    *)
        rotate_to "$1" "$2"
        ;;
esac

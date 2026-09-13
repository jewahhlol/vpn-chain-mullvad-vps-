#!/bin/bash
set -e

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; RESET="\e[0m"

echo -e "${CYAN}================================================"
echo "  vpn-chain: Mullvad WireGuard Setup (VPS)"
echo "  Enables reverse mode (exit through Mullvad)"
echo -e "================================================${RESET}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Run as root${RESET}"
    exit 1
fi

# Install WireGuard tools
echo -e "${CYAN}[*] Installing WireGuard tools...${RESET}"
apt-get install -y -qq wireguard-tools

# Generate keys
echo -e "${CYAN}[*] Generating Mullvad WireGuard keys...${RESET}"
mkdir -p /etc/wireguard
WG_PRIV=$(wg genkey)
WG_PUB=$(echo $WG_PRIV | wg pubkey)
echo $WG_PRIV > /etc/wireguard/mullvad_private.key
echo $WG_PUB > /etc/wireguard/mullvad_public.key
chmod 600 /etc/wireguard/mullvad_private.key

echo ""
echo -e "${YELLOW}Your Mullvad WireGuard public key:${RESET}"
echo -e "${GREEN}$WG_PUB${RESET}"
echo ""
echo -e "${YELLOW}Register this key with Mullvad:${RESET}"
echo -e "  curl -sSL https://api.mullvad.net/wg/ -d account=YOUR_ACCOUNT_NUMBER --data-urlencode pubkey=$WG_PUB"
echo ""
read -p "Paste the IP address Mullvad returned (e.g., 10.68.x.x/32): " MULLVAD_ADDR

if [ -z "$MULLVAD_ADDR" ]; then
    echo -e "${RED}No address provided. Exiting.${RESET}"
    exit 1
fi

# Add /32 if not present
echo "$MULLVAD_ADDR" | grep -q "/" || MULLVAD_ADDR="${MULLVAD_ADDR}/32"

# Download server list
echo -e "${CYAN}[*] Downloading Mullvad server list...${RESET}"
curl -s https://api.mullvad.net/www/relays/wireguard/ | python3 -c '
import json,sys
data = json.load(sys.stdin)
servers = [{"host":r["hostname"],"ip":r["ipv4_addr_in"],"pubkey":r["pubkey"],"country":r["country_name"],"city":r["city_name"]} for r in data if r["active"]]
with open("/etc/wireguard/mullvad-servers.json","w") as f:
    json.dump(servers, f, indent=2)
print(f"Downloaded {len(servers)} servers")
'

# Pick a default server (Switzerland, Zurich)
DEFAULT_SERVER=$(python3 -c "
import json
for s in json.load(open('/etc/wireguard/mullvad-servers.json')):
    if 'ch-zrh' in s['host']:
        print(f\"{s['ip']}|{s['pubkey']}|{s['host']}\")
        break
")
DEFAULT_IP=$(echo "$DEFAULT_SERVER" | cut -d'|' -f1)
DEFAULT_PUBKEY=$(echo "$DEFAULT_SERVER" | cut -d'|' -f2)
DEFAULT_HOST=$(echo "$DEFAULT_SERVER" | cut -d'|' -f3)

echo -e "${GREEN}[+] Default server: $DEFAULT_HOST ($DEFAULT_IP)${RESET}"

# Create Mullvad WG config
cat > /etc/wireguard/mullvad.conf << CONF
[Interface]
PrivateKey = $WG_PRIV
Address = $MULLVAD_ADDR
DNS = 100.64.0.3
Table = 42

[Peer]
PublicKey = $DEFAULT_PUBKEY
Endpoint = $DEFAULT_IP:51820
AllowedIPs = 0.0.0.0/0
CONF
chmod 600 /etc/wireguard/mullvad.conf

# Install management scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/mullvad-wg-start.sh" /usr/local/bin/mullvad-wg-start.sh
cp "$SCRIPT_DIR/mullvad-wg-stop.sh" /usr/local/bin/mullvad-wg-stop.sh
cp "$SCRIPT_DIR/mullvad-rotate.sh" /usr/local/bin/mullvad-rotate
chmod +x /usr/local/bin/mullvad-wg-start.sh /usr/local/bin/mullvad-wg-stop.sh /usr/local/bin/mullvad-rotate

# Create systemd service
cat > /etc/systemd/system/mullvad-wg.service << SVC
[Unit]
Description=Mullvad WireGuard for reverse chain
After=network-online.target awg-quick@awg0.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/mullvad-wg-start.sh
ExecStop=/usr/local/bin/mullvad-wg-stop.sh

[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload

echo ""
echo -e "${CYAN}================================================"
echo "  MULLVAD WG SETUP COMPLETE"
echo -e "================================================${RESET}"
echo ""
echo -e "${GREEN}Commands:${RESET}"
echo "  mullvad-wg-start.sh          Start Mullvad WG"
echo "  mullvad-wg-stop.sh           Stop Mullvad WG"
echo "  mullvad-rotate us            Rotate to US server"
echo "  mullvad-rotate de ber        Rotate to Berlin"
echo "  mullvad-rotate               Show current + list countries"
echo "  systemctl start mullvad-wg   Start via systemd"
echo ""
echo -e "${GREEN}To activate now:${RESET}"
echo "  mullvad-wg-start.sh"

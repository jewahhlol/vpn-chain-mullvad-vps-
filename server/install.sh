#!/bin/bash
set -e

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; RESET="\e[0m"

echo -e "${CYAN}================================================"
echo "  vpn-chain: VPS Server Setup"
echo "  AmneziaWG server + IP forwarding"
echo -e "================================================${RESET}"
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Run as root${RESET}"
    exit 1
fi

# Detect OS
if [ -f /etc/debian_version ]; then
    OS="debian"
    CODENAME=$(lsb_release -cs 2>/dev/null || echo "bookworm")
elif [ -f /etc/lsb-release ]; then
    OS="ubuntu"
    CODENAME=$(lsb_release -cs)
else
    echo -e "${RED}Unsupported OS. Need Debian 12+ or Ubuntu 22.04+${RESET}"
    exit 1
fi
echo -e "${GREEN}[+] Detected: $OS ($CODENAME)${RESET}"

# Install dependencies
echo -e "${CYAN}[*] Installing dependencies...${RESET}"
apt-get update -qq
apt-get install -y -qq curl wget gnupg2 iptables linux-headers-$(uname -r) 2>/dev/null || \
    apt-get install -y -qq curl wget gnupg2 iptables linux-headers-amd64

# Install AmneziaWG
echo -e "${CYAN}[*] Installing AmneziaWG...${RESET}"
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 57290828 2>/dev/null
echo "deb https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main" > /etc/apt/sources.list.d/amnezia.list
apt-get update -qq
apt-get install -y amneziawg

# Load module
modprobe amneziawg 2>/dev/null || {
    echo -e "${YELLOW}[!] AmneziaWG module not loaded. You may need to reboot and re-run this script.${RESET}"
    echo -e "${YELLOW}[!] Run: reboot && cd $(pwd) && ./install.sh${RESET}"
    exit 1
}
echo -e "${GREEN}[+] AmneziaWG module loaded${RESET}"

# Generate keys
echo -e "${CYAN}[*] Generating keys...${RESET}"
SERVER_PRIV=$(awg genkey)
SERVER_PUB=$(echo $SERVER_PRIV | awg pubkey)
CLIENT_PRIV=$(awg genkey)
CLIENT_PUB=$(echo $CLIENT_PRIV | awg pubkey)

# Generate obfuscation parameters
JC=$((RANDOM % 10 + 3))
JMIN=$((RANDOM % 50 + 50))
JMAX=$((JMIN + RANDOM % 100 + 30))
S1=$((RANDOM % 200 + 10))
S2=$((RANDOM % 200 + 10))
S3=$((RANDOM % 200 + 10))
S4=$((RANDOM % 200 + 10))
H1=$((RANDOM * RANDOM))
H2=$((RANDOM * RANDOM))
H3=$((RANDOM * RANDOM))
H4=$((RANDOM * RANDOM))
I1=$((RANDOM % 200 + 50))

# Detect default interface
DEFAULT_IF=$(ip route | grep 'default via' | head -1 | awk '{print $5}')
VPS_IP=$(ip -4 addr show $DEFAULT_IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
AWG_PORT=5000

echo -e "${GREEN}[+] VPS IP: $VPS_IP${RESET}"
echo -e "${GREEN}[+] Interface: $DEFAULT_IF${RESET}"
echo -e "${GREEN}[+] AWG port: $AWG_PORT${RESET}"

# Create server config
mkdir -p /etc/amnezia/amneziawg
cat > /etc/amnezia/amneziawg/awg0.conf << CONF
[Interface]
Address = 10.9.9.1/24
ListenPort = $AWG_PORT
PrivateKey = $SERVER_PRIV
MTU = 1280
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
S3 = $S3
S4 = $S4
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4
I1 = $I1
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $DEFAULT_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $DEFAULT_IF -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.9.9.3/32
CONF
chmod 600 /etc/amnezia/amneziawg/awg0.conf

# Enable IP forwarding
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-forward.conf
sysctl -w net.ipv4.ip_forward=1

# Start and enable AWG
awg-quick up awg0
systemctl enable awg-quick@awg0 2>/dev/null || true

echo -e "${GREEN}[+] AmneziaWG server running on port $AWG_PORT${RESET}"

# Generate client config
CLIENT_CONF="/root/client.conf"
cat > $CLIENT_CONF << CONF
[Interface]
Address = 10.9.9.3/32
PrivateKey = $CLIENT_PRIV
DNS = 1.1.1.1
MTU = 1280
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
S3 = $S3
S4 = $S4
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4
I1 = $I1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $VPS_IP:$AWG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25

[Socks5]
BindAddress = 127.0.0.1:1080
CONF

echo ""
echo -e "${CYAN}================================================"
echo "  SETUP COMPLETE"
echo -e "================================================${RESET}"
echo ""
echo -e "${YELLOW}Client config saved to: $CLIENT_CONF${RESET}"
echo -e "${YELLOW}Copy it to your VM as /etc/wireproxy-awg.conf${RESET}"
echo ""
echo -e "${CYAN}--- CLIENT CONFIG (copy this) ---${RESET}"
cat $CLIENT_CONF
echo -e "${CYAN}--- END CONFIG ---${RESET}"
echo ""
echo -e "${GREEN}Next steps:${RESET}"
echo "  1. Copy the client config above to your attack VM"
echo "  2. On the VM: cd vpn-chain/client && sudo ./install.sh"
echo "  3. On the VM: sudo vpn-chain start"
echo ""
echo -e "${GREEN}For reverse mode (Mullvad exit rotation):${RESET}"
echo "  Run: ./setup-mullvad-wg.sh"

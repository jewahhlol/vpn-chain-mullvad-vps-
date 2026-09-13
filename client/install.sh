#!/bin/bash
set -e

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; RESET="\e[0m"

echo -e "${CYAN}================================================"
echo "  vpn-chain: Client VM Setup"
echo "  wireproxy-awg + redsocks + vpn-chain command"
echo -e "================================================${RESET}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Run as root (sudo ./install.sh)${RESET}"
    exit 1
fi

ARCH=$(uname -m)
case $ARCH in
    x86_64) ARCH_NAME="amd64" ;;
    aarch64) ARCH_NAME="arm64" ;;
    *) echo -e "${RED}Unsupported architecture: $ARCH${RESET}"; exit 1 ;;
esac

# Install redsocks
echo -e "${CYAN}[*] Installing redsocks...${RESET}"
apt-get update -qq
apt-get install -y -qq redsocks curl wget

# Install wireproxy-awg
echo -e "${CYAN}[*] Installing wireproxy-awg...${RESET}"
LATEST=$(curl -s https://api.github.com/repos/artem-russkikh/wireproxy-awg/releases/latest | grep tag_name | cut -d'"' -f4)
if [ -z "$LATEST" ]; then
    LATEST="v1.0.17"
fi
echo -e "${GREEN}[+] Latest version: $LATEST${RESET}"

curl -sL "https://github.com/artem-russkikh/wireproxy-awg/releases/download/${LATEST}/wireproxy_linux_${ARCH_NAME}.tar.gz" -o /tmp/wireproxy-awg.tar.gz
tar xzf /tmp/wireproxy-awg.tar.gz -C /tmp/
mv /tmp/wireproxy /usr/local/bin/wireproxy-awg
chmod +x /usr/local/bin/wireproxy-awg
echo -e "${GREEN}[+] wireproxy-awg $(wireproxy-awg --version 2>&1)${RESET}"

# Install redsocks config
echo -e "${CYAN}[*] Configuring redsocks...${RESET}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/redsocks.conf" /etc/redsocks.conf
systemctl stop redsocks 2>/dev/null || true
systemctl disable redsocks 2>/dev/null || true

# Install vpn-chain script
echo -e "${CYAN}[*] Installing vpn-chain command...${RESET}"
cp "$SCRIPT_DIR/vpn-chain.sh" /opt/vpn-chain.sh
chmod +x /opt/vpn-chain.sh
ln -sf /opt/vpn-chain.sh /usr/sbin/vpn-chain

# Install wireproxy-awg config template if no config exists
if [ ! -f /etc/wireproxy-awg.conf ]; then
    cp "$SCRIPT_DIR/wireproxy-awg.conf.example" /etc/wireproxy-awg.conf
    chmod 600 /etc/wireproxy-awg.conf
    echo -e "${YELLOW}[!] Created /etc/wireproxy-awg.conf from template${RESET}"
    echo -e "${YELLOW}[!] Edit it with your VPS connection details${RESET}"
else
    echo -e "${GREEN}[+] /etc/wireproxy-awg.conf already exists, keeping it${RESET}"
fi

# Install dnscrypt-proxy (DNS leak prevention)
echo -e "${CYAN}[*] Installing dnscrypt-proxy (DNS-over-HTTPS)...${RESET}"
apt-get install -y -qq dnscrypt-proxy
# Configure: listen on 127.0.0.53, force TCP (redsocks catches TCP → chain)
sed -i "s/^listen_addresses.*/listen_addresses = ['127.0.0.53:53']/" /etc/dnscrypt-proxy/dnscrypt-proxy.toml
sed -i "/^force_tcp/d" /etc/dnscrypt-proxy/dnscrypt-proxy.toml
sed -i "/^proxy/d" /etc/dnscrypt-proxy/dnscrypt-proxy.toml
sed -i "/^listen_addresses/a force_tcp = true\nproxy = \"socks5://127.0.0.1:1080\"" /etc/dnscrypt-proxy/dnscrypt-proxy.toml
systemctl restart dnscrypt-proxy
systemctl enable dnscrypt-proxy
# Lock resolv.conf to use dnscrypt-proxy
chattr -i /etc/resolv.conf 2>/dev/null || true
echo "nameserver 127.0.0.53" > /etc/resolv.conf
chattr +i /etc/resolv.conf
echo -e "${GREEN}[+] dnscrypt-proxy configured (DNS-over-HTTPS, no leaks)${RESET}"

# Cleanup
rm -f /tmp/wireproxy-awg.tar.gz

echo ""
echo -e "${CYAN}================================================"
echo "  CLIENT SETUP COMPLETE"
echo -e "================================================${RESET}"
echo ""
echo -e "${GREEN}Next steps:${RESET}"
echo "  1. Edit /etc/wireproxy-awg.conf with config from VPS setup"
echo "  2. For forward mode: install Mullvad VPN (see docs/mullvad-setup.md)"
echo "  3. Run: sudo vpn-chain start"
echo ""
echo -e "${GREEN}Commands:${RESET}"
echo "  sudo vpn-chain start          Forward mode (Mullvad → VPS)"
echo "  sudo vpn-chain start reverse  Reverse mode (VPS → Mullvad)"
echo "  sudo vpn-chain stop           Stop everything"
echo "  sudo vpn-chain status         Check status"
echo "  sudo vpn-chain check          Verify all traffic goes through chain"

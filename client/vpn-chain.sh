#!/bin/bash
# vpn-chain — double VPN chain manager
# Forward: Kali → Mullvad → VPS (exit = VPS IP)
# Reverse: Kali → VPS → Mullvad (exit = Mullvad IP, rotatable)

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; RESET="\e[0m"

# Extract VPS IP from wireproxy config
VPS_IP=$(grep -A5 '\[Peer\]' /etc/wireproxy-awg.conf | grep Endpoint | awk '{print $3}' | cut -d: -f1)
if [ -z "$VPS_IP" ]; then
    echo -e "${RED}Cannot read VPS IP from /etc/wireproxy-awg.conf${RESET}"
    exit 1
fi

# SSH to VPS (through tunnel if available, otherwise direct)
vps_cmd() {
    if ip route get 10.9.9.1 &>/dev/null && ssh -o ConnectTimeout=3 -o BatchMode=yes root@10.9.9.1 true 2>/dev/null; then
        ssh -o ConnectTimeout=5 -o BatchMode=yes root@10.9.9.1 "$1" 2>/dev/null
    else
        ssh -o ConnectTimeout=5 -o BatchMode=yes root@$VPS_IP "$1" 2>/dev/null
    fi
}

stop_all() {
    iptables -t nat -D OUTPUT -p tcp -j REDSOCKS 2>/dev/null
    iptables -t nat -F REDSOCKS 2>/dev/null
    iptables -t nat -X REDSOCKS 2>/dev/null
    ip6tables -P OUTPUT ACCEPT 2>/dev/null
    ip6tables -F 2>/dev/null
    killall redsocks 2>/dev/null
    pkill -f wireproxy-awg 2>/dev/null
    echo -e "${GREEN}[+] All chains stopped${RESET}"
}

setup_redsocks_iptables() {
    killall redsocks 2>/dev/null
    redsocks -c /etc/redsocks.conf
    echo -e "${GREEN}[+] redsocks started${RESET}"

    iptables -t nat -N REDSOCKS 2>/dev/null || iptables -t nat -F REDSOCKS
    iptables -t nat -A REDSOCKS -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A REDSOCKS -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A REDSOCKS -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A REDSOCKS -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A REDSOCKS -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A REDSOCKS -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A REDSOCKS -d 224.0.0.0/4 -j RETURN
    iptables -t nat -A REDSOCKS -d 240.0.0.0/4 -j RETURN
    iptables -t nat -A REDSOCKS -d $VPS_IP -j RETURN
    iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports 12345
    iptables -t nat -A OUTPUT -p tcp -j REDSOCKS
    ip6tables -P OUTPUT DROP
    ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null
    echo -e "${GREEN}[+] iptables configured (IPv6 blocked)${RESET}"
}

start_wireproxy() {
    if ! pgrep -f wireproxy-awg > /dev/null; then
        /usr/local/bin/wireproxy-awg -c /etc/wireproxy-awg.conf &>/dev/null &
        sleep 3
    fi
    if pgrep -f wireproxy-awg > /dev/null; then
        echo -e "${GREEN}[+] wireproxy-awg running (SOCKS5 127.0.0.1:1080)${RESET}"
    else
        echo -e "${RED}[-] wireproxy-awg FAILED to start${RESET}"
        return 1
    fi
}

start_forward() {
    echo -e "${CYAN}[*] FORWARD: VM -> Mullvad -> VPS${RESET}"
    echo -e "${CYAN}[*] Exit IP: $VPS_IP${RESET}"
    echo ""

    # Stop Mullvad WG on VPS (so traffic exits through VPS directly)
    echo -e "${YELLOW}[*] Switching VPS to direct mode...${RESET}"
    vps_cmd "mullvad-wg-stop.sh 2>/dev/null; echo ok" && \
        echo -e "${GREEN}[+] VPS: Mullvad WG stopped (direct exit)${RESET}" || \
        echo -e "${YELLOW}[!] Could not reach VPS via SSH (configure manually)${RESET}"

    if ! command -v mullvad &>/dev/null; then
        echo -e "${RED}[-] Mullvad not installed. Install it first (see docs/mullvad-setup.md)${RESET}"
        return 1
    fi

    # Unlock resolv.conf so Mullvad can set its DNS
    chattr -i /etc/resolv.conf 2>/dev/null
    if ! mullvad status 2>/dev/null | grep -q "Connected"; then
        echo -e "${YELLOW}[!] Connecting Mullvad...${RESET}"
        mullvad connect
        sleep 3
    fi
    echo -e "${GREEN}[+] Mullvad: $(mullvad status | head -1)${RESET}"

    start_wireproxy || return 1
    setup_redsocks_iptables

    echo ""
    echo -e "${CYAN}[*] Verifying...${RESET}"
    IP=$(curl -4 -s --connect-timeout 10 ifconfig.me)
    if [ "$IP" = "$VPS_IP" ]; then
        echo -e "${GREEN}[+] SUCCESS! Exit IP: $IP (VPS)${RESET}"
    else
        echo -e "${RED}[-] UNEXPECTED IP: $IP (expected $VPS_IP)${RESET}"
    fi
}

start_reverse() {
    echo -e "${CYAN}[*] REVERSE: VM -> VPS -> Mullvad${RESET}"
    echo -e "${CYAN}[*] Exit IP: Mullvad (rotatable)${RESET}"
    echo ""

    mullvad disconnect 2>/dev/null
    echo -e "${GREEN}[+] Mullvad disconnected (not needed in reverse mode)${RESET}"

    # Lock DNS to dnscrypt-proxy (prevent leaks in reverse mode)
    chattr -i /etc/resolv.conf 2>/dev/null
    echo "nameserver 127.0.0.53" > /etc/resolv.conf
    chattr +i /etc/resolv.conf

    start_wireproxy || return 1
    setup_redsocks_iptables

    # Start Mullvad WG on VPS (so traffic exits through Mullvad)
    echo -e "${YELLOW}[*] Switching VPS to Mullvad exit...${RESET}"
    vps_cmd "mullvad-wg-start.sh 2>/dev/null; echo ok" && \
        echo -e "${GREEN}[+] VPS: Mullvad WG started${RESET}" || \
        echo -e "${YELLOW}[!] Could not reach VPS via SSH (run mullvad-wg-start.sh on VPS manually)${RESET}"

    echo ""
    echo -e "${CYAN}[*] Verifying...${RESET}"
    IP=$(curl -4 -s --connect-timeout 10 ifconfig.me)
    echo -e "${GREEN}[+] Exit IP: $IP (Mullvad)${RESET}"
}

case "$1" in
    start)
        stop_all
        if [ "$2" = "reverse" ]; then
            start_reverse
        else
            start_forward
        fi
        ;;
    stop)
        stop_all
        chattr -i /etc/resolv.conf 2>/dev/null
        mullvad disconnect 2>/dev/null
        ;;
    status)
        echo -e "${CYAN}=== VPN Chain Status ===${RESET}"
        echo ""
        MULLVAD_STATUS=$(mullvad status 2>/dev/null | head -1 || echo "not installed")
        echo -e "${YELLOW}Mullvad:${RESET}       $MULLVAD_STATUS"
        echo -e "${YELLOW}wireproxy-awg:${RESET} $(pgrep -f wireproxy-awg > /dev/null && echo -e "${GREEN}running${RESET}" || echo -e "${RED}stopped${RESET}")"
        echo -e "${YELLOW}redsocks:${RESET}      $(pgrep redsocks > /dev/null && echo -e "${GREEN}running${RESET}" || echo -e "${RED}stopped${RESET}")"
        echo -e "${YELLOW}iptables:${RESET}      $(iptables -t nat -L REDSOCKS 2>/dev/null | grep -q REDIRECT && echo -e "${GREEN}active${RESET}" || echo -e "${RED}inactive${RESET}")"
        echo -e "${YELLOW}dnscrypt-proxy:${RESET}$(systemctl is-active dnscrypt-proxy 2>/dev/null | grep -q active && echo -e " ${GREEN}running${RESET}" || echo -e " ${RED}stopped${RESET}")"
        echo ""
        echo -e "${YELLOW}Exit IP:${RESET} $(curl -4 -s --connect-timeout 5 ifconfig.me)"
        echo -e "${YELLOW}VPS IP:${RESET}  $VPS_IP"
        echo -e "${YELLOW}DNS:${RESET}     $(grep nameserver /etc/resolv.conf | awk '{print $2}')"
        ;;
    check)
        echo -e "${CYAN}=== Full Chain Verification ===${RESET}"
        echo -e "${YELLOW}curl:${RESET}    $(curl -4 -s --connect-timeout 5 ifconfig.me)"
        echo -e "${YELLOW}wget:${RESET}    $(wget -4 -qO- --timeout=5 ifconfig.me 2>/dev/null)"
        echo -e "${YELLOW}python:${RESET}  $(python3 -c "import urllib.request; print(urllib.request.urlopen('http://ifconfig.me').read().decode().strip())" 2>/dev/null)"
        echo -e "${YELLOW}DNS:${RESET}     $(nslookup example.com 2>/dev/null | grep Server | awk '{print $2}')"
        DNS_EXT=$(nslookup -type=txt o-o.myaddr.l.google.com ns1.google.com 2>/dev/null | grep text | head -1 | tr -d '"' | awk '{print $NF}')
        echo -e "${YELLOW}DNS exit:${RESET}$([ -n "$DNS_EXT" ] && echo " $DNS_EXT" || echo " could not determine")"
        ;;
    *)
        echo "vpn-chain — double VPN chain manager"
        echo ""
        echo "Usage: vpn-chain {start|start reverse|stop|status|check}"
        echo ""
        echo "  start          FORWARD: VM -> Mullvad -> VPS (exit = $VPS_IP)"
        echo "  start reverse  REVERSE: VM -> VPS -> Mullvad (exit = Mullvad IP)"
        echo "  stop           Stop all chains"
        echo "  status         Component status + exit IP"
        echo "  check          Verify all apps exit through chain"
        ;;
esac

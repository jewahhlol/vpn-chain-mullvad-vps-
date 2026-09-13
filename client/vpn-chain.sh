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

    mullvad dns set custom 127.0.0.53 2>/dev/null
    if ! mullvad status 2>/dev/null | grep -q "Connected"; then
        echo -e "${YELLOW}[!] Connecting Mullvad...${RESET}"
        chattr -i /etc/resolv.conf 2>/dev/null
        mullvad connect
        sleep 3
    fi
    echo -e "${GREEN}[+] Mullvad: $(mullvad status | head -1)${RESET}"

    # Lock DNS to dnscrypt-proxy (prevent Mullvad DNS from leaking chain structure)
    chattr -i /etc/resolv.conf 2>/dev/null
    echo "nameserver 127.0.0.53" > /etc/resolv.conf
    chattr +i /etc/resolv.conf

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
        echo ""

        # Exit IP from multiple apps
        CURL_IP=$(curl -4 -s --connect-timeout 10 ifconfig.me)
        WGET_IP=$(wget -4 -qO- --timeout=10 --header="User-Agent: curl/8.0" ifconfig.me 2>/dev/null)
        PY_IP=$(python3 -c "import urllib.request; print(urllib.request.urlopen('http://ifconfig.me').read().decode().strip())" 2>/dev/null)
        echo -e "${YELLOW}curl:${RESET}      ${CURL_IP:-FAILED}"
        echo -e "${YELLOW}wget:${RESET}      ${WGET_IP:-FAILED}"
        echo -e "${YELLOW}python:${RESET}    ${PY_IP:-FAILED}"

        # Check all apps show same IP
        if [ "$CURL_IP" = "$WGET_IP" ] && [ "$CURL_IP" = "$PY_IP" ] && [ -n "$CURL_IP" ]; then
            echo -e "${GREEN}[+] All apps exit through same IP${RESET}"
        else
            echo -e "${RED}[-] WARNING: Apps show different IPs!${RESET}"
        fi
        echo ""

        # DNS check
        DNS_SERVER=$(nslookup example.com 2>/dev/null | grep Server | awk '{print $2}')
        echo -e "${YELLOW}DNS server:${RESET}  ${DNS_SERVER:-FAILED}"
        if [ "$DNS_SERVER" = "127.0.0.53" ]; then
            echo -e "${GREEN}[+] DNS goes through dnscrypt-proxy (no leaks)${RESET}"
        else
            echo -e "${RED}[-] WARNING: DNS may be leaking (expected 127.0.0.53)${RESET}"
        fi
        echo ""

        # IPv6 check
        IPV6=$(curl -6 -s --connect-timeout 5 ifconfig.me 2>/dev/null)
        if [ -z "$IPV6" ]; then
            echo -e "${GREEN}[+] IPv6: blocked (no leaks)${RESET}"
        else
            echo -e "${RED}[-] WARNING: IPv6 is leaking! ($IPV6)${RESET}"
        fi

        # Detect mode and verify chain
        MULLVAD_STATUS=$(mullvad status 2>/dev/null | head -1)
        echo ""
        if echo "$MULLVAD_STATUS" | grep -q "Connected"; then
            echo -e "${CYAN}--- FORWARD MODE ---${RESET}"
            MULLVAD_RELAY=$(mullvad status 2>/dev/null | grep Relay | awk '{print $2}')
            MULLVAD_LOCATION=$(mullvad status 2>/dev/null | grep "Visible location" | sed 's/.*Visible location:[[:space:]]*//')
            echo -e "${YELLOW}Mullvad relay:${RESET}  $MULLVAD_RELAY"
            echo -e "${YELLOW}Mullvad location:${RESET} $MULLVAD_LOCATION"

            # Check what VPS sees as source
            VPS_PEER=$(vps_cmd "awg show | grep endpoint | awk '{print \$3}' | cut -d: -f1" 2>/dev/null)
            if [ -n "$VPS_PEER" ]; then
                echo -e "${YELLOW}VPS sees source:${RESET} $VPS_PEER"
                if [ "$VPS_PEER" != "$(curl -4 -s --connect-timeout 3 ifconfig.me/ip 2>/dev/null)" ]; then
                    echo -e "${GREEN}[+] VPS does NOT see your real IP (sees Mullvad exit)${RESET}"
                fi
            fi
            echo -e "${YELLOW}Target sees:${RESET}    $CURL_IP (VPS)"
        else
            echo -e "${CYAN}--- REVERSE MODE ---${RESET}"
            VPS_MULLVAD=$(vps_cmd "curl -s --connect-timeout 5 --interface mullvad ifconfig.me" 2>/dev/null)
            echo -e "${YELLOW}VPS Mullvad exit:${RESET} ${VPS_MULLVAD:-not running}"
            echo -e "${YELLOW}Target sees:${RESET}      $CURL_IP (Mullvad)"
        fi

        echo ""
        echo -e "${CYAN}--- SUMMARY ---${RESET}"
        ISSUES=0
        [ "$CURL_IP" = "$WGET_IP" ] && [ "$CURL_IP" = "$PY_IP" ] && [ -n "$CURL_IP" ] || { echo -e "${RED}  [!] Exit IP mismatch across apps${RESET}"; ISSUES=$((ISSUES+1)); }
        [ "$DNS_SERVER" = "127.0.0.53" ] || { echo -e "${RED}  [!] DNS leak detected${RESET}"; ISSUES=$((ISSUES+1)); }
        [ -z "$IPV6" ] || { echo -e "${RED}  [!] IPv6 leak detected${RESET}"; ISSUES=$((ISSUES+1)); }
        [ $ISSUES -eq 0 ] && echo -e "${GREEN}  All checks passed. No leaks detected.${RESET}"
        ;;
    rotate)
        shift
        ARGS="$*"
        if [ -z "$ARGS" ]; then
            vps_cmd "mullvad-rotate" && echo "" && \
            echo -e "${YELLOW}Exit IP:${RESET} $(curl -4 -s --connect-timeout 5 ifconfig.me)"
        else
            vps_cmd "mullvad-rotate $ARGS"
            sleep 2
            IP=$(curl -4 -s --connect-timeout 5 ifconfig.me)
            echo -e "${GREEN}[+] New exit IP: $IP${RESET}"
        fi
        ;;
    switch)
        shift
        if ! mullvad status 2>/dev/null | grep -q "Connected"; then
            echo -e "${RED}[-] Mullvad not connected. 'switch' is for forward mode only.${RESET}"
            echo -e "${YELLOW}    For reverse mode use: vpn-chain rotate${RESET}"
            exit 1
        fi
        if [ -z "$1" ]; then
            echo -e "${CYAN}=== Mullvad Server (Forward Mode) ===${RESET}"
            mullvad status 2>/dev/null
            echo ""
            echo "Usage: vpn-chain switch <country> [city]"
            echo ""
            echo "Examples:"
            echo "  vpn-chain switch de        Germany (random server)"
            echo "  vpn-chain switch de ber    Berlin"
            echo "  vpn-chain switch us nyc    New York"
            echo "  vpn-chain switch ch zrh    Zurich"
            echo ""
            echo "Available locations:"
            mullvad relay list 2>/dev/null | grep -E "^\S" | head -30
        else
            LOCATION="$*"
            echo -e "${CYAN}[*] Switching Mullvad to: $LOCATION${RESET}"
            mullvad relay set location $LOCATION 2>&1
            mullvad reconnect 2>&1
            sleep 5
            NEW_STATUS=$(mullvad status 2>/dev/null)
            echo -e "${GREEN}[+] $(echo "$NEW_STATUS" | head -1)${RESET}"
            echo -e "${GREEN}    $(echo "$NEW_STATUS" | grep "Visible location")${RESET}"
        fi
        ;;
    *)
        echo "vpn-chain — double VPN chain manager"
        echo ""
        echo "Usage: vpn-chain {start|start reverse|stop|status|check|rotate|switch}"
        echo ""
        echo "  start          FORWARD: VM -> Mullvad -> VPS (exit = $VPS_IP)"
        echo "  start reverse  REVERSE: VM -> VPS -> Mullvad (exit = Mullvad IP)"
        echo "  stop           Stop all chains"
        echo "  status         Component status + exit IP"
        echo "  check          Full chain verification (leak test)"
        echo "  rotate [cc]    Rotate Mullvad server (reverse mode)"
        echo "                   rotate         — show current + countries"
        echo "                   rotate us      — random US server"
        echo "                   rotate de ber  — Berlin"
        echo "  switch [cc]    Switch Mullvad server (forward mode)"
        echo "                   switch         — show current + locations"
        echo "                   switch de      — Germany"
        echo "                   switch us nyc  — New York"
        ;;
esac

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

# SSH to VPS (try public IP first, then tunnel IP)
vps_cmd() {
    ssh -o ConnectTimeout=15 -o BatchMode=yes root@$VPS_IP "$1" 2>/dev/null || \
    ssh -o ConnectTimeout=15 -o BatchMode=yes root@10.9.9.1 "$1" 2>/dev/null
}

stop_all() {
    iptables -t nat -D OUTPUT -p tcp -j REDSOCKS 2>/dev/null
    iptables -t nat -F REDSOCKS 2>/dev/null
    iptables -t nat -X REDSOCKS 2>/dev/null
    # Remove UDP leak protection rules
    iptables -D OUTPUT -p udp -j DROP 2>/dev/null
    iptables -D OUTPUT -p udp --dport 53 -d 127.0.0.53 -j ACCEPT 2>/dev/null
    iptables -D OUTPUT -p udp -d $VPS_IP -j ACCEPT 2>/dev/null
    iptables -D OUTPUT -p udp -d 10.0.0.0/8 -j ACCEPT 2>/dev/null
    iptables -D OUTPUT -p udp -d 127.0.0.0/8 -j ACCEPT 2>/dev/null
    iptables -D OUTPUT -p udp -d 192.168.0.0/16 -j ACCEPT 2>/dev/null
    ip6tables -P OUTPUT ACCEPT 2>/dev/null
    ip6tables -F 2>/dev/null
    killall redsocks 2>/dev/null
    pkill -f wireproxy-awg 2>/dev/null
    # Restore normal DNS so internet works without the chain
    chattr -i /etc/resolv.conf 2>/dev/null
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    # Remove SOCKS5 proxy from dnscrypt-proxy so it works standalone on next boot
    if [ -f /etc/dnscrypt-proxy/dnscrypt-proxy.toml ]; then
        sed -i '/^proxy/d' /etc/dnscrypt-proxy/dnscrypt-proxy.toml
        systemctl restart dnscrypt-proxy 2>/dev/null
    fi
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
    # Block outgoing UDP (except DNS to dnscrypt and VPS for wireproxy) to prevent QUIC/UDP leaks
    iptables -A OUTPUT -p udp --dport 53 -d 127.0.0.53 -j ACCEPT
    iptables -A OUTPUT -p udp -d $VPS_IP -j ACCEPT
    iptables -A OUTPUT -p udp -d 10.0.0.0/8 -j ACCEPT
    iptables -A OUTPUT -p udp -d 127.0.0.0/8 -j ACCEPT
    iptables -A OUTPUT -p udp -d 192.168.0.0/16 -j ACCEPT
    iptables -A OUTPUT -p udp -j DROP
    ip6tables -P OUTPUT DROP
    ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null
    echo -e "${GREEN}[+] iptables configured (IPv6 blocked, UDP leak protection)${RESET}"
}

start_wireproxy() {
    pkill -f wireproxy-awg 2>/dev/null
    sleep 1
    /usr/local/bin/wireproxy-awg -c /etc/wireproxy-awg.conf &>/dev/null &
    sleep 3
    if pgrep -f wireproxy-awg > /dev/null; then
        echo -e "${GREEN}[+] wireproxy-awg running (SOCKS5 127.0.0.1:1080)${RESET}"
    else
        echo -e "${RED}[-] wireproxy-awg FAILED to start${RESET}"
        return 1
    fi
}

# Test that SOCKS5 proxy actually works (handshake completed)
test_socks5() {
    curl -x socks5://127.0.0.1:1080 -4 -s --connect-timeout 8 ifconfig.me 2>/dev/null
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

    start_wireproxy || return 1

    # Enable SOCKS5 proxy in dnscrypt-proxy (route DNS through chain)
    if [ -f /etc/dnscrypt-proxy/dnscrypt-proxy.toml ]; then
        sed -i '/^proxy/d' /etc/dnscrypt-proxy/dnscrypt-proxy.toml
        sed -i '/^force_tcp/a proxy = "socks5://127.0.0.1:1080"' /etc/dnscrypt-proxy/dnscrypt-proxy.toml
        systemctl restart dnscrypt-proxy 2>/dev/null
    fi
    echo -e "${GREEN}[+] DNS: dnscrypt-proxy → SOCKS5 (no leaks)${RESET}"

    # Lock DNS to dnscrypt-proxy
    chattr -i /etc/resolv.conf 2>/dev/null
    echo "nameserver 127.0.0.53" > /etc/resolv.conf
    chattr +i /etc/resolv.conf
    setup_redsocks_iptables

    # Verify chain works — if not, auto-switch Mullvad servers
    FALLBACK_RELAYS="de fr nl gb ch us"
    echo ""
    echo -e "${CYAN}[*] Verifying...${RESET}"
    IP=$(test_socks5)

    if [ "$IP" = "$VPS_IP" ]; then
        RELAY_NAME=$(mullvad status 2>/dev/null | grep "Relay:" | awk '{print $NF}')
        RELAY_LOC=$(mullvad status 2>/dev/null | grep "Visible location:" | sed 's/.*location:[[:space:]]*//' | sed 's/\.  *IPv4.*//')
        echo -e "${GREEN}[+] SUCCESS! Exit IP: $IP (VPS)${RESET}"
        echo -e "${GREEN}    Mullvad: $RELAY_NAME ($RELAY_LOC)${RESET}"
    else
        echo -e "${YELLOW}[!] Chain not working with current Mullvad server. Auto-switching...${RESET}"
        for RELAY in $FALLBACK_RELAYS; do
            echo -e "${YELLOW}[*] Trying: $RELAY...${RESET}"
            mullvad relay set location $RELAY 2>/dev/null
            mullvad reconnect 2>/dev/null
            # Wait up to 15s for connection
            for _w in $(seq 1 15); do
                mullvad status 2>/dev/null | grep -q "Connected" && break
                sleep 1
            done
            if ! mullvad status 2>/dev/null | grep -q "Connected"; then
                echo -e "${RED}    [-] $RELAY: Mullvad can't connect${RESET}"
                continue
            fi
            # Restart wireproxy with new Mullvad route
            pkill -f wireproxy-awg 2>/dev/null
            sleep 1
            /usr/local/bin/wireproxy-awg -c /etc/wireproxy-awg.conf &>/dev/null &
            sleep 6
            IP=$(test_socks5)
            if [ "$IP" = "$VPS_IP" ]; then
                RELAY_NAME=$(mullvad status 2>/dev/null | grep "Relay:" | awk '{print $NF}')
                RELAY_LOC=$(mullvad status 2>/dev/null | grep "Visible location:" | sed 's/.*location:[[:space:]]*//' | sed 's/\.  *IPv4.*//')
                echo -e "${GREEN}[+] SUCCESS! Exit IP: $IP (VPS) via Mullvad $RELAY_NAME ($RELAY_LOC)${RESET}"
                break
            else
                echo -e "${RED}    [-] $RELAY: handshake failed${RESET}"
            fi
        done
        if [ "$IP" != "$VPS_IP" ]; then
            echo -e "${RED}[-] FAILED: Could not establish chain through any Mullvad server${RESET}"
            echo -e "${RED}    Try: sudo vpn-chain start reverse (doesn't need Mullvad on VM)${RESET}"
        fi
    fi
}

start_reverse() {
    echo -e "${CYAN}[*] REVERSE: VM -> VPS -> Mullvad${RESET}"
    echo -e "${CYAN}[*] Exit IP: Mullvad (rotatable)${RESET}"
    echo ""

    mullvad disconnect 2>/dev/null
    echo -e "${GREEN}[+] Mullvad disconnected (not needed in reverse mode)${RESET}"

    start_wireproxy || return 1

    # Enable SOCKS5 proxy in dnscrypt-proxy (route DNS through chain)
    if [ -f /etc/dnscrypt-proxy/dnscrypt-proxy.toml ]; then
        sed -i '/^proxy/d' /etc/dnscrypt-proxy/dnscrypt-proxy.toml
        sed -i '/^force_tcp/a proxy = "socks5://127.0.0.1:1080"' /etc/dnscrypt-proxy/dnscrypt-proxy.toml
        systemctl restart dnscrypt-proxy 2>/dev/null
    fi
    echo -e "${GREEN}[+] DNS: dnscrypt-proxy → SOCKS5 (no leaks)${RESET}"

    # Lock DNS to dnscrypt-proxy
    chattr -i /etc/resolv.conf 2>/dev/null
    echo "nameserver 127.0.0.53" > /etc/resolv.conf
    chattr +i /etc/resolv.conf
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

        # Get VM's local IP for comparison
        VM_LOCAL_IP=$(ip -4 addr show $(ip route | grep 'default via' | head -1 | awk '{print $5}') 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

        # Detect mode and verify chain
        MULLVAD_STATUS=$(mullvad status 2>/dev/null | head -1)
        CHAIN_OK=true
        echo ""
        if echo "$MULLVAD_STATUS" | grep -q "Connected"; then
            echo -e "${CYAN}--- CHAIN: You → Mullvad → VPS → Target ---${RESET}"
            echo ""

            # Link 1: VM → Mullvad
            MULLVAD_RELAY=$(mullvad status 2>/dev/null | grep Relay | awk '{print $2}')
            MULLVAD_LOCATION=$(mullvad status 2>/dev/null | grep "Visible location" | sed 's/.*Visible location:[[:space:]]*//')
            echo -e "${YELLOW}[1] VM → Mullvad${RESET}"
            echo -e "    Relay: $MULLVAD_RELAY"
            echo -e "    Location: $MULLVAD_LOCATION"
            if [ -n "$MULLVAD_RELAY" ]; then
                echo -e "    ${GREEN}✓ Mullvad tunnel active${RESET}"
            else
                echo -e "    ${RED}✗ Mullvad not connected!${RESET}"
                CHAIN_OK=false
            fi
            echo ""

            # Link 2: Mullvad → VPS
            echo -e "${YELLOW}[2] Mullvad → VPS${RESET}"
            VPS_PEER_RAW=$(vps_cmd "awg show | grep endpoint" 2>/dev/null)
            VPS_PEER=$(echo "$VPS_PEER_RAW" | awk '{print $NF}' | cut -d: -f1)
            if [ -n "$VPS_PEER" ]; then
                echo -e "    VPS sees source: $VPS_PEER (Mullvad exit)"
                if [ "$VPS_PEER" != "$VM_LOCAL_IP" ]; then
                    echo -e "    ${GREEN}✓ Your real IP ($VM_LOCAL_IP) is hidden from VPS${RESET}"
                else
                    echo -e "    ${RED}✗ VPS sees your real IP! Mullvad is bypassed!${RESET}"
                    CHAIN_OK=false
                fi
            else
                echo -e "    ${YELLOW}! Cannot reach VPS via SSH to verify${RESET}"
            fi
            echo ""

            # Link 3: VPS → Target
            echo -e "${YELLOW}[3] VPS → Target${RESET}"
            echo -e "    Target sees: $CURL_IP"
            if [ "$CURL_IP" = "$VPS_IP" ]; then
                echo -e "    ${GREEN}✓ Exit IP = VPS IP ($VPS_IP)${RESET}"
            else
                echo -e "    ${RED}✗ Exit IP ($CURL_IP) ≠ VPS IP ($VPS_IP)${RESET}"
                CHAIN_OK=false
            fi
        else
            echo -e "${CYAN}--- CHAIN: You → VPS → Mullvad → Target ---${RESET}"
            echo ""

            # Link 1: VM → VPS
            echo -e "${YELLOW}[1] VM → VPS${RESET}"
            if pgrep -f wireproxy-awg > /dev/null; then
                echo -e "    AmneziaWG tunnel → $VPS_IP:5000"
                echo -e "    ${GREEN}✓ AWG tunnel active${RESET}"
            else
                echo -e "    ${RED}✗ wireproxy-awg not running!${RESET}"
                CHAIN_OK=false
            fi
            echo ""

            # Link 2: VPS → Mullvad
            echo -e "${YELLOW}[2] VPS → Mullvad${RESET}"
            VPS_MULLVAD_IP=$(vps_cmd "curl -s --connect-timeout 5 --interface mullvad ifconfig.me" 2>/dev/null)
            VPS_MULLVAD_PEER_RAW=$(vps_cmd "wg show mullvad endpoints" 2>/dev/null)
            VPS_MULLVAD_PEER=$(echo "$VPS_MULLVAD_PEER_RAW" | awk '{print $NF}' | cut -d: -f1)
            if [ -n "$VPS_MULLVAD_IP" ]; then
                echo -e "    Mullvad server: $VPS_MULLVAD_PEER"
                echo -e "    Mullvad exit IP: $VPS_MULLVAD_IP"
                echo -e "    ${GREEN}✓ VPS routes through Mullvad WG${RESET}"
            else
                echo -e "    ${RED}✗ Mullvad WG not running on VPS!${RESET}"
                CHAIN_OK=false
            fi
            echo ""

            # Link 3: Mullvad → Target
            echo -e "${YELLOW}[3] Mullvad → Target${RESET}"
            echo -e "    Target sees: $CURL_IP"
            if [ "$CURL_IP" != "$VPS_IP" ] && [ "$CURL_IP" != "$VM_LOCAL_IP" ] && [ -n "$CURL_IP" ]; then
                echo -e "    ${GREEN}✓ Exit IP ≠ your real IP${RESET}"
                echo -e "    ${GREEN}✓ Exit IP ≠ VPS IP (traffic exits through Mullvad)${RESET}"
            elif [ "$CURL_IP" = "$VPS_IP" ]; then
                echo -e "    ${RED}✗ Exit IP = VPS! Mullvad WG not routing!${RESET}"
                CHAIN_OK=false
            elif [ "$CURL_IP" = "$VM_LOCAL_IP" ]; then
                echo -e "    ${RED}✗ Exit IP = your real IP! Chain broken!${RESET}"
                CHAIN_OK=false
            fi
        fi

        echo ""
        echo -e "${CYAN}--- SUMMARY ---${RESET}"
        ISSUES=0
        [ "$CURL_IP" = "$WGET_IP" ] && [ "$CURL_IP" = "$PY_IP" ] && [ -n "$CURL_IP" ] || { echo -e "${RED}  [!] Exit IP mismatch across apps${RESET}"; ISSUES=$((ISSUES+1)); }
        [ "$DNS_SERVER" = "127.0.0.53" ] || { echo -e "${RED}  [!] DNS leak detected${RESET}"; ISSUES=$((ISSUES+1)); }
        [ -z "$IPV6" ] || { echo -e "${RED}  [!] IPv6 leak detected${RESET}"; ISSUES=$((ISSUES+1)); }
        [ "$CHAIN_OK" = "true" ] || { echo -e "${RED}  [!] Chain integrity failed — not all links verified${RESET}"; ISSUES=$((ISSUES+1)); }
        [ $ISSUES -eq 0 ] && echo -e "${GREEN}  All checks passed. Chain intact, no leaks.${RESET}"
        ;;
    rotate|switch)
        shift
        ARGS="$*"
        # Detect mode: Mullvad connected on VM = forward, otherwise = reverse
        if mullvad status 2>/dev/null | grep -q "Connected"; then
            # FORWARD MODE — switch Mullvad relay on VM
            if [ -z "$ARGS" ]; then
                echo -e "${CYAN}=== Mullvad Server (Forward Mode) ===${RESET}"
                mullvad status 2>/dev/null
                echo ""
                echo -e "${CYAN}=== Available Locations ===${RESET}"
                mullvad relay list 2>/dev/null | grep -E "^[A-Z]|^\t[A-Z]" | sed 's/\t/  /' | sed 's/ @.*//'
                echo ""
                echo -e "${YELLOW}Usage: vpn-chain switch <country_code> [city_code]${RESET}"
                echo "  Example: vpn-chain switch de ber"
            else
                # Save current working relay for fallback
                OLD_RELAY=$(mullvad status 2>/dev/null | grep "Relay:" | awk '{print $2}')
                OLD_LOCATION=$(echo "$OLD_RELAY" | sed 's/-wg-.*//;s/-/ /')

                # Try requested location first, then auto-retry random servers
                try_mullvad_switch() {
                    local LOC="$1"
                    mullvad relay set location $LOC 2>/dev/null
                    mullvad reconnect 2>/dev/null
                    # Wait up to 15s for Mullvad to connect
                    local i=0
                    while [ $i -lt 15 ]; do
                        if mullvad status 2>/dev/null | grep -q "Connected"; then
                            break
                        fi
                        sleep 1
                        i=$((i+1))
                    done
                    if ! mullvad status 2>/dev/null | grep -q "Connected"; then
                        return 1
                    fi
                    # Restart wireproxy to use new Mullvad route
                    pkill -f wireproxy-awg 2>/dev/null
                    sleep 1
                    /usr/local/bin/wireproxy-awg -c /etc/wireproxy-awg.conf &>/dev/null &
                    sleep 6
                    local IP=$(test_socks5)
                    if [ "$IP" = "$VPS_IP" ]; then
                        return 0
                    fi
                    return 1
                }

                echo -e "${CYAN}[*] Forward mode: switching Mullvad to: $ARGS${RESET}"
                if try_mullvad_switch "$ARGS"; then
                    RELAY_NAME=$(mullvad status 2>/dev/null | grep "Relay:" | awk '{print $NF}')
                    RELAY_LOC=$(mullvad status 2>/dev/null | grep "Visible location:" | sed 's/.*location:[[:space:]]*//' | sed 's/\.  *IPv4.*//')
                    echo -e "${GREEN}[+] Connected: $RELAY_NAME ($RELAY_LOC)${RESET}"
                    echo -e "${GREEN}    Exit IP (VPS): $VPS_IP${RESET}"
                else
                    echo -e "${RED}[-] $ARGS: failed. Trying 10 random servers...${RESET}"
                    # Get all country codes and pick 10 random
                    ALL_CODES=$(mullvad relay list 2>/dev/null | grep -oP '^\S.*\(\K[a-z]{2}(?=\))' | sort -u)
                    RANDOM_CODES=$(echo "$ALL_CODES" | shuf | head -10)
                    FOUND=0
                    for CODE in $RANDOM_CODES; do
                        echo -e "${YELLOW}[*] Trying: $CODE...${RESET}"
                        if try_mullvad_switch "$CODE"; then
                            RELAY_NAME=$(mullvad status 2>/dev/null | grep "Relay:" | awk '{print $NF}')
                            RELAY_LOC=$(mullvad status 2>/dev/null | grep "Visible location:" | sed 's/.*location:[[:space:]]*//' | sed 's/\.  *IPv4.*//')
                            echo -e "${GREEN}[+] Connected: $RELAY_NAME ($RELAY_LOC)${RESET}"
                            echo -e "${GREEN}    Exit IP (VPS): $VPS_IP${RESET}"
                            FOUND=1
                            break
                        else
                            echo -e "${RED}    [-] $CODE: failed${RESET}"
                        fi
                    done
                    if [ "$FOUND" = "0" ]; then
                        echo -e "${RED}[-] All 10 attempts failed. Restoring: $OLD_LOCATION${RESET}"
                        try_mullvad_switch "$OLD_LOCATION"
                        echo -e "${GREEN}[+] Restored: $OLD_RELAY${RESET}"
                    fi
                fi
            fi
        else
            # REVERSE MODE — rotate Mullvad WG on VPS
            if [ -z "$ARGS" ]; then
                vps_cmd "mullvad-rotate" && echo "" && \
                echo -e "${YELLOW}Exit IP:${RESET} $(curl -4 -s --connect-timeout 5 ifconfig.me)"
            else
                echo -e "${CYAN}[*] Reverse mode: rotating VPS Mullvad to: $ARGS${RESET}"
                vps_cmd "mullvad-rotate $ARGS"
                sleep 2
                IP=$(curl -4 -s --connect-timeout 5 ifconfig.me)
                echo -e "${GREEN}[+] New exit IP: $IP${RESET}"
            fi
        fi
        ;;
    *)
        echo "vpn-chain — double VPN chain manager"
        echo ""
        echo "Usage: vpn-chain {start|start reverse|stop|status|check|switch}"
        echo ""
        echo "  start          FORWARD: VM -> Mullvad -> VPS (exit = $VPS_IP)"
        echo "  start reverse  REVERSE: VM -> VPS -> Mullvad (exit = Mullvad IP)"
        echo "  stop           Stop all chains"
        echo "  status         Component status + exit IP"
        echo "  check          Full chain verification (leak test)"
        echo "  switch [cc]    Switch Mullvad server (auto-detects mode)"
        echo "                   switch         — show current + available"
        echo "                   switch us      — USA"
        echo "                   switch de ber  — Berlin"
        ;;
esac

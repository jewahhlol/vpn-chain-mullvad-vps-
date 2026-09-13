# Troubleshooting

## Chain won't start

### wireproxy-awg fails to start
```bash
# Check if config exists and is readable
sudo cat /etc/wireproxy-awg.conf

# Run in foreground to see errors
sudo pkill -f wireproxy-awg
sudo /usr/local/bin/wireproxy-awg -c /etc/wireproxy-awg.conf
```

### wireproxy-awg: "Handshake did not complete"

**Cause**: Client can't establish AmneziaWG tunnel with VPS.

Checklist:
1. VPS is reachable: `ping YOUR_VPS_IP`
2. AWG server is running on VPS: `ssh root@VPS "awg show"`
3. Port 5000 is open: `ssh root@VPS "ss -ulnp | grep 5000"`
4. Keys match: client PublicKey in [Peer] = server's public key
5. Client's public key is in server's [Peer] AllowedIPs
6. Obfuscation params (Jc, Jmin, Jmax, S1-S4, H1-H4, I1) are identical on both sides
7. In forward mode: Mullvad is connected (`mullvad status`)

**Derive client public key from private key:**
```bash
grep PrivateKey /etc/wireproxy-awg.conf | awk '{print $3}' | wg pubkey
```
This must match what's in the server's `[Peer] PublicKey`.

### Mullvad won't connect (VirtualBox)

Try QUIC obfuscation:
```bash
mullvad obfuscation set mode default
mullvad disconnect && mullvad connect
```

If still fails — VirtualBox Bridged Adapter over WiFi is flaky. Some WiFi drivers/adapters don't support it well. Try:
- Different Mullvad server locations
- Different obfuscation modes
- Wired (Ethernet) connection instead of WiFi

## Wrong exit IP

### Shows Mullvad IP instead of VPS IP (forward mode)
redsocks/iptables not active. Check:
```bash
sudo vpn-chain status
sudo iptables -t nat -L REDSOCKS
```

### Shows real/home IP
Chain not running at all:
```bash
sudo vpn-chain start  # or: start reverse
```

### Shows IPv6 address
IPv6 is leaking. Fix:
```bash
sudo ip6tables -P OUTPUT DROP
sudo ip6tables -A OUTPUT -o lo -j ACCEPT
```
This is done automatically by `vpn-chain start`.

## SSH to VPS lost

### After enabling Mullvad app on VPS
The Mullvad app's nftables kill switch blocks SSH. Never use the Mullvad app on a VPS.

**Fix**: Access VPS via provider's web console (VNC/KVM), then:
```bash
mullvad disconnect
mullvad auto-connect set off
apt remove -y mullvad-vpn
iptables -F
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
nft flush ruleset 2>/dev/null
```

If console login also fails, reinstall the OS from the provider's panel.

### After enabling Mullvad WG (plain WireGuard) on VPS
This shouldn't happen with `Table = 42`. If it does:
```bash
# From provider console:
wg-quick down mullvad
ip rule del from 10.9.9.0/24 table 42
ip route flush table 42
```

## DNS leaks

Check DNS server:
```bash
nslookup example.com
```

Should show `127.0.0.53` (dnscrypt-proxy), not your ISP's DNS.

If DNS is leaking:
```bash
# Check resolv.conf — must point to dnscrypt-proxy
cat /etc/resolv.conf
# Should show: nameserver 127.0.0.53

# If wrong, fix and lock it:
sudo chattr -i /etc/resolv.conf
echo "nameserver 127.0.0.53" | sudo tee /etc/resolv.conf
sudo chattr +i /etc/resolv.conf

# Verify dnscrypt-proxy is running
systemctl status dnscrypt-proxy
```

## Performance issues

### Slow speeds
- wireproxy-awg is userspace — CPU overhead is higher than kernel WireGuard
- Double encryption adds latency
- Try a Mullvad/VPS server geographically closer

### High latency
Expected with double VPN. Reduce by:
- Using VPS and Mullvad servers in the same region
- Forward mode: Mullvad server near VPS
- Reverse mode: Mullvad server near target

## After VM reboot

Nothing persists. Run:
```bash
sudo vpn-chain start          # or: start reverse
```

## After VPS reboot

AWG server auto-starts (if enabled with systemctl). For reverse mode:
```bash
mullvad-wg-start.sh
# or
systemctl start mullvad-wg
```

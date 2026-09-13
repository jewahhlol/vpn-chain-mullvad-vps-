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

### Mullvad won't connect (stuck on "Connecting")

**Cause 1: Device revoked.** Mullvad allows max 5 devices per account. If yours was kicked, it will try to connect forever without a clear error.

Check:
```bash
mullvad account get
```
If it says "The current device has been revoked" — re-login:
```bash
mullvad account login YOUR_ACCOUNT_NUMBER
```

**Cause 2: Wrong obfuscation mode.** In Russia and countries with DPI, plain WireGuard is blocked. Mullvad may show "Connected" but no traffic passes.

Fix — enable QUIC obfuscation:
```bash
# Mullvad 2026+:
mullvad anti-censorship set mode quic

# Older versions:
mullvad obfuscation set mode default
```
Then reconnect:
```bash
mullvad disconnect && mullvad connect
```

**Cause 3: VirtualBox Bridged WiFi.** Some WiFi adapters don't work well with Bridged Adapter. Try:
- Different Mullvad server locations (`mullvad relay set location de`)
- Wired (Ethernet) connection instead of WiFi
- Different obfuscation modes

> **Note on Russia/censored networks**: Forward mode requires Mullvad to connect from the VM. If your ISP blocks WireGuard, you **must** use QUIC obfuscation. If even QUIC doesn't work, use reverse mode instead — it only needs AmneziaWG to VPS (DPI-resistant by design).

### Forward mode: Mullvad "Connected" but no internet

**Cause**: Mullvad shows Connected but traffic is silently dropped by DPI (common in Russia with plain WireGuard).

Symptoms:
- `curl ifconfig.me` hangs or returns empty
- `ping 8.8.8.8` — "Destination Port Unreachable" or 100% loss
- `mullvad status` shows "Connected"

Fix:
```bash
mullvad anti-censorship set mode quic
mullvad reconnect
```

If QUIC also doesn't work — use reverse mode instead. It bypasses the issue entirely because AmneziaWG (not Mullvad) is the outer tunnel.

### AmneziaWG "Configuration parsing error" on VPS

**Cause**: H1-H4 parameters in `awg0.conf` have wrong format. They must be plain integers, not strings with dashes.

Wrong: `H1 = 123-456`
Correct: `H1 = 123456`

If you see this after running `install.sh`, the installer has a bug. Re-run with the latest version from the repo.

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

## SSH "REMOTE HOST IDENTIFICATION HAS CHANGED"

**Cause**: You reinstalled the VPS OS. The new install has different SSH host keys, but your machine remembers the old ones.

This is **not an attack** — it's expected after VPS reinstall.

Fix — remove the old key on **every machine** that connected to the VPS:
```bash
# On your host machine:
ssh-keygen -f ~/.ssh/known_hosts -R VPS_IP

# On Kali VM (as kali user):
ssh-keygen -f ~/.ssh/known_hosts -R VPS_IP

# On Kali VM (as root, used by vpn-chain):
sudo ssh-keygen -R VPS_IP
```

**Rule**: Error appeared → fix it on that machine. SSH tells you which file and which line in the error message.

## `sudo ssh-copy-id`: "No identities found"

**Cause**: Root has no SSH key. `vpn-chain` runs as root (via sudo), so the SSH key must belong to root.

Fix:
```bash
sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
sudo ssh-copy-id root@VPS_IP
```

Verify:
```bash
sudo ssh root@VPS_IP "echo ok"
```

> **Important**: `ssh root@VPS_IP` (without sudo) uses kali's key. `sudo ssh root@VPS_IP` uses root's key. `vpn-chain` uses root's key.

## `ssh root@VPS_IP`: asks for password (but `sudo ssh` works)

The SSH key is only in `/root/.ssh/`. When you SSH without sudo, it uses `/home/kali/.ssh/` which doesn't have the key.

Either always use `sudo ssh`, or copy kali's key too:
```bash
ssh-copy-id root@VPS_IP
```

## VPS: `git: command not found`

Fresh Debian doesn't have git. Install it first:
```bash
apt-get update && apt-get install -y git
```

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

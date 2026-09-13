# Mullvad VPN Setup

Mullvad is required on the **client VM** for forward mode, and registered on the **VPS** for reverse mode.

## Client VM (Forward Mode)

### Install via APT repository (Debian/Ubuntu/Kali)

```bash
# Add Mullvad repository
curl -fsSL https://repository.mullvad.net/deb/mullvad-keyring.asc | \
    sudo tee /usr/share/keyrings/mullvad-keyring.asc > /dev/null

echo "deb [signed-by=/usr/share/keyrings/mullvad-keyring.asc arch=amd64] \
    https://repository.mullvad.net/deb/stable $(lsb_release -cs) main" | \
    sudo tee /etc/apt/sources.list.d/mullvad.list

sudo apt update
sudo apt install mullvad-vpn
```

### Login and configure

```bash
mullvad account login YOUR_ACCOUNT_NUMBER
mullvad relay set tunnel-protocol wireguard
mullvad obfuscation set mode udp2tcp    # or: mullvad tunnel wireguard --quantum-resistant on

# For VirtualBox Bridged WiFi — QUIC is usually the only method that works:
mullvad obfuscation set mode default

# Connect
mullvad connect
mullvad status
```

### Recommended settings

```bash
mullvad auto-connect set on
mullvad lan set allow              # allow LAN access (SSH from host)
mullvad lockdown-mode set off      # don't block when disconnected (vpn-chain handles this)
```

### Change server location

```bash
mullvad relay set location ch zrh   # Switzerland, Zurich
mullvad relay set location us nyc   # USA, New York
mullvad relay set location de ber   # Germany, Berlin
mullvad relay list                  # show all servers
mullvad reconnect                   # reconnect to current selection
```

## VPS (Reverse Mode)

On the VPS, we use **plain WireGuard** (not the Mullvad app) to avoid the nftables kill switch that blocks SSH.

### Register a WireGuard key with Mullvad

This is done automatically by `server/setup-mullvad-wg.sh`. If you need to do it manually:

```bash
# Generate a WireGuard keypair
wg genkey | tee /etc/wireguard/mullvad_private.key | wg pubkey > /etc/wireguard/mullvad_public.key

# Register public key with Mullvad
curl -sSL https://api.mullvad.net/wg/ \
    -d account=YOUR_ACCOUNT_NUMBER \
    --data-urlencode pubkey=$(cat /etc/wireguard/mullvad_public.key)

# Returns an IP address like 10.68.x.x/32 — use this in the WG config
```

### Mullvad WireGuard config on VPS

```ini
# /etc/wireguard/mullvad.conf
[Interface]
PrivateKey = <from mullvad_private.key>
Address = 10.68.x.x/32        # from registration
DNS = 100.64.0.3
Table = 42                     # CRITICAL: separate routing table

[Peer]
PublicKey = <mullvad server pubkey>
Endpoint = <mullvad server ip>:51820
AllowedIPs = 0.0.0.0/0
```

`Table = 42` ensures Mullvad routes go to a separate routing table, keeping SSH working on the main table.

### Getting Mullvad server details

```bash
# List all servers
curl -s https://api.mullvad.net/www/relays/wireguard/ | \
    python3 -c "import json,sys; [print(f'{s[\"hostname\"]} {s[\"ipv4_addr_in\"]} {s[\"pubkey\"]}') for s in json.load(sys.stdin) if s['active'] and 'ch-zrh' in s['hostname']]"
```

Or use the included `mullvad-rotate` script which handles all of this automatically.

## Important Notes

- **QUIC obfuscation** is often the only Mullvad connection method that works through VirtualBox Bridged WiFi adapter. If Mullvad won't connect, try different obfuscation modes.
- **Don't use Mullvad app on VPS.** Its nftables kill switch will block SSH and lock you out. Use plain WireGuard with `Table = 42` instead.
- **Mullvad account sharing**: you can register multiple WireGuard keys under one account (up to 5 devices). One key for the VM, one for the VPS.

# vpn-chain

Double VPN chain for pentest operations. System-wide transparent proxying — every application in the VM exits through the chain automatically.

## What it does

Two operating modes with one command:

```
sudo vpn-chain start           # FORWARD: You → Mullvad → VPS → Target
sudo vpn-chain start reverse   # REVERSE: You → VPS → Mullvad → Target
sudo vpn-chain stop            # Kill everything
```

**Forward mode** — maximum anonymity. Your VPS never learns your real IP (sees only Mullvad exit). Target sees VPS IP. Fixed exit IP.

**Reverse mode** — operational flexibility. Rotate exit IP instantly across 500+ Mullvad servers. Target sees Mullvad IP. One command to switch countries.

## Who sees what

### Forward mode

| Party | Sees | Doesn't see |
|-------|------|-------------|
| ISP | Encrypted QUIC to Mullvad | Destination, content |
| Mullvad | Your IP → encrypted blob to VPS | Content (AmneziaWG encrypted) |
| VPS | Mullvad exit IP → original request | Your real IP |
| Target | VPS IP | Anything about you |

### Reverse mode

| Party | Sees | Doesn't see |
|-------|------|-------------|
| ISP | Encrypted AmneziaWG to VPS | Destination, content |
| VPS | Your IP → encrypted WG to Mullvad | Content (WireGuard encrypted) |
| Mullvad | VPS IP → original request | Your real IP |
| Target | Mullvad exit IP | Anything about you |

## Architecture

```
FORWARD MODE:
┌────────────┐     ┌───────────────┐     ┌─────────────────┐     ┌────────┐
│  Kali VM   │ ──→ │ Mullvad (QUIC)│ ──→ │ VPS (AmneziaWG) │ ──→ │ Target │
│            │     │  1st tunnel   │     │  2nd tunnel      │     │        │
│ wireproxy  │     │               │     │  Decrypts AWG    │     │        │
│ redsocks   │     │  Hides you    │     │  Forwards plain  │     │        │
│ iptables   │     │  from VPS     │     │                  │     │        │
└────────────┘     └───────────────┘     └─────────────────┘     └────────┘

REVERSE MODE:
┌────────────┐     ┌─────────────────┐     ┌─────────────┐     ┌────────┐
│  Kali VM   │ ──→ │ VPS (AmneziaWG) │ ──→ │ Mullvad (WG)│ ──→ │ Target │
│            │     │  1st tunnel      │     │ 2nd tunnel  │     │        │
│ wireproxy  │     │  Decrypts AWG    │     │             │     │        │
│ redsocks   │     │  Re-encrypts WG  │     │ Rotatable   │     │        │
│ iptables   │     │                  │     │ exit IP     │     │        │
└────────────┘     └─────────────────┘     └─────────────┘     └────────┘
```

## How it works (under the hood)

The problem: Mullvad's firewall (`nftables`) blocks all traffic except through its own interface (`wg0-mullvad`). Any new VPN interface (WireGuard, AmneziaWG, TUN) gets dropped. You can't just stack two VPN interfaces.

The solution: **wireproxy-awg** runs AmneziaWG entirely in userspace — no kernel interface, no nftables conflict. It opens a UDP socket through Mullvad's tunnel and exposes a SOCKS5 proxy. **redsocks** + **iptables** transparently redirect all system TCP traffic through that proxy. No app knows it's being proxied.

```
App sends packet to 93.184.216.34:80
  ↓
iptables REDIRECT → 127.0.0.1:12345
  ↓
redsocks accepts, reads original destination (SO_ORIGINAL_DST)
  ↓
redsocks → SOCKS5 connect to 127.0.0.1:1080
  ↓
wireproxy-awg wraps in AmneziaWG, sends through Mullvad tunnel
  ↓
VPS decrypts, forwards to 93.184.216.34:80
```

## Requirements

### Client (attack VM)
- Kali Linux / Debian-based VM
- VirtualBox with **Bridged Adapter** (not NAT — NAT leaks through host VPN)
- Mullvad VPN account (for forward mode)

### Server (VPS)
- Debian 12 / Ubuntu 22.04+
- KVM virtualization (not OpenVZ)
- Public IPv4 address
- Recommended: buy with crypto, no KYC

## Quick Start

### 1. Set up the VPS

Get a VPS with Debian 12 / Ubuntu 22.04+ (KVM, not OpenVZ). SSH into it and run:

```bash
ssh root@YOUR_VPS_IP

apt-get update && apt-get install -y git
git clone https://github.com/jewahhlol/vpn-chain-mullvad-vps-.git vpn-chain
cd vpn-chain/server
chmod +x *.sh
./install.sh
```

> **If you see "AmneziaWG module not loaded"**: the kernel module was built for a newer kernel than what's running. Run `reboot`, SSH back in, and run `./install.sh` again. This is normal on fresh Debian installs.

The installer will output a **client config** at the end — copy it, you'll need it in step 3.

### 2. Set up the client VM

Now on your **Kali / Debian VM** (not the VPS — this is your attack machine, must use **Bridged Adapter** in VirtualBox, not NAT):

```bash
git clone https://github.com/jewahhlol/vpn-chain-mullvad-vps-.git vpn-chain
cd vpn-chain/client
chmod +x install.sh
sudo ./install.sh
```

This installs wireproxy-awg, redsocks, dnscrypt-proxy, and the `vpn-chain` command on the VM.

### 3. Paste the client config

Take the client config that `install.sh` printed on the VPS (step 1) and paste it:

```bash
sudo nano /etc/wireproxy-awg.conf
```

Replace everything in the file with the config from the VPS. It looks like this:

```ini
[Interface]
Address = 10.9.9.3/32
PrivateKey = <generated key>
DNS = 1.1.1.1
...

[Peer]
PublicKey = <server public key>
Endpoint = YOUR_VPS_IP:5000
...

[Socks5]
BindAddress = 127.0.0.1:1080
```

### 4. Set up SSH key for auto-switching

The `vpn-chain` script SSHs to the VPS to toggle Mullvad WG when switching modes. Since the script runs as root (via sudo), the SSH key must belong to root:

```bash
# Generate root's SSH key (skip if /root/.ssh/id_ed25519 already exists)
sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519

# Copy it to the VPS (enter VPS root password when prompted)
sudo ssh-copy-id root@YOUR_VPS_IP

# Verify it works without a password
sudo ssh root@YOUR_VPS_IP "echo ok"
```

> **Without this step**: the chain itself still works, but you'll need to SSH to the VPS manually to run `mullvad-wg-start.sh` / `mullvad-wg-stop.sh` when switching modes.

### 5. Set up reverse mode (optional)

If you want exit IP rotation (recommended), run on the VPS:

```bash
cd vpn-chain/server
./setup-mullvad-wg.sh
```

The script will:
1. Generate a WireGuard key pair
2. Show you a `curl` command to register the key with Mullvad
3. Ask you to paste the IP address Mullvad returned

> **How to register**: open a second terminal to the VPS, run the `curl` command the script shows (replace `YOUR_ACCOUNT_NUMBER` with your Mullvad account number). It returns an IP like `10.68.x.x/32` — paste that into the first terminal.

### 6. Test it

```bash
# Reverse mode (VM → VPS → Mullvad)
sudo vpn-chain start reverse

# Check your exit IP
curl ifconfig.me

# Full leak test
sudo vpn-chain check

# Switch to a different country (works in both modes)
sudo vpn-chain switch us

# Switch to forward mode (VM → Mullvad → VPS)
sudo vpn-chain start forward

# Stop everything
sudo vpn-chain stop
```

### 7. For forward mode: install Mullvad on the VM

Forward mode requires the Mullvad app on your VM. See [docs/mullvad-setup.md](docs/mullvad-setup.md).

## Commands

```bash
sudo vpn-chain start            # Forward mode (exit = VPS IP)
sudo vpn-chain start reverse    # Reverse mode (exit = Mullvad IP)
sudo vpn-chain stop             # Stop all chains
sudo vpn-chain status           # Show component status + exit IP
sudo vpn-chain check            # Full leak test (IP, DNS, IPv6)
sudo vpn-chain switch           # Show current server + available locations
sudo vpn-chain switch us        # Switch to US (auto-detects mode)
sudo vpn-chain switch de ber    # Switch to Berlin
sudo vpn-chain switch jp        # Switch to Japan
```

## Replacing / rotating VPS

When your VPS expires or you want a fresh one:

**1. Get a new VPS** (fresh Debian 12 install)

**2. Clear old SSH keys** — the new VPS has different host keys, so SSH will refuse to connect with a "REMOTE HOST IDENTIFICATION HAS CHANGED" error. Fix by removing the old key from every machine that connected to it:

```bash
# On your host machine
ssh-keygen -f ~/.ssh/known_hosts -R OLD_VPS_IP

# On the Kali VM (as kali user)
ssh-keygen -f ~/.ssh/known_hosts -R OLD_VPS_IP

# On the Kali VM (as root, used by vpn-chain)
sudo ssh-keygen -R OLD_VPS_IP
```

> **Why this happens**: SSH remembers each server's fingerprint to prevent man-in-the-middle attacks. When you reinstall the OS, the server gets new keys, and SSH thinks someone is impersonating the server. Removing the old entry tells SSH to accept the new key.

**3. Set up the new VPS** — run `install.sh` and `setup-mullvad-wg.sh` (same as Quick Start steps 1 and 5)

**4. Update client config** — paste the new client config into `/etc/wireproxy-awg.conf` on the VM

**5. Set up SSH key** — `sudo ssh-copy-id root@NEW_VPS_IP`

**6. Go** — `sudo vpn-chain start reverse`

## File Structure

```
vpn-chain/
├── README.md
├── client/
│   ├── install.sh              # Client installer
│   ├── vpn-chain.sh            # Main management script
│   ├── redsocks.conf           # redsocks template
│   └── wireproxy-awg.conf.example
├── server/
│   ├── install.sh              # VPS installer (AmneziaWG server)
│   ├── setup-mullvad-wg.sh     # Mullvad WG setup for reverse mode
│   ├── mullvad-rotate.sh       # Server rotation script
│   ├── mullvad-wg-start.sh     # Safe Mullvad start (keeps SSH)
│   └── mullvad-wg-stop.sh      # Mullvad stop
└── docs/
    ├── how-it-works.md         # Deep technical explanation
    ├── mullvad-setup.md        # Mullvad installation guide
    ├── troubleshooting.md      # Common issues and fixes
    └── threat-model.md         # Security analysis
```

## Security Notes

- **Kill switch is architectural**: if Mullvad drops (forward mode), VPS becomes unreachable, all traffic stops. No manual kill switch needed.
- **IPv6 is blocked**: `ip6tables -P OUTPUT DROP` prevents leaks.
- **DNS goes through the chain**: dnscrypt-proxy resolves via DNS-over-HTTPS (TCP/443), which redsocks catches and routes through the chain. No UDP DNS leaks.
- **UDP limitations**: redsocks only handles TCP. Raw UDP (some VoIP, game traffic) won't go through the chain.
- **Host isolation**: use Bridged Adapter in VirtualBox, not NAT. NAT routes VM traffic through the host's network stack (and any host VPN).

## Tested On

- Client: Kali Linux 2026.2 (VirtualBox, Bridged WiFi)
- Server: Debian 12 (Bookworm)
- wireproxy-awg: 1.0.17
- AmneziaWG kernel module: 1.0.20210914
- Mullvad VPN: 2026.4

## License

MIT

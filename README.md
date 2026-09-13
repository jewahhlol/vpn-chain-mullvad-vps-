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

```bash
ssh root@YOUR_VPS_IP

# Download and run server setup
git clone https://github.com/YOUR_USER/vpn-chain.git
cd vpn-chain/server
chmod +x install.sh
./install.sh
```

The installer will:
- Install AmneziaWG kernel module
- Generate server + client keys
- Create AWG server config with obfuscation
- Enable IP forwarding
- Set up iptables MASQUERADE
- Print client config to copy to your VM

### 2. Set up the client VM

```bash
# On the Kali VM
git clone https://github.com/YOUR_USER/vpn-chain.git
cd vpn-chain/client
chmod +x install.sh
./install.sh
```

The installer will:
- Install wireproxy-awg, redsocks
- Create config templates
- Install `vpn-chain` command

### 3. Configure

```bash
# Paste the client config from step 1
sudo nano /etc/wireproxy-awg.conf

# For forward mode: install and configure Mullvad
# See docs/mullvad-setup.md
```

### 4. Set up SSH key for auto-switching

The `vpn-chain` script automatically SSHs to the VPS to switch Mullvad WG on/off when changing modes. Set up key-based SSH auth:

```bash
# On the Kali VM (as root, since vpn-chain runs under sudo)
sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
sudo ssh-copy-id root@YOUR_VPS_IP
```

Without this, mode switching still works but you'll need to SSH to the VPS manually to run `mullvad-wg-start.sh` / `mullvad-wg-stop.sh`.

### 5. Set up reverse mode (optional)

```bash
# On the VPS
cd vpn-chain/server
chmod +x setup-mullvad-wg.sh
./setup-mullvad-wg.sh
```

### 6. Run

```bash
sudo vpn-chain start            # forward mode
sudo vpn-chain start reverse    # reverse mode
sudo vpn-chain status           # check
```

## Mode Switching

Switching between forward and reverse is fully automatic — the script SSHs to the VPS and toggles Mullvad WG:

```bash
sudo vpn-chain start           # Forward: stops Mullvad WG on VPS, starts Mullvad on VM
sudo vpn-chain start reverse   # Reverse: starts Mullvad WG on VPS, stops Mullvad on VM
```

If SSH to VPS fails (no key, VPS unreachable), you'll see a warning — switch VPS mode manually.

## Server Management (reverse mode)

Rotate Mullvad exit servers on VPS:

```bash
mullvad-rotate              # show current server + list countries
mullvad-rotate us           # random US server
mullvad-rotate de ber       # Berlin
mullvad-rotate gb lon       # London
mullvad-rotate jp tyo       # Tokyo
mullvad-rotate list us      # show all US servers
mullvad-rotate update       # refresh server list from Mullvad API
```

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
- **DNS goes through the chain**: resolved by Mullvad (100.64.0.x) or VPS, not your ISP.
- **UDP limitations**: redsocks only handles TCP. Raw UDP (some VoIP, game traffic) won't go through the chain. DNS works because it's resolved by the tunnel's DNS server.
- **Host isolation**: use Bridged Adapter in VirtualBox, not NAT. NAT routes VM traffic through the host's network stack (and any host VPN).

## Tested On

- Client: Kali Linux 2026.2 (VirtualBox, Bridged WiFi)
- Server: Debian 12 (Bookworm)
- wireproxy-awg: 1.0.17
- AmneziaWG kernel module: 1.0.20210914
- Mullvad VPN: 2026.4

## License

MIT

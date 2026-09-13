# How It Works

## The Problem

You want all traffic from your VM to exit through a double VPN chain. Sounds simple — stack two VPNs. But:

1. **Mullvad kills other VPN interfaces.** Its `nftables` firewall has `policy drop` on the OUTPUT chain. Only traffic through `wg0-mullvad` is allowed. Any new interface (`awg0`, `wg1`, `tun0`) is blocked.

2. **You can't modify Mullvad's firewall.** Changing its rules breaks the kill switch. The kill switch is the whole point of Mullvad.

3. **Per-app proxying is unreliable.** `proxychains` uses `LD_PRELOAD` — it doesn't work with statically linked binaries, and you have to remember to prefix every command.

4. **tun2socks creates a TUN interface.** Back to problem #1.

## The Solution

Five components, each doing one thing:

### 1. wireproxy-awg (userspace AmneziaWG)

Instead of creating a kernel network interface, wireproxy-awg runs the entire AmneziaWG protocol in userspace. It opens a regular UDP socket to the VPS (which goes through Mullvad's `wg0-mullvad` — allowed by nftables), performs the AmneziaWG handshake inside that socket, and exposes the tunnel as a SOCKS5 proxy on `127.0.0.1:1080`.

For the kernel, it's just a process sending UDP packets through an allowed interface. No new interface, no nftables conflict.

### 2. redsocks (transparent SOCKS redirector)

redsocks listens on `127.0.0.1:12345` and accepts connections that were redirected by iptables. When a redirected packet arrives, redsocks reads the original destination using `SO_ORIGINAL_DST` (the kernel preserves this), then opens a SOCKS5 connection to `127.0.0.1:1080` (wireproxy-awg) and asks it to connect to the original destination.

The application never knows its packet was intercepted. redsocks handles the SOCKS5 negotiation transparently.

### 3. iptables (traffic interception)

A custom chain `REDSOCKS` in the `nat` table catches all outgoing TCP:

```
iptables -t nat -A OUTPUT -p tcp -j REDSOCKS
```

Inside the chain, private/local addresses are excluded (RETURN), and everything else is redirected:

```
-d 127.0.0.0/8   → RETURN  (loopback — prevent infinite loop)
-d 10.0.0.0/8    → RETURN  (private networks)
-d 192.168.0.0/16 → RETURN (LAN)
-d VPS_IP        → RETURN  (wireproxy-awg must reach VPS directly)
all other TCP    → REDIRECT --to-ports 12345  (send to redsocks)
```

The VPS IP exclusion is critical. Without it: wireproxy-awg tries to connect to VPS → iptables redirects to redsocks → redsocks sends to wireproxy-awg → wireproxy-awg tries to connect to VPS → infinite loop.

### 4. ip6tables (IPv6 leak prevention)

```
ip6tables -P OUTPUT DROP
ip6tables -A OUTPUT -o lo -j ACCEPT
```

The SOCKS5 chain is IPv4-only. If an app uses IPv6, the packet bypasses everything and goes through Mullvad directly (forward mode) or exits with the real IP (reverse mode). Blocking IPv6 forces all apps to fall back to IPv4, which gets caught by iptables.

### 5. Mullvad VPN (first/last tunnel)

In **forward mode**: Mullvad runs on the VM. It's the outer tunnel. wireproxy-awg's UDP packets to VPS travel inside Mullvad's encrypted tunnel. VPS sees Mullvad's exit IP, not yours.

In **reverse mode**: Mullvad runs on the VPS (as plain WireGuard, not the app — the app's nftables kill switch blocks SSH). Traffic from the VM goes directly to VPS via AmneziaWG, then VPS routes it through Mullvad WireGuard (using `Table = 42` for separate routing). SSH to VPS still works because policy routing keeps SSH on the original interface.

## Data Flow

### Forward mode: curl ifconfig.me

```
curl creates TCP socket to 34.117.188.166:80
  │
  ├─ iptables nat OUTPUT chain
  │  └─ REDSOCKS chain
  │     ├─ not 127.0.0.0/8 ✓
  │     ├─ not 10.0.0.0/8 ✓
  │     ├─ not 192.168.0.0/16 ✓
  │     ├─ not VPS_IP ✓
  │     └─ REDIRECT to 127.0.0.1:12345
  │
  ├─ redsocks receives on :12345
  │  ├─ reads original dest: 34.117.188.166:80 (SO_ORIGINAL_DST)
  │  └─ SOCKS5 CONNECT 34.117.188.166:80 → 127.0.0.1:1080
  │
  ├─ wireproxy-awg receives SOCKS5 request
  │  ├─ wraps in AmneziaWG packet
  │  └─ sends UDP to VPS:5000 via wg0-mullvad
  │
  ├─ Mullvad encrypts, sends to Mullvad server
  │
  ├─ Mullvad server decrypts, forwards to VPS:5000
  │
  ├─ VPS AWG server decrypts
  │  └─ forwards HTTP GET to 34.117.188.166:80
  │
  └─ ifconfig.me sees VPS IP
```

### Reverse mode: curl ifconfig.me

```
curl creates TCP socket to 34.117.188.166:80
  │
  ├─ (same iptables/redsocks/wireproxy-awg path)
  │
  ├─ wireproxy-awg sends UDP directly to VPS:5000
  │  (no Mullvad on VM — packet goes through regular internet)
  │
  ├─ VPS AWG server decrypts
  │  ├─ policy routing: from 10.9.9.0/24 → table 42
  │  ├─ table 42 default route → mullvad interface
  │  └─ WireGuard encrypts, sends to Mullvad server
  │
  ├─ Mullvad server decrypts
  │  └─ forwards HTTP GET to 34.117.188.166:80
  │
  └─ ifconfig.me sees Mullvad exit IP
```

## Why AmneziaWG (not plain WireGuard)

AmneziaWG adds obfuscation to the WireGuard handshake. Parameters like Jc, Jmin, Jmax add junk packets; S1-S4 add padding; H1-H4 modify header fields; I1 adds init packet padding. This makes the traffic harder to identify via DPI compared to standard WireGuard, which has a distinctive handshake pattern.

## Why Table = 42 on VPS

When Mullvad WG runs on the VPS, we use `Table = 42` in the WireGuard config. This tells wg-quick to put routes in a separate routing table instead of replacing the default route. SSH connections continue using the main routing table (default route via eth0). Only AWG client traffic (10.9.9.0/24) is routed through table 42 via policy routing (`ip rule add from 10.9.9.0/24 table 42`).

This is why we don't use the Mullvad app on the VPS — its nftables kill switch would block SSH, with no workaround.

## Auto-switching VPS mode

The `vpn-chain` script includes a `vps_cmd()` function that automatically SSHs to the VPS when changing modes:

- `vpn-chain start` (forward) → runs `mullvad-wg-stop.sh` on VPS so traffic exits directly
- `vpn-chain start reverse` → runs `mullvad-wg-start.sh` on VPS so traffic exits through Mullvad

SSH tries the tunnel IP first (`10.9.9.1` — works if wireproxy-awg is already running), then falls back to the public VPS IP. This requires key-based SSH auth for root on both the VM and VPS (`sudo ssh-copy-id root@VPS_IP`).

## Why Bridged Adapter (not NAT)

With VirtualBox NAT, VM traffic goes through the host's network stack. If the host runs a VPN for personal use, VM traffic passes through that VPN too — mixing personal and operational traffic. With Bridged Adapter, the VM gets its own IP from the router and communicates directly, bypassing the host entirely.

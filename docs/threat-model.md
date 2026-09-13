# Threat Model

## What this protects against

### Target attribution
The target sees only the exit IP (VPS or Mullvad server). No identifying information about you reaches the target through the network layer.

### ISP surveillance
Your ISP sees encrypted traffic to either Mullvad (forward mode, looks like QUIC/HTTPS) or your VPS (reverse mode, looks like AmneziaWG — obfuscated, hard to classify via DPI). They cannot see the destination or content.

### Single point of compromise
No single party in the chain knows both who you are AND what you're doing:

**Forward mode:**
- Mullvad knows your IP but not your traffic (AmneziaWG encrypted)
- VPS knows your traffic but not your IP (sees Mullvad exit)

**Reverse mode:**
- VPS knows your IP and traffic content (it decrypts AWG then re-encrypts to Mullvad)
- This is the tradeoff for exit IP rotation

### VPS seizure (forward mode)
If your VPS is seized, the attacker finds:
- AmneziaWG server config (keys, obfuscation params)
- Mullvad WireGuard config (if reverse mode was set up)
- Logs may show Mullvad exit IPs that connected (kernel conntrack)

They do NOT find:
- Your real IP (connections came from Mullvad)
- Historical connection data (unless they were logging traffic in real-time)

### VPS seizure (reverse mode)
If seized while you're actively connected:
- Your real IP is visible in `awg show` peer endpoint
- This is the key weakness of reverse mode

## What this does NOT protect against

### Mullvad compromise (forward mode)
If Mullvad is compromised (court order, real-time surveillance on their server), they can see your real IP connecting and correlate it with the VPS endpoint. They can then correlate VPS traffic with the target.

**Mitigation**: Mullvad has been audited, uses RAM-only servers, has been raided with no data found. But trust is required.

### Application-layer leaks
This chain protects the network layer. It does NOT protect against:
- Browser fingerprinting (Canvas, WebGL, fonts, screen size)
- JavaScript-based IP detection (WebRTC — disable it)
- Cookies, login sessions, unique identifiers
- Metadata in uploaded files (EXIF in images)
- DNS over HTTPS that bypasses system DNS

**Mitigation**: Harden Firefox with arkenfox user.js, disable WebRTC, use uBlock Origin.

### Timing correlation
A global adversary watching both your ISP and the target can correlate traffic patterns. If you send a request and the target receives it 200ms later, the timing matches.

**Mitigation**: Not practically solvable with VPNs. Tor is better for this (adds random delays, batching). For most pentest scenarios, this is not a realistic threat.

### UDP traffic
redsocks only handles TCP. Raw UDP traffic (not wrapped in the SOCKS5 chain) goes through Mullvad in forward mode, or directly in reverse mode.

**Affected**: Some tools that use raw UDP sockets (certain scanners, VoIP)
**Not affected**: DNS (resolved by tunnel's DNS server), HTTP/HTTPS, SSH, most pentest tools

### Host machine correlation
If your host machine (outside the VM) visits the same targets through its own VPN, traffic patterns could be correlated.

**Mitigation**: Keep host and VM activities completely separate. Use Bridged Adapter, not NAT.

## Comparison of modes

| Threat | Forward | Reverse |
|--------|---------|---------|
| Target sees real IP | No (VPS) | No (Mullvad) |
| ISP knows destination | No | No |
| VPS knows who you are | No | **Yes** |
| Exit IP is static | Yes | No (rotatable) |
| VPS seizure reveals you | No | **Yes** (if active) |
| Mullvad compromise reveals you | **Yes** | No |
| Kill switch | Architectural | Manual |

## Recommendations

- **Use forward mode** when anonymity is critical (you don't want anyone tracing back to you)
- **Use reverse mode** when flexibility is needed (target blocks IPs, you need to rotate)
- **Buy VPS with crypto** (Monero) from a no-KYC provider
- **Pay for Mullvad with cash or crypto**
- **Don't SSH to VPS from your real IP** in forward mode — use the chain
- **Rotate VPS periodically** — a long-lived VPS accumulates connection patterns

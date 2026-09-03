# deploy-anti-gfw

One-shot personal anti-censorship proxy node for mainland China. SSH into a fresh
Ubuntu/Debian VPS (Lightsail / EC2 / any KVM) as root and run the script — it deploys
the full "default starter stack" in a few minutes.

## What it installs

- **Xray** — VLESS + XTLS-Vision + REALITY on TCP 443 (reliable on all 3 ISPs)
- **sing-box** — AnyTLS on TCP 8443 (TCP alternative, auto-failover)
- **Hysteria2** (optional, off by default) — UDP 443; China Mobile throttles UDP under load
- **Network tuning** — BBR/fq, 64MB buffers, initcwnd 30, MSS clamp (persisted via systemd)
- **Self-hosted subscription server** — traffic-metered config (source of truth + airport-style usage bar)

## Usage

```bash
# full script
ssh root@YOUR_VPS
bash deploy-anti-gfw.sh

# or the single-line version (gzip+base64 compressed, paste-friendly):
# content of deploy-anti-gfw.oneliner.txt
```

Optional Hysteria2:

```bash
ENABLE_HY2=1 bash deploy-anti-gfw.sh
```

### Overridable defaults

| Env var       | Default             |
|---------------|---------------------|
| `REALITY_PORT`| 443                 |
| `ANYTLS_PORT` | 8443                |
| `SUB_PORT`    | 28443               |
| `SNI`         | www.microsoft.com   |
| `CAP_GB`      | 2000                |
| `NODE_NAME`   | Tokyo               |

## After it finishes

The script prints:

1. **Subscription URL** — import in Stash / Clash.Meta / mihomo
2. **A plain `vless://` link** — single-node quick import
3. **Traffic dashboard URL** — monthly usage vs. cap

## Important caveats

- **Cloud firewall must be opened manually** (Lightsail/EC2 console — IPv4 and IPv6 are
  separate): TCP 443, TCP 8443, TCP `<SUB_PORT>` (plus UDP 443 if `ENABLE_HY2=1`).
- The subscription serves node secrets over **plain HTTP** — keep the token secret and
  refresh the subscription *through* the proxy.
- China Mobile users: prefer the Reality node; Hysteria2 (UDP) gets throttled under load.
- The Hysteria2 entry uses **mihomo** spelling (`password`/`obfs-password`/`up`/`down`);
  Stash users need `auth`/`up-speed`/`down-speed` instead.

## Files

- `deploy-anti-gfw.sh` — the readable, editable script
- `deploy-anti-gfw.oneliner.txt` — the same script as a gzip+base64 one-liner

Scope: a personal node for your own access only. Keep it personal-scale.

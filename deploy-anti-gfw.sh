#!/usr/bin/env bash
#
# deploy-anti-gfw.sh — one-shot personal anti-censorship node for mainland China.
#
# SSH into a fresh Ubuntu/Debian VPS (Lightsail / EC2 / any KVM) as root and run:
#
#     bash deploy-anti-gfw.sh
#
# It fully automates the "default starter stack" from the anti-gfw-proxy skill:
#   * Xray  VLESS + XTLS-Vision + REALITY  (TCP 443)  — reliable on all 3 ISPs
#   * sing-box  AnyTLS                       (TCP 8443) — TCP alternative, auto-failover
#   * BBR/fq + buffers + initcwnd + MSS-clamp network tuning
#   * a self-hosted subscription server (source of truth + 机场-style traffic bar)
#   * a ready-to-import Stash / Clash.Meta (mihomo) client config
#
# When it finishes it prints:
#   * the subscription URL   (import this in Stash / Clash / mihomo)
#   * a plain vless:// link  (single-node quick import)
#   * the traffic dashboard URL
#
# Optional (default OFF due to the China-Mobile-UDP-throttle caveat):
#   ENABLE_HY2=1 bash deploy-anti-gfw.sh    # also install Hysteria2 (UDP 443)
#
# You can override the defaults via environment variables:
#   REALITY_PORT  (443)   ANYTLS_PORT  (8443)   SUB_PORT  (28443)
#   SNI           (www.microsoft.com)          CAP_GB     (2000)
#   NODE_NAME     (Tokyo)
#
# NOTE: the OS firewall rules below are set automatically, but the **cloud**
# firewall (Lightsail/EC2 console, IPv4 *and* IPv6 are separate) MUST be opened
# by you for TCP 443, TCP 8443, TCP <SUB_PORT> (and UDP 443 if ENABLE_HY2=1).
#
# Scope: a personal node for your own access only. Keep it personal-scale.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------
REALITY_PORT="${REALITY_PORT:-443}"
ANYTLS_PORT="${ANYTLS_PORT:-8443}"
SUB_PORT="${SUB_PORT:-28443}"
CAP_GB="${CAP_GB:-2000}"
SNI="${SNI:-www.microsoft.com}"
NODE_NAME="${NODE_NAME:-}"
ENABLE_HY2="${ENABLE_HY2:-0}"
if [[ -z "$NODE_NAME" ]]; then
  # prompt only when stdin is a terminal (works for `bash <(curl ...)`; pipes skip silently)
  [[ -t 0 ]] && read -r -p "Node name (e.g. Taiwan / Tokyo / HongKong): " NODE_NAME
fi
NODE_NAME="$(printf '%s' "${NODE_NAME:-Tokyo}" | tr ' ' '-')"   # URL-safe label

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
log() { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die() { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root:  sudo bash $0"

command -v curl    >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq curl; }
command -v openssl >/dev/null || apt-get install -y -qq openssl
command -v tar     >/dev/null || true
command -v ufw     >/dev/null || true

# public IP + primary interface (for the traffic dashboard)
PUB_IP="$(curl -fsSL --max-time 10 https://api.ipify.org 2>/dev/null \
         || curl -fsSL --max-time 10 https://ifconfig.me 2>/dev/null \
         || curl -fsSL --max-time 10 https://icanhazip.com 2>/dev/null \
         || echo '')"
IFACE="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
IFACE="${IFACE:-eth0}"
[[ -n "$PUB_IP" ]] || warn "could not detect public IP; the subscription URL will be wrong until you fix it."

# ---------------------------------------------------------------------------
# 1. network tuning (helps every TCP protocol)
# ---------------------------------------------------------------------------
log "network tuning (BBR/fq, buffers, initcwnd, MSS clamp)"
modprobe tcp_bbr 2>/dev/null || true
echo tcp_bbr > /etc/modules-load.d/bbr.conf
cat > /etc/sysctl.d/99-proxy.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fastopen = 1
net.core.somaxconn = 8192
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

cat > /usr/local/sbin/net-tune.sh <<EOF
#!/bin/bash
R=\$(ip route show default | head -1)
echo "\$R" | grep -q initcwnd || ip route replace \$R initcwnd 30 initrwnd 30
iptables -t mangle -D OUTPUT -p tcp -m multiport --sports ${REALITY_PORT},${ANYTLS_PORT} --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -A OUTPUT -p tcp -m multiport --sports ${REALITY_PORT},${ANYTLS_PORT} --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
EOF
chmod +x /usr/local/sbin/net-tune.sh
cat > /etc/systemd/system/net-tune.service <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/net-tune.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now net-tune.service >/dev/null
systemctl daemon-reload

# ---------------------------------------------------------------------------
# 2. Xray — VLESS + Vision + REALITY on TCP 443
# ---------------------------------------------------------------------------
log "installing Xray (Reality)"
if ! command -v xray >/dev/null; then
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null \
    || die "Xray install script download/execution failed"
fi
command -v xray >/dev/null || die "xray binary not found after install"
UUID="$(xray uuid)"
KPAIR="$(xray x25519)"
# xray >= 1.8.6 prints "Private key: / Public key:", xray >= 25 prints
# "PrivateKey: / Password (PublicKey):" — accept both spellings.
PRIV="$(printf '%s\n' "$KPAIR" | sed -nE 's/^Private ?[Kk]ey: //p' | head -1)"
PBK="$(printf '%s\n' "$KPAIR" | sed -nE 's/^(Public ?key|Password \(PublicKey\)): //p' | head -1)"
SID="$(openssl rand -hex 8)"
[[ -n "$PRIV" && -n "$PBK" ]] || die "failed to parse 'xray x25519' output"

cat > /usr/local/etc/xray/config.json <<EOF
{ "log": { "loglevel": "none" },
  "inbounds": [{ "listen": "::", "port": ${REALITY_PORT}, "protocol": "vless",
    "settings": { "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision" }], "decryption": "none" },
    "streamSettings": { "network": "tcp", "security": "reality",
      "realitySettings": { "show": false, "dest": "${SNI}:443", "xver": 0,
        "serverNames": ["${SNI}"], "privateKey": "${PRIV}", "shortIds": ["${SID}"] } },
    "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] } }],
  "outbounds": [ { "protocol": "freedom" }, { "protocol": "blackhole", "tag": "block" } ],
  "routing": { "rules": [ { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" } ] } }
EOF
xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1 \
  || { warn "xray config failed validation (dumping for debug)"; cat /usr/local/etc/xray/config.json; die "xray config invalid"; }
systemctl enable --now xray >/dev/null
systemctl restart xray

# ---------------------------------------------------------------------------
# 3. sing-box — AnyTLS on TCP 8443
# ---------------------------------------------------------------------------
log "installing sing-box (AnyTLS)"
if ! command -v sing-box >/dev/null; then
  case "$(uname -m)" in
    x86_64|amd64)  SB_ARCH="amd64" ;;
    aarch64|arm64) SB_ARCH="arm64" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
  TAG="$(curl -fsSL --max-time 30 https://api.github.com/repos/SagerNet/sing-box/releases/latest \
         | grep -m1 '"tag_name"' | cut -d'"' -f4)"
  [[ -n "$TAG" ]] || die "failed to query latest sing-box release (GitHub API)"
  VER="${TAG#v}"
  curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${VER}-linux-${SB_ARCH}.tar.gz" \
    | tar xz -C /tmp || die "failed to download sing-box ${TAG}"
  install "/tmp/sing-box-${VER}-linux-${SB_ARCH}/sing-box" /usr/local/bin/sing-box \
    || die "failed to install sing-box binary"
fi
command -v sing-box >/dev/null || die "sing-box binary not found"
mkdir -p /etc/sing-box
ANYTLS_PW="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-32)"
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout /etc/sing-box/key.pem -out /etc/sing-box/cert.pem -subj "/CN=${SNI}" -days 3650 2>/dev/null
cat > /etc/sing-box/config.json <<EOF
{ "log": {"level":"warn"},
  "inbounds": [{ "type":"anytls", "listen":"::", "listen_port":${ANYTLS_PORT},
    "users":[{"name":"user","password":"${ANYTLS_PW}"}],
    "tls":{"enabled":true,"server_name":"${SNI}",
      "certificate_path":"/etc/sing-box/cert.pem","key_path":"/etc/sing-box/key.pem"} }],
  "outbounds": [{"type":"direct"}] }
EOF
sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1 \
  || { warn "sing-box config failed validation (dumping for debug)"; cat /etc/sing-box/config.json; die "sing-box config invalid"; }
cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now sing-box >/dev/null
systemctl restart sing-box

# ---------------------------------------------------------------------------
# 4. Hysteria2 (optional — UDP, see China-Mobile caveat)
# ---------------------------------------------------------------------------
HY2_AUTH=""; HY2_OBFS=""
if [[ "$ENABLE_HY2" == "1" ]]; then
  log "installing Hysteria2 (UDP 443 — China Mobile will throttle this under load)"
  curl -fsSL https://get.hy2.sh/ | bash >/dev/null
  mkdir -p /etc/hysteria
  HY2_AUTH="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-32)"
  HY2_OBFS="$(openssl rand -hex 16)"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /etc/hysteria/key.pem -out /etc/hysteria/cert.pem -subj "/CN=${SNI}" -days 3650 2>/dev/null
  cat > /etc/hysteria/config.yaml <<EOF
listen: :443
tls: {cert: /etc/hysteria/cert.pem, key: /etc/hysteria/key.pem}
auth: {type: password, password: "${HY2_AUTH}"}
obfs: {type: salamander, salamander: {password: "${HY2_OBFS}"}}
masquerade: {type: proxy, proxy: {url: "https://${SNI}/", rewriteHost: true}}
EOF
  chown -R hysteria:hysteria /etc/hysteria
  systemctl enable --now hysteria-server >/dev/null
fi

# ---------------------------------------------------------------------------
# 5. OS firewall (cloud firewall is separate — must be done in the console)
# ---------------------------------------------------------------------------
log "opening OS firewall ports (if ufw is active)"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 22/tcp            >/dev/null 2>&1 || true
  ufw allow ${REALITY_PORT}/tcp >/dev/null 2>&1 || true
  ufw allow ${ANYTLS_PORT}/tcp  >/dev/null 2>&1 || true
  ufw allow ${SUB_PORT}/tcp     >/dev/null 2>&1 || true
  [[ "$ENABLE_HY2" == "1" ]] && ufw allow 443/udp >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 6. traffic meter + self-hosted subscription dashboard
# ---------------------------------------------------------------------------
log "installing traffic meter + subscription server"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq python3 python3-yaml vnstat >/dev/null 2>&1 || true
systemctl enable --now vnstat >/dev/null 2>&1 || true

SUB_TOKEN="$(openssl rand -hex 16)"
mkdir -p /etc/stash-sub

# --- the source-of-truth client config (Stash / Clash.Meta / mihomo) ---------
cat > /etc/stash-sub/config.yaml <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false

proxies:
  - name: "${NODE_NAME}-Reality"
    type: vless
    server: ${PUB_IP}
    port: ${REALITY_PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${SNI}
    client-fingerprint: chrome
    reality-opts: { public-key: ${PBK}, short-id: ${SID} }
  - name: "${NODE_NAME}-AnyTLS"
    type: anytls
    server: ${PUB_IP}
    port: ${ANYTLS_PORT}
    password: ${ANYTLS_PW}
    sni: ${SNI}
    skip-cert-verify: true
    client-fingerprint: chrome
    udp: true
    alpn: [h2, http/1.1]
EOF

# optional Hysteria2 node (mihomo spelling — Stash uses auth/up-speed/down-speed!)
if [[ "$ENABLE_HY2" == "1" ]]; then
  cat >> /etc/stash-sub/config.yaml <<EOF
  - name: "${NODE_NAME}-Hy2"
    type: hysteria2
    server: ${PUB_IP}
    port: 443
    password: ${HY2_AUTH}
    obfs: salamander
    obfs-password: ${HY2_OBFS}
    sni: ${SNI}
    skip-cert-verify: true
    up: 30 Mbps
    down: 200 Mbps
EOF
fi

GROUP_NODES="\"${NODE_NAME}-Reality\", \"${NODE_NAME}-AnyTLS\""
[[ "$ENABLE_HY2" == "1" ]] && GROUP_NODES="${GROUP_NODES}, \"${NODE_NAME}-Hy2\""

cat >> /etc/stash-sub/config.yaml <<EOF

proxy-groups:
  - { name: Proxy, type: select, proxies: [${GROUP_NODES}] }
  - { name: AI,    type: select, proxies: [${GROUP_NODES}] }

rules:
  # WeChat / QQ  (force-direct, above everything else)
  - DOMAIN-SUFFIX,qq.com,DIRECT
  - DOMAIN-SUFFIX,wechat.com,DIRECT
  - DOMAIN-SUFFIX,weixin.qq.com,DIRECT
  - DOMAIN-SUFFIX,qpic.cn,DIRECT
  - DOMAIN-SUFFIX,qlogo.cn,DIRECT
  # Douyin / ByteDance
  - DOMAIN-SUFFIX,douyin.com,DIRECT
  - DOMAIN-SUFFIX,iesdouyin.com,DIRECT
  - DOMAIN-SUFFIX,amemv.com,DIRECT
  - DOMAIN-SUFFIX,snssdk.com,DIRECT
  - DOMAIN-SUFFIX,bytedance.com,DIRECT
  - DOMAIN-SUFFIX,byteimg.com,DIRECT
  # the long tail of CN domains
  - GEOSITE,cn,DIRECT
  # YouTube -> fastest node; AI services -> AI group
  - GEOSITE,youtube,${NODE_NAME}-Reality
  - GEOSITE,category-ai-!cn,AI
  - MATCH,Proxy

dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.0/15
  fake-ip-filter:
    - '*.ntp.org'
    - 'time.apple.com'
    - 'time.windows.com'
    - '*.pool.ntp.org'
    - 'stun.*'
    - '*.lan'
  default-nameserver: [223.5.5.5, 119.29.29.29]
  nameserver-policy:
    'geosite:cn': https://dns.alidns.com/dns-query
    'geosite:geolocation-!cn': https://cloudflare-dns.com/dns-query
EOF

# --- the dashboard (verbatim from the skill, constants patched below) --------
cat > /usr/local/sbin/traffic-dashboard.py <<'PYEOF'
#!/usr/bin/env python3
import http.server, subprocess, time, calendar, yaml

SECRET = "CHANGE_ME_openssl_rand_hex_16"
PORT   = 28443
CAP_GB = 2000.0
CONFIG = "/etc/stash-sub/config.yaml"
IFACE  = "ens5"

def _boot_bytes():
    for ln in open("/proc/net/dev"):
        if IFACE in ln:
            p = ln.split(); return int(p[1]), int(p[9])
    return 0, 0

def usage():
    brx, btx = _boot_bytes()
    vrx = vtx = trx = ttx = 0
    try:
        f = subprocess.run(["vnstat", "--oneline", "b"], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, universal_newlines=True,
                           timeout=5).stdout.strip().split(";")
        if len(f) >= 15:
            vrx, vtx, trx, ttx = int(f[8]), int(f[9]), int(f[3]), int(f[4])
    except Exception:
        pass
    return dict(tx=max(vtx, btx), rx=max(vrx, brx), vtx=vtx, btx=btx, ttx=ttx, trx=trx)

def reset_ts():
    n = time.gmtime(); y, m = n.tm_year, n.tm_mon
    y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    return int(calendar.timegm((y, m, 1, 0, 0, 0, 0, 0, 0)))

def build_sub(used_tx):
    d = yaml.safe_load(open(CONFIG, encoding="utf-8"))
    gb = used_tx / 1e9; pct = 100 * gb / CAP_GB; rem = max(CAP_GB - gb, 0)
    days = max(int((reset_ts() - time.time()) / 86400), 0)
    info = [
        {"name": f"Used {gb:.1f}G / {CAP_GB:.0f}G  {pct:.1f}%", "type": "socks5",
         "server": "127.0.0.1", "port": 1, "udp": False},
        {"name": f"Remaining {rem:.0f} GB", "type": "socks5",
         "server": "127.0.0.1", "port": 1, "udp": False},
        {"name": f"Resets in {days} days", "type": "socks5",
         "server": "127.0.0.1", "port": 1, "udp": False},
    ]
    d["proxies"] = info + d.get("proxies", [])
    d["proxy-groups"] = [{"name": "Traffic", "type": "select",
                          "proxies": [x["name"] for x in info]}] + d.get("proxy-groups", [])
    return yaml.dump(d, allow_unicode=True, sort_keys=False)

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        if SECRET not in s.path:
            s.send_response(404); s.end_headers(); return
        u = usage(); used = u["tx"]
        if "/sub" in s.path:
            try:
                body = build_sub(used).encode("utf-8")
            except Exception as e:
                s.send_response(500); s.end_headers(); s.wfile.write(str(e).encode()); return
            s.send_response(200)
            s.send_header("Content-Type", "text/yaml; charset=utf-8")
            s.send_header("Profile-Update-Interval", "12")
            s.send_header("subscription-userinfo",
                          f"upload=0; download={used}; total={int(CAP_GB*1e9)}; expire={reset_ts()}")
            s.send_header("Content-Disposition", 'attachment; filename="config.yaml"')
            s.send_header("Content-Length", str(len(body))); s.end_headers(); s.wfile.write(body); return
        gb = used / 1e9; pct = 100 * gb / CAP_GB
        html = f"""<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Traffic</title>
<style>body{{font-family:-apple-system,sans-serif;background:#0b0b0c;color:#eee;margin:0;padding:20px}}.c{{background:#1c1c1e;border-radius:14px;padding:18px;max-width:460px;margin:0 auto 14px}}.b{{font-size:32px;font-weight:700}}.s{{color:#8e8e93;font-size:12px}}.bar{{height:14px;background:#2c2c2e;border-radius:7px;overflow:hidden;margin:10px 0}}.f{{height:100%;background:linear-gradient(90deg,#30d158,#ffd60a,#ff453a);width:{min(pct,100):.1f}%}}.r{{display:flex;justify-content:space-between;padding:7px 0;border-bottom:1px solid #2c2c2e;font-size:15px}}</style>
<div class=c><div class=s>Outbound used this month (counts toward cap)</div><div class=b>{gb:.1f} <span style=font-size:15px;color:#8e8e93>/ {CAP_GB:.0f} GB</span></div><div class=bar><div class=f></div></div><div class=s>{pct:.1f}% used &middot; {max(CAP_GB-gb,0):.0f} GB left &middot; auto-refresh 60s</div></div>
<div class=c><div class=r><span>vnstat month out</span><b>{u['vtx']/1e9:.1f} GB</b></div><div class=r><span>since-boot out</span><b>{u['btx']/1e9:.1f} GB</b></div><div class=r><span>today out/in</span><b>{u['ttx']/1e9:.1f} / {u['trx']/1e9:.1f} GB</b></div><div class=s style=margin-top:8px>Authoritative: cloud console Data transfer</div></div>
<script>setTimeout(()=>location.reload(),60000)</script>"""
        b = html.encode(); s.send_response(200)
        s.send_header("Content-Type", "text/html; charset=utf-8")
        s.send_header("Content-Length", str(len(b))); s.end_headers(); s.wfile.write(b)

    def log_message(s, *a):
        pass

if __name__ == "__main__":
    http.server.HTTPServer(("0.0.0.0", PORT), H).serve_forever()
PYEOF

# patch the dashboard constants to the values we actually generated
sed -i "s/CHANGE_ME_openssl_rand_hex_16/${SUB_TOKEN}/;
        s/^PORT *= *[0-9]*/PORT   = ${SUB_PORT}/;
        s/^CAP_GB *= *[0-9.]*/CAP_GB = ${CAP_GB}/;
        s/^IFACE *= *\"[^\"]*\"/IFACE  = \"${IFACE}\"/" /usr/local/sbin/traffic-dashboard.py
chmod +x /usr/local/sbin/traffic-dashboard.py

cat > /etc/systemd/system/stash-sub.service <<'EOF'
[Unit]
Description=traffic dashboard + subscription
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/bin/python3 /usr/local/sbin/traffic-dashboard.py
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now stash-sub >/dev/null

# ---------------------------------------------------------------------------
# 7. verify + report
# ---------------------------------------------------------------------------
log "verifying services"
for svc in xray sing-box stash-sub; do
  state="$(systemctl is-active "$svc" 2>/dev/null || echo inactive)"
  printf '  %-10s %s\n' "$svc" "$state"
done
ss -lntp 2>/dev/null | grep -E ":(${REALITY_PORT}|${ANYTLS_PORT}|${SUB_PORT}) " | sed 's/^/  /' || true

SUB_URL="http://${PUB_IP}:${SUB_PORT}/sub/${SUB_TOKEN}"
DASH_URL="http://${PUB_IP}:${SUB_PORT}/${SUB_TOKEN}"
VLESS_URL="vless://${UUID}@${PUB_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PBK}&sid=${SID}&type=tcp&headerType=none#${NODE_NAME}-Reality"

echo
echo "=============================================================="
echo "  DONE"
echo "=============================================================="
echo "  Subscription (import in Stash / Clash / mihomo):"
echo "    ${SUB_URL}"
echo
echo "  Single-node Reality link:"
echo "    ${VLESS_URL}"
echo
echo "  Traffic dashboard:"
echo "    ${DASH_URL}"
echo
echo "  NODES"
echo "    ${NODE_NAME}-Reality   vless  ${PUB_IP}:${REALITY_PORT}  (SNI ${SNI})"
echo "    ${NODE_NAME}-AnyTLS    anytls ${PUB_IP}:${ANYTLS_PORT}  (SNI ${SNI})"
if [[ "$ENABLE_HY2" == "1" ]]; then
  echo "    ${NODE_NAME}-Hy2       hysteria2 ${PUB_IP}:443/UDP"
fi
echo
echo "  NEXT STEPS"
echo "    * Open the CLOUD firewall (console, IPv4 AND IPv6 are separate):"
echo "        TCP ${REALITY_PORT}, TCP ${ANYTLS_PORT}, TCP ${SUB_PORT}"
[[ "$ENABLE_HY2" == "1" ]] && echo "        UDP 443"
echo "    * The subscription serves node secrets over plain HTTP: keep the"
echo "      token secret, and refresh the subscription THROUGH the proxy."
echo "    * China Mobile users: prefer the Reality node; Hysteria2 (UDP) gets"
echo "      throttled under load on CMCC."
echo "=============================================================="

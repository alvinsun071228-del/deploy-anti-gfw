# deploy-anti-gfw

一键部署个人翻墙节点:SSH 登录你的海外 VPS,粘贴一条命令,几分钟内自动搭好一套**带流量统计、可直接导入客户端**的代理服务。

不需要懂 Linux,不需要懂代理协议,跟着下面的步骤做就行。

## 部署完成后你会得到

| 产出 | 说明 |
|---|---|
| **2~3 个节点** | Reality 主节点(抗封锁)+ AnyTLS 备用节点(自动故障切换)+ Hysteria2(可选) |
| **1 个订阅链接** | 导入客户端自动获得节点 + 分流规则 + 机场式流量条 |
| **1 个流量仪表盘** | 网页实时显示本月已用 / 上限 / 剩余 / 重置天数 |

## 部署了什么

| 组件 | 协议 | 端口 | 说明 |
|---|---|---|---|
| Xray | VLESS + XTLS-Vision + REALITY | TCP 443 | 主节点,三大运营商都稳,伪装成访问 microsoft.com |
| sing-box | AnyTLS | TCP 8443 | 备用 TCP 协议,客户端不支持时自动切换 |
| Hysteria2(可选) | QUIC/UDP | UDP 443 | 低延迟,但移动网络 UDP 高峰期易被限速,默认不装 |
| 网络调优 | BBR/fq、64MB 缓冲、initcwnd、MSS clamp | - | 通过 systemd 持久化,重启不丢 |
| 订阅服务器 | Python + vnstat | TCP 28443 | 输出带流量信息的订阅配置 + 仪表盘网页 |

## 你需要准备

1. **一台海外 VPS**
   - 系统:Ubuntu 20.04+ 或 Debian 11+(64 位)
   - 配置:512MB 内存即可,1GB 更宽裕
   - 推荐:AWS Lightsail、Vultr、DigitalOcean、搬瓦工(BandwagonHost)等,机房选日本 / 香港 / 新加坡 / 美国
2. **SSH 客户端**
   - macOS / Linux:系统自带终端
   - Windows:PowerShell、Termius、Xshell 均可
3. **代理客户端**(装在你平时上网的设备上)
   - iOS:Stash
   - Android:Clash Meta for Android、FlClash
   - Windows:v2rayN、Clash Verge Rev
   - macOS / Linux:Clash Verge Rev

## 三步安装

### 第 1 步:SSH 登录你的 VPS

```bash
ssh root@你的服务器IP
```

> 用非 root 用户登录的,先执行 `sudo -i` 切到 root,再继续。

### 第 2 步:运行脚本(三种方式任选)

**方式 A — 一条命令(推荐)**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/alvinsun071228-del/deploy-anti-gfw/main/deploy-anti-gfw.sh)
```

服务器上没有 curl 的话用 wget 版:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/alvinsun071228-del/deploy-anti-gfw/main/deploy-anti-gfw.sh)
```

**方式 B — 先下载、检查代码再运行**

```bash
curl -fsSL -o deploy-anti-gfw.sh https://raw.githubusercontent.com/alvinsun071228-del/deploy-anti-gfw/main/deploy-anti-gfw.sh
less deploy-anti-gfw.sh      # 先读一遍代码,放心了再继续
sudo bash deploy-anti-gfw.sh
```

**方式 C — 单行压缩版**(方式 A 网络不通时用)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/alvinsun071228-del/deploy-anti-gfw/main/deploy-anti-gfw.oneliner.txt | base64 -d | gunzip)
```

或手动:打开 [`deploy-anti-gfw.oneliner.txt`](deploy-anti-gfw.oneliner.txt),复制全部内容粘贴到终端回车。

### 第 3 步:记下脚本最后打印的三个链接

跑完(约 3~5 分钟)会输出:

- **Subscription(订阅地址)** — `http://你的IP:28443/sub/一串随机token`,下面导入客户端用它
- **Single-node Reality link** — `vless://` 开头的单节点链接,快速导入用
- **Traffic dashboard(仪表盘)** — `http://你的IP:28443/那串token`,浏览器打开看流量

## ⚠️ 必做:开放云防火墙(最常见翻车点)

脚本只配置了**服务器系统内**的防火墙。云厂商控制台的防火墙(安全组)是独立的另一层,**必须手动开放**:

| 用途 | 协议 | 端口 |
|---|---|---|
| Reality 节点 | TCP | 443 |
| AnyTLS 节点 | TCP | 8443 |
| 订阅 / 仪表盘 | TCP | 28443 |
| Hysteria2(仅当开启时) | UDP | 443 |

- AWS Lightsail:实例 → 网络(Networking)→ 防火墙规则;**IPv4 和 IPv6 是两组独立规则,都要加**
- AWS EC2:安全组(Security Group)→ 入站规则
- Vultr / DigitalOcean / 搬瓦工:后台防火墙页,同样注意 IPv4 / IPv6 分开

## 导入客户端

### 订阅方式(推荐)

把 `http://你的IP:28443/sub/那串token` 粘贴到客户端:

- **Stash(iOS)**:设置页 → 点击「+」→ 添加订阅
- **Clash Verge Rev / Clash Meta for Android / FlClash**:Profiles(配置)→ 新建 → 粘贴 URL
- **v2rayN(Windows)**:订阅分组 → 订阅分组设置 → 添加 → 粘贴 URL → 更新订阅

订阅自带分流规则:微信/QQ/抖音/字节系和国内网站强制直连,YouTube 自动走 Reality 节点,AI 服务单独分组,国内外 DNS 分流。选 `Proxy` 分组即可全局代理。

### 单节点方式

把 `vless://` 链接导入 v2rayN、Shadowrocket、v2rayNG、Streisand 等任意支持 VLESS + REALITY 的客户端。

### 客户端兼容性提示

- **Reality 节点**:需要客户端支持 XTLS-Vision,上面列出的客户端都支持
- **AnyTLS 节点**:较新,Clash Meta 系(mihomo / Clash Verge Rev / FlClash)支持;老客户端连不上会自动走 Reality,不影响使用

## 可选参数

运行脚本前加环境变量即可覆盖默认值:

| 变量 | 默认值 | 说明 |
|---|---|---|
| `REALITY_PORT` | `443` | Reality 节点端口,被墙时可换 |
| `ANYTLS_PORT` | `8443` | AnyTLS 节点端口 |
| `SUB_PORT` | `28443` | 订阅 / 仪表盘端口 |
| `SNI` | `www.microsoft.com` | REALITY 伪装的目标网站 |
| `CAP_GB` | `2000` | 每月流量上限(GB),仪表盘和订阅流量条按它算 |
| `NODE_NAME` | `Tokyo` | 节点显示名称 |
| `ENABLE_HY2` | `0` | 设为 `1` 时额外安装 Hysteria2 |

示例:

```bash
CAP_GB=500 NODE_NAME=HongKong bash <(curl -fsSL https://raw.githubusercontent.com/alvinsun071228-del/deploy-anti-gfw/main/deploy-anti-gfw.sh)

ENABLE_HY2=1 bash deploy-anti-gfw.sh
```

> 重跑脚本会覆盖配置并重新生成所有密钥,旧的订阅链接会失效,需要重新导入。

## 流量仪表盘

浏览器打开 `http://你的IP:28443/那串token`:

- 本月已用 / 上限 / 剩余 / 重置天数,带机场式进度条,60 秒自动刷新
- 客户端订阅里同样带流量信息,打开客户端就能看到

## 常见问题

### 订阅链接打不开 / 导入失败

订阅是**明文 HTTP**,在墙内直接访问可能被干扰。先用 vless 单节点链接连上代理,**再通过代理**刷新订阅。同时检查云防火墙是否开放了 `28443`。

### 节点连不上

1. 云防火墙是否开放了对应端口(最常见的坑,先查这个)
2. SSH 回服务器执行 `ss -lntp`,确认 443 / 8443 / 28443 在监听
3. Reality 被墙:换 `REALITY_PORT` 和 `SNI` 重新部署

### 中国移动用户

优先用 Reality 节点;Hysteria2 走 UDP,移动会在高峰期限速甚至阻断,不建议依赖。

### Stash 用户开 Hysteria2

订阅里 Hy2 节点字段是 mihomo 拼写(`password` / `obfs-password` / `up` / `down`),**Stash 需要手动改成** `auth` / `up-speed` / `down-speed`。

### 忘了 token

SSH 回服务器,查看 `/usr/local/sbin/traffic-dashboard.py` 开头的 `SECRET = "..."` 那一行。

### 卸载

没有一键卸载。停服务、删文件即可:

```bash
systemctl disable --now xray sing-box stash-sub net-tune 2>/dev/null
rm -rf /usr/local/etc/xray /etc/sing-box /etc/stash-sub /etc/hysteria
rm -f /usr/local/sbin/traffic-dashboard.py /usr/local/sbin/net-tune.sh /etc/systemd/system/{stash-sub,net-tune,sing-box}.service /etc/sysctl.d/99-proxy.conf
```

## 工作原理简述

| 协议 | 特点 |
|---|---|
| VLESS + XTLS-Vision + REALITY | 无需证书,流量伪装成与 microsoft.com 的合法 TLS 会话,抗探测能力强,目前被封锁概率最低的方案之一 |
| AnyTLS | 较新的协议,流量形态接近普通 TLS,作为第二协议冗余 |
| Hysteria2 | 基于 QUIC(UDP),低延迟高吞吐,代价是 UDP 在部分网络(尤其移动)容易被 QoS 限速 |

## 安全性

- 订阅和仪表盘靠 URL 里的**随机 token** 保护,泄露 token 等于泄露节点,发截图前打码
- 订阅走明文 HTTP,**刷新订阅时请通过代理**,避免 token 在墙内链路被看到
- 节点按**自用**设计,公开分享有 IP 被墙、流量被滥用的风险

## 免责声明

本项目仅供技术学习与交流。请遵守你所在地区的法律法规,因使用本项目产生的任何后果由使用者自行承担。

## 文件

| 文件 | 说明 |
|---|---|
| `deploy-anti-gfw.sh` | 完整脚本,可读、可改 |
| `deploy-anti-gfw.oneliner.txt` | 同一脚本的 gzip+base64 单行压缩版 |

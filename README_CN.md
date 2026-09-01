# Netglimmer VPN Manager

> 企业级 OpenConnect VPN 管理面板，支持实时监控、态势感知与一键自动化部署。

**Netglimmer** 是一套基于 [ocserv](https://ocserv.gitlab.io/www/ocserv.html) (OpenConnect VPN 服务器) 构建的商业级 VPN 管理解决方案。它提供了一个现代化的 Web 管理面板，包含用户管理、实时监控、证书管理等丰富功能。

![Version](https://img.shields.io/badge/version-1.7-blue)
![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-lightgrey)
![License](https://img.shields.io/badge/license-Commercial-red)

---

## 功能特性

- **仪表盘** — 实时在线用户数监控、系统资源占用（CPU / 内存 / 磁盘）以及 VPN 服务状态展示
- **态势感知** — 世界 / 中国双地图可视化（采用 ECharts 离线地图，零外部依赖）：来源国家/省份热力图、动态连接轨迹、TOP 统计排行、活跃源水滴波纹效果；登录失败/封禁源红框威胁标记；24h / 7d / 全部时间范围切换；支持全屏大屏展示模式（独立持久化 Token）
- **服务器位置** — 可在态势感知页面设置服务器所在国家/省份，直观呈现连接轨迹
- **IP 地理位置查询** — 三级查询链机制：ip2region 离线数据库（可经由系统设置导入）→ 本地持久化缓存 → ip-api.com 在线兜底查询
- **用户管理** — VPN 用户的创建、修改与删除；查看登录历史与流量消耗；支持 CSV 批量导入/导出
- **用户组管理** — 创建/编辑用户组，支持按组配置客户端 IP 网段 (`config-per-group`) 及成员组归属管理
- **资源管理** — 管理 VPN 客户端可访问的网络资源（CIDR / 域名），按组进行分配；CIDR 资源将下发为 VPN 路由，域名资源则通过智能域名放行机制处理
- **在线用户** — 实时在线会话监控，支持一键强制踢出用户
- **连接历史** — 详细的 VPN 连接日志记录（时间、IP、流量、时长）；支持检索与 CSV 导出
- **网络与策略** — 网络接口管理（自动/静态双模式、三 DNS 配置、实时吞吐率）、静态路由、NAT 规则（SNAT/DNAT/MASQUERADE）、访问控制（带命中计数器的过滤链）、支持 IPv6 全双栈
- **证书管理** — 纯 Web 化的 CA 证书、服务器证书及客户端证书生成，支持 PKCS#12 导出与 CRL 吊销列表管理
- **封禁管理** — 查看并解封被 ocserv 自动封禁的 IP
- **VPN 配置** — 可直接在 Web UI 修改 ocserv 核心参数（监听端口/协议、服务伪装、客户端网段、DNS 下发、智能域名放行、登录 Banner 等）
- **系统设置** — 时区设置（支持 80+ 城市双语选择）、NTP 时间同步、面板 HTTPS 端口修改、空闲超时设置、GeoIP 数据库管理
- **配置备份** — ZIP 一键备份与还原（包含 ocserv.conf、ocpasswd、config-per-group 及 SQLite 数据库）；支持定时自动备份；支持 AES-256-GCM 加密备份与 SSH 远程推送
- **消息通知** — 支持邮件 (SMTP)、飞书 Webhook 以及 Telegram Bot 通知渠道，提供细粒度的事件订阅配置
- **密码重置** — 用户可通过邮件自助重置密码（包含 CSP 安全头与频率限制）
- **双语支持** — 中文 / 英文 界面切换 (vue-i18n)
- **WebSocket** — 实时数据推送，无需手动刷新页面
- **离线授权** — 纯离线试用（15天）+ License 证书授权（永久 / 限时）；Ed25519 签名校验，具备防系统时钟回拨保护
- **安全保障** — bcrypt 密码哈希存储、Session Token 与 IP 强绑定；内部 API 双重鉴权（Nginx 层 + X-Internal-Token）；WebSocket 连接生命周期绑定

---

## 系统要求

| 项目 | 要求规格 |
|---|---|
| **操作系统** | Debian 12 / Ubuntu (x86_64) |
| **CPU** | 1 核及以上 |
| **内存** | 512 MB 及以上 |
| **磁盘空间** | 2 GB 及以上（额外需要约 120 MB 存放离线依赖） |
| **网络** | 推荐使用具备公网 IP 的服务器 |
| **权限** | root 权限 |

---

## 快速开始

### 一键安装

```bash
# 下载并解压安装包
wget https://github.com/netglimmer/netglimmer-vpn-manage/archive/refs/heads/main.zip -O netglimmer-vpn-manage.zip
unzip netglimmer-vpn-manage.zip
cd netglimmer-vpn-manage-main

# 在线模式安装（自动检测，会有交互提示）
sudo bash netglimmer_vpn_install.sh

# 离线模式安装（无需互联网连接）
sudo bash netglimmer_vpn_install.sh --offline
```

安装脚本将自动完成以下操作：
1. 安装系统依赖包（离线模式下使用附带的 `offline-debs/`）
2. 从源码编译并安装 ocserv 1.5.0
3. 自动生成 SSL 证书
4. 配置 VPN 服务网络（NAT、防火墙规则、dnsmasq）
5. 安装管理面板二进制文件（自动识别交付模式，无需配置 Go/Node 环境）
6. 配置并启动 systemd 系统服务
7. 配置 Nginx HTTPS 反向代理

### 安装完成后

1. 使用浏览器访问面板：`https://<你的服务器IP>:443`
2. 使用默认凭据登录：用户名 **admin** / 密码 **netglimmer**（请在首次登录后立即修改！）
3. 前往 **系统授权** 页面获取您的机器码（Machine ID）
4. 联系软件供应商获取对应的 `.lic` 授权文件
5. 导入授权文件完成激活

### 管理控制台菜单

```bash
# 打开交互式管理菜单
sudo bash netglimmer_vpn_install.sh

# 卸载服务
sudo bash netglimmer_vpn_install.sh uninstall
```

---

## 安装包结构

```
netglimmer_vpn_install_v1.7_release/
├── ocserv-manager              # 预编译的管理面板二进制文件 (~15 MB)
├── netglimmer_vpn_install.sh   # 一键安装/卸载脚本 (~3,040 行)
├── pack_offline_debs.sh        # 离线 .deb 包打包脚本（在联网主机上运行）
├── connect.sh                  # ocserv 连接 Hook 脚本（用户上线事件）
├── disconnect.sh               # ocserv 断开 Hook 脚本（用户下线事件）
├── ocserv-1.5.0.tar.xz         # ocserv 源码包 (GPL 协议，在目标机编译)
├── offline-debs/               # 196 个系统依赖 .deb 安装包 (~120 MB)
├── EULA.txt                    # 最终用户许可协议
├── .gitignore                  # Git 忽略规则文件
└── checksums.sha256            # SHA256 文件完整性校验和
```

### 校验安装包完整性

```bash
cd netglimmer_vpn_install_v1.7_release
sha256sum -c checksums.sha256
```

---

## 系统架构图

```
┌─────────────────────────────────────────────┐
│                 Web 浏览器                  │
│           (Vue 3 + Element Plus)            │
└──────────────┬──────────────────────────────┘
               │ HTTPS (WebSocket)
┌──────────────▼──────────────────────────────┐
│               Nginx (443)                   │
│         反向代理 + TLS 证书解密             │
└──────────────┬──────────────────────────────┘
               │ HTTP (127.0.0.1:8088)
┌──────────────▼──────────────────────────────┐
│         ocserv-manager (Go 程序)            │
│  ┌──────────┐ ┌──────────┐ ┌────────────┐  │
│  │ REST API │ │WebSocket │ │   内置     │  │
│  │ (net/http)│ │   Hub    │ │  前端静态  │  │
│  └──────────┘ └──────────┘ └────────────┘  │
│              SQLite (WAL 模式)               │
└──────────────┬──────────────────────────────┘
               │ iptables / ipset / dnsmasq
┌──────────────▼──────────────────────────────┐
│            ocserv 1.5.0 (OpenConnect)        │
│        VPN 隧道 (TCP 443 + UDP DTLS)        │
└─────────────────────────────────────────────┘
```

---

## 离线部署指南

本安装包专为**完全隔离的无网环境（物理隔离区）**设计：

- 所有的系统依赖均已打包为 `.deb` 文件
- ocserv 将通过本地源码包直接编译安装
- 管理面板为包含了内置前端静态资源的单个预编译二进制文件
- 安装全过程无需任何互联网连接

### 安装模式说明

安装脚本同时支持在线与完全离线模式：

```bash
# 交互式安装（根据 offline-debs/ 目录是否存在进行提示）
sudo bash netglimmer_vpn_install.sh

# 强制离线模式安装（若缺少 offline-debs/ 目录则报错退出）
sudo bash netglimmer_vpn_install.sh --offline

# 通过环境变量强制设定在线/离线模式
OFFLINE_MODE=true  sudo bash netglimmer_vpn_install.sh   # 强制离线
OFFLINE_MODE=false sudo bash netglimmer_vpn_install.sh   # 强制在线
```

> **注意**：随包附带的 `offline-debs/` 适用于 **Debian 12 amd64** 系统。若需在其他发行版或架构上部署，请参考下方章节。

### 为其他 Linux 发行版打包离线依赖

附带的 `offline-debs/` 依赖包**绑定于特定的系统版本和 CPU 架构**（默认 Debian 12 amd64）。若您需要部署至其他发行版（如 Ubuntu 22.04）或不同架构（如 ARM64），请在一台与目标服务器**系统、版本及架构完全一致且可联网的主机**上重新生成离线依赖包：

```bash
# 在具有相同系统版本/架构的联网机器上执行（需要 root 权限）
sudo bash pack_offline_debs.sh
```

该脚本将完成：
1. 解析并计算所有所需软件的全部传递依赖关系链
2. 将所有 `.deb` 安装包下载至 `offline-debs/` 目录
3. 使用 `dpkg-scanpackages` 进行模拟分析，验证依赖闭包的完整性
4. 写入包含系统/架构元数据的 `PACK_INFO` 标识文件

打包完成后，将整套安装包（包含更新后的 `offline-debs/` 目录）拷贝至无网的目标服务器即可进行离线安装。

---

## 系统升级

升级至新版本步骤如下：

1. 下载最新的发布安装包
2. 解压并替换 `ocserv-manager` 二进制文件
3. 重启服务：`systemctl restart ocserv-manager`
4. 您的授权许可、用户数据及配置文件均会被自动保留

---

## 软件许可协议

本软件为商业专有软件，受 [Netglimmer EULA](EULA.txt) 协议约束。

- **试用许可**：安装后自动获得 15 天的全功能免费试用期
- **商业授权**：提供按服务器绑定的按时计费或永久商业授权

安装包内包含的 ocserv 组件遵循 GPLv2 开源协议，并以源码形式提供以便在目标机器上编译。

---

## 技术支持

如需技术支持、购买商业授权或提交 Bug 报告，请联系您的 Netglimmer 供应商或在仓库中提交 Issue。

---

*Netglimmer VPN Manager v1.7 — 基于 Go + Vue 3 + ocserv 构建*

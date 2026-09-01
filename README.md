# Netglimmer VPN Manager

> Enterprise-grade OpenConnect VPN management panel with real-time monitoring, situational awareness, and one-click deployment.

**Netglimmer** is a commercial VPN management solution built on top of [ocserv](https://ocserv.gitlab.io/www/ocserv.html) (OpenConnect VPN server). It provides a modern web-based administration panel with comprehensive features for user management, real-time monitoring, certificate management, and more.

![Version](https://img.shields.io/badge/version-1.7-blue)
![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-lightgrey)
![License](https://img.shields.io/badge/license-Commercial-red)

---

## Features

- **Dashboard** — Real-time online user count, system resources (CPU / Memory / Disk), and VPN service status
- **Situational Awareness** — World / China dual-map visualization (ECharts offline maps, zero external dependency): source country/province heat mapping, animated connection paths, TOP rankings, active source ripple effects; login failure / banned source red threat markers; 24h / 7d / all range switching; full-screen big-screen mode (independent persistent token)
- **Server Location** — Set server country/province in the situational awareness page for intuitive connection path visualization
- **IP Geolocation** — Three-tier query chain: ip2region offline DB (import via System Settings) → local persistent cache → ip-api.com online fallback
- **User Management** — Create, modify, delete VPN users; view login history and traffic usage; CSV import/export
- **User Group Management** — Create/edit user groups with per-group client IP subnets (`config-per-group`); manage group membership
- **Resource Management** — Manage VPN client accessible network resources (CIDR / domain), assign by group; CIDR resources pushed as VPN routes, domain resources handled by smart domain pass-through
- **Online Users** — Real-time online session monitoring with one-click user disconnect
- **Connection History** — Detailed VPN connection records (time, IP, traffic, duration); search and CSV export
- **Network & Policy** — Network interfaces (auto/static dual-mode, triple DNS, real-time throughput), static routes, NAT rules (SNAT/DNAT/MASQUERADE), access control (filter chain with hit counters), IPv6 full dual-stack support
- **Certificate Management** — Full web-based CA, server cert, client cert generation, PKCS#12 export, and CRL management
- **Ban Management** — View and unblock IPs banned by ocserv
- **VPN Configuration** — Modify ocserv core settings via web UI (listening port/protocol, service camouflage, client subnets, DNS push, smart domain pass-through, login banner, etc.)
- **System Settings** — Timezone (80+ cities, bilingual), NTP sync, panel HTTPS port, idle timeout, GeoIP database management
- **Configuration Backup** — ZIP one-click backup/restore (ocserv.conf, ocpasswd, config-per-group, SQLite DB); scheduled auto-backup; AES-256-GCM encrypted backup with SSH remote push
- **Notifications** — Email (SMTP), Feishu Webhook, and Telegram Bot channels with fine-grained event subscription
- **Password Reset** — User self-service password reset via email (CSP headers + rate limiting)
- **Bilingual** — Chinese / English interface (vue-i18n)
- **WebSocket** — Real-time data push, no manual polling needed
- **Offline Licensing** — Pure offline trial (15 days) + License authorization (permanent / duration); Ed25519 signature verification, anti-clock-rollback protection
- **Security** — bcrypt password hashing, session token + IP binding; internal API dual-auth (nginx layer + X-Internal-Token); WebSocket lifecycle-bound connections

---

## System Requirements

| Requirement | Specification |
|---|---|
| **OS** | Debian 12 / Ubuntu (x86_64) |
| **CPU** | 1+ core |
| **RAM** | 512 MB+ |
| **Disk** | 2 GB+ (plus offline deps ~120 MB) |
| **Network** | Public IP recommended for VPN server |
| **Privilege** | root |

---

## Quick Start

### One-Click Installation

```bash
# Download and extract the release package
tar xzf netglimmer_vpn_install_v1.7_release.tar.gz
cd netglimmer_vpn_install_v1.7_release

# Online mode (auto-detects, will prompt)
sudo bash netglimmer_vpn_install.sh

# Offline mode (no internet required)
sudo bash netglimmer_vpn_install.sh --offline
```

The installer will:
1. Install system dependencies (from bundled `offline-debs/` in offline mode)
2. Compile and install ocserv 1.5.0 from source
3. Generate SSL certificates
4. Configure VPN service (NAT, firewall rules, dnsmasq)
5. Install the management panel binary (auto-detected binary delivery mode, skips Go/Node)
6. Set up systemd services
7. Configure Nginx HTTPS reverse proxy

### Post-Installation

1. Access the panel at `https://<your-server-ip>:443`
2. Login with default credentials: **admin** / **netglimmer** (change immediately!)
3. Navigate to **Authorization** page to get your machine ID
4. Contact your vendor to obtain a `.lic` license file
5. Import the license file to activate

### Management Console

```bash
# Interactive management menu
sudo bash netglimmer_vpn_install.sh

# Uninstall
sudo bash netglimmer_vpn_install.sh uninstall
```

---

## Package Contents

```
netglimmer_vpn_install_v1.7_release/
├── ocserv-manager              # Pre-compiled management panel binary (~15 MB)
├── netglimmer_vpn_install.sh   # One-click install/uninstall script (~3,040 lines)
├── pack_offline_debs.sh        # Generate offline .deb packages (run on internet-connected host)
├── connect.sh                  # ocserv connection hook script (user connect event)
├── disconnect.sh               # ocserv disconnection hook script (user disconnect event)
├── ocserv-1.5.0.tar.xz         # ocserv source (GPL, compiled on target)
├── offline-debs/               # 196 system dependency .deb packages (~120 MB)
├── EULA.txt                    # End User License Agreement
├── .gitignore                  # Git ignore rules (prevent accidental commits)
└── checksums.sha256            # SHA256 integrity checksums
```

### Verify Package Integrity

```bash
cd netglimmer_vpn_install_v1.7_release
sha256sum -c checksums.sha256
```

---

## Architecture

```
┌─────────────────────────────────────────────┐
│                  Browser                     │
│           (Vue 3 + Element Plus)            │
└──────────────┬──────────────────────────────┘
               │ HTTPS (WebSocket)
┌──────────────▼──────────────────────────────┐
│               Nginx (443)                   │
│        Reverse Proxy + TLS Termination      │
└──────────────┬──────────────────────────────┘
               │ HTTP (127.0.0.1:8088)
┌──────────────▼──────────────────────────────┐
│         ocserv-manager (Go binary)          │
│  ┌──────────┐ ┌──────────┐ ┌────────────┐  │
│  │ REST API │ │WebSocket │ │   Embed    │  │
│  │ (net/http)│ │   Hub    │ │  Frontend  │  │
│  └──────────┘ └──────────┘ └────────────┘  │
│              SQLite (WAL mode)               │
└──────────────┬──────────────────────────────┘
               │ iptables / ipset / dnsmasq
┌──────────────▼──────────────────────────────┐
│            ocserv 1.5.0 (OpenConnect)        │
│        VPN Tunnel (TCP 443 + UDP DTLS)      │
└─────────────────────────────────────────────┘
```

---

## Offline Deployment

The package is designed for **fully air-gapped** deployment:

- All system dependencies are bundled as `.deb` packages
- ocserv is compiled from bundled source tarball
- The management panel is a pre-compiled single binary with embedded frontend
- No internet access required during installation

### Installation Modes

The installer supports both online and fully offline modes:

```bash
# Interactive (prompts based on offline-debs/ availability)
sudo bash netglimmer_vpn_install.sh

# Force offline mode (fails if offline-debs/ is missing)
sudo bash netglimmer_vpn_install.sh --offline

# Force online/offline via environment variable
OFFLINE_MODE=true  sudo bash netglimmer_vpn_install.sh   # force offline
OFFLINE_MODE=false sudo bash netglimmer_vpn_install.sh   # force online
```

> **Note**: The bundled `offline-debs/` are for **Debian 12 amd64**. For other distributions or architectures, see the section below.

### Generating Offline Deb Packages for Other Distributions

The bundled `offline-debs/` packages are **tied to a specific distribution version and architecture** (Debian 12 amd64 by default). If you need to deploy on a different distribution (e.g., Ubuntu 22.04) or architecture (e.g., ARM64), regenerate the offline deb packages on an **internet-connected host** running the **same distribution, version, and architecture** as the target machine:

```bash
# Run on an internet-connected machine with matching distro/version/arch (requires root)
sudo bash pack_offline_debs.sh
```

The script will:
1. Resolve the full transitive dependency closure for all required packages
2. Download every `.deb` into `offline-debs/`
3. Verify closure completeness using `dpkg-scanpackages` (dry-run solve)
4. Write a `PACK_INFO` marker with distro/version/arch metadata

Then copy the entire release package directory (with the updated `offline-debs/`) to the air-gapped target machine.

---

## Upgrade

To upgrade to a newer version:

1. Download the new release package
2. Extract and replace the `ocserv-manager` binary
3. Restart the service: `systemctl restart ocserv-manager`
4. Your license, user data, and configuration are preserved

---

## License

This software is proprietary and licensed under the [Netglimmer EULA](EULA.txt).

- **Trial**: 15-day fully functional trial upon installation
- **Commercial License**: Duration-based or permanent, per-server licensing available

The included ocserv component is licensed under GPLv2 and is provided as source code for on-target compilation.

---

## Support

For technical support, license inquiries, or bug reports, please contact your Netglimmer vendor or open an issue in this repository.

---

*Netglimmer VPN Manager v1.7 — Built with Go + Vue 3 + ocserv*

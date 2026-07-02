# Tailscale OpenWrt Installer

Modular installer for Tailscale on OpenWrt 25.12+ (tested on Xiaomi Mi Router 3G / MT7621).

## Features

- **Modular design** - Each step in a separate script for easy debugging
- **Automatic architecture detection** - Works on MIPS (MT7621), ARM, ARM64, x86_64
- **Multiple installation methods** - apk (preferred) or direct binary download
- **Auto dependency installation** - ca-certificates, kmod-tun, iptables modules
- **Network & firewall configuration** - Interface, zone, forwarding, access rules
- **Procd service management** - Auto-start with watchdog/respawn
- **Exit Node support** - Optional (`TAILSCALE_EXIT_NODE=1`)
- **Subnet router support** - Auto-detects LAN subnet (`TAILSCALE_ADVERTISE_ROUTES=auto`)
- **Auth key support** - Fully automated (`TAILSCALE_AUTH_KEY=tskey-xxx`)
- **DNS control** - Optional Tailscale DNS (`TAILSCALE_ACCEPT_DNS=1`)

## Quick Start

```bash
# Copy to router and run
scp -r tailscale root@192.168.1.1:/root/
ssh root@192.168.1.1
cd /root/tailscale
./install.sh
```

Then authorize via the URL shown in the output.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TAILSCALE_AUTH_KEY` | *(empty)* | Auth key for automatic authorization (get from [tailscale.com/k/keys](https://login.tailscale.com/admin/settings/keys)) |
| `TAILSCALE_EXIT_NODE` | `0` | Set to `1` to advertise as exit node |
| `TAILSCALE_ADVERTISE_ROUTES` | `auto` | Subnets to advertise. `auto` = detect LAN, `0` = disable, or CIDR like `192.168.1.0/24` |
| `TAILSCALE_ACCEPT_DNS` | `0` | Set to `1` to use Tailscale DNS (MagicDNS) |
| `TAILSCALE_SSH` | `1` | Set to `0` to disable `--ssh` flag |
| `TAILSCALE_EXTRA_ARGS` | *(empty)* | Extra args passed to `tailscale up` |
| `TAILSCALE_INSTALL_DIR` | `auto` | Install location: `auto` (prefer /usr/sbin), or custom path |

## Examples

### Manual authorization (default)
```bash
./install.sh
```

### Automatic with auth key
```bash
TAILSCALE_AUTH_KEY=tskey-abc123 ./install.sh
```

### As Exit Node + Subnet Router
```bash
TAILSCALE_AUTH_KEY=tskey-abc123 \
TAILSCALE_EXIT_NODE=1 \
TAILSCALE_ADVERTISE_ROUTES=auto \
./install.sh
```

### Custom subnet only
```bash
TAILSCALE_ADVERTISE_ROUTES=192.168.31.0/24 ./install.sh
```

### With MagicDNS
```bash
TAILSCALE_ACCEPT_DNS=1 ./install.sh
```

### Custom hostname
```bash
TAILSCALE_EXTRA_ARGS="--hostname=xiaomi-router" ./install.sh
```

## Architecture Support

| Router Architecture | `uname -m` | Tailscale Binary |
|---------------------|------------|------------------|
| MT7621 (Mi Router 3G, etc.) | `mips` / `mipsel` | `mipsle` |
| MT7622 / MT798x (ARM) | `armv7l` | `arm` |
| IPQ807x / IPQ60xx (ARM64) | `aarch64` | `arm64` |
| x86_64 | `x86_64` | `amd64` |

## Module Structure

```
tailscale/
├── install.sh              # Main entry point
├── lib/
│   ├── common.sh           # Logging, helpers, UCI wrappers
│   ├── system.sh           # Arch detection, deps, installation
│   ├── network.sh          # Network interface utilities
│   └── firewall.sh         # Firewall zone, rules, NAT
└── modules/
    ├── 01-deps.sh          # Install dependencies
    ├── 02-install.sh       # Install Tailscale (apk or download)
    ├── 03-network.sh       # Configure network interface
    ├── 04-firewall.sh      # Configure firewall
    ├── 05-service.sh       # Procd init script + autostart
    └── 06-config.sh        # Summary & instructions
```

## Post-Installation

After running the installer:

1. **If using auth key**: Device connects automatically on boot
2. **If manual**: Run the shown `tailscale up` command and open the URL
3. **Approve routes** in [Tailscale Admin Console](https://login.tailscale.com/admin/machines) if advertising routes/exit node

### Useful Commands

```bash
# Check status
tailscale status

# Get Tailscale IP
tailscale ip -4

# Network diagnostics
tailscale netcheck

# Restart service
/etc/init.d/tailscale restart

# View logs
logread -f | grep tailscale
```

## Uninstall

```bash
# Stop and disable service
/etc/init.d/tailscale stop
/etc/init.d/tailscale disable

# Remove firewall rules
uci -q delete firewall.tailscale
uci -q delete firewall.tailscale_ssh
uci -q delete firewall.tailscale_http
uci -q delete firewall.tailscale_https
uci -q delete firewall.tailscale_exit_node_nat
# Remove forwarding
uci commit firewall
/etc/init.d/firewall reload

# Remove network interface
uci -q delete network.tailscale
uci commit network
/etc/init.d/network reload

# Remove binaries
rm -f /usr/bin/tailscale /usr/sbin/tailscaled /tmp/tailscale/tailscale*

# Remove init script
rm -f /etc/init.d/tailscale

# Remove from rc.local
sed -i '/tailscale up/d' /etc/rc.local

# Remove TUN module autoload
rm -f /etc/modules.d/99-tailscale-tun
```

## Troubleshooting

### TUN device not found
```bash
modprobe tun
ls -l /dev/net/tun
```
Add `tun` to `/etc/modules.d/99-tailscale-tun` for persistence.

### Low disk space
The installer auto-detects space and uses `/tmp/tailscale` if `/overlay` has <20MB free.
```bash
df -h /overlay
```

### Firewall not working
```bash
# Check zone exists
uci show firewall.tailscale

# Check forwarding
uci show firewall.@forwarding

# Reload firewall
/etc/init.d/firewall restart
```

### Can't connect to Tailscale
```bash
# Check daemon status
/etc/init.d/tailscale status
logread | grep tailscale

# Run netcheck
tailscale netcheck

# Manual reconnect
tailscale up --accept-dns=false --advertise-routes=192.168.1.0/24 --ssh
```

## Requirements

- OpenWrt 21.02+ (tested on 25.12.4)
- Root access
- Internet connectivity (for downloads)
- ~20MB free on `/overlay` (or uses `/tmp`)

## License

MIT License - Feel free to use and modify.
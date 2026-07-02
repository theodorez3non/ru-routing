#!/bin/sh
# lib/common.sh - Common utilities for Tailscale installation scripts
# Part of Tailscale OpenWrt installer

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    if [ -n "${DEBUG:-}" ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Run command with logging and error checking
run_cmd() {
    local cmd="$1"
    local desc="${2:-Executing command}"
    log_debug "$desc: $cmd"
    if eval "$cmd"; then
        log_debug "Success: $desc"
        return 0
    else
        local ret=$?
        log_error "Failed ($ret): $desc"
        return $ret
    fi
}

# Check if running as root
require_root() {
    if [ "$(id -u)" != "0" ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Check if command exists
require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command not found: $cmd"
        exit 1
    fi
}

# Check if file exists
require_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        log_error "Required file not found: $file"
        exit 1
    fi
}

# Check if directory exists
require_dir() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        log_error "Required directory not found: $dir"
        exit 1
    fi
}

# Get OpenWrt version
get_openwrt_version() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${VERSION_ID:-unknown}"
    else
        echo "unknown"
    fi
}

# Get architecture
get_arch() {
    uname -m
}

# Get Tailscale architecture name
get_tailscale_arch() {
    local arch=$(get_arch)
    case "$arch" in
        mips|mipsel) echo "mipsle" ;;
        armv7l) echo "arm" ;;
        aarch64) echo "arm64" ;;
        x86_64) echo "amd64" ;;
        *) echo "unknown" ;;
    esac
}

# Check disk space in KB
get_free_space_kb() {
    local path="${1:-/overlay}"
    df "$path" | awk 'NR==2 {print $4}'
}

# Check disk space in MB
get_free_space_mb() {
    local path="${1:-/overlay}"
    local kb=$(get_free_space_kb "$path")
    echo $((kb / 1024))
}

# Check if we have enough space (in MB)
check_space() {
    local required_mb="${1:-20}"
    local path="${2:-/overlay}"
    local free_mb=$(get_free_space_mb "$path")
    
    if [ "$free_mb" -lt "$required_mb" ]; then
        log_warn "Low disk space on $path: ${free_mb}MB free, ${required_mb}MB required"
        return 1
    fi
    log_info "Disk space OK: ${free_mb}MB free on $path"
    return 0
}

# Safe uci set with commit
uci_set() {
    local config="$1"
    local section="$2"
    local option="$3"
    local value="$4"
    
    uci -q set "$config.$section.$option=$value"
}

# Safe uci add
uci_add() {
    local config="$1"
    local type="$2"
    local name="$3"
    
    uci -q add "$config" "$type" >/dev/null 2>&1
    uci -q rename "$config.@$type[-1]=$name" >/dev/null 2>&1
}

# Commit uci changes
uci_commit() {
    local config="$1"
    uci commit "$config" 2>/dev/null || true
}

# Reload config
reload_config() {
    /etc/init.d/network reload 2>/dev/null || /etc/init.d/network restart 2>/dev/null || true
    /etc/init.d/firewall reload 2>/dev/null || /etc/init.d/firewall restart 2>/dev/null || true
}

# Get LAN subnet in CIDR notation
get_lan_subnet() {
    local ipaddr=$(uci -q get network.lan.ipaddr)
    local netmask=$(uci -q get network.lan.netmask)
    
    if [ -z "$ipaddr" ] || [ -z "$netmask" ]; then
        log_warn "Could not determine LAN subnet from uci"
        echo "192.168.1.0/24"
        return
    fi
    
    # Convert netmask to CIDR
    local cidr=0
    IFS=. read -r o1 o2 o3 o4 <<EOF
$netmask
EOF
    for octet in $o1 $o2 $o3 $o4; do
        case $octet in
            255) cidr=$((cidr + 8)) ;;
            254) cidr=$((cidr + 7)) ;;
            252) cidr=$((cidr + 6)) ;;
            248) cidr=$((cidr + 5)) ;;
            240) cidr=$((cidr + 4)) ;;
            224) cidr=$((cidr + 3)) ;;
            192) cidr=$((cidr + 2)) ;;
            128) cidr=$((cidr + 1)) ;;
            0) ;;
            *) log_warn "Unusual netmask octet: $octet" ;;
        esac
    done
    
    echo "${ipaddr}/${cidr}"
}

# Get LAN interface name
get_lan_interface() {
    uci -q get network.lan.ifname || echo "br-lan"
}

# Get WAN interface name
get_wan_interface() {
    uci -q get network.wan.ifname || uci -q get network.wan.device || echo "eth0"
}

# Get Tailscale install directory based on available space
get_install_dir() {
    local install_dir_var="${TAILSCALE_INSTALL_DIR:-auto}"
    
    if [ "$install_dir_var" = "auto" ]; then
        if check_space 20 "/overlay" >/dev/null 2>&1; then
            echo "/usr/sbin"
        else
            echo "/tmp/tailscale"
        fi
    else
        echo "$install_dir_var"
    fi
}
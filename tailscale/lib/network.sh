#!/bin/sh
# lib/network.sh - Network utilities for Tailscale
# Part of Tailscale OpenWrt installer

# Source common utilities
. "$(dirname "$0")/common.sh"

# Get LAN subnet in CIDR notation
get_lan_subnet() {
    local ipaddr=$(uci -q get network.lan.ipaddr)
    local netmask=$(uci -q get network.lan.netmask)
    
    if [ -z "$ipaddr" ] || [ -z "$netmask" ]; then
        log_warn "Could not determine LAN subnet from uci, using default"
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

# Get Tailscale interface name
get_tailscale_interface() {
    echo "tailscale0"
}

# Setup Tailscale network interface
setup_tailscale_interface() {
    log_step "Setting up Tailscale network interface..."
    
    local ts_iface=$(get_tailscale_interface)
    
    # Create interface
    uci_set network tailscale interface
    uci_set network tailscale device "$ts_iface"
    uci_set network tailscale proto "unmanaged"
    uci_set network tailscale auto "1"
    
    uci_commit network
    
    log_info "Tailscale interface configured: $ts_iface"
    return 0
}

# Reload network configuration
reload_network() {
    log_info "Reloading network configuration..."
    /etc/init.d/network reload 2>/dev/null || /etc/init.d/network restart 2>/dev/null || true
}

# Check if Tailscale interface exists in network config
has_tailscale_interface() {
    uci -q get network.tailscale >/dev/null 2>&1
}

# Remove Tailscale interface
remove_tailscale_interface() {
    log_step "Removing "Removing Tailscale network interface..."
    uci -q delete network.tailscale
    uci_commit network
    reload_network
}
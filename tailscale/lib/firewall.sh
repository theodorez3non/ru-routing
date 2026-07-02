#!/bin/sh
# lib/firewall.sh - Firewall configuration for Tailscale
# Part of Tailscale OpenWrt installer

# Source common utilities
. "$(dirname "$0")/common.sh"

# Setup Tailscale firewall zone
setup_tailscale_zone() {
    log_step "Setting up Tailscale firewall zone..."
    
    local lan_iface=$(get_lan_interface)
    
    # Add zone if not exists
    if ! uci -q get firewall.tailscale >/dev/null 2>&1; then
        uci_add firewall zone tailscale
    fi
    
    uci_set firewall tailscale name "tailscale"
    uci_set firewall tailscale input "ACCEPT"
    uci_set firewall tailscale output "ACCEPT"
    uci_set firewall tailscale forward "REJECT"
    uci_set firewall tailscale masq "1"
    uci_set firewall tailscale mtu_fix "1"
    uci_add_list firewall tailscale network "tailscale"
    
    log_info "Tailscale firewall zone configured"
}

# Setup forwarding from tailscale to lan
setup_tailscale_forwarding() {
    log_step "Setting up Tailscale -> LAN forwarding..."
    
    # Check if forwarding already exists
    local idx=0
    local found=0
    while uci -q get "firewall.@forwarding[$idx]" >/dev/null 2>&1; do
        local src=$(uci -q get "firewall.@forwarding[$idx].src")
        local dest=$(uci -q get "firewall.@forwarding[$idx].dest")
        if [ "$src" = "tailscale" ] && [ "$dest" = "lan" ]; then
            found=1
            break
        fi
        idx=$((idx + 1))
    done
    
    if [ $found -eq 0 ]; then
        uci_add firewall forwarding
        uci_set firewall @forwarding[-1] src "tailscale"
        uci_set firewall @forwarding[-1] dest "lan"
        log_info "Forwarding tailscale -> lan added"
    else
        log_debug "Forwarding tailscale -> lan already exists"
    fi
}

# Setup access rules for SSH, HTTP, HTTPS from tailscale zone
setup_tailscale_access_rules() {
    log_step "Setting up Tailscale access rules..."
    
    # SSH rule
    if ! uci -q get firewall.tailscale_ssh >/dev/null 2>&1; then
        uci_add firewall rule tailscale_ssh
        uci_set firewall tailscale_ssh name "Allow-Tailscale-SSH"
        uci_set firewall tailscale_ssh src "tailscale"
        uci_set firewall tailscale_ssh proto "tcp"
        uci_set firewall tailscale_ssh dest_port "22"
        uci_set firewall tailscale_ssh target "ACCEPT"
        log_info "SSH access rule added"
    fi
    
    # HTTP rule
    if ! uci -q get firewall.tailscale_http >/dev/null 2>&1; then
        uci_add firewall rule tailscale_http
        uci_set firewall tailscale_http name "Allow-Tailscale-HTTP"
        uci_set firewall tailscale_http src "tailscale"
        uci_set firewall tailscale_http proto "tcp"
        uci_set firewall tailscale_http dest_port "80"
        uci_set firewall tailscale_http target "ACCEPT"
        log_info "HTTP access rule added"
    fi
    
    # HTTPS rule
    if ! uci -q get firewall.tailscale_https >/dev/null 2>&1; then
        uci_add firewall rule tailscale_https
        uci_set firewall tailscale_https name "Allow-Tailscale-HTTPS"
        uci_set firewall tailscale_https src "tailscale"
        uci_set firewall tailscale_https proto "tcp"
        uci_set firewall tailscale_https dest_port "443"
        uci_set firewall tailscale_https target "ACCEPT"
        log_info "HTTPS access rule added"
    fi
}

# Setup Exit Node NAT rules (if enabled)
setup_exit_node_nat() {
    local wan_iface=$(get_wan_interface)
    
    log_step "Setting up Exit Node NAT..."
    
    # Add NAT rule for exit node traffic
    if ! uci -q get firewall.tailscale_exit_node_nat >/dev/null 2>&1; then
        uci_add firewall redirect tailscale_exit_node_nat
        uci_set firewall tailscale_exit_node_nat name "Tailscale-Exit-Node-NAT"
        uci_set firewall tailscale_exit_node_nat src "tailscale"
        uci_set firewall tailscale_exit_node_nat dest "wan"
        uci_set firewall tailscale_exit_node_nat proto "all"
        uci_set firewall tailscale_exit_node_nat target "DNAT"
        uci_set firewall tailscale_exit_node_nat family "ipv4"
        log_info "Exit Node NAT rule added"
    fi
    
    # Also ensure MASQUERADE on WAN for tailscale traffic
    local idx=0
    local found=0
    while uci -q get "firewall.@zone[$idx]" >/dev/null 2>&1; do
        local name=$(uci -q get "firewall.@zone[$idx].name")
        if [ "$name" = "wan" ]; then
            local masq=$(uci -q get "firewall.@zone[$idx].masq")
            if [ "$masq" != "1" ]; then
                uci_set firewall @zone[$idx] masq "1"
                log_info "Enabled MASQUERADE on WAN zone"
            fi
            found=1
            break
        fi
        idx=$((idx + 1))
    done
}

# Setup all firewall rules
setup_firewall() {
    log_step "Configuring firewall for Tailscale..."
    
    setup_tailscale_zone
    setup_tailscale_forwarding
    setup_tailscale_access_rules
    
    # Check if exit node is enabled
    if [ "${TAILSCALE_EXIT_NODE:-0}" = "1" ]; then
        setup_exit_node_nat
    fi
    
    uci_commit firewall
    reload_config
    
    log_info "Firewall configuration complete"
}

# Remove all Tailscale firewall rules
remove_firewall_rules() {
    log_step "Removing Tailscale firewall rules..."
    
    uci -q delete firewall.tailscale
    uci -q delete firewall.tailscale_ssh
    uci -q delete firewall.tailscale_http
    uci -q delete firewall.tailscale_https
    uci -q delete firewall.tailscale_exit_node_nat
    
    # Remove forwarding
    local idx=0
    while uci -q get "firewall.@forwarding[$idx]" >/dev/null 2>&1; do
        local src=$(uci -q get "firewall.@forwarding[$idx].src")
        local dest=$(uci -q get "firewall.@forwarding[$idx].dest")
        if [ "$src" = "tailscale" ] && [ "$dest" = "lan" ]; then
            uci -q delete "firewall.@forwarding[$idx]"
        else
            idx=$((idx + 1))
        fi
    done
    
    uci_commit firewall
    reload_config
    
    log_info "Firewall rules removed"
}
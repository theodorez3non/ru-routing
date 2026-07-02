#!/bin/sh
# modules/06-config.sh - Generate final configuration and instructions
# Part of Tailscale OpenWrt installer

# Source libraries
. "$(dirname "$0")/../lib/common.sh"
. "$(dirname "$0")/../lib/system.sh"
. "$(dirname "$0")/../lib/network.sh"

log_step "Module 06: Final configuration and instructions"

# Display final configuration summary
show_summary() {
    echo ""
    echo "=========================================="
    echo "  Tailscale Installation Complete!"
    echo "=========================================="
    echo ""
    
    local version=$(get_tailscale_version)
    log_info "Tailscale version: $version"
    
    local lan_subnet=$(get_lan_subnet)
    log_info "LAN subnet: $lan_subnet"
    
    local ts_ip=$(tailscale ip -4 2>/dev/null | head -1 || echo "Not connected yet")
    log_info "Tailscale IP: $ts_ip"
    
    echo ""
    echo "------------------------------------------"
    echo "  Next Steps:"
    echo "------------------------------------------"
    
    if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
        log_info "Auth key provided - Tailscale should auto-connect on boot"
    else
        echo "1. Authorize this device:"
        echo "   tailscale up $(get_tailscale_up_args)"
        echo ""
        echo "   This will output a URL. Open it in a browser to authenticate."
    fi
    
    echo ""
    echo "2. After authorization, your router will be accessible via Tailscale:"
    echo "   Web interface: http://<Tailscale_IP>"
    echo "   SSH: ssh root@<Tailscale_IP>"
    echo ""
    
    if [ "${TAILSCALE_EXIT_NODE:-0}" = "1" ]; then
        echo "3. Exit Node is ENABLED - other devices can route traffic through this router"
        echo "   Enable in Tailscale admin console: Machines -> ... -> Use as exit node"
        echo ""
    fi
    
    if [ "${TAILSCALE_ADVERTISE_ROUTES:-auto}" != "0" ]; then
        echo "4. Subnet routes advertised: ${TAILSCALE_ADVERTISE_ROUTES:-auto}"
        echo "   Approve in Tailscale admin console: Machines -> ... -> Edit route settings"
        echo ""
    fi
    
    echo "------------------------------------------"
    echo "  Useful Commands:"
    echo "------------------------------------------"
    echo "  tailscale status          - Check connection status"
    echo "  tailscale ip -4           - Get Tailscale IPv4"
    echo "  tailscale netcheck        - Run network diagnostics"
    echo "  /etc/init.d/tailscale restart  - Restart tailscaled"
    echo "  logread -f | grep tailscale    - View logs"
    echo ""
    echo "=========================================="
}

# Generate the tailscale up command for reference
show_tailscale_up_command() {
    local args=$(get_tailscale_up_args)
    echo ""
    echo "Reference command for manual execution:"
    echo "  tailscale up $args"
    echo ""
}

show_summary
show_tailscale_up_command

log_info "Configuration module complete"
#!/bin/sh
# modules/05-service.sh - Configure service and autostart
# Part of Tailscale OpenWrt installer

# Source libraries
. "$(dirname "$0")/../lib/common.sh"
. "$(dirname "$0")/../lib/system.sh"

log_step "Module 05: Configuring service and autostart"

# Create procd init script for tailscaled
create_init_script() {
    log_info "Creating procd init script..."
    
    cat > /etc/init.d/tailscale <<'EOF'
#!/bin/sh /etc/rc.common
# Tailscale init script for OpenWrt (procd)

START=99
STOP=10
USE_PROCD=1
PROG=/usr/sbin/tailscaled

start_service() {
    # Ensure TUN module is loaded
    modprobe tun 2>/dev/null || true
    
    # Ensure /var/run/tailscale exists
    mkdir -p /var/run/tailscale
    
    procd_open_instance
    procd_set_param command "$PROG" --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param user root
    procd_close_instance
}

stop_service() {
    killall -9 tailscaled 2>/dev/null || true
    rm -f /var/run/tailscale/tailscaled.sock
}
EOF

    chmod +x /etc/init.d/tailscale
    log_info "Init script created"
}

# Enable and start the service
enable_service() {
    log_info "Enabling and starting tailscale service..."
    
    /etc/init.d/tailscale enable
    /etc/init.d/tailscale start
    
    # Wait for tailscaled to be ready
    local retries=10
    while [ $retries -gt 0 ]; do
        if tailscale status >/dev/null 2>&1; then
            log_info "tailscaled is running"
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done
    
    log_warn "tailscaled may not be fully started yet"
}

# Add autostart to rc.local for tailscale up command
setup_autostart() {
    log_info "Setting up autostart for tailscale up..."
    
    local rc_local="/etc/rc.local"
    local autostart_cmd="sleep 10 && tailscale up $(get_tailscale_up_args) &"
    
    # Remove any existing tailscale up lines
    sed -i '/tailscale up/d' "$rc_local"
    
    # Add before exit 0
    sed -i "/^exit 0/i $autostart_cmd" "$rc_local"
    
    log_info "Autostart command added: $autostart_cmd"
}

# Get tailscale up arguments from environment
get_tailscale_up_args() {
    local args=""
    
    # Accept DNS
    if [ "${TAILSCALE_ACCEPT_DNS:-0}" = "1" ]; then
        args="$args --accept-dns=true"
    else
        args="$args --accept-dns=false"
    fi
    
    # Advertise routes
    local routes="${TAILSCALE_ADVERTISE_ROUTES:-auto}"
    if [ "$routes" = "auto" ]; then
        routes=$(get_lan_subnet)
    fi
    if [ "$routes" != "0" ] && [ -n "$routes" ]; then
        args="$args --advertise-routes=$routes"
    fi
    
    # Exit node
    if [ "${TAILSCALE_EXIT_NODE:-0}" = "1" ]; then
        args="$args --advertise-exit-node"
    fi
    
    # SSH
    if [ "${TAILSCALE_SSH:-1}" = "1" ]; then
        args="$args --ssh"
    fi
    
    # Auth key
    if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
        args="$args --authkey=${TAILSCALE_AUTH_KEY}"
    fi
    
    # Extra args
    if [ -n "${TAILSCALE_EXTRA_ARGS:-}" ]; then
        args="$args ${TAILSCALE_EXTRA_ARGS}"
    fi
    
    echo "$args"
}

# Main
create_init_script
enable_service
setup_autostart

log_info "Service module complete"
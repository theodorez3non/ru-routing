#!/bin/sh
# install.sh - Tailscale OpenWrt Installer
# Main entry point for modular installation
#
# Usage:
#   ./install.sh                                    # Interactive, manual auth
#   TAILSCALE_AUTH_KEY=tskey-xxx ./install.sh       # Auto-auth with auth key
#   TAILSCALE_EXIT_NODE=1 ./install.sh              # Enable exit node
#   TAILSCALE_ADVERTISE_ROUTES=192.168.1.0/24 ./install.sh  # Custom routes
#   TAILSCALE_ACCEPT_DNS=1 ./install.sh             # Accept DNS from Tailscale
#   TAILSCALE_EXTRA_ARGS="--hostname=myrouter" ./install.sh # Extra args

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source common utilities first
. "$SCRIPT_DIR/lib/common.sh"

# Display banner
echo ""
echo "=========================================="
echo "  Tailscale OpenWrt Installer"
echo "  Target: Xiaomi Mi Router 3G (MT7621)"
echo "  OpenWrt: 25.12.4+"
echo "=========================================="
echo ""

# Require root
require_root

# Parse environment variables with defaults
export TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
export TAILSCALE_EXIT_NODE="${TAILSCALE_EXIT_NODE:-0}"
export TAILSCALE_ADVERTISE_ROUTES="${TAILSCALE_ADVERTISE_ROUTES:-auto}"
export TAILSCALE_ACCEPT_DNS="${TAILSCALE_ACCEPT_DNS:-0}"
export TAILSCALE_SSH="${TAILSCALE_SSH:-1}"
export TAILSCALE_EXTRA_ARGS="${TAILSCALE_EXTRA_ARGS:-}"
export TAILSCALE_INSTALL_DIR="${TAILSCALE_INSTALL_DIR:-auto}"

# Log configuration
log_info "Configuration:"
log_info "  Auth Key: TAILSCALE_AUTH_KEY: ${TAILSCALE_AUTH_KEY:+(set)}"
log_info "  TAILSCALE_EXIT_NODE: $TAILSCALE_EXIT_NODE"
log_info "  TAILSCALE_ADVERTISE_ROUTES: $TAILSCALE_ADVERTISE_ROUTES"
log_info "  TAILSCALE_ACCEPT_DNS: $TAILSCALE_ACCEPT_DNS"
log_info "  TAILSCALE_SSH: $TAILSCALE_SSH"
log_info "  TAILSCALE_EXTRA_ARGS: $TAILSCALE_EXTRA_ARGS"
log_info "  TAILSCALE_INSTALL_DIR: $TAILSCALE_INSTALL_DIR"
echo ""

# Run modules in order
MODULES_DIR="$SCRIPT_DIR/modules"

run_module() {
    local module="$1"
    local module_path="$MODULES_DIR/$module"
    
    if [ ! -f "$module_path" ]; then
        log_error "Module not found: $module"
        exit 1
    fi
    
    if [ ! -x "$module_path" ]; then
        chmod +x "$module_path"
    fi
    
    log_step "Running module: $module"
    
    if ! "$module_path"; then
        log_error "Module failed: $module"
        exit 1
    fi
    
    log_info "Module completed: $module"
    echo ""
}

# Run all modules
run_module "01-deps.sh"
run_module "02-install.sh"
run_module "03-network.sh"
run_module "04-firewall.sh"
run_module "05-service.sh"
run_module "06-config.sh"

log_info "Installation complete!"
#!/bin/sh
# modules/02-install.sh - Install Tailscale
# Part of Tailscale OpenWrt installer

# Source libraries
. "$(dirname "$0")/../lib/common.sh"
. "$(dirname "$0")/../lib/system.sh"

log_step "Module 02: Installing Tailscale"

# Check if already installed
if check_tailscale_installed; then
    log_info "Tailscale already installed, skipping installation"
    exit 0
fi

check_system
install_tailscale

log_info "Installation module complete"
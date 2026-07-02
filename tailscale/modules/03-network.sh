#!/bin/sh
# modules/03-network.sh - Configure network interface
# Part of Tailscale OpenWrt installer

# Source libraries
. "$(dirname "$0")/../lib/common.sh"
. "$(dirname "$0")/../lib/network.sh"

log_step "Module 03: Configuring network interface"

setup_tailscale_interface
reload_network

log_info "Network module complete"
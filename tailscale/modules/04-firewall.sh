#!/bin/sh
# modules/04-firewall.sh - Configure firewall
# Part of Tailscale OpenWrt installer

# Source libraries
. "$(dirname "$0")/../lib/common.sh"
. "$(dirname "$0")/../lib/firewall.sh"

log_step "Module 04: Configuring firewall"

setup_firewall

log_info "Firewall module complete"
#!/bin/sh
# modules/01-deps.sh - Install dependencies
# Part of Tailscale OpenWrt installer

# Source libraries
. "$(dirname "$0")/../lib/common.sh"
. "$(dirname "$0")/../lib/system.sh"

log_step "Module 01: Installing dependencies"

install_deps
ensure_tun_persistent
check_tun_module

log_info "Dependencies module complete"
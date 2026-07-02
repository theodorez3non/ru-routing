#!/bin/sh
# lib/system.sh - System checks and dependency management
# Part of Tailscale OpenWrt installer

# Source common utilities
. "$(dirname "$0")/common.sh"

# Required packages for Tailscale on OpenWrt
TAILSCALE_DEPS="ca-certificates kmod-tun iptables-mod-nat-extra iptables-mod-conntrack-extra kmod-ipt-nat"

# Check and install dependencies
install_deps() {
    log_step "Installing dependencies..."
    
    # Update package list
    run_cmd "apk update" "Updating package list" || {
        log_warn "Failed to update package list, continuing anyway"
    }
    
    # Install each dependency
    local failed_deps=""
    for dep in $TAILSCALE_DEPS; do
        if apk info -e "$dep" >/dev/null 2>&1; then
            log_debug "Package already installed: $dep"
        else
            log_info "Installing: $dep"
            if ! run_cmd "apk add $dep" "Installing $dep"; then
                failed_deps="$failed_deps $dep"
            fi
        fi
    done
    
    if [ -n "$failed_deps" ]; then
        log_error "Failed to install dependencies:$failed_deps"
        return 1
    fi
    
    log_info "All dependencies installed successfully"
    return 0
}

# Check if TUN module is loaded
check_tun_module() {
    if lsmod | grep -q "^tun "; then
        log_debug "TUN module is loaded"
        return 0
    fi
    
    log_info "Loading TUN module..."
    if modprobe tun; then
        log_info "TUN module loaded successfully"
        return 0
    else
        log_error "Failed to load TUN module"
        return 1
    fi
}

# Ensure TUN module loads on boot
ensure_tun_persistent() {
    if ! grep -q "^tun$" /etc/modules.d/* 2>/dev/null; then
        log_info "Adding TUN module to boot..."
        echo "tun" >> /etc/modules.d/99-tailscale-tun
    fi
}

# Check if Tailscale is already installed
check_tailscale_installed() {
    if command -v tailscale >/dev/null 2>&1 && command -v tailscaled >/dev/null 2>&1; then
        local version=$(tailscale version 2>/dev/null | head -1)
        log_info "Tailscale already installed: $version"
        return 0
    fi
    return 1
}

# Get installed Tailscale version
get_tailscale_version() {
    tailscale version 2>/dev/null | head -1 || echo "not installed"
}

# Check system compatibility
check_system() {
    log_step "Checking system compatibility..."
    
    # Check architecture
    local arch=$(get_arch)
    local ts_arch=$(get_tailscale_arch)
    
    log_info "System architecture: $arch"
    log_info "Tailscale architecture: $ts_arch"
    
    if [ "$ts_arch" = "unknown" ]; then
        log_error "Unsupported architecture: $arch"
        return 1
    fi
    
    # Check OpenWrt version
    local version=$(get_openwrt_version)
    log_info "OpenWrt version: $version"
    
    # Check if we're on OpenWrt 25.12+
    case "$version" in
        25.12*|24.10*|23.05*|22.03*|21.02*)
            log_info "Supported OpenWrt version detected"
            ;;
        *)
            log_warn "Untested OpenWrt version: $version (continuing anyway)"
            ;;
    esac
    
    # Check disk space
    local free_mb=$(get_free_space_mb "/overlay")
    log_info "Free space on /overlay: ${free_mb}MB"
    
    if [ "$free_mb" -lt 10 ]; then
        log_warn "Very low disk space, installation may fail"
    fi
    
    # Check TUN support
    if [ ! -c /dev/net/tun ]; then
        log_warn "/dev/net/tun not found, will try to load module"
        check_tun_module
    else
        log_info "TUN device available"
    fi
    
    return 0
}

# Install Tailscale via apk
install_via_apk() {
    log_step "Attempting installation via apk..."
    
    if ! command -v apk >/dev/null 2>&1; then
        log_warn "apk not available"
        return 1
    fi
    
    # Check if tailscale package exists
    if ! apk search -q tailscale >/dev/null 2>&1; then
        log_warn "tailscale package not found in repositories"
        return 1
    fi
    
    if run_cmd "apk add tailscale" "Installing tailscale via apk"; then
        if check_tailscale_installed; then
            log_info "Tailscale installed successfully via apk"
            return 0
        fi
    fi
    
    log_warn "apk installation failed"
    return 1
}

# Download and install Tailscale binaries
install_via_download() {
    local install_dir="$1"
    local ts_arch=$(get_tailscale_arch)
    
    log_step "Downloading Tailscale binaries for $ts_arch..."
    
    local base_url="https://pkgs.tailscale.com/stable/${ts_arch}"
    local tailscale_url="${base_url}/tailscale"
    local tailscaled_url="${base_url}/tailscaled"
    
    log_info "Download URLs:"
    log_info "  tailscale: $tailscale_url"
    log_info "  tailscaled: $tailscaled_url"
    
    # Create install directory
    mkdir -p "$install_dir"
    
    # Download tailscaled
    if ! run_cmd "wget -O '${install_dir}/tailscaled' '$tailscaled_url'" "Downloading tailscaled"; then
        log_error "Failed to download tailscaled"
        return 1
    fi
    
    # Download tailscale
    if ! run_cmd "wget -O '${install_dir}/tailscale' '$tailscale_url'" "Downloading tailscale"; then
        log_error "Failed to download tailscale"
        return 1
    fi
    
    # Make executable
    chmod +x "${install_dir}/tailscaled" "${install_dir}/tailscale"
    
    # Create symlinks in standard locations if not already there
    if [ "$install_dir" != "/usr/sbin" ]; then
        ln -sf "${install_dir}/tailscale" /usr/bin/tailscale
        ln -sf "${install_dir}/tailscaled" /usr/sbin/tailscaled
    fi
    
    # Verify installation
    if check_tailscale_installed; then
        log_info "Tailscale installed successfully via download"
        return 0
    else
        log_error "Installation verification failed"
        return 1
    fi
}

# Main installation function
install_tailscale() {
    local install_dir=$(get_install_dir)
    
    log_info "Install directory: $install_dir"
    
    # Try apk first if we have space
    if check_space 20 "/overlay" >/dev/null 2>&1; then
        if install_via_apk; then
            return 0
        fi
    else
        log_warn "Insufficient space for apk installation, using download method"
    fi
    
    # Fallback to download
    install_via_download "$install_dir"
}
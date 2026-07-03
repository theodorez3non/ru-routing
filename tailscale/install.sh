#!/bin/sh
# Tailscale installer for OpenWrt
# Supports OpenWrt 24.x (opkg) and 25.x (apk)
# Production-ready, idempotent, well-structured.

set -u

# ============================================================================
# Constants and configuration
# ============================================================================

readonly TAILSCALE_UP_ARGS="--advertise-exit-node --accept-dns=false --netfilter-mode=off --ssh"
readonly REQUIRED_PACKAGES="kmod-tun ca-bundle libustream-openssl wget"

# ============================================================================
# Color definitions
# ============================================================================

if [ -t 1 ]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly NC='\033[0m' # No Color
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly NC=''
fi

# ============================================================================
# Logging functions
# ============================================================================

log_info() {
    echo "${GREEN}[INFO]${NC} $1"
}

log_ok() {
    echo "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo "${RED}[ERROR]${NC} $1"
}

log_header() {
    echo "${BLUE}==>${NC} $1"
}

# ============================================================================
# Utility functions
# ============================================================================

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if a UCI section exists
uci_has_section() {
    local config="$1"
    local section="$2"
    uci show "$config.$section" >/dev/null 2>&1
}

# Check if a firewall rule with a given name exists
firewall_rule_exists() {
    local name="$1"
    uci show firewall 2>/dev/null | grep -q "firewall.@rule.*.name='$name'"
}

# Check if a forwarding rule exists (src->dest)
firewall_forwarding_exists() {
    local src="$1"
    local dest="$2"
    uci show firewall 2>/dev/null | grep -q "forwarding.*src='$src'.*dest='$dest'"
}

# Check if a firewall zone exists by name
firewall_zone_exists() {
    local name="$1"
    uci show firewall 2>/dev/null | grep -q "zone.*.name='$name'"
}

# Get the current package manager (apk or opkg)
detect_package_manager() {
    if command_exists apk; then
        echo "apk"
    elif command_exists opkg; then
        echo "opkg"
    else
        echo "unknown"
    fi
}

# ============================================================================
# Main functions
# ============================================================================

print_header() {
    cat <<EOF
=========================================
Tailscale installer for OpenWrt
=========================================
EOF
}

print_summary() {
    local pm=$(detect_package_manager)
    local arch=$(uname -m)
    local version=$(cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_RELEASE | cut -d= -f2 | tr -d "'")
    local free_space=$(df / | awk 'NR==2 {print int($4/1024)}')
    log_info "OpenWrt version : ${version:-unknown}"
    log_info "Architecture    : $arch"
    log_info "Package manager : $pm"
    log_info "Free space      : ${free_space:-?} MiB"
    echo ""
}

# Install required dependencies
install_dependencies() {
    local pm=$(detect_package_manager)
    log_info "Installing required packages: $REQUIRED_PACKAGES"

    case "$pm" in
        apk)
            apk update || { log_error "Failed to update package lists"; return 1; }
            apk add $REQUIRED_PACKAGES || { log_error "Failed to install dependencies"; return 1; }
            ;;
        opkg)
            opkg update || { log_error "Failed to update package lists"; return 1; }
            opkg install $REQUIRED_PACKAGES || { log_error "Failed to install dependencies"; return 1; }
            ;;
        *)
            log_error "No supported package manager found."
            return 1
            ;;
    esac

    log_ok "Dependencies installed."
    return 0
}

# Check if Tailscale is already installed
is_tailscale_installed() {
    if command_exists tailscale && command_exists tailscaled; then
        return 0
    fi

    # Fallback: check via package manager
    local pm=$(detect_package_manager)
    case "$pm" in
        apk)
            apk info tailscale 2>/dev/null | grep -q "tailscale" && return 0
            ;;
        opkg)
            opkg list-installed | grep -q "^tailscale" && return 0
            ;;
    esac
    return 1
}

# Install Tailscale using the official package
install_tailscale() {
    local pm=$(detect_package_manager)
    log_info "Installing Tailscale via $pm..."

    case "$pm" in
        apk)
            apk update || { log_error "Failed to update package lists"; return 1; }
            apk add tailscale || { log_error "Failed to install tailscale"; return 1; }
            ;;
        opkg)
            opkg update || { log_error "Failed to update package lists"; return 1; }
            opkg install tailscale || { log_error "Failed to install tailscale"; return 1; }
            ;;
        *)
            log_error "No supported package manager."
            return 1
            ;;
    esac

    # Verify installation
    if ! command_exists tailscale || ! command_exists tailscaled; then
        log_error "Tailscale binaries not found after installation."
        return 1
    fi

    log_ok "Tailscale installed successfully."
    return 0
}

# Enable and start the Tailscale service
start_tailscale_service() {
    if [ ! -f "/etc/init.d/tailscale" ]; then
        log_error "Tailscale init script not found. Package may be incomplete."
        return 1
    fi

    log_info "Enabling Tailscale service..."
    /etc/init.d/tailscale enable || { log_error "Failed to enable service"; return 1; }

    log_info "Starting Tailscale service..."
    /etc/init.d/tailscale start || { log_error "Failed to start service"; return 1; }

    # Wait a moment for the daemon to be ready
    sleep 2

    if ! pgrep -f tailscaled >/dev/null; then
        log_error "Tailscale daemon (tailscaled) is not running."
        return 1
    fi

    log_ok "Tailscale service is running."
    return 0
}

# Check Tailscale authentication status and print login link if needed
check_auth_status() {
    log_info "Checking Tailscale authentication status..."
    local status_output
    status_output=$(tailscale status 2>&1)

    if echo "$status_output" | grep -q "Logged out"; then
        log_warn "You are not logged in to Tailscale."
        echo ""
        echo "Please run the following command to authenticate:"
        echo "    tailscale up $TAILSCALE_UP_ARGS"
        echo ""
        echo "After that, a URL will be displayed. Open it in your browser to log in."
        return 1
    elif echo "$status_output" | grep -q "https://login.tailscale.com"; then
        local url=$(echo "$status_output" | grep -o "https://login.tailscale.com/[^ ]*" | head -1)
        log_info "Authentication required. Visit the following URL:"
        echo ""
        echo "    $url"
        echo ""
        return 1
    else
        log_ok "Already authenticated to Tailscale."
        return 0
    fi
}

# Configure UCI network and firewall
configure_uci() {
    log_header "Configuring network and firewall..."

    # ---- Network interface ----
    if ! uci_has_section network tailscale; then
        log_info "Creating network interface 'tailscale'..."
        uci set network.tailscale=interface
        uci set network.tailscale.device='tailscale0'
        uci set network.tailscale.proto='unmanaged'
        uci set network.tailscale.auto='1'
    else
        log_info "Network interface 'tailscale' already exists."
    fi

    # ---- Firewall zone ----
    if ! firewall_zone_exists tailscale; then
        log_info "Creating firewall zone 'tailscale'..."
        uci add firewall zone
        uci set firewall.@zone[-1].name='tailscale'
        uci set firewall.@zone[-1].input='ACCEPT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].forward='REJECT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci add_list firewall.@zone[-1].network='tailscale'
    else
        log_info "Firewall zone 'tailscale' already exists."
    fi

    # ---- Forwarding: tailscale -> wan ----
    if ! firewall_forwarding_exists tailscale wan; then
        log_info "Adding forwarding rule: tailscale -> wan..."
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='tailscale'
        uci set firewall.@forwarding[-1].dest='wan'
    else
        log_info "Forwarding tailscale -> wan already exists."
    fi

    # ---- SSH access rule ----
    if ! firewall_rule_exists "Allow-Tailscale-SSH"; then
        log_info "Adding SSH access rule..."
        uci add firewall rule
        uci set firewall.@rule[-1].name='Allow-Tailscale-SSH'
        uci set firewall.@rule[-1].src='tailscale'
        uci set firewall.@rule[-1].proto='tcp'
        uci set firewall.@rule[-1].dest_port='22'
        uci set firewall.@rule[-1].target='ACCEPT'
    else
        log_info "SSH access rule already exists."
    fi

    # ---- Web access (HTTP/HTTPS) ----
    if ! firewall_rule_exists "Allow-Tailscale-Web"; then
        log_info "Adding web access rule (HTTP/HTTPS)..."
        uci add firewall rule
        uci set firewall.@rule[-1].name='Allow-Tailscale-Web'
        uci set firewall.@rule[-1].src='tailscale'
        uci set firewall.@rule[-1].proto='tcp'
        uci set firewall.@rule[-1].dest_port='80 443'
        uci set firewall.@rule[-1].target='ACCEPT'
    else
        log_info "Web access rule already exists."
    fi

    # Commit and reload
    log_info "Committing UCI changes..."
    uci commit network
    uci commit firewall

    log_info "Reloading network and firewall..."
    /etc/init.d/network reload || log_warn "Network reload failed (may be normal)."
    /etc/init.d/firewall reload || { log_error "Firewall reload failed"; return 1; }

    log_ok "UCI configuration applied."
    return 0
}

# Enable IPv4 forwarding (persistent via UCI)
enable_ip_forwarding() {
    log_info "Enabling IPv4 forwarding..."
    local current=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    if [ "$current" != "1" ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || log_warn "Could not set sysctl directly."
    fi

    # Persist via UCI
    if uci_has_section network globals; then
        if [ "$(uci get network.globals.forwarding 2>/dev/null)" != "1" ]; then
            uci set network.globals.forwarding='1'
            uci commit network
        fi
    else
        uci set network.globals=globals
        uci set network.globals.forwarding='1'
        uci commit network
    fi
    log_ok "IPv4 forwarding enabled."
}

# Run tailscale up with the defined arguments
run_tailscale_up() {
    log_info "Starting Tailscale with arguments: $TAILSCALE_UP_ARGS"
    if tailscale up $TAILSCALE_UP_ARGS; then
        log_ok "Tailscale is up."
        return 0
    else
        log_error "tailscale up failed."
        return 1
    fi
}

# Print final status
print_final_status() {
    echo ""
    echo "========================================="
    echo "Tailscale setup completed"
    echo "========================================="
    log_info "Tailscale is installed and configured."
    log_info "To see the current status, run: tailscale status"
    log_info "If you need to access local devices, add --advertise-routes=... manually."
    echo ""
    log_info "Your router can now act as an Exit Node (after enabling in the admin console)."
}

# ============================================================================
# Main function
# ============================================================================

main() {
    # Ensure we run as root
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root."
        exit 1
    fi

    print_header
    print_summary

    # Step 1: Install dependencies
    install_dependencies || exit 1

    # Step 2: Install Tailscale if not present
    if is_tailscale_installed; then
        log_ok "Tailscale is already installed."
    else
        install_tailscale || exit 1
    fi

    # Step 3: Ensure Tailscale service is enabled and running
    start_tailscale_service || exit 1

    # Step 4: Configure UCI (network, firewall)
    configure_uci || exit 1

    # Step 5: Enable IP forwarding
    enable_ip_forwarding

    # Step 6: Run tailscale up to set exit node, SSH, etc.
    run_tailscale_up || log_warn "tailscale up had issues (may be already configured)."

    # Step 7: Check authentication and print link if needed
    check_auth_status

    # Step 8: Final message
    print_final_status
}

# ============================================================================
# Execute main
# ============================================================================

main
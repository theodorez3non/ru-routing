#!/bin/sh
#
# Tailscale — полное удаление для OpenWrt 24.x / 25.x
#
# Удаляет все артефакты, созданные install.sh. Не трогает kmod-tun, ca-bundle,
# iptables-nft и базовые зоны lan/wan.
#
# Совместимость: BusyBox ash (/bin/sh), opkg (24.x), apk (25.x)
#

set -u

# =============================================================================
# Константы (согласованы с install.sh)
#
# Контракт артефактов:
#   пакет tailscale, init /etc/init.d/tailscale
#   UCI /etc/config/tailscale (fw_mode=off), network.tailscale
#   state: /etc/tailscale, /var/lib/tailscale, /var/run/tailscale
#   kernel iface tailscale0
#   firewall: zone tailscale, forwarding tailscale->wan, SSH/HTTP/HTTPS rules
#   tmp /tmp/tailscale_up.log
#   не удаляем: kmod-tun, ca-bundle, iptables-nft, зоны lan/wan
# =============================================================================

readonly SCRIPT_TITLE="Tailscale removal for OpenWrt"

readonly TAILSCALE_PKG="tailscale"
readonly TAILSCALE_INIT="/etc/init.d/tailscale"

readonly TAILSCALE_IFACE="tailscale0"
readonly TAILSCALE_UCI_CONFIG="/etc/config/tailscale"
readonly SYS_NET_PATH="/sys/class/net"

readonly NET_INTERFACE="tailscale"

readonly FW_ZONE="tailscale"
readonly FW_ZONE_LEGACY="tailscaleZone"

readonly FW_RULE_SSH="Allow-Tailscale-SSH"
readonly FW_RULE_HTTP="Allow-Tailscale-HTTP"
readonly FW_RULE_HTTPS="Allow-Tailscale-HTTPS"
readonly FW_RULE_WEB="Allow-Tailscale-Web"

readonly TAILSCALE_STATE_DIR="/etc/tailscale"
readonly TAILSCALE_LIB_DIR="/var/lib/tailscale"
readonly TAILSCALE_RUN_DIR="/var/run/tailscale"
readonly TAILSCALE_UP_LOG="/tmp/tailscale_up.log"

readonly PROCESS_STOP_WAIT_SECS=2

# =============================================================================
# Состояние
# =============================================================================

SYS_ARCH=""
SYS_VERSION=""
SYS_PM="unknown"
TAILSCALE_INIT_PATH=""

# =============================================================================
# Цвета
# =============================================================================

if [ -t 1 ]; then
    C_INFO='\033[0;32m'
    C_OK='\033[0;32m'
    C_WARN='\033[1;33m'
    C_ERR='\033[0;31m'
    C_HDR='\033[0;34m'
    C_RST='\033[0m'
else
    C_INFO=''
    C_OK=''
    C_WARN=''
    C_ERR=''
    C_HDR=''
    C_RST=''
fi

# =============================================================================
# Логирование
# =============================================================================

log_info()  { printf '%b[INFO]%b %s\n' "$C_INFO" "$C_RST" "$1"; }
log_ok()    { printf '%b[OK]%b %s\n'   "$C_OK"   "$C_RST" "$1"; }
log_warn()  { printf '%b[WARN]%b %s\n' "$C_WARN" "$C_RST" "$1"; }
log_error() { printf '%b[ERROR]%b %s\n' "$C_ERR"  "$C_RST" "$1" >&2; }
log_step()  { printf '%b==>%b %s\n' "$C_HDR" "$C_RST" "$1"; }
die()       { log_error "$1"; exit 1; }

# =============================================================================
# Утилиты
# =============================================================================

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Скрипт необходимо запускать от root."
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

read_openwrt_var() {
    _var="$1"
    [ -f /etc/openwrt_release ] || return 0
    grep "^${_var}=" /etc/openwrt_release 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d "'\""
}

detect_system() {
    SYS_ARCH="$(read_openwrt_var DISTRIB_ARCH)"
    [ -z "$SYS_ARCH" ] && SYS_ARCH="$(uname -m 2>/dev/null || echo unknown)"
    SYS_VERSION="$(read_openwrt_var DISTRIB_RELEASE)"
    [ -z "$SYS_VERSION" ] && SYS_VERSION="unknown"
    if have_cmd apk; then
        SYS_PM="apk"
    elif have_cmd opkg; then
        SYS_PM="opkg"
    else
        SYS_PM="unknown"
    fi
}

is_process_running() {
    _name="$1"
    if have_cmd pidof; then
        pidof "$_name" >/dev/null 2>&1 && return 0
    else
        ps -w | grep -v grep | grep -q "[${_name%?}]${_name#?}" && return 0
    fi
    return 1
}

interface_exists() {
    [ -d "${SYS_NET_PATH}/${TAILSCALE_IFACE}" ] \
        || ip link show dev "$TAILSCALE_IFACE" >/dev/null 2>&1
}

resolve_init_script() {
    if [ -x "$TAILSCALE_INIT" ]; then
        TAILSCALE_INIT_PATH="$TAILSCALE_INIT"
        return 0
    fi
    TAILSCALE_INIT_PATH=""
    return 1
}

is_tailscale_zone_name() {
    case "$1" in
        "$FW_ZONE"|"$FW_ZONE_LEGACY") return 0 ;;
        *) return 1 ;;
    esac
}

is_tailscale_rule_name() {
    case "$1" in
        "$FW_RULE_SSH"|"$FW_RULE_HTTP"|"$FW_RULE_HTTPS"|"$FW_RULE_WEB") return 0 ;;
        Allow-Tailscale-*) return 0 ;;
        *) return 1 ;;
    esac
}

pm_is_installed() {
    _pkg="$1"
    case "$SYS_PM" in
        apk)
            apk info -e "$_pkg" >/dev/null 2>&1 && return 0
            apk list -I 2>/dev/null | grep -q "^${_pkg}-" && return 0
            return 1
            ;;
        opkg)
            opkg status "$_pkg" 2>/dev/null | grep -q '^Status: install'
            ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# Фаза 1: остановка
# =============================================================================

stop_tailscaled() {
    if have_cmd tailscale; then
        log_info "tailscale down..."
        tailscale down 2>/dev/null || true
    fi
    if resolve_init_script; then
        "$TAILSCALE_INIT_PATH" stop 2>/dev/null || true
        "$TAILSCALE_INIT_PATH" disable 2>/dev/null || true
    fi
    if have_cmd pidof; then
        _pid="$(pidof tailscaled 2>/dev/null || true)"
        if [ -n "$_pid" ]; then
            kill "$_pid" 2>/dev/null || true
            sleep "$PROCESS_STOP_WAIT_SECS"
            if is_process_running tailscaled; then
                kill -9 "$_pid" 2>/dev/null || true
                sleep 1
            fi
        fi
    fi
    if is_process_running tailscaled; then
        log_warn "Процесс tailscaled всё ещё работает."
        return 1
    fi
    log_ok "Процесс tailscaled остановлен."
}

phase_stop_service() {
    log_step "Фаза 1: остановка Tailscale"
    stop_tailscaled
}

# =============================================================================
# Фаза 2: удаление интерфейса и UCI
# =============================================================================

remove_kernel_interface() {
    if ! interface_exists; then
        log_info "Интерфейс ${TAILSCALE_IFACE} не найден."
        return 0
    fi
    ip link set dev "$TAILSCALE_IFACE" down 2>/dev/null || true
    ip link delete dev "$TAILSCALE_IFACE" 2>/dev/null \
        || ip tuntap del mode tun dev "$TAILSCALE_IFACE" 2>/dev/null \
        || true
    if interface_exists; then
        log_warn "Интерфейс ${TAILSCALE_IFACE} не удалён."
        return 1
    fi
    log_ok "Интерфейс ${TAILSCALE_IFACE} удалён."
}

firewall_zone_index_by_name() {
    _zone="$1"
    _idx=0
    while uci -q get "firewall.@zone[${_idx}]" >/dev/null 2>&1; do
        _name="$(uci -q get "firewall.@zone[${_idx}].name" 2>/dev/null || true)"
        if [ "$_name" = "$_zone" ]; then
            printf '%s' "$_idx"
            return 0
        fi
        _idx=$((_idx + 1))
    done
    return 1
}

firewall_anonymous_section_count() {
    _type="$1"
    _idx=0
    while uci -q get "firewall.@${_type}[${_idx}]" >/dev/null 2>&1; do
        _idx=$((_idx + 1))
    done
    printf '%s' "$_idx"
}

remove_network_interface() {
    if uci -q get "network.${NET_INTERFACE}" >/dev/null 2>&1; then
        uci delete "network.${NET_INTERFACE}" || return 1
        log_ok "Удалена network.${NET_INTERFACE}"
    fi
}

remove_firewall_rules() {
    _count="$(firewall_anonymous_section_count rule)"
    _removed=0
    _idx=$((_count - 1))
    while [ "$_idx" -ge 0 ]; do
        _name="$(uci -q get "firewall.@rule[${_idx}].name" 2>/dev/null || true)"
        _src="$(uci -q get "firewall.@rule[${_idx}].src" 2>/dev/null || true)"
        if is_tailscale_rule_name "$_name" || is_tailscale_zone_name "$_src"; then
            uci delete "firewall.@rule[${_idx}]" || return 1
            _removed=1
        fi
        _idx=$((_idx - 1))
    done
    [ "$_removed" -eq 1 ] && log_ok "Правила firewall Tailscale удалены."
}

remove_firewall_forwardings() {
    _count="$(firewall_anonymous_section_count forwarding)"
    _removed=0
    _idx=$((_count - 1))
    while [ "$_idx" -ge 0 ]; do
        _src="$(uci -q get "firewall.@forwarding[${_idx}].src" 2>/dev/null || true)"
        _dest="$(uci -q get "firewall.@forwarding[${_idx}].dest" 2>/dev/null || true)"
        if is_tailscale_zone_name "$_src" || is_tailscale_zone_name "$_dest"; then
            uci delete "firewall.@forwarding[${_idx}]" || return 1
            _removed=1
        fi
        _idx=$((_idx - 1))
    done
    [ "$_removed" -eq 1 ] && log_ok "Forwarding Tailscale удалены."
}

remove_firewall_zones() {
    _removed=0
    for _zone in "$FW_ZONE" "$FW_ZONE_LEGACY"; do
        _idx="$(firewall_zone_index_by_name "$_zone" 2>/dev/null || true)"
        while [ -n "$_idx" ]; do
            uci delete "firewall.@zone[${_idx}]" || return 1
            _removed=1
            _idx="$(firewall_zone_index_by_name "$_zone" 2>/dev/null || true)"
        done
    done
    [ "$_removed" -eq 1 ] && log_ok "Зоны firewall Tailscale удалены."
}

uci_commit_and_reload() {
    _changed=0
    if uci changes network 2>/dev/null | grep -q .; then
        uci commit network || die "uci commit network failed."
        _changed=1
    fi
    if uci changes firewall 2>/dev/null | grep -q .; then
        uci commit firewall || die "uci commit firewall failed."
        _changed=1
    fi
    if [ "$_changed" -eq 1 ]; then
        /etc/init.d/network reload 2>/dev/null || log_warn "network reload warning."
        /etc/init.d/firewall reload 2>/dev/null || log_warn "firewall reload warning."
    fi
}

phase_remove_uci() {
    log_step "Фаза 2: удаление UCI и интерфейса"
    remove_kernel_interface || true
    remove_network_interface
    remove_firewall_rules
    remove_firewall_forwardings
    remove_firewall_zones
    uci_commit_and_reload
    log_ok "UCI и интерфейс очищены."
}

# =============================================================================
# Фаза 3: удаление пакета и файлов
# =============================================================================

remove_tailscale_package() {
    case "$SYS_PM" in
        apk)
            if pm_is_installed "$TAILSCALE_PKG"; then
                apk del "$TAILSCALE_PKG" || die "apk del $TAILSCALE_PKG failed."
                log_ok "Пакет удалён (apk)."
            else
                log_info "Пакет $TAILSCALE_PKG не установлен (apk)."
            fi
            ;;
        opkg)
            if pm_is_installed "$TAILSCALE_PKG"; then
                opkg remove "$TAILSCALE_PKG" || die "opkg remove $TAILSCALE_PKG failed."
                log_ok "Пакет удалён (opkg)."
            else
                log_info "Пакет $TAILSCALE_PKG не установлен (opkg)."
            fi
            ;;
        *)
            log_warn "Пакетный менеджер не найден."
            ;;
    esac
}

remove_tailscale_files() {
    for _path in "$TAILSCALE_STATE_DIR" "$TAILSCALE_LIB_DIR" "$TAILSCALE_RUN_DIR"; do
        if [ -d "$_path" ]; then
            rm -rf "$_path"
            log_ok "Удалено: $_path"
        fi
    done
    if [ -f "$TAILSCALE_UCI_CONFIG" ]; then
        rm -f "$TAILSCALE_UCI_CONFIG"
        log_ok "Удалено: $TAILSCALE_UCI_CONFIG"
    fi
    if [ -f "$TAILSCALE_UP_LOG" ]; then
        rm -f "$TAILSCALE_UP_LOG"
    fi
    if ls /tmp/tailscale* >/dev/null 2>&1; then
        rm -rf /tmp/tailscale*
        log_ok "Удалены /tmp/tailscale*"
    fi
}

remove_fake_iptables_stubs() {
    for _bin in iptables ip6tables; do
        _path="/usr/bin/$_bin"
        if [ -f "$_path" ] && grep -q 'Фиктивный' "$_path" 2>/dev/null; then
            rm -f "$_path"
            log_ok "Удалён фиктивный $_bin."
        fi
    done
}

remove_rc_local_entries() {
    if [ -f /etc/rc.local ] && grep -q 'tailscale' /etc/rc.local 2>/dev/null; then
        sed -i '/tailscale/d' /etc/rc.local
        log_ok "Записи tailscale удалены из rc.local."
    fi
}

phase_remove_package_and_files() {
    log_step "Фаза 3: удаление пакета и файлов"
    remove_tailscale_package
    remove_tailscale_files
    remove_fake_iptables_stubs
    remove_rc_local_entries
    log_ok "Пакет и файлы удалены."
}

# =============================================================================
# Проверки
# =============================================================================

verify_core_firewall_zones() {
    _missing=""
    for _zone in lan wan; do
        firewall_zone_index_by_name "$_zone" >/dev/null 2>&1 || _missing="${_missing} ${_zone}"
    done
    if [ -n "$_missing" ]; then
        log_warn "Отсутствуют базовые зоны:${_missing}"
        return 1
    fi
    log_ok "Зоны lan/wan на месте."
    return 0
}

verify_removal() {
    _issues=0

    if is_process_running tailscaled; then
        log_warn "Процесс tailscaled остался."
        _issues=1
    fi
    if interface_exists; then
        log_warn "Интерфейс ${TAILSCALE_IFACE} остался."
        _issues=1
    fi
    if pm_is_installed "$TAILSCALE_PKG"; then
        log_warn "Пакет ${TAILSCALE_PKG} остался."
        _issues=1
    fi
    if uci -q get "network.${NET_INTERFACE}" >/dev/null 2>&1; then
        log_warn "UCI network.${NET_INTERFACE} остался."
        _issues=1
    fi
    if firewall_zone_index_by_name "$FW_ZONE" >/dev/null 2>&1; then
        log_warn "Firewall-зона ${FW_ZONE} осталась."
        _issues=1
    fi
    if firewall_zone_index_by_name "$FW_ZONE_LEGACY" >/dev/null 2>&1; then
        log_warn "Firewall-зона ${FW_ZONE_LEGACY} осталась."
        _issues=1
    fi
    if [ -x "$TAILSCALE_INIT" ]; then
        log_warn "Init-скрипт ${TAILSCALE_INIT} остался."
        _issues=1
    fi
    if [ -f "$TAILSCALE_UCI_CONFIG" ]; then
        log_warn "Файл $TAILSCALE_UCI_CONFIG остался."
        _issues=1
    fi
    if [ -d "$TAILSCALE_LIB_DIR" ] || [ -d "$TAILSCALE_STATE_DIR" ]; then
        log_warn "State-директории Tailscale остались."
        _issues=1
    fi

    return "$_issues"
}

# =============================================================================
# Вывод
# =============================================================================

print_banner() {
    printf '\n=========================================\n%s\n=========================================\n\n' "$SCRIPT_TITLE"
}

print_system_summary() {
    log_info "OpenWrt version : ${SYS_VERSION}"
    log_info "Architecture    : ${SYS_ARCH}"
    log_info "Package manager : ${SYS_PM}"
    printf '\n'
}

print_final_report() {
    printf '\n=========================================\n Удаление Tailscale завершено\n=========================================\n\n'
    if verify_removal; then
        log_ok "Tailscale полностью удалён."
    else
        log_warn "Остались артефакты — рекомендуется перезагрузка."
    fi
    verify_core_firewall_zones || true
    printf '\n'
}

prompt_reboot() {
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        log_info "Неинтерактивный режим. При необходимости: reboot"
        return 0
    fi
    printf '\n'
    log_info "Рекомендуется перезагрузка для полной очистки."
    printf 'Перезагрузить сейчас? (y/N): '
    read -r _answer
    case "$_answer" in
        y|Y|yes|YES) reboot ;;
        *) log_info "Перезагрузка отменена." ;;
    esac
}

# =============================================================================
# Точка входа
# =============================================================================

main() {
    require_root
    detect_system
    print_banner
    print_system_summary

    phase_stop_service
    phase_remove_uci
    phase_remove_package_and_files
    print_final_report
    prompt_reboot
}

main "$@"

#!/bin/sh
#
# DoH (DNS-over-HTTPS) — полное удаление для OpenWrt
# Откатывает изменения, сделанные install-doh.sh
#
# Совместимость: BusyBox ash (/bin/sh), opkg (24.x), apk (25.x)
#

set -u

# =============================================================================
# Константы
# =============================================================================

readonly SCRIPT_TITLE="DoH removal for OpenWrt"
readonly PKG_NAME="https-dns-proxy"
readonly LUCI_PKG="luci-app-https-dns-proxy"
readonly UCI_CONFIG="https-dns-proxy"
readonly DEFAULT_PORT="5053"

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

log_info() { printf '%b[INFO]%b %s\n' "$C_INFO" "$C_RST" "$1"; }
log_ok()   { printf '%b[OK]%b %s\n'   "$C_OK"   "$C_RST" "$1"; }
log_warn() { printf '%b[WARN]%b %s\n' "$C_WARN" "$C_RST" "$1"; }
log_error(){ printf '%b[ERROR]%b %s\n' "$C_ERR"  "$C_RST" "$1" >&2; }
log_step() { printf '%b==>%b %s\n' "$C_HDR" "$C_RST" "$1"; }
die()      { log_error "$1"; exit 1; }

# =============================================================================
# Утилиты
# =============================================================================

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Скрипт необходимо запускать от root."
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_package_manager() {
    if have_cmd apk; then
        echo "apk"
    elif have_cmd opkg; then
        echo "opkg"
    else
        echo "unknown"
    fi
}

pm_is_installed() {
    _pkg="$1"
    _pm="$2"
    case "$_pm" in
        apk) apk info -e "$_pkg" >/dev/null 2>&1 ;;
        opkg) opkg status "$_pkg" 2>/dev/null | grep -q '^Status: install' ;;
        *) return 1 ;;
    esac
}

pm_remove() {
    _pkg="$1"
    _pm="$2"
    case "$_pm" in
        apk) apk del "$_pkg" ;;
        opkg) opkg remove "$_pkg" ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# Остановка сервиса
# =============================================================================

stop_service() {
    log_step "Остановка https-dns-proxy"
    if [ -f /etc/init.d/https-dns-proxy ]; then
        /etc/init.d/https-dns-proxy stop 2>/dev/null || true
        /etc/init.d/https-dns-proxy disable 2>/dev/null || true
        log_ok "Сервис остановлен и отключён."
    else
        log_info "Init-скрипт не найден — пропускаем."
    fi
}

# =============================================================================
# Удаление пакетов
# =============================================================================

remove_packages() {
    log_step "Удаление пакетов DoH"
    _pm="$(detect_package_manager)"
    [ "$_pm" = "unknown" ] && { log_warn "Пакетный менеджер не найден — удаление пропущено."; return 0; }

    if pm_is_installed "$PKG_NAME" "$_pm"; then
        log_info "Удаление $PKG_NAME..."
        pm_remove "$PKG_NAME" "$_pm" || log_warn "Не удалось удалить $PKG_NAME."
        log_ok "$PKG_NAME удалён."
    else
        log_info "$PKG_NAME не установлен — пропуск."
    fi

    if pm_is_installed "$LUCI_PKG" "$_pm"; then
        log_info "Удаление $LUCI_PKG (опционально)..."
        pm_remove "$LUCI_PKG" "$_pm" 2>/dev/null && log_ok "$LUCI_PKG удалён." || true
    fi
}

# =============================================================================
# Очистка UCI
# =============================================================================

remove_uci_config() {
    log_step "Удаление UCI-конфигурации DoH"
    if uci -q get "$UCI_CONFIG" >/dev/null 2>&1; then
        uci delete "$UCI_CONFIG" 2>/dev/null || true
        uci commit "$UCI_CONFIG" 2>/dev/null || true
        log_ok "UCI-секция $UCI_CONFIG удалена."
    else
        log_info "UCI-секция $UCI_CONFIG не найдена — пропуск."
    fi
}

# =============================================================================
# Восстановление dnsmasq
# =============================================================================

restore_dnsmasq() {
    log_step "Восстановление настроек dnsmasq"

    # Определяем порт, который использовался (если сохранился в UCI, иначе по умолчанию)
    _port="$DEFAULT_PORT"
    if uci -q get "$UCI_CONFIG.dns.listen_port" >/dev/null 2>&1; then
        _port="$(uci -q get "$UCI_CONFIG.dns.listen_port")"
    fi

    # Удаляем наш server (127.0.0.1#<port>)
    _server_to_remove="127.0.0.1#${_port}"
    if uci -q get dhcp.@dnsmasq[0].server >/dev/null 2>&1; then
        # Проверяем, есть ли такой сервер в списке
        _current_servers="$(uci -q get dhcp.@dnsmasq[0].server)"
        _new_servers=""
        _found=0
        for _s in $_current_servers; do
            if [ "$_s" = "$_server_to_remove" ]; then
                _found=1
                log_info "Удаление сервера $_server_to_remove из dnsmasq"
            else
                _new_servers="$_new_servers $_s"
            fi
        done
        if [ "$_found" -eq 1 ]; then
            # Очищаем список и добавляем все, кроме удалённого
            uci -q del_list dhcp.@dnsmasq[0].server 2>/dev/null
            for _s in $_new_servers; do
                [ -n "$_s" ] && uci add_list "dhcp.@dnsmasq[0].server=$_s"
            done
            uci commit dhcp
            log_ok "Сервер $_server_to_remove удалён из dnsmasq."
        else
            log_info "Сервер $_server_to_remove не найден в dnsmasq — пропуск."
        fi
    fi

    # Убираем noresolv, если он был установлен в 1 (мы его ставили)
    if uci -q get dhcp.@dnsmasq[0].noresolv >/dev/null 2>&1; then
        _noresolv="$(uci -q get dhcp.@dnsmasq[0].noresolv)"
        if [ "$_noresolv" = "1" ]; then
            log_info "Удаление noresolv из dnsmasq"
            uci delete dhcp.@dnsmasq[0].noresolv 2>/dev/null
            uci commit dhcp
            log_ok "noresolv удалён."
        fi
    fi

    # Убираем возможный фиктивный resolvfile, если он был установлен
    if uci -q get dhcp.@dnsmasq[0].resolvfile >/dev/null 2>&1; then
        _resolvfile="$(uci -q get dhcp.@dnsmasq[0].resolvfile)"
        if [ "$_resolvfile" = "/tmp/resolv.conf.dummy" ]; then
            log_info "Удаление resolvfile '/tmp/resolv.conf.dummy'"
            uci delete dhcp.@dnsmasq[0].resolvfile 2>/dev/null
            uci commit dhcp
            log_ok "resolvfile удалён."
        fi
    fi

    log_ok "Настройки dnsmasq восстановлены."
}

restart_dnsmasq() {
    log_info "Перезапуск dnsmasq..."
    /etc/init.d/dnsmasq restart || log_warn "Не удалось перезапустить dnsmasq."
    log_ok "dnsmasq перезапущен."
}

# =============================================================================
# Завершение
# =============================================================================

print_banner() {
    printf '\n=========================================\n%s\n=========================================\n\n' "$SCRIPT_TITLE"
}

prompt_reboot() {
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        log_info "Неинтерактивный режим. Рекомендуется перезагрузка: reboot"
        return 0
    fi
    printf '\n'
    log_info "Для полной очистки рекомендуется перезагрузить роутер."
    printf 'Перезагрузить сейчас? (y/N): '
    read -r _answer
    case "$_answer" in
        y|Y|yes|YES) log_info "Перезагрузка..."; reboot ;;
        *) log_info "Перезагрузка отменена. Выполните 'reboot' позже." ;;
    esac
}

# =============================================================================
# Точка входа
# =============================================================================

main() {
    require_root
    print_banner
    stop_service
    remove_packages
    remove_uci_config
    restore_dnsmasq
    restart_dnsmasq

    printf '\n'
    log_ok "DoH удалён."
    prompt_reboot
}

main "$@"
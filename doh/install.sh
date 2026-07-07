#!/bin/sh
#
# DoH (DNS-over-HTTPS) installer for OpenWrt
# Устанавливает https-dns-proxy, настраивает DNS-сервер через DoH,
# перенаправляет dnsmasq на локальный прокси.
#
# Использование:
#   sh install-doh.sh [--provider cloudflare|google|quad9|adguard] [--port <порт>]
#
# По умолчанию: Cloudflare, порт 5053
#

set -u

# =============================================================================
# Константы
# =============================================================================

readonly SCRIPT_TITLE="DoH Installer for OpenWrt"
readonly PKG_NAME="https-dns-proxy"
readonly LUCI_PKG="luci-app-https-dns-proxy"   # опционально, можно убрать

# Провайдеры DoH
CLOUDFLARE_URL="https://cloudflare-dns.com/dns-query"
GOOGLE_URL="https://dns.google/dns-query"
QUAD9_URL="https://dns.quad9.net/dns-query"
ADGUARD_URL="https://dns.adguard.com/dns-query"

DEFAULT_PROVIDER="cloudflare"
DEFAULT_PORT="5053"
LISTEN_ADDR="127.0.0.1"
USER="nobody"
GROUP="nogroup"

PROVIDER="$DEFAULT_PROVIDER"
PORT="$DEFAULT_PORT"

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
        SYS_PM="apk"
    elif have_cmd opkg; then
        SYS_PM="opkg"
    else
        SYS_PM="unknown"
    fi
}

pm_update() {
    case "$SYS_PM" in
        apk) apk update || return 1 ;;
        opkg) opkg update || return 1 ;;
        *) return 1 ;;
    esac
}

pm_install() {
    _pkg="$1"
    case "$SYS_PM" in
        apk) apk add "$_pkg" || return 1 ;;
        opkg) opkg install "$_pkg" || return 1 ;;
        *) return 1 ;;
    esac
}

pm_is_installed() {
    _pkg="$1"
    case "$SYS_PM" in
        apk) apk info -e "$_pkg" >/dev/null 2>&1 ;;
        opkg) opkg status "$_pkg" 2>/dev/null | grep -q '^Status: install' ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# Определение URL провайдера
# =============================================================================

get_provider_url() {
    case "$1" in
        cloudflare) echo "$CLOUDFLARE_URL" ;;
        google)     echo "$GOOGLE_URL" ;;
        quad9)      echo "$QUAD9_URL" ;;
        adguard)    echo "$ADGUARD_URL" ;;
        *)          echo "$CLOUDFLARE_URL" ;;
    esac
}

# =============================================================================
# Настройка https-dns-proxy
# =============================================================================

configure_https_dns_proxy() {
    log_step "Настройка https-dns-proxy"

    # Удаляем старую конфигурацию (если есть)
    uci -q delete https-dns-proxy.@https-dns-proxy[0] 2>/dev/null || true

    # Создаём новую секцию
    uci set https-dns-proxy.dns="https-dns-proxy"
    uci set "https-dns-proxy.dns.resolver_url=$(get_provider_url "$PROVIDER")"
    uci set "https-dns-proxy.dns.listen_addr=$LISTEN_ADDR"
    uci set "https-dns-proxy.dns.listen_port=$PORT"
    uci set "https-dns-proxy.dns.user=$USER"
    uci set "https-dns-proxy.dns.group=$GROUP"
    uci commit https-dns-proxy

    log_ok "Конфигурация https-dns-proxy сохранена (провайдер: $PROVIDER, порт: $PORT)"
}

restart_https_dns_proxy() {
    log_info "Перезапуск https-dns-proxy..."
    /etc/init.d/https-dns-proxy restart || die "Не удалось перезапустить https-dns-proxy."
    log_ok "Сервис https-dns-proxy перезапущен."
}

# =============================================================================
# Настройка dnsmasq
# =============================================================================

configure_dnsmasq() {
    log_step "Настройка dnsmasq для использования DoH-прокси"

    # Отключаем использование внешних DNS-серверов из /tmp/resolv.conf
    uci set dhcp.@dnsmasq[0].noresolv='1'

    # Удаляем все существующие серверы, чтобы избежать дублей
    uci -q del_list dhcp.@dnsmasq[0].server 2>/dev/null || true

    # Добавляем наш локальный прокси
    uci add_list "dhcp.@dnsmasq[0].server=127.0.0.1#$PORT"

    # Опционально: отключаем использование resolv.conf (чтобы не было утечек)
    uci set dhcp.@dnsmasq[0].resolvfile='/tmp/resolv.conf.dummy' 2>/dev/null || true

    uci commit dhcp

    log_ok "dnsmasq настроен на использование 127.0.0.1#$PORT"
}

restart_dnsmasq() {
    log_info "Перезапуск dnsmasq..."
    /etc/init.d/dnsmasq restart || die "Не удалось перезапустить dnsmasq."
    log_ok "dnsmasq перезапущен."
}

# =============================================================================
# Проверка работы
# =============================================================================

verify_dns() {
    log_step "Проверка DNS (nslookup openwrt.org)"
    if have_cmd nslookup; then
        nslookup openwrt.org 127.0.0.1 || log_warn "Проверка DNS не удалась – возможно, проблема с DoH-сервером."
    else
        log_warn "nslookup не установлен, пропускаем проверку."
    fi
}

# =============================================================================
# Установка
# =============================================================================

install_packages() {
    log_step "Установка пакетов"

    pm_update || die "Не удалось обновить списки пакетов."

    if pm_is_installed "$PKG_NAME"; then
        log_info "Пакет $PKG_NAME уже установлен."
    else
        log_info "Установка $PKG_NAME..."
        pm_install "$PKG_NAME" || die "Не удалось установить $PKG_NAME."
    fi

    # LUCI-пакет не обязателен, но установим, если доступен
    if pm_is_installed "$LUCI_PKG"; then
        log_info "Пакет $LUCI_PKG уже установлен."
    else
        log_info "Установка $LUCI_PKG (опционально)..."
        pm_install "$LUCI_PKG" 2>/dev/null && log_ok "LUCI-пакет установлен." || log_warn "LUCI-пакет не установлен (не критично)."
    fi

    log_ok "Пакеты установлены."
}

# =============================================================================
# Включение автозапуска (для https-dns-proxy уже включено, но проверим)
# =============================================================================

enable_service() {
    if [ -f /etc/init.d/https-dns-proxy ]; then
        /etc/init.d/https-dns-proxy enable || log_warn "Не удалось включить автозапуск https-dns-proxy."
        log_ok "Автозапуск https-dns-proxy включён."
    fi
}

# =============================================================================
# Завершение
# =============================================================================

print_banner() {
    printf '\n=========================================\n%s\n=========================================\n\n' "$SCRIPT_TITLE"
}

print_summary() {
    log_info "Провайдер DoH : $PROVIDER"
    log_info "Порт прокси   : $PORT"
    log_info "Менеджер пакетов : $SYS_PM"
    printf '\n'
}

print_final_report() {
    printf '\n=========================================\n'
    log_ok "DoH установлен и настроен."
    printf '\n'
    log_info "Проверка: nslookup openwrt.org 127.0.0.1"
    log_info "Для смены провайдера перезапустите скрипт с --provider"
    log_info "Для отката удалите пакет: %s remove %s" "$SYS_PM" "$PKG_NAME"
    printf '\n'
}

# =============================================================================
# Точка входа
# =============================================================================

main() {
    # Парсинг аргументов
    while [ $# -gt 0 ]; do
        case "$1" in
            --provider)
                [ -n "$2" ] || die "Ошибка: --provider требует значение (cloudflare, google, quad9, adguard)"
                PROVIDER="$2"
                shift 2
                ;;
            --port)
                [ -n "$2" ] || die "Ошибка: --port требует номер порта"
                PORT="$2"
                shift 2
                ;;
            *) die "Неизвестный аргумент: $1" ;;
        esac
    done

    require_root
    detect_package_manager
    [ "$SYS_PM" = "unknown" ] && die "Не найден пакетный менеджер (opkg/apk)."

    print_banner
    print_summary

    install_packages
    configure_https_dns_proxy
    enable_service
    restart_https_dns_proxy
    configure_dnsmasq
    restart_dnsmasq
    verify_dns

    print_final_report
}

main "$@"
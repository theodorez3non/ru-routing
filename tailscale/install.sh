#!/bin/sh
#
# Tailscale Exit Node — установщик для OpenWrt 24.x / 25.x
#
# Режимы:
#   1. Первичная установка — ставятся только отсутствующие пакеты.
#   2. Повторный запуск — пакеты не трогаются, сервис сбрасывается и настраивается заново.
#
# Использование:
#   sh install.sh [--mirror <URL>]
#
# Совместимость: BusyBox ash (/bin/sh), opkg (24.x), apk (25.x)
#

set -u

# =============================================================================
# Константы (согласованы с remove.sh)
#
# Контракт артефактов:
#   пакет tailscale, init /etc/init.d/tailscale
#   UCI /etc/config/tailscale (fw_mode=off), network.tailscale (proto none)
#   state: /etc/tailscale, /var/lib/tailscale, /var/run/tailscale
#   kernel iface tailscale0
#   firewall: zone tailscale, forwarding tailscale->wan, SSH/HTTP/HTTPS rules
#   tmp /tmp/tailscale_up.log
# =============================================================================

readonly SCRIPT_TITLE="Tailscale installer for OpenWrt"

readonly TAILSCALE_PKG="tailscale"
readonly TAILSCALE_INIT="/etc/init.d/tailscale"
readonly TAILSCALE_UP_ARGS="--advertise-exit-node --accept-dns=false --netfilter-mode=off --ssh"

readonly TAILSCALE_IFACE="tailscale0"
readonly TAILSCALE_UCI_CONFIG="/etc/config/tailscale"
readonly TAILSCALE_FW_MODE="off"
readonly SYS_NET_PATH="/sys/class/net"

readonly NET_INTERFACE="tailscale"
readonly NET_PROTO="none"

readonly FW_ZONE="tailscale"
readonly FW_ZONE_LEGACY="tailscaleZone"
readonly FW_WAN_ZONE="wan"

readonly FW_RULE_SSH="Allow-Tailscale-SSH"
readonly FW_RULE_HTTP="Allow-Tailscale-HTTP"
readonly FW_RULE_HTTPS="Allow-Tailscale-HTTPS"
readonly FW_RULE_WEB="Allow-Tailscale-Web"

readonly PORT_SSH="22"
readonly PORT_HTTP="80"
readonly PORT_HTTPS="443"

readonly TAILSCALE_STATE_DIR="/etc/tailscale"
readonly TAILSCALE_LIB_DIR="/var/lib/tailscale"
readonly TAILSCALE_RUN_DIR="/var/run/tailscale"
readonly TAILSCALE_UP_LOG="/tmp/tailscale_up.log"

readonly DEP_PACKAGES="kmod-tun ca-bundle"
readonly OPTIONAL_PACKAGES="iptables-nft ip6tables-nft"

readonly MIN_FREE_KIB=10240
readonly DAEMON_WAIT_SECS=30
readonly DAEMON_POLL_SECS=2
readonly PROCESS_STOP_WAIT_SECS=2

readonly IFACE_WAIT_SECS=10
readonly IFACE_BIND_WAIT_SECS=3

readonly TAILSCALE_UP_HINT_TIMEOUT="60s"

readonly OPENWRT_RELEASE_FILE="/etc/openwrt_release"
readonly TIMEZONE_NAME="Europe/Moscow"
readonly TIMEZONE_STRING="MSK-3"

# =============================================================================
# Состояние
# =============================================================================

SYS_ARCH=""
SYS_VERSION=""
SYS_PM=""
SYS_FREE_KIB=""
TAILSCALE_INIT_PATH=""
REPO_FILE=""
INSTALL_MODE="reconfigure"

MIRROR_URL=""

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
    [ -f "$OPENWRT_RELEASE_FILE" ] || return 0
    grep "^${_var}=" "$OPENWRT_RELEASE_FILE" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d "'\""
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

interface_is_operational() {
    interface_exists \
        && ip -o link show dev "$TAILSCALE_IFACE" 2>/dev/null | grep -q '<.*UP.*>'
}

log_interface_state() {
    _state="$(ip -o link show dev "$TAILSCALE_IFACE" 2>/dev/null || echo 'отсутствует')"
    log_info "Состояние ${TAILSCALE_IFACE}: ${_state}"
}

is_mips_platform() {
    case "$SYS_ARCH" in
        mips*|*mips*|ramips*) return 0 ;;
        *) return 1 ;;
    esac
}

netfilter_tool_available() {
    _tool="$1"
    have_cmd "$_tool" && return 0
    [ -x "/usr/sbin/$_tool" ] && return 0
    return 1
}

# =============================================================================
# Обнаружение системы
# =============================================================================

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

    _target="/overlay"
    df -k "$_target" >/dev/null 2>&1 || _target="/"
    SYS_FREE_KIB="$(df -k "$_target" 2>/dev/null | awk 'NR==2 {print $4}')"
    [ -z "$SYS_FREE_KIB" ] && SYS_FREE_KIB=0

    if is_tailscale_package_installed; then
        INSTALL_MODE="reconfigure"
    else
        INSTALL_MODE="fresh"
    fi
}

validate_environment() {
    [ "$SYS_PM" = "unknown" ] && die "Не найден пакетный менеджер (opkg/apk)."
    if [ "$SYS_FREE_KIB" -lt "$MIN_FREE_KIB" ] 2>/dev/null; then
        log_warn "Мало свободного места: ${SYS_FREE_KIB} KiB (рекомендуется >= ${MIN_FREE_KIB} KiB)."
    fi
}

# =============================================================================
# Зеркало репозиториев
# =============================================================================

setup_mirror() {
    [ -z "$MIRROR_URL" ] && return 0

    case "$SYS_PM" in
        apk)
            if [ -f "/etc/apk/repositories.d/distfeeds.list" ]; then
                REPO_FILE="/etc/apk/repositories.d/distfeeds.list"
            elif [ -f "/etc/apk/repositories" ]; then
                REPO_FILE="/etc/apk/repositories"
            else
                log_warn "Файл репозиториев apk не найден."
                return 0
            fi
            ;;
        opkg)
            if [ -f "/etc/opkg/distfeeds.conf" ]; then
                REPO_FILE="/etc/opkg/distfeeds.conf"
            else
                log_warn "Файл репозиториев opkg не найден."
                return 0
            fi
            ;;
        *) return 1 ;;
    esac

    cp "$REPO_FILE" "${REPO_FILE}.backup" || return 1
    sed -i "s|https\?://downloads.openwrt.org|$MIRROR_URL|g" "$REPO_FILE" || return 1
    log_info "Зеркало установлено: $MIRROR_URL"
}

restore_mirror() {
    [ -z "$MIRROR_URL" ] || [ -z "$REPO_FILE" ] && return 0
    if [ -f "${REPO_FILE}.backup" ]; then
        mv "${REPO_FILE}.backup" "$REPO_FILE" 2>/dev/null && log_info "Репозитории восстановлены."
    fi
}

# =============================================================================
# Пакетный менеджер
# =============================================================================

pm_update_indexes() {
    log_info "Обновление списков пакетов ($SYS_PM)..."
    case "$SYS_PM" in
        apk)  apk update || return 1 ;;
        opkg) opkg update || return 1 ;;
        *) return 1 ;;
    esac
}

pm_is_installed() {
    _pkg="$1"
    case "$SYS_PM" in
        apk)
            apk info -e "$_pkg" >/dev/null 2>&1 && return 0
            apk list -I 2>/dev/null | grep -q "^${_pkg}-" && return 0
            apk list --installed 2>/dev/null | grep -q "^${_pkg}-" && return 0
            return 1
            ;;
        opkg)
            opkg status "$_pkg" 2>/dev/null | grep -q '^Status: install'
            ;;
        *) return 1 ;;
    esac
}

is_tailscale_package_installed() {
    pm_is_installed "$TAILSCALE_PKG"
}

packages_missing_from_list() {
    _list="$1"
    for _pkg in $_list; do
        pm_is_installed "$_pkg" || return 0
    done
    return 1
}

pm_install() {
    _pkg="$1"
    case "$SYS_PM" in
        apk)  apk add "$_pkg" || return 1 ;;
        opkg) opkg install "$_pkg" || return 1 ;;
        *) return 1 ;;
    esac
}

pm_install_if_missing() {
    _pkg="$1"
    if pm_is_installed "$_pkg"; then
        log_info "Пакет уже установлен: $_pkg"
        return 0
    fi
    log_info "Установка: $_pkg"
    pm_install "$_pkg" || return 1
    log_ok "Пакет $_pkg установлен."
}

binary_in_path() {
    have_cmd "$1"
}

verify_tailscale_binaries() {
    for _bin in tailscale tailscaled; do
        if binary_in_path "$_bin"; then
            log_ok "Бинарник найден: $_bin"
        else
            log_error "Бинарник не найден: $_bin"
            return 1
        fi
    done
    return 0
}

# =============================================================================
# Фаза 1: установка пакетов (только при отсутствии)
# =============================================================================

ensure_tun() {
    if ! lsmod | grep -q tun; then
        log_info "Загрузка модуля tun..."
        modprobe tun || die "Не удалось загрузить модуль tun."
    fi
    if [ ! -c /dev/net/tun ]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200
        chmod 600 /dev/net/tun
    fi
    log_ok "TUN готов (/dev/net/tun)."
}

configure_timezone() {
    if ! uci -q get system.@system[0] >/dev/null 2>&1; then
        uci add system system >/dev/null
    fi
    _zone="$(uci -q get system.@system[0].zonename 2>/dev/null || true)"
    _tz="$(uci -q get system.@system[0].timezone 2>/dev/null || true)"
    if [ "$_zone" = "$TIMEZONE_NAME" ] && [ "$_tz" = "$TIMEZONE_STRING" ]; then
        log_info "Часовой пояс уже настроен: $TIMEZONE_NAME"
        return 0
    fi
    uci set system.@system[0].zonename="$TIMEZONE_NAME"
    uci set system.@system[0].timezone="$TIMEZONE_STRING"
    uci commit system
    log_ok "Часовой пояс: $TIMEZONE_NAME"
}

phase_install_packages() {
    log_step "Фаза 1: установка пакетов"

    if [ "$INSTALL_MODE" = "reconfigure" ]; then
        log_ok "Пакет $TAILSCALE_PKG уже установлен — пропуск установки пакетов."
        verify_tailscale_binaries || die "Бинарники Tailscale недоступны."
        return 0
    fi

    _all_pkgs="$DEP_PACKAGES $OPTIONAL_PACKAGES $TAILSCALE_PKG"
    if packages_missing_from_list "$_all_pkgs"; then
        pm_update_indexes || die "Не удалось обновить списки пакетов."
    fi

    for _pkg in $DEP_PACKAGES; do
        pm_install_if_missing "$_pkg" || die "Не удалось установить $_pkg."
    done

    for _pkg in $OPTIONAL_PACKAGES; do
        pm_install_if_missing "$_pkg" 2>/dev/null \
            || log_warn "Опциональный пакет $_pkg недоступен."
    done

    pm_install_if_missing "$TAILSCALE_PKG" || die "Не удалось установить $TAILSCALE_PKG."
    verify_tailscale_binaries || die "Бинарники Tailscale недоступны после установки."

    ensure_tun
    configure_timezone
    log_ok "Фаза 1 завершена: пакеты установлены."
}

# =============================================================================
# UCI — вспомогательные функции
# =============================================================================

firewall_zone_index_by_name() {
    _zone_name="$1"
    _zone_idx=0
    while uci -q get "firewall.@zone[${_zone_idx}]" >/dev/null 2>&1; do
        _zone_cur="$(uci -q get "firewall.@zone[${_zone_idx}].name" 2>/dev/null || true)"
        if [ "$_zone_cur" = "$_zone_name" ]; then
            printf '%s' "$_zone_idx"
            return 0
        fi
        _zone_idx=$((_zone_idx + 1))
    done
    return 1
}

firewall_anonymous_section_count() {
    _sec_type="$1"
    _sec_idx=0
    while uci -q get "firewall.@${_sec_type}[${_sec_idx}]" >/dev/null 2>&1; do
        _sec_idx=$((_sec_idx + 1))
    done
    printf '%s' "$_sec_idx"
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

firewall_rule_exists() {
    _rule_chk="$1"
    _rule_idx=0
    while uci -q get "firewall.@rule[${_rule_idx}]" >/dev/null 2>&1; do
        _rule_cur="$(uci -q get "firewall.@rule[${_rule_idx}].name" 2>/dev/null || true)"
        [ "$_rule_cur" = "$_rule_chk" ] && return 0
        _rule_idx=$((_rule_idx + 1))
    done
    return 1
}

firewall_forwarding_exists() {
    _fwd_src="$1"
    _fwd_dest="$2"
    _fwd_idx=0
    while uci -q get "firewall.@forwarding[${_fwd_idx}]" >/dev/null 2>&1; do
        _fwd_cur_src="$(uci -q get "firewall.@forwarding[${_fwd_idx}].src" 2>/dev/null || true)"
        _fwd_cur_dest="$(uci -q get "firewall.@forwarding[${_fwd_idx}].dest" 2>/dev/null || true)"
        if [ "$_fwd_cur_src" = "$_fwd_src" ] && [ "$_fwd_cur_dest" = "$_fwd_dest" ]; then
            return 0
        fi
        _fwd_idx=$((_fwd_idx + 1))
    done
    return 1
}

# =============================================================================
# Фаза 2: сброс сервиса (всегда при каждом запуске)
# =============================================================================

resolve_init_script() {
    if [ -x "$TAILSCALE_INIT" ]; then
        TAILSCALE_INIT_PATH="$TAILSCALE_INIT"
        return 0
    fi
    TAILSCALE_INIT_PATH=""
    return 1
}

stop_tailscaled() {
    if have_cmd tailscale; then
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
}

delete_kernel_interface() {
    if ! interface_exists; then
        return 0
    fi
    ip link set dev "$TAILSCALE_IFACE" down 2>/dev/null || true
    ip link delete dev "$TAILSCALE_IFACE" 2>/dev/null \
        || ip tuntap del mode tun dev "$TAILSCALE_IFACE" 2>/dev/null \
        || true
}

clear_tailscale_state() {
    for _path in "$TAILSCALE_STATE_DIR" "$TAILSCALE_LIB_DIR" "$TAILSCALE_RUN_DIR"; do
        [ -d "$_path" ] && rm -rf "$_path"
    done
    rm -f "$TAILSCALE_UP_LOG" 2>/dev/null || true
    if ls /tmp/tailscale* >/dev/null 2>&1; then
        rm -rf /tmp/tailscale*
    fi
}

remove_uci_network_tailscale() {
    if uci -q get "network.${NET_INTERFACE}" >/dev/null 2>&1; then
        uci -q delete "network.${NET_INTERFACE}.ipaddr" 2>/dev/null || true
        uci -q delete "network.${NET_INTERFACE}.netmask" 2>/dev/null || true
        uci delete "network.${NET_INTERFACE}" || return 1
        log_info "Удалена секция network.${NET_INTERFACE}"
    fi
}

remove_uci_firewall_tailscale() {
    _rm_count="$(firewall_anonymous_section_count rule)"
    _rm_idx=$((_rm_count - 1))
    while [ "$_rm_idx" -ge 0 ]; do
        _rm_name="$(uci -q get "firewall.@rule[${_rm_idx}].name" 2>/dev/null || true)"
        _rm_src="$(uci -q get "firewall.@rule[${_rm_idx}].src" 2>/dev/null || true)"
        if is_tailscale_rule_name "$_rm_name" || is_tailscale_zone_name "$_rm_src"; then
            uci delete "firewall.@rule[${_rm_idx}]" || return 1
        fi
        _rm_idx=$((_rm_idx - 1))
    done

    _rm_count="$(firewall_anonymous_section_count forwarding)"
    _rm_idx=$((_rm_count - 1))
    while [ "$_rm_idx" -ge 0 ]; do
        _rm_src="$(uci -q get "firewall.@forwarding[${_rm_idx}].src" 2>/dev/null || true)"
        _rm_dest="$(uci -q get "firewall.@forwarding[${_rm_idx}].dest" 2>/dev/null || true)"
        if is_tailscale_zone_name "$_rm_src" || is_tailscale_zone_name "$_rm_dest"; then
            uci delete "firewall.@forwarding[${_rm_idx}]" || return 1
        fi
        _rm_idx=$((_rm_idx - 1))
    done

    for _rm_zone in "$FW_ZONE" "$FW_ZONE_LEGACY"; do
        _rm_zidx="$(firewall_zone_index_by_name "$_rm_zone" 2>/dev/null || true)"
        while [ -n "$_rm_zidx" ]; do
            uci delete "firewall.@zone[${_rm_zidx}]" || return 1
            _rm_zidx="$(firewall_zone_index_by_name "$_rm_zone" 2>/dev/null || true)"
        done
    done
}

phase_reset_service() {
    log_step "Фаза 2: сброс сервиса Tailscale"

    stop_tailscaled
    delete_kernel_interface
    clear_tailscale_state
    remove_uci_network_tailscale
    remove_uci_firewall_tailscale

    if uci changes network 2>/dev/null | grep -q .; then
        uci commit network 2>/dev/null || true
    fi
    if uci changes firewall 2>/dev/null | grep -q .; then
        uci commit firewall 2>/dev/null || true
    fi

    log_ok "Фаза 2 завершена: сервис и конфигурация сброшены."
}

# =============================================================================
# Фаза 3: настройка сервиса
# =============================================================================

configure_tailscale_daemon() {
    if ! uci -q get tailscale.settings >/dev/null 2>&1; then
        uci set tailscale.settings=settings
        uci set tailscale.settings.log_stderr='1'
        uci set tailscale.settings.log_stdout='1'
        uci set tailscale.settings.port='41641'
        uci set tailscale.settings.state_file="${TAILSCALE_LIB_DIR}/tailscaled.state"
    fi
    uci set "tailscale.settings.fw_mode=${TAILSCALE_FW_MODE}"
    uci commit tailscale || die "Не удалось сохранить $TAILSCALE_UCI_CONFIG"
    log_ok "Демон: fw_mode=${TAILSCALE_FW_MODE}"
}

wait_for_daemon_ready() {
    _elapsed=0
    _sock="${TAILSCALE_RUN_DIR}/tailscaled.sock"
    while [ "$_elapsed" -lt "$DAEMON_WAIT_SECS" ]; do
        if [ -S "$_sock" ]; then
            log_ok "Демон готов (сокет $_sock)."
            return 0
        fi
        sleep "$DAEMON_POLL_SECS"
        _elapsed=$((_elapsed + DAEMON_POLL_SECS))
    done
    if is_process_running tailscaled; then
        log_warn "Сокет не появился, но процесс tailscaled работает."
        return 0
    fi
    die "Демон tailscaled не запустился."
}

create_tailscale_tun_interface() {
    if interface_exists; then
        ip link set dev "$TAILSCALE_IFACE" up 2>/dev/null || return 1
        return 0
    fi
    ip tuntap add mode tun dev "$TAILSCALE_IFACE" 2>/dev/null || return 1
    ip link set dev "$TAILSCALE_IFACE" up 2>/dev/null || return 1
    return 0
}

ensure_tailscale_interface() {
    _elapsed=0
    log_info "Проверка интерфейса ${TAILSCALE_IFACE}..."

    while [ "$_elapsed" -lt "$IFACE_WAIT_SECS" ]; do
        if interface_is_operational; then
            log_ok "Интерфейс ${TAILSCALE_IFACE} готов."
            return 0
        fi
        sleep 1
        _elapsed=$((_elapsed + 1))
    done

    if is_mips_platform; then
        log_warn "MIPS: создаём ${TAILSCALE_IFACE} вручную."
    else
        log_warn "Интерфейс не появился за ${IFACE_WAIT_SECS} с — создаём вручную."
    fi

    create_tailscale_tun_interface || die "Не удалось создать ${TAILSCALE_IFACE}."
    sleep "$IFACE_BIND_WAIT_SECS"
    interface_exists || die "Интерфейс ${TAILSCALE_IFACE} не создан."
    log_ok "Интерфейс ${TAILSCALE_IFACE} создан."
}

configure_network_uci() {
    uci set "network.${NET_INTERFACE}=interface"
    uci set "network.${NET_INTERFACE}.proto=${NET_PROTO}"
    uci set "network.${NET_INTERFACE}.device=${TAILSCALE_IFACE}"
    uci -q delete "network.${NET_INTERFACE}.ipaddr" 2>/dev/null || true
    uci -q delete "network.${NET_INTERFACE}.netmask" 2>/dev/null || true
    uci -q delete "network.${NET_INTERFACE}.ip6assign" 2>/dev/null || true
    log_ok "UCI network.${NET_INTERFACE} создан (proto=${NET_PROTO})."
}

add_firewall_rule_if_missing() {
    _rule_name="$1"
    _rule_port="$2"
    if firewall_rule_exists "$_rule_name"; then
        log_info "Правило $_rule_name уже существует."
        return 0
    fi
    _rule_sec="$(uci add firewall rule)"
    uci set "firewall.${_rule_sec}.name=${_rule_name}"
    uci set "firewall.${_rule_sec}.src=${FW_ZONE}"
    uci set "firewall.${_rule_sec}.proto=tcp"
    uci set "firewall.${_rule_sec}.dest_port=${_rule_port}"
    uci set "firewall.${_rule_sec}.target=ACCEPT"
    log_ok "Правило $_rule_name добавлено (порт $_rule_port)."
}

configure_firewall_uci() {
    if ! firewall_zone_index_by_name "$FW_ZONE" >/dev/null 2>&1; then
        _zone_sec="$(uci add firewall zone)"
        uci set "firewall.${_zone_sec}.name=${FW_ZONE}"
        uci set "firewall.${_zone_sec}.input=ACCEPT"
        uci set "firewall.${_zone_sec}.output=ACCEPT"
        uci set "firewall.${_zone_sec}.forward=ACCEPT"
        uci set "firewall.${_zone_sec}.masq=1"
        uci set "firewall.${_zone_sec}.mtu_fix=1"
        uci add_list "firewall.${_zone_sec}.network=${NET_INTERFACE}"
        log_ok "Firewall-зона ${FW_ZONE} создана."
    else
        log_info "Firewall-зона ${FW_ZONE} уже существует."
    fi

    if ! firewall_forwarding_exists "$FW_ZONE" "$FW_WAN_ZONE"; then
        _fwd_sec="$(uci add firewall forwarding)"
        uci set "firewall.${_fwd_sec}.src=${FW_ZONE}"
        uci set "firewall.${_fwd_sec}.dest=${FW_WAN_ZONE}"
        log_ok "Forwarding ${FW_ZONE} -> ${FW_WAN_ZONE} добавлен."
    fi

    add_firewall_rule_if_missing "$FW_RULE_SSH" "$PORT_SSH"
    add_firewall_rule_if_missing "$FW_RULE_HTTP" "$PORT_HTTP"
    add_firewall_rule_if_missing "$FW_RULE_HTTPS" "$PORT_HTTPS"
}

enable_ip_forwarding() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    if uci -q get network.globals >/dev/null 2>&1; then
        uci set network.globals.forwarding='1'
    else
        uci set network.globals=globals
        uci set network.globals.forwarding='1'
    fi
    log_ok "IPv4 forwarding включён."
}

uci_commit_and_reload() {
    uci commit network || die "uci commit network failed."
    uci commit firewall || die "uci commit firewall failed."
    /etc/init.d/network reload 2>/dev/null || log_warn "network reload warning."
    /etc/init.d/firewall reload 2>/dev/null || log_warn "firewall reload warning."
}

phase_configure_service() {
    log_step "Фаза 3: настройка сервиса Tailscale"

    ensure_tun
    if ! netfilter_tool_available iptables || ! netfilter_tool_available ip6tables; then
        for _pkg in $OPTIONAL_PACKAGES; do
            pm_install_if_missing "$_pkg" 2>/dev/null || true
        done
    fi

    configure_tailscale_daemon

    resolve_init_script || die "Init-скрипт $TAILSCALE_INIT не найден."
    log_info "Включение и запуск сервиса..."
    "$TAILSCALE_INIT_PATH" enable || die "Не удалось включить автозапуск."
    "$TAILSCALE_INIT_PATH" start || die "Не удалось запустить сервис."

    wait_for_daemon_ready
    ensure_tailscale_interface
    configure_network_uci
    configure_firewall_uci
    enable_ip_forwarding
    uci_commit_and_reload

    log_ok "Фаза 3 завершена: сервис настроен."
}

# =============================================================================
# Фаза 4: подсказка для авторизации (вручную)
# =============================================================================

is_tailscale_authenticated() {
    _status="$(tailscale status 2>&1 || true)"
    printf '%s\n' "$_status" | grep -qi 'logged out' && return 1
    printf '%s\n' "$_status" | grep -qi 'needs login' && return 1
    printf '%s\n' "$_status" | grep -q 'https://login.tailscale.com/' && return 1
    tailscale ip -4 >/dev/null 2>&1
}

build_tailscale_up_command() {
    # shellcheck disable=SC2086
    printf 'tailscale up --reset --timeout=%s %s' "$TAILSCALE_UP_HINT_TIMEOUT" "$TAILSCALE_UP_ARGS"
}

print_tailscale_login_hint() {
    _up_cmd="$(build_tailscale_up_command)"
    log_step "Фаза 4: авторизация и Exit Node"
    printf '\n'
    log_info "Скрипт не запускает tailscale up автоматически."
    log_info "Для входа в сеть и включения Exit Node выполните:"
    printf '\n    %s\n\n' "$_up_cmd"
    log_info "Затем откройте ссылку из вывода команды или проверьте: tailscale status"
}

# =============================================================================
# Итог
# =============================================================================

print_banner() {
    printf '\n=========================================\n%s\n=========================================\n\n' "$SCRIPT_TITLE"
}

print_system_summary() {
    log_info "OpenWrt version : ${SYS_VERSION}"
    log_info "Architecture    : ${SYS_ARCH}"
    log_info "Package manager : ${SYS_PM}"
    log_info "Free space      : ${SYS_FREE_KIB} KiB"
    log_info "Режим           : ${INSTALL_MODE}"
    printf '\n'
}

print_final_report() {
    _auth="не авторизовано"
    is_tailscale_authenticated && _auth="авторизовано"
    _state="остановлен"
    is_process_running tailscaled && _state="работает"
    _ts_ip="$(tailscale ip -4 2>/dev/null || true)"
    _up_cmd="$(build_tailscale_up_command)"

    printf '\n=========================================\n Установка Tailscale завершена\n=========================================\n\n'
    log_ok "Режим          : ${INSTALL_MODE}"
    log_ok "Сервис         : ${_state}"
    log_ok "Интерфейс      : ${TAILSCALE_IFACE}"
    log_ok "LuCI           : network.${NET_INTERFACE}"
    log_info "Авторизация    : ${_auth} (выполняется вручную)"
    log_info "Exit Node      : ${TAILSCALE_UP_ARGS}"
    [ -n "$_ts_ip" ] && log_info "Tailscale IPv4 : ${_ts_ip}"
    printf '\n'
    log_info "Команда для входа в сеть:"
    printf '    %s\n' "$_up_cmd"
    printf '\n'
    log_info "Статус: tailscale status"
    log_info "Админка: https://login.tailscale.com/admin/machines"
    printf '\n'
}

# =============================================================================
# Точка входа
# =============================================================================

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --mirror)
                [ -n "$2" ] || die "Ошибка: --mirror требует URL."
                MIRROR_URL="$2"
                shift 2
                ;;
            *) die "Неизвестный аргумент: $1" ;;
        esac
    done

    require_root
    detect_system

    trap restore_mirror EXIT

    if [ -n "$MIRROR_URL" ]; then
        setup_mirror || die "Не удалось настроить зеркало."
    fi

    print_banner
    print_system_summary
    validate_environment

    phase_install_packages
    phase_reset_service
    phase_configure_service
    print_tailscale_login_hint
    print_final_report
}

main "$@"

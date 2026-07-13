#!/bin/sh
#
# Tailscale Exit Node — production installer for OpenWrt 24.x / 25.x
# Безопасная установка: не изменяет DNS, firewall, маршруты, интерфейсы UCI.
# Поддерживает авторизацию по ключу или интерактивно (вывод ссылки).
#
# Использование:
#   sh install.sh [--mirror <URL>] [--auth-key <ключ>]
#

set -u

# =============================================================================
# Константы
# =============================================================================

readonly SCRIPT_TITLE="Tailscale installer for OpenWrt (non‑invasive)"

readonly TAILSCALE_PKG="tailscale"
readonly TAILSCALE_INIT_DEFAULT="/etc/init.d/tailscale"
readonly TAILSCALE_UP_ARGS="--advertise-exit-node --accept-dns=false --netfilter-mode=off --ssh"

readonly DEP_PACKAGES="kmod-tun ca-bundle"
readonly OPTIONAL_PACKAGES="iptables-nft ip6tables-nft"
readonly MIN_FREE_KIB=10240
readonly DAEMON_WAIT_SECS=30
readonly DAEMON_POLL_SECS=2
readonly TAILSCALE_UP_TIMEOUT=15
readonly TAILSCALE_UP_AUTH_TIMEOUT=120

readonly TAILSCALE_IFACE="tailscale0"
readonly TAILSCALE_UCI_CONFIG="/etc/config/tailscale"
readonly TAILSCALE_FW_MODE="off"
readonly SYS_NET_PATH="/sys/class/net"
readonly IFACE_WAIT_SECS=10
readonly IFACE_BIND_WAIT_SECS=3
readonly IFACE_RETRY_WAIT_SECS=5
readonly TAILSCALE_UP_LOG="/tmp/tailscale_up.log"
readonly TAILSCALE_UP_MAX_ATTEMPTS=2

readonly OPENWRT_RELEASE_FILE="/etc/openwrt_release"

# Настройки времени (опционально)
readonly TIMEZONE_NAME="Europe/Moscow"
readonly TIMEZONE_STRING="MSK-3"

# Служебные файлы
readonly FORWARDING_BACKUP="/etc/tailscale/.forwarding_orig"

# =============================================================================
# Состояние
# =============================================================================

SYS_ARCH=""
SYS_VERSION=""
SYS_PM=""
SYS_FREE_KIB=""
TAILSCALE_INIT_PATH=""
REPO_FILE=""

MIRROR_URL=""
AUTH_KEY=""

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

# Проверка и запуск команды с таймаутом (собственная реализация)
run_with_timeout() {
    _timeout="$1"
    shift
    if have_cmd timeout; then
        timeout "$_timeout" "$@"
        return $?
    fi
    # Fallback: запустить в фоне, убить через timeout
    "$@" &
    _pid=$!
    _elapsed=0
    while [ "$_elapsed" -lt "$_timeout" ]; do
        sleep 1
        _elapsed=$((_elapsed + 1))
        kill -0 "$_pid" 2>/dev/null || break
    done
    if kill -0 "$_pid" 2>/dev/null; then
        kill "$_pid" 2>/dev/null
        wait "$_pid" 2>/dev/null
        return 124 # таймаут
    else
        wait "$_pid" 2>/dev/null
        return $?
    fi
}

# Проверка наличия процесса по имени
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
        && ip link show dev "$TAILSCALE_IFACE" >/dev/null 2>&1
}

interface_link_is_up() {
    interface_exists || return 1
    ip -o link show dev "$TAILSCALE_IFACE" 2>/dev/null | grep -q '<.*UP.*>'
}

interface_is_operational() {
    interface_link_is_up
}

log_interface_state() {
    _state="$(ip -o link show dev "$TAILSCALE_IFACE" 2>/dev/null || echo 'отсутствует')"
    log_info "Состояние ${TAILSCALE_IFACE}: ${_state}"
}

is_mips_platform() {
    case "$SYS_ARCH" in
        mips*|*mips*|ramips*)
            return 0
            ;;
    esac
    return 1
}

read_openwrt_var() {
    _var="$1"
    [ -f "$OPENWRT_RELEASE_FILE" ] || return 0
    grep "^${_var}=" "$OPENWRT_RELEASE_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d "'\""
}

# =============================================================================
# Обнаружение системы
# =============================================================================

detect_architecture() {
    SYS_ARCH="$(read_openwrt_var DISTRIB_ARCH)"
    [ -z "$SYS_ARCH" ] && SYS_ARCH="$(uname -m 2>/dev/null || echo unknown)"
}

detect_openwrt_version() {
    SYS_VERSION="$(read_openwrt_var DISTRIB_RELEASE)"
    [ -z "$SYS_VERSION" ] && SYS_VERSION="unknown"
}

detect_package_manager() {
    if have_cmd apk; then
        SYS_PM="apk"
    elif have_cmd opkg; then
        SYS_PM="opkg"
    else
        SYS_PM="unknown"
    fi
}

detect_free_space() {
    _target="/overlay"
    df -k "$_target" >/dev/null 2>&1 || _target="/"
    SYS_FREE_KIB="$(df -k "$_target" 2>/dev/null | awk 'NR==2 {print $4}')"
    [ -z "$SYS_FREE_KIB" ] && SYS_FREE_KIB=0
}

detect_system() {
    detect_architecture
    detect_openwrt_version
    detect_package_manager
    detect_free_space
}

validate_environment() {
    [ "$SYS_PM" = "unknown" ] && die "Не найден пакетный менеджер (opkg/apk)."
    if [ "$SYS_FREE_KIB" -lt "$MIN_FREE_KIB" ] 2>/dev/null; then
        log_warn "Мало свободного места: ${SYS_FREE_KIB} KiB (рекомендуется >= ${MIN_FREE_KIB} KiB)."
    fi
}

# =============================================================================
# Работа с зеркалом репозиториев
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
                log_warn "Файл репозиториев apk не найден, пропускаем замену."
                return 0
            fi
            ;;
        opkg)
            if [ -f "/etc/opkg/distfeeds.conf" ]; then
                REPO_FILE="/etc/opkg/distfeeds.conf"
            else
                log_warn "Файл репозиториев opkg не найден, пропускаем замену."
                return 0
            fi
            ;;
        *) return 1 ;;
    esac

    [ ! -f "$REPO_FILE" ] && { log_warn "Файл $REPO_FILE не найден"; return 0; }

    cp "$REPO_FILE" "${REPO_FILE}.backup" || return 1
    sed -i "s|https\?://downloads.openwrt.org|$MIRROR_URL|g" "$REPO_FILE" || return 1
    log_info "Зеркало установлено: $MIRROR_URL"
    return 0
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
        apk) apk update || return 1 ;;
        opkg) opkg update || return 1 ;;
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

pm_install() {
    _pkg="$1"
    case "$SYS_PM" in
        apk) apk add "$_pkg" || return 1 ;;
        opkg) opkg install "$_pkg" || return 1 ;;
        *) return 1 ;;
    esac
}

pm_reinstall() {
    _pkg="$1"
    case "$SYS_PM" in
        apk) apk add --force-overwrite "$_pkg" || return 1 ;;
        opkg) opkg install --force-reinstall "$_pkg" || return 1 ;;
        *) return 1 ;;
    esac
}

install_dependencies() {
    log_step "Установка зависимостей"
    pm_update_indexes || die "Не удалось обновить списки пакетов."
    for _pkg in $DEP_PACKAGES; do
        if pm_is_installed "$_pkg"; then
            log_info "Пакет уже установлен: $_pkg"
        else
            log_info "Установка: $_pkg"
            pm_install "$_pkg" || die "Не удалось установить пакет: $_pkg"
        fi
    done
    log_ok "Зависимости готовы."
}

install_optional_packages() {
    for _pkg in $OPTIONAL_PACKAGES; do
        if pm_is_installed "$_pkg"; then
            log_info "Опциональный пакет уже установлен: $_pkg"
            continue
        fi
        log_info "Пробуем установить опциональный пакет: $_pkg"
        pm_install "$_pkg" 2>/dev/null || log_warn "Пакет $_pkg недоступен (не критично при fw_mode=off)."
    done
}

# =============================================================================
# Настройка времени (опционально)
# =============================================================================

configure_timezone() {
    log_step "Настройка часового пояса"

    if uci -q get system.@system[0] >/dev/null 2>&1; then
        _idx=0
    else
        log_info "Создание секции system..."
        uci add system system
        _idx=0
    fi

    _current_zone="$(uci -q get system.@system[${_idx}].zonename 2>/dev/null || true)"
    _current_timezone="$(uci -q get system.@system[${_idx}].timezone 2>/dev/null || true)"

    if [ "$_current_zone" = "$TIMEZONE_NAME" ] && [ "$_current_timezone" = "$TIMEZONE_STRING" ]; then
        log_info "Часовой пояс уже настроен: $TIMEZONE_NAME"
        return 0
    fi

    log_info "Установка часового пояса: $TIMEZONE_NAME ($TIMEZONE_STRING)"
    uci set "system.@system[${_idx}].zonename=$TIMEZONE_NAME"
    uci set "system.@system[${_idx}].timezone=$TIMEZONE_STRING"
    uci commit system

    if /etc/init.d/sysntpd status >/dev/null 2>&1; then
        /etc/init.d/sysntpd restart || log_warn "Не удалось перезапустить sysntpd."
    fi

    log_ok "Часовой пояс установлен."
}

# =============================================================================
# Обеспечение работы TUN
# =============================================================================

ensure_tun() {
    log_step "Проверка TUN устройства"

    # Загружаем модуль, если не загружен
    if ! lsmod | grep -q tun; then
        log_info "Загрузка модуля tun..."
        modprobe tun || { log_warn "Не удалось загрузить модуль tun"; return 1; }
    else
        log_info "Модуль tun уже загружен."
    fi

    # Проверяем устройство /dev/net/tun
    if [ ! -c /dev/net/tun ]; then
        log_info "Создание /dev/net/tun..."
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200
        chmod 600 /dev/net/tun
        log_ok "Устройство создано."
    else
        log_ok "Устройство /dev/net/tun существует."
    fi

    return 0
}

# =============================================================================
# Netfilter и конфигурация демона
# =============================================================================

netfilter_tool_available() {
    _tool="$1"
    if have_cmd "$_tool"; then
        return 0
    fi
    if [ -x "/usr/sbin/$_tool" ]; then
        return 0
    fi
    return 1
}

ensure_netfilter_tools() {
    log_step "Проверка netfilter"

    if netfilter_tool_available iptables && netfilter_tool_available ip6tables; then
        log_ok "iptables/ip6tables доступны."
        return 0
    fi

    log_warn "iptables/ip6tables не найдены — пробуем установить iptables-nft и ip6tables-nft..."
    install_optional_packages

    if netfilter_tool_available iptables && netfilter_tool_available ip6tables; then
        log_ok "iptables/ip6tables установлены."
        return 0
    fi

    if netfilter_tool_available iptables; then
        log_warn "ip6tables недоступен. tailscaled --cleanup может выдавать предупреждения."
    else
        log_warn "iptables недоступен. При fw_mode=off это не критично."
    fi
}

configure_tailscale_daemon() {
    log_step "Настройка демона Tailscale (UCI)"

    if ! uci -q get tailscale.settings >/dev/null 2>&1; then
        if [ -f "$TAILSCALE_UCI_CONFIG" ]; then
            log_info "Загрузка существующего $TAILSCALE_UCI_CONFIG"
        else
            log_info "Создание минимальной конфигурации tailscale..."
            uci set tailscale.settings=settings
            uci set tailscale.settings.log_stderr='1'
            uci set tailscale.settings.log_stdout='1'
            uci set tailscale.settings.port='41641'
            uci set tailscale.settings.state_file='/var/lib/tailscale/tailscaled.state'
        fi
    fi

    _current_fw="$(uci -q get tailscale.settings.fw_mode 2>/dev/null || true)"
    if [ "$_current_fw" != "$TAILSCALE_FW_MODE" ]; then
        log_info "Установка tailscale.settings.fw_mode=${TAILSCALE_FW_MODE}"
        uci set "tailscale.settings.fw_mode=${TAILSCALE_FW_MODE}"
    else
        log_info "tailscale.settings.fw_mode уже ${TAILSCALE_FW_MODE}"
    fi

    uci commit tailscale || die "Не удалось сохранить /etc/config/tailscale"
    log_ok "Демон настроен: netfilter отключён на уровне tailscaled."
}

# =============================================================================
# Tailscale — установка и проверка
# =============================================================================

is_tailscale_package_installed() { pm_is_installed "$TAILSCALE_PKG"; }

binary_in_path() { have_cmd "$1"; }

binary_from_package_list() {
    _bin="$1"
    case "$SYS_PM" in
        opkg) opkg files "$TAILSCALE_PKG" 2>/dev/null | grep -q "/${_bin}\$" ;;
        apk)  apk info -L "$TAILSCALE_PKG" 2>/dev/null | grep -q "/${_bin}\$" ;;
        *) return 1 ;;
    esac
}

verify_tailscale_binaries() {
    _missing=""
    for _bin in tailscale tailscaled; do
        if binary_in_path "$_bin"; then
            log_ok "Бинарник найден в PATH: $_bin"
        elif binary_from_package_list "$_bin"; then
            log_ok "Бинарник найден в пакете: $_bin"
        else
            _missing="${_missing} ${_bin}"
        fi
    done
    [ -n "$_missing" ] && { log_error "Не найдены бинарники:${_missing}"; return 1; }
    return 0
}

install_tailscale() {
    log_step "Установка Tailscale"
    pm_update_indexes || die "Не удалось обновить списки перед установкой."
    log_info "Установка пакета $TAILSCALE_PKG..."
    pm_install "$TAILSCALE_PKG" || die "Не удалось установить пакет."
    verify_tailscale_binaries || die "Бинарники недоступны."
    log_ok "Tailscale установлен."
}

ensure_tailscale_installed() {
    if is_tailscale_package_installed; then
        if is_init_script_executable "$TAILSCALE_INIT_DEFAULT" || \
           is_init_script_executable "$(init_script_from_package_list)"; then
            log_ok "Пакет уже установлен."
            verify_tailscale_binaries || die "Бинарники не найдены."
            return 0
        fi
        log_warn "Пакет установлен, но init-скрипт отсутствует – переустановка."
        reinstall_tailscale_package || die "Ошибка переустановки."
        verify_tailscale_binaries || die "Бинарники не найдены после переустановки."
        return 0
    fi

    if binary_in_path tailscale && binary_in_path tailscaled && \
       is_init_script_executable "$TAILSCALE_INIT_DEFAULT"; then
        log_ok "Бинарники уже доступны."
        return 0
    fi

    install_tailscale
}

# =============================================================================
# Сервис Tailscale
# =============================================================================

init_script_from_package_list() {
    case "$SYS_PM" in
        opkg) opkg files "$TAILSCALE_PKG" 2>/dev/null | grep '/etc/init.d/' | head -n1 ;;
        apk)  apk info -L "$TAILSCALE_PKG" 2>/dev/null | grep '/etc/init.d/' | head -n1 ;;
    esac
}

is_init_script_executable() { [ -n "$1" ] && [ -x "$1" ]; }

reinstall_tailscale_package() {
    log_info "Переустановка $TAILSCALE_PKG..."
    pm_update_indexes || return 1
    pm_reinstall "$TAILSCALE_PKG" || return 1
    return 0
}

resolve_tailscale_init_path() {
    if is_init_script_executable "$TAILSCALE_INIT_DEFAULT"; then
        TAILSCALE_INIT_PATH="$TAILSCALE_INIT_DEFAULT"; return 0
    fi
    _pkg_init="$(init_script_from_package_list)"
    if is_init_script_executable "$_pkg_init"; then
        TAILSCALE_INIT_PATH="$_pkg_init"; return 0
    fi
    if is_tailscale_package_installed; then
        reinstall_tailscale_package || return 1
        if is_init_script_executable "$TAILSCALE_INIT_DEFAULT"; then
            TAILSCALE_INIT_PATH="$TAILSCALE_INIT_DEFAULT"; return 0
        fi
        _pkg_init="$(init_script_from_package_list)"
        if is_init_script_executable "$_pkg_init"; then
            TAILSCALE_INIT_PATH="$_pkg_init"; return 0
        fi
    fi
    return 1
}

ensure_init_script_exists() {
    resolve_tailscale_init_path || die "Init-скрипт Tailscale не найден."
    log_ok "Init-скрипт: $TAILSCALE_INIT_PATH"
}

enable_service() {
    log_info "Включение автозапуска..."
    "$TAILSCALE_INIT_PATH" enable || die "Не удалось включить автозапуск."
    log_ok "Автозапуск включён."
}

start_service() {
    log_info "Запуск сервиса..."
    "$TAILSCALE_INIT_PATH" start || die "Не удалось запустить сервис."
}

# Проверка готовности демона по наличию сокета
wait_for_daemon_ready() {
    _elapsed=0
    _sock="/var/run/tailscale/tailscaled.sock"
    log_info "Ожидание появления сокета tailscaled (до ${DAEMON_WAIT_SECS} с)..."
    while [ "$_elapsed" -lt "$DAEMON_WAIT_SECS" ]; do
        if [ -S "$_sock" ]; then
            log_ok "Демон готов (сокет $_sock)."
            return 0
        fi
        sleep "$DAEMON_POLL_SECS"
        _elapsed=$((_elapsed + DAEMON_POLL_SECS))
    done
    log_warn "Сокет $_sock не появился за ${DAEMON_WAIT_SECS} с."
    # Проверяем, жив ли процесс
    if is_process_running tailscaled; then
        log_warn "Процесс tailscaled запущен, но сокет недоступен. Проверьте логи: logread | grep tailscale"
        log_warn "Продолжаем выполнение, возможно, сокет появится позже."
        return 0  # не прерываем скрипт
    else
        log_error "Процесс tailscaled не найден. Проверьте логи: logread | grep tailscale"
        return 1
    fi
}

check_daemon_status() {
    if is_process_running tailscaled; then
        log_ok "Статус: работает."
        return 0
    fi
    log_error "Статус: не работает."
    return 1
}

manage_service() {
    log_step "Управление сервисом Tailscale"
    ensure_init_script_exists
    enable_service

    if is_process_running tailscaled; then
        log_info "Демон уже запущен — перезапуск с актуальной конфигурацией..."
        restart_tailscale_service || die "Не удалось перезапустить Tailscale."
    else
        start_service
        wait_for_daemon_ready || die "Tailscaled не запущен."
    fi

    ensure_tailscale_interface || log_warn "Не удалось подготовить ${TAILSCALE_IFACE}."
    check_daemon_status || die "Проверка статуса tailscaled не пройдена."
}

# =============================================================================
# Интерфейс tailscale0
# =============================================================================

restart_tailscale_service() {
    if [ -z "$TAILSCALE_INIT_PATH" ] || [ ! -x "$TAILSCALE_INIT_PATH" ]; then
        resolve_tailscale_init_path || return 1
    fi

    log_info "Перезапуск сервиса Tailscale..."
    "$TAILSCALE_INIT_PATH" restart || return 1
    wait_for_daemon_ready || return 1
    return 0
}

create_tailscale_tun_interface() {
    if interface_exists; then
        log_info "Интерфейс ${TAILSCALE_IFACE} уже есть в sysfs — поднимаем link..."
        ip link set dev "$TAILSCALE_IFACE" up 2>/dev/null || return 1
        return 0
    fi

    log_info "Создание TUN-интерфейса ${TAILSCALE_IFACE} через ip tuntap..."
    ip tuntap add mode tun dev "$TAILSCALE_IFACE" 2>/dev/null || return 1
    ip link set dev "$TAILSCALE_IFACE" up 2>/dev/null || return 1
    return 0
}

ensure_tailscale_interface() {
    _elapsed=0

    log_info "Проверка интерфейса ${TAILSCALE_IFACE}..."
    log_interface_state

    while [ "$_elapsed" -lt "$IFACE_WAIT_SECS" ]; do
        if interface_is_operational; then
            log_ok "Интерфейс ${TAILSCALE_IFACE} готов."
            return 0
        fi
        sleep 1
        _elapsed=$((_elapsed + 1))
    done

    if is_mips_platform; then
        log_warn "Платформа MIPS: tailscaled часто не создаёт ${TAILSCALE_IFACE} самостоятельно."
    else
        log_warn "Интерфейс ${TAILSCALE_IFACE} не появился за ${IFACE_WAIT_SECS} с."
    fi

    if ! create_tailscale_tun_interface; then
        log_error "Не удалось создать ${TAILSCALE_IFACE}. Проверьте kmod-tun и /dev/net/tun."
        return 1
    fi

    log_ok "Интерфейс ${TAILSCALE_IFACE} создан вручную."
    log_info "Ожидание привязки к работающему tailscaled (${IFACE_BIND_WAIT_SECS} с)..."
    log_info "Перезапуск не выполняется: tailscaled --cleanup удалил бы интерфейс."
    sleep "$IFACE_BIND_WAIT_SECS"
    log_interface_state

    if interface_exists; then
        return 0
    fi

    log_error "Интерфейс ${TAILSCALE_IFACE} по-прежнему отсутствует."
    return 1
}

# =============================================================================
# Tailscale — Exit Node и авторизация
# =============================================================================

is_tailscale_authenticated() {
    _status=""

    _status="$(tailscale status 2>&1 || true)"

    if printf '%s\n' "$_status" | grep -qi 'logged out'; then
        return 1
    fi

    if printf '%s\n' "$_status" | grep -qi 'needs login'; then
        return 1
    fi

    if printf '%s\n' "$_status" | grep -q 'https://login.tailscale.com/'; then
        return 1
    fi

    tailscale ip -4 >/dev/null 2>&1
}

build_tailscale_up_command() {
    _timeout_flag="$TAILSCALE_UP_TIMEOUT"
    if [ -n "$AUTH_KEY" ]; then
        _timeout_flag="$TAILSCALE_UP_AUTH_TIMEOUT"
    fi

    _cmd="tailscale up --reset --timeout=${_timeout_flag}s"

    if [ -n "$AUTH_KEY" ]; then
        _cmd="$_cmd --auth-key=$AUTH_KEY"
    fi

    # shellcheck disable=SC2086
    _cmd="$_cmd $TAILSCALE_UP_ARGS"
    printf '%s' "$_cmd"
}

run_tailscale_up() {
    _attempt_no="$1"
    _cmd="$(build_tailscale_up_command)"
    _ret=0
    _timeout="$TAILSCALE_UP_TIMEOUT"

    if [ -n "$AUTH_KEY" ]; then
        _timeout="$TAILSCALE_UP_AUTH_TIMEOUT"
    fi

    : > "$TAILSCALE_UP_LOG"
    log_info "Выполнение (таймаут ${_timeout} с): $_cmd"

    run_with_timeout "$_timeout" sh -c "$_cmd" >> "$TAILSCALE_UP_LOG" 2>&1
    _ret=$?

    if [ "$_ret" -eq 124 ]; then
        log_warn "tailscale up #${_attempt_no} не завершился за ${_timeout} с."
        if have_cmd logread; then
            log_info "Последние записи tailscaled:"
            logread 2>/dev/null | grep -i tailscale | tail -n 5 >&2 || true
        fi
    elif [ "$_ret" -ne 0 ]; then
        log_warn "tailscale up #${_attempt_no} завершился с кодом $_ret."
        if grep -q 'flag provided but not defined' "$TAILSCALE_UP_LOG" 2>/dev/null; then
            log_error "Неверный аргумент tailscale up. Проверьте команду в логе выше."
        fi
        if grep -qi 'invalid auth key\|auth key expired\|unable to authenticate' "$TAILSCALE_UP_LOG" 2>/dev/null; then
            log_error "Проблема с ключом авторизации. Создайте новый ключ в админке Tailscale."
        fi
    fi

    if [ -s "$TAILSCALE_UP_LOG" ]; then
        cat "$TAILSCALE_UP_LOG"
    fi

    log_interface_state
    return "$_ret"
}

extract_login_url_from_sources() {
    _url=""
    _status=""

    _url="$(grep -o 'https://login.tailscale.com/[^ ]*' "$TAILSCALE_UP_LOG" 2>/dev/null | head -n 1)"
    if [ -n "$_url" ]; then
        printf '%s' "$_url"
        return 0
    fi

    _status="$(tailscale status 2>&1 || true)"
    _url="$(printf '%s\n' "$_status" | grep -o 'https://login.tailscale.com/[^ ]*' | head -n 1)"
    if [ -n "$_url" ]; then
        printf '%s' "$_url"
        return 0
    fi

    if have_cmd logread; then
        _url="$(logread 2>/dev/null | grep 'login.tailscale.com' | grep -o 'https://login.tailscale.com/[^ ]*' | tail -n 1)"
        if [ -n "$_url" ]; then
            printf '%s' "$_url"
            return 0
        fi
    fi

    return 1
}

print_login_instructions() {
    _cmd="$(build_tailscale_up_command)"

    if _url="$(extract_login_url_from_sources)"; then
        printf '\n'
        log_info "Для завершения авторизации перейдите по ссылке:"
        printf '    %s\n\n' "$_url"
        log_info "После входа включите Exit Node: https://login.tailscale.com/admin/machines"
        return 0
    fi

    log_warn "Не удалось получить ссылку для входа. Выполните вручную:"
    printf '    %s\n' "$_cmd"

    if [ -f "$TAILSCALE_UP_LOG" ]; then
        log_info "Последние строки лога:"
        tail -n 5 "$TAILSCALE_UP_LOG" >&2
    fi

    return 1
}

configure_exit_node() {
    log_step "Настройка Exit Node"

    if is_tailscale_authenticated; then
        log_ok "Tailscale уже авторизован (IPv4: $(tailscale ip -4 2>/dev/null)). Пропускаем 'tailscale up'."
        return 0
    fi

    if [ -n "$AUTH_KEY" ]; then
        log_info "Используется ключ авторизации."
    fi

    _attempt=0
    while [ "$_attempt" -lt "$TAILSCALE_UP_MAX_ATTEMPTS" ]; do
        _attempt=$((_attempt + 1))
        log_info "Попытка авторизации #${_attempt} из ${TAILSCALE_UP_MAX_ATTEMPTS}..."

        if ! interface_is_operational; then
            log_warn "Интерфейс ${TAILSCALE_IFACE} не готов — восстанавливаем..."
            ensure_tailscale_interface || log_warn "Не удалось подготовить ${TAILSCALE_IFACE}."
            sleep "$IFACE_RETRY_WAIT_SECS"
        fi

        run_tailscale_up "$_attempt"

        if is_tailscale_authenticated; then
            log_ok "Tailscale успешно авторизован (IPv4: $(tailscale ip -4 2>/dev/null))."
            return 0
        fi

        if interface_is_operational; then
            log_info "Интерфейс ${TAILSCALE_IFACE} работает — ожидается успешный tailscale up."
        elif interface_exists; then
            log_warn "Интерфейс ${TAILSCALE_IFACE} существует, но не в состоянии UP."
        else
            log_warn "Интерфейс ${TAILSCALE_IFACE} отсутствует."
        fi

        if [ "$_attempt" -lt "$TAILSCALE_UP_MAX_ATTEMPTS" ]; then
            log_info "Повторная подготовка интерфейса перед следующей попыткой..."
            ensure_tailscale_interface || true
            sleep "$IFACE_RETRY_WAIT_SECS"
        fi

        if [ "$_attempt" -eq "$TAILSCALE_UP_MAX_ATTEMPTS" ]; then
            print_login_instructions
        fi
    done

    return 0
}

# =============================================================================
# Финальная проверка
# =============================================================================

verify_installation() {
    _ok=0
    verify_tailscale_binaries || _ok=1
    if ! is_process_running tailscaled; then
        log_error "tailscaled не запущен."
        _ok=1
    fi
    if ! interface_exists; then
        log_warn "Интерфейс ${TAILSCALE_IFACE} не найден."
    fi
    if ! tailscale version >/dev/null 2>&1; then
        log_error "LocalAPI не отвечает."
        _ok=1
    fi
    return "$_ok"
}

# =============================================================================
# Вывод информации
# =============================================================================

print_banner() {
    printf '\n=========================================\n%s\n=========================================\n\n' "$SCRIPT_TITLE"
}

print_system_summary() {
    log_info "OpenWrt version : ${SYS_VERSION}"
    log_info "Architecture    : ${SYS_ARCH}"
    log_info "Package manager : ${SYS_PM}"
    log_info "Free space      : ${SYS_FREE_KIB} KiB"
    printf '\n'
}

print_final_report() {
    _auth="не авторизовано"
    is_tailscale_authenticated && _auth="авторизовано"
    _state="остановлен"
    is_process_running tailscaled && _state="работает"
    _iface="отсутствует"
    interface_exists && _iface="создан"
    _ts_ip="$(tailscale ip -4 2>/dev/null || true)"

    printf '\n=========================================\n Установка Tailscale завершена\n=========================================\n\n'
    log_ok "Пакет          : установлен"
    log_ok "Сервис         : ${_state}"
    log_ok "Интерфейс      : ${_iface} (${TAILSCALE_IFACE})"
    log_ok "Авторизация    : ${_auth}"
    log_info "Exit Node      : объявлен (${TAILSCALE_UP_ARGS})"
    [ -n "$_ts_ip" ] && log_info "Tailscale IPv4 : ${_ts_ip}"
    printf '\n'
    log_info "Проверка статуса : tailscale status"
    log_info "Админка Tailscale: https://login.tailscale.com/admin/machines"
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
            --auth-key)
                [ -n "$2" ] || die "Ошибка: --auth-key требует ключ."
                AUTH_KEY="$2"
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

    install_dependencies
    configure_timezone          # опционально, не влияет на сеть

    ensure_tun
    ensure_netfilter_tools

    ensure_tailscale_installed
    configure_tailscale_daemon
    manage_service
    configure_exit_node

    # Установка считается успешной при работающем демоне, даже без авторизации
    print_final_report
}

main "$@"
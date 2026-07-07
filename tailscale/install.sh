#!/bin/sh
#
# Tailscale Exit Node — production installer for OpenWrt 24.x / 25.x
# С поддержкой зеркал репозиториев, неинтерактивной авторизации и настройкой времени.
#
# Использование:
#   sh install.sh --mirror <URL> [--auth-key <ключ>]
#

set -u

# =============================================================================
# Константы
# =============================================================================

readonly SCRIPT_TITLE="Tailscale installer for OpenWrt"

readonly TAILSCALE_PKG="tailscale"
readonly TAILSCALE_INIT_DEFAULT="/etc/init.d/tailscale"
readonly TAILSCALE_CONFIG="/etc/config/tailscale"
readonly TAILSCALE_UP_ARGS="--advertise-exit-node --accept-dns=false --netfilter-mode=off --ssh"

readonly NET_INTERFACE="tailscale"
readonly NET_DEVICE="tailscale0"
readonly FW_ZONE="tailscale"
readonly FW_WAN_ZONE="wan"

readonly FW_RULE_SSH="Allow-Tailscale-SSH"
readonly FW_RULE_HTTP="Allow-Tailscale-HTTP"
readonly FW_RULE_HTTPS="Allow-Tailscale-HTTPS"

readonly PORT_SSH="22"
readonly PORT_HTTP="80"
readonly PORT_HTTPS="443"

# Добавлен пакет tzdata для временных зон
readonly DEP_PACKAGES="kmod-tun ca-bundle tzdata"

readonly MIN_FREE_KIB=10240
readonly DAEMON_WAIT_SECS=30
readonly DAEMON_POLL_SECS=2
readonly TAILSCALE_UP_TIMEOUT=15   # секунд ожидания авторизации

readonly OPENWRT_RELEASE_FILE="/etc/openwrt_release"

# Настройки времени
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

# =============================================================================
# Настройка времени (добавлено)
# =============================================================================

configure_timezone() {
    log_step "Настройка часового пояса"

    # Проверяем, существует ли секция system
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

    # Перезапускаем службу времени (если есть)
    if /etc/init.d/sysntpd status >/dev/null 2>&1; then
        /etc/init.d/sysntpd restart || log_warn "Не удалось перезапустить sysntpd."
    fi

    log_ok "Часовой пояс установлен."
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

is_daemon_running() {
    if have_cmd pidof; then
        pidof tailscaled >/dev/null 2>&1 && return 0
    else
        pgrep tailscaled >/dev/null 2>&1 && return 0
    fi
    return 1
}

wait_for_daemon() {
    _elapsed=0
    log_info "Ожидание запуска tailscaled (до ${DAEMON_WAIT_SECS} с)..."
    while [ "$_elapsed" -lt "$DAEMON_WAIT_SECS" ]; do
        if is_daemon_running; then
            log_ok "Демон запущен."
            return 0
        fi
        sleep "$DAEMON_POLL_SECS"
        _elapsed=$((_elapsed + DAEMON_POLL_SECS))
    done
    log_error "Демон не запустился за ${DAEMON_WAIT_SECS} с."
    return 1
}

check_daemon_status() {
    if is_daemon_running; then
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
    start_service
    wait_for_daemon || die "Tailscaled не запустился."
    check_daemon_status || die "Проверка статуса не пройдена."
}

# =============================================================================
# UCI — вспомогательные функции
# =============================================================================

uci_section_exists() {
    _cfg="$1"; _sec="$2"
    uci -q get "${_cfg}.${_sec}" >/dev/null 2>&1
}

firewall_zone_index_by_name() {
    _zone="$1"; _idx=0
    while uci -q get "firewall.@zone[${_idx}]" >/dev/null 2>&1; do
        _name="$(uci -q get "firewall.@zone[${_idx}].name" 2>/dev/null || true)"
        [ "$_name" = "$_zone" ] && { printf '%s' "$_idx"; return 0; }
        _idx=$((_idx + 1))
    done
    return 1
}

firewall_zone_exists() { firewall_zone_index_by_name "$1" >/dev/null 2>&1; }

firewall_forwarding_exists() {
    _src="$1"; _dest="$2"; _idx=0
    while uci -q get "firewall.@forwarding[${_idx}]" >/dev/null 2>&1; do
        _f_src="$(uci -q get "firewall.@forwarding[${_idx}].src" 2>/dev/null || true)"
        _f_dest="$(uci -q get "firewall.@forwarding[${_idx}].dest" 2>/dev/null || true)"
        [ "$_f_src" = "$_src" ] && [ "$_f_dest" = "$_dest" ] && return 0
        _idx=$((_idx + 1))
    done
    return 1
}

firewall_rule_exists() {
    _name="$1"; _idx=0
    while uci -q get "firewall.@rule[${_idx}]" >/dev/null 2>&1; do
        _n="$(uci -q get "firewall.@rule[${_idx}].name" 2>/dev/null || true)"
        [ "$_n" = "$_name" ] && return 0
        _idx=$((_idx + 1))
    done
    return 1
}

uci_commit_and_reload() {
    log_info "Сохранение изменений UCI..."
    uci commit network || die "Ошибка uci commit network."
    uci commit firewall || die "Ошибка uci commit firewall."
    log_info "Перезагрузка network и firewall..."
    /etc/init.d/network reload || log_warn "Перезагрузка network с предупреждением."
    /etc/init.d/firewall reload || die "Не удалось перезагрузить firewall."
}

# =============================================================================
# UCI — сеть и firewall
# =============================================================================

configure_network_interface() {
    if uci_section_exists network "$NET_INTERFACE"; then
        log_info "Интерфейс '$NET_INTERFACE' уже существует."
        return 0
    fi
    log_info "Создание интерфейса '$NET_INTERFACE'..."
    uci set "network.${NET_INTERFACE}=interface"
    uci set "network.${NET_INTERFACE}.device=${NET_DEVICE}"
    uci set "network.${NET_INTERFACE}.proto=unmanaged"
    uci set "network.${NET_INTERFACE}.auto=1"
    log_ok "Интерфейс создан."
}

configure_firewall_zone() {
    if firewall_zone_exists "$FW_ZONE"; then
        log_info "Firewall-зона '$FW_ZONE' уже существует."
        return 0
    fi
    log_info "Создание зоны '$FW_ZONE'..."
    uci add firewall zone
    uci set "firewall.@zone[-1].name=${FW_ZONE}"
    uci set "firewall.@zone[-1].input=ACCEPT"
    uci set "firewall.@zone[-1].output=ACCEPT"
    uci set "firewall.@zone[-1].forward=ACCEPT"
    uci set "firewall.@zone[-1].masq=1"
    uci set "firewall.@zone[-1].mtu_fix=1"
    uci add_list "firewall.@zone[-1].network=${NET_INTERFACE}"
    log_ok "Зона создана."
}

configure_firewall_forwarding() {
    if firewall_forwarding_exists "$FW_ZONE" "$FW_WAN_ZONE"; then
        log_info "Forwarding ${FW_ZONE} -> ${FW_WAN_ZONE} уже настроен."
        return 0
    fi
    log_info "Добавление forwarding ${FW_ZONE} -> ${FW_WAN_ZONE}..."
    uci add firewall forwarding
    uci set "firewall.@forwarding[-1].src=${FW_ZONE}"
    uci set "firewall.@forwarding[-1].dest=${FW_WAN_ZONE}"
    log_ok "Forwarding добавлен."
}

add_firewall_rule_if_missing() {
    _name="$1"; _proto="$2"; _port="$3"
    if firewall_rule_exists "$_name"; then
        log_info "Правило '$_name' уже существует."
        return 0
    fi
    log_info "Добавление правила '$_name' (порт $_port)..."
    uci add firewall rule
    uci set "firewall.@rule[-1].name=${_name}"
    uci set "firewall.@rule[-1].src=${FW_ZONE}"
    uci set "firewall.@rule[-1].proto=${_proto}"
    uci set "firewall.@rule[-1].dest_port=${_port}"
    uci set "firewall.@rule[-1].target=ACCEPT"
    log_ok "Правило добавлено."
}

configure_firewall_rules() {
    add_firewall_rule_if_missing "$FW_RULE_SSH"   "tcp" "$PORT_SSH"
    add_firewall_rule_if_missing "$FW_RULE_HTTP"  "tcp" "$PORT_HTTP"
    add_firewall_rule_if_missing "$FW_RULE_HTTPS" "tcp" "$PORT_HTTPS"
}

configure_network() {
    log_step "Настройка сети и firewall"
    configure_network_interface
    configure_firewall_zone
    configure_firewall_forwarding
    configure_firewall_rules
    uci_commit_and_reload
    log_ok "Сеть и firewall настроены."
}

# =============================================================================
# IP forwarding
# =============================================================================

enable_ip_forwarding_runtime() {
    _cur="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    [ "$_cur" = "1" ] && { log_info "IPv4 forwarding уже включён (runtime)."; return 0; }
    log_info "Включение IPv4 forwarding (runtime)..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 && log_ok "Включён." || log_warn "Не удалось."
}

enable_ip_forwarding_uci() {
    if uci_section_exists network globals; then
        _fwd="$(uci -q get network.globals.forwarding 2>/dev/null || echo 0)"
        [ "$_fwd" = "1" ] && { log_info "IP forwarding уже сохранён в UCI."; return 0; }
        uci set network.globals.forwarding='1'
    else
        log_info "Создание network.globals..."
        uci set network.globals=globals
        uci set network.globals.forwarding='1'
    fi
    uci commit network || die "Не удалось сохранить IP forwarding."
    log_ok "IP forwarding сохранён в UCI."
}

enable_ip_forwarding() {
    log_step "Настройка IP forwarding"
    enable_ip_forwarding_runtime
    enable_ip_forwarding_uci
}

# =============================================================================
# Tailscale — Exit Node и авторизация (НЕ зависает!)
# =============================================================================

configure_exit_node() {
    log_step "Настройка Exit Node"

    # Формируем команду
    _cmd="tailscale up"

    if [ -n "$AUTH_KEY" ]; then
        _cmd="$_cmd --auth-key=$AUTH_KEY"
        log_info "Используется ключ авторизации."
    fi

    _cmd="$_cmd $TAILSCALE_UP_ARGS"
    log_info "Выполнение: $_cmd"

    # Запускаем с таймаутом, чтобы не повиснуть
    if ! timeout "$TAILSCALE_UP_TIMEOUT" sh -c "$_cmd" 2>&1 | tee /tmp/tailscale_up.log; then
        log_warn "tailscale up завершился с ошибкой или по таймауту."
    fi

    # Проверяем, авторизовались ли
    if tailscale status >/dev/null 2>&1; then
        log_ok "Tailscale успешно авторизован."
        return 0
    fi

    # Если не авторизованы – извлекаем ссылку из вывода
    _url="$(grep -o 'https://login.tailscale.com/[^ ]*' /tmp/tailscale_up.log 2>/dev/null | head -n1)"
    if [ -n "$_url" ]; then
        printf '\n'
        log_info "Для завершения авторизации перейдите по ссылке:"
        printf '    %s\n\n' "$_url"
        log_info "После входа выполните 'tailscale up' вручную или перезапустите скрипт с ключом."
    else
        log_warn "Не удалось получить ссылку для входа. Попробуйте выполнить вручную:"
        printf '    %s\n' "$_cmd"
    fi

    return 0
}

# =============================================================================
# Проверка авторизации (для финального отчёта)
# =============================================================================

is_tailscale_authenticated() {
    tailscale status >/dev/null 2>&1 && tailscale ip -4 >/dev/null 2>&1
    return $?
}

# =============================================================================
# Финальная проверка
# =============================================================================

verify_installation() {
    _ok=0
    verify_tailscale_binaries || _ok=1
    is_daemon_running || { log_error "tailscaled не запущен."; _ok=1; }
    uci_section_exists network "$NET_INTERFACE" || { log_error "Интерфейс $NET_INTERFACE не найден."; _ok=1; }
    firewall_zone_exists "$FW_ZONE" || { log_error "Зона $FW_ZONE не найдена."; _ok=1; }
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
    is_daemon_running && _state="работает"
    _ts_ip="$(tailscale ip -4 2>/dev/null || true)"

    printf '\n=========================================\n Установка Tailscale завершена\n=========================================\n\n'
    log_ok "Пакет          : установлен"
    log_ok "Сервис         : ${_state}"
    log_ok "Авторизация    : ${_auth}"
    log_ok "Exit Node      : настроен (${TAILSCALE_UP_ARGS})"
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
    # Парсинг аргументов
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

    # Восстановление репозиториев при выходе
    trap restore_mirror EXIT

    if [ -n "$MIRROR_URL" ]; then
        setup_mirror || die "Не удалось настроить зеркало."
    fi

    print_banner
    print_system_summary
    validate_environment

    install_dependencies
    configure_timezone            # <-- добавлено
    ensure_tailscale_installed
    manage_service
    configure_network
    enable_ip_forwarding
    configure_exit_node

    if verify_installation; then
        print_final_report
    else
        log_warn "Установка завершена с предупреждениями."
        print_final_report
        exit 1
    fi
}

main "$@"
#!/bin/sh
#
# Tailscale Exit Node — production installer for OpenWrt 24.x / 25.x
#
# Устанавливает официальный пакет Tailscale, настраивает сеть, firewall
# и поднимает туннель в режиме Exit Node. Идемпотентен при повторном запуске.
#
# Совместимость: BusyBox ash (/bin/sh), opkg (24.x), apk (25.x)
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

readonly DEP_PACKAGES="kmod-tun ca-bundle"

readonly MIN_FREE_KIB=10240
readonly DAEMON_WAIT_SECS=30
readonly DAEMON_POLL_SECS=2

readonly OPENWRT_RELEASE_FILE="/etc/openwrt_release"

# =============================================================================
# Состояние (заполняется при обнаружении системы)
# =============================================================================

SYS_ARCH=""
SYS_VERSION=""
SYS_PM=""
SYS_FREE_KIB=""
TAILSCALE_INIT_PATH=""

# =============================================================================
# Цвета терминала
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

log_info() {
    printf '%b[INFO]%b %s\n' "$C_INFO" "$C_RST" "$1"
}

log_ok() {
    printf '%b[OK]%b %s\n' "$C_OK" "$C_RST" "$1"
}

log_warn() {
    printf '%b[WARN]%b %s\n' "$C_WARN" "$C_RST" "$1"
}

log_error() {
    printf '%b[ERROR]%b %s\n' "$C_ERR" "$C_RST" "$1" >&2
}

log_step() {
    printf '%b==>%b %s\n' "$C_HDR" "$C_RST" "$1"
}

die() {
    log_error "$1"
    exit 1
}

# =============================================================================
# Утилиты
# =============================================================================

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Скрипт необходимо запускать от root."
    fi
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

read_openwrt_var() {
    _var_name="$1"

    if [ ! -f "$OPENWRT_RELEASE_FILE" ]; then
        return 0
    fi

    grep "^${_var_name}=" "$OPENWRT_RELEASE_FILE" 2>/dev/null \
        | head -n 1 \
        | cut -d= -f2- \
        | tr -d "'\""
}

# =============================================================================
# Обнаружение системы
# =============================================================================

detect_architecture() {
    _arch="$(read_openwrt_var DISTRIB_ARCH)"
    if [ -z "$_arch" ]; then
        _arch="$(uname -m 2>/dev/null || echo unknown)"
    fi
    SYS_ARCH="$_arch"
}

detect_openwrt_version() {
    _ver="$(read_openwrt_var DISTRIB_RELEASE)"
    if [ -z "$_ver" ]; then
        _ver="unknown"
    fi
    SYS_VERSION="$_ver"
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
    if ! df -k "$_target" >/dev/null 2>&1; then
        _target="/"
    fi
    SYS_FREE_KIB="$(df -k "$_target" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ -z "$SYS_FREE_KIB" ]; then
        SYS_FREE_KIB="0"
    fi
}

detect_system() {
    detect_architecture
    detect_openwrt_version
    detect_package_manager
    detect_free_space
}

validate_environment() {
    if [ "$SYS_PM" = "unknown" ]; then
        die "Не найден поддерживаемый пакетный менеджер (opkg или apk)."
    fi

    if [ "$SYS_FREE_KIB" -lt "$MIN_FREE_KIB" ] 2>/dev/null; then
        log_warn "Мало свободного места: ${SYS_FREE_KIB} KiB (рекомендуется >= ${MIN_FREE_KIB} KiB)."
    fi
}

# =============================================================================
# Пакетный менеджер
# =============================================================================

pm_update_indexes() {
    log_info "Обновление списков пакетов ($SYS_PM)..."

    case "$SYS_PM" in
        apk)
            apk update || return 1
            ;;
        opkg)
            opkg update || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

pm_is_installed() {
    _pkg="$1"

    case "$SYS_PM" in
        apk)
            apk info -e "$_pkg" >/dev/null 2>&1
            ;;
        opkg)
            opkg status "$_pkg" 2>/dev/null | grep -q '^Status: install'
            ;;
        *)
            return 1
            ;;
    esac
}

pm_install() {
    _pkg="$1"

    case "$SYS_PM" in
        apk)
            apk add "$_pkg" || return 1
            ;;
        opkg)
            opkg install "$_pkg" || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

pm_reinstall() {
    _pkg="$1"

    case "$SYS_PM" in
        apk)
            apk add --force-overwrite "$_pkg" || return 1
            ;;
        opkg)
            opkg install --force-reinstall "$_pkg" || return 1
            ;;
        *)
            return 1
            ;;
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
# Tailscale — установка и проверка
# =============================================================================

is_tailscale_package_installed() {
    pm_is_installed "$TAILSCALE_PKG"
}

binary_in_path() {
    _name="$1"
    have_cmd "$_name"
}

binary_from_package_list() {
    _name="$1"

    case "$SYS_PM" in
        opkg)
            opkg files "$TAILSCALE_PKG" 2>/dev/null | grep -q "/${_name}\$"
            ;;
        apk)
            apk info -L "$TAILSCALE_PKG" 2>/dev/null | grep -q "/${_name}\$"
            ;;
        *)
            return 1
            ;;
    esac
}

verify_tailscale_binaries() {
    _missing=""

    for _bin in tailscale tailscaled; do
        if binary_in_path "$_bin"; then
            log_ok "Бинарник найден в PATH: $_bin"
            continue
        fi

        if binary_from_package_list "$_bin"; then
            log_ok "Бинарник найден в пакете: $_bin"
            continue
        fi

        _missing="${_missing} ${_bin}"
    done

    if [ -n "$_missing" ]; then
        log_error "Не найдены бинарники:${_missing}"
        return 1
    fi

    return 0
}

install_tailscale() {
    log_step "Установка Tailscale"

    pm_update_indexes || die "Не удалось обновить списки пакетов перед установкой Tailscale."

    log_info "Установка пакета $TAILSCALE_PKG через $SYS_PM..."
    pm_install "$TAILSCALE_PKG" || die "Не удалось установить пакет $TAILSCALE_PKG."

    verify_tailscale_binaries || die "Tailscale установлен, но бинарники недоступны."

    log_ok "Tailscale установлен."
}

ensure_tailscale_installed() {
    if is_tailscale_package_installed; then
        if is_init_script_executable "$TAILSCALE_INIT_DEFAULT" \
            || is_init_script_executable "$(init_script_from_package_list)"; then
            log_ok "Пакет $TAILSCALE_PKG уже установлен — переустановка не требуется."
            verify_tailscale_binaries || die "Пакет установлен, но бинарники tailscale/tailscaled недоступны."
            return 0
        fi

        log_warn "Пакет $TAILSCALE_PKG установлен, но init-скрипт отсутствует."
        reinstall_tailscale_package || die "Не удалось восстановить файлы пакета $TAILSCALE_PKG."
        verify_tailscale_binaries || die "После переустановки бинарники tailscale/tailscaled недоступны."
        return 0
    fi

    if binary_in_path tailscale && binary_in_path tailscaled \
        && is_init_script_executable "$TAILSCALE_INIT_DEFAULT"; then
        log_ok "Бинарники Tailscale уже доступны — установка пакета не требуется."
        return 0
    fi

    install_tailscale
}

# =============================================================================
# Сервис Tailscale (штатный init.d из пакета)
# =============================================================================

init_script_from_package_list() {
    case "$SYS_PM" in
        opkg)
            opkg files "$TAILSCALE_PKG" 2>/dev/null | grep '/etc/init.d/' | head -n 1
            ;;
        apk)
            apk info -L "$TAILSCALE_PKG" 2>/dev/null | grep '/etc/init.d/' | head -n 1
            ;;
    esac
}

is_init_script_executable() {
    _path="$1"
    [ -n "$_path" ] && [ -x "$_path" ]
}

reinstall_tailscale_package() {
    log_warn "Файлы пакета $TAILSCALE_PKG повреждены или удалены — выполняем переустановку..."

    pm_update_indexes || return 1
    pm_reinstall "$TAILSCALE_PKG" || return 1

    log_ok "Пакет $TAILSCALE_PKG переустановлен."
    return 0
}

resolve_tailscale_init_path() {
    if is_init_script_executable "$TAILSCALE_INIT_DEFAULT"; then
        TAILSCALE_INIT_PATH="$TAILSCALE_INIT_DEFAULT"
        return 0
    fi

    _pkg_init="$(init_script_from_package_list)"
    if is_init_script_executable "$_pkg_init"; then
        TAILSCALE_INIT_PATH="$_pkg_init"
        return 0
    fi

    if ! is_tailscale_package_installed; then
        return 1
    fi

    reinstall_tailscale_package || return 1

    if is_init_script_executable "$TAILSCALE_INIT_DEFAULT"; then
        TAILSCALE_INIT_PATH="$TAILSCALE_INIT_DEFAULT"
        return 0
    fi

    _pkg_init="$(init_script_from_package_list)"
    if is_init_script_executable "$_pkg_init"; then
        TAILSCALE_INIT_PATH="$_pkg_init"
        return 0
    fi

    return 1
}

ensure_init_script_exists() {
    if resolve_tailscale_init_path; then
        log_ok "Init-скрипт найден: $TAILSCALE_INIT_PATH"
        return 0
    fi

    die "Init-скрипт Tailscale не найден. Выполните: $SYS_PM install --force-reinstall $TAILSCALE_PKG"
}

enable_service() {
    log_info "Включение автозапуска сервиса Tailscale..."
    "$TAILSCALE_INIT_PATH" enable || die "Не удалось включить автозапуск сервиса Tailscale."
    log_ok "Автозапуск включён."
}

start_service() {
    log_info "Запуск сервиса Tailscale..."
    "$TAILSCALE_INIT_PATH" start || die "Не удалось запустить сервис Tailscale."
}

is_daemon_running() {
    if have_cmd pidof; then
        if pidof tailscaled >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi

    pgrep tailscaled >/dev/null 2>&1
}

wait_for_daemon() {
    _elapsed=0

    log_info "Ожидание запуска tailscaled (до ${DAEMON_WAIT_SECS} с)..."

    while [ "$_elapsed" -lt "$DAEMON_WAIT_SECS" ]; do
        if is_daemon_running; then
            log_ok "Демон tailscaled запущен."
            return 0
        fi
        sleep "$DAEMON_POLL_SECS"
        _elapsed=$((_elapsed + DAEMON_POLL_SECS))
    done

    log_error "Демон tailscaled не запустился за ${DAEMON_WAIT_SECS} с."
    return 1
}

check_daemon_status() {
    if is_daemon_running; then
        log_ok "Статус демона: работает."
        return 0
    fi

    log_error "Статус демона: не работает."
    return 1
}

manage_service() {
    log_step "Управление сервисом Tailscale"

    ensure_init_script_exists
    enable_service
    start_service
    wait_for_daemon || die "Tailscaled не запустился."
    check_daemon_status || die "Проверка статуса tailscaled не пройдена."
}

# =============================================================================
# UCI — вспомогательные функции
# =============================================================================

uci_section_exists() {
    _config="$1"
    _section="$2"
    uci -q get "${_config}.${_section}" >/dev/null 2>&1
}

firewall_zone_index_by_name() {
    _zone_name="$1"
    _idx=0

    while uci -q get "firewall.@zone[${_idx}]" >/dev/null 2>&1; do
        _name="$(uci -q get "firewall.@zone[${_idx}].name" 2>/dev/null || true)"
        if [ "$_name" = "$_zone_name" ]; then
            printf '%s' "$_idx"
            return 0
        fi
        _idx=$((_idx + 1))
    done

    return 1
}

firewall_zone_exists() {
    _zone_name="$1"
    firewall_zone_index_by_name "$_zone_name" >/dev/null 2>&1
}

firewall_forwarding_exists() {
    _src="$1"
    _dest="$2"
    _idx=0

    while uci -q get "firewall.@forwarding[${_idx}]" >/dev/null 2>&1; do
        _f_src="$(uci -q get "firewall.@forwarding[${_idx}].src" 2>/dev/null || true)"
        _f_dest="$(uci -q get "firewall.@forwarding[${_idx}].dest" 2>/dev/null || true)"
        if [ "$_f_src" = "$_src" ] && [ "$_f_dest" = "$_dest" ]; then
            return 0
        fi
        _idx=$((_idx + 1))
    done

    return 1
}

firewall_rule_exists() {
    _rule_name="$1"
    _idx=0

    while uci -q get "firewall.@rule[${_idx}]" >/dev/null 2>&1; do
        _name="$(uci -q get "firewall.@rule[${_idx}].name" 2>/dev/null || true)"
        if [ "$_name" = "$_rule_name" ]; then
            return 0
        fi
        _idx=$((_idx + 1))
    done

    return 1
}

uci_commit_and_reload() {
    log_info "Сохранение изменений UCI..."
    uci commit network || die "Не удалось выполнить uci commit network."
    uci commit firewall || die "Не удалось выполнить uci commit firewall."

    log_info "Перезагрузка network и firewall..."
    /etc/init.d/network reload || log_warn "Перезагрузка network завершилась с предупреждением."
    /etc/init.d/firewall reload || die "Не удалось перезагрузить firewall."
}

# =============================================================================
# UCI — сеть
# =============================================================================

configure_network_interface() {
    if uci_section_exists network "$NET_INTERFACE"; then
        log_info "Сетевой интерфейс '$NET_INTERFACE' уже существует."
        return 0
    fi

    log_info "Создание сетевого интерфейса '$NET_INTERFACE'..."
    uci set "network.${NET_INTERFACE}=interface"
    uci set "network.${NET_INTERFACE}.device=${NET_DEVICE}"
    uci set "network.${NET_INTERFACE}.proto=unmanaged"
    uci set "network.${NET_INTERFACE}.auto=1"
    log_ok "Интерфейс '$NET_INTERFACE' создан."
}

# =============================================================================
# UCI — firewall
# =============================================================================

configure_firewall_zone() {
    if firewall_zone_exists "$FW_ZONE"; then
        log_info "Firewall-зона '$FW_ZONE' уже существует."
        return 0
    fi

    log_info "Создание firewall-зоны '$FW_ZONE'..."
    uci add firewall zone
    uci set "firewall.@zone[-1].name=${FW_ZONE}"
    uci set "firewall.@zone[-1].input=ACCEPT"
    uci set "firewall.@zone[-1].output=ACCEPT"
    uci set "firewall.@zone[-1].forward=ACCEPT"
    uci set "firewall.@zone[-1].masq=1"
    uci set "firewall.@zone[-1].mtu_fix=1"
    uci add_list "firewall.@zone[-1].network=${NET_INTERFACE}"
    log_ok "Firewall-зона '$FW_ZONE' создана."
}

configure_firewall_forwarding() {
    if firewall_forwarding_exists "$FW_ZONE" "$FW_WAN_ZONE"; then
        log_info "Forwarding ${FW_ZONE} -> ${FW_WAN_ZONE} уже настроен."
        return 0
    fi

    log_info "Добавление forwarding: ${FW_ZONE} -> ${FW_WAN_ZONE}..."
    uci add firewall forwarding
    uci set "firewall.@forwarding[-1].src=${FW_ZONE}"
    uci set "firewall.@forwarding[-1].dest=${FW_WAN_ZONE}"
    log_ok "Forwarding ${FW_ZONE} -> ${FW_WAN_ZONE} добавлен."
}

add_firewall_rule_if_missing() {
    _name="$1"
    _proto="$2"
    _port="$3"

    if firewall_rule_exists "$_name"; then
        log_info "Правило firewall '$_name' уже существует."
        return 0
    fi

    log_info "Добавление правила firewall: $_name (порт $_port)..."
    uci add firewall rule
    uci set "firewall.@rule[-1].name=${_name}"
    uci set "firewall.@rule[-1].src=${FW_ZONE}"
    uci set "firewall.@rule[-1].proto=${_proto}"
    uci set "firewall.@rule[-1].dest_port=${_port}"
    uci set "firewall.@rule[-1].target=ACCEPT"
    log_ok "Правило '$_name' добавлено."
}

configure_firewall_rules() {
    add_firewall_rule_if_missing "$FW_RULE_SSH" "tcp" "$PORT_SSH"
    add_firewall_rule_if_missing "$FW_RULE_HTTP" "tcp" "$PORT_HTTP"
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
    _current="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    if [ "$_current" = "1" ]; then
        log_info "IPv4 forwarding уже включён (runtime)."
        return 0
    fi

    log_info "Включение IPv4 forwarding (runtime)..."
    if sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
        log_ok "IPv4 forwarding включён (runtime)."
    else
        log_warn "Не удалось включить IPv4 forwarding через sysctl."
    fi
}

enable_ip_forwarding_uci() {
    if uci_section_exists network globals; then
        _fwd="$(uci -q get network.globals.forwarding 2>/dev/null || echo 0)"
        if [ "$_fwd" = "1" ]; then
            log_info "IPv4 forwarding уже сохранён в UCI."
            return 0
        fi
        uci set network.globals.forwarding='1'
    else
        log_info "Создание секции network.globals для IP forwarding..."
        uci set network.globals=globals
        uci set network.globals.forwarding='1'
    fi

    uci commit network || die "Не удалось сохранить IP forwarding в UCI."
    log_ok "IPv4 forwarding сохранён в UCI."
}

enable_ip_forwarding() {
    log_step "Настройка IP forwarding"

    enable_ip_forwarding_runtime
    enable_ip_forwarding_uci
}

# =============================================================================
# Tailscale — Exit Node и авторизация
# =============================================================================

configure_exit_node() {
    log_step "Настройка Exit Node"

    log_info "Выполнение: tailscale up ${TAILSCALE_UP_ARGS}"

    # shellcheck disable=SC2086
    if tailscale up $TAILSCALE_UP_ARGS; then
        log_ok "Tailscale поднят с параметрами Exit Node."
        return 0
    fi

    log_warn "tailscale up завершился с ошибкой (возможно, требуется авторизация)."
    return 0
}

is_tailscale_authenticated() {
    _status=""

    _status="$(tailscale status 2>&1 || true)"

    if printf '%s\n' "$_status" | grep -qi 'logged out'; then
        return 1
    fi

    if printf '%s\n' "$_status" | grep -q 'https://login.tailscale.com/'; then
        return 1
    fi

    if printf '%s\n' "$_status" | grep -qi 'needs login'; then
        return 1
    fi

    if tailscale ip -4 >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

extract_login_url() {
    _status=""
    _url=""

    _status="$(tailscale status 2>&1 || true)"
    _url="$(printf '%s\n' "$_status" | grep -o 'https://login.tailscale.com/[^ ]*' | head -n 1)"

    if [ -n "$_url" ]; then
        printf '%s' "$_url"
        return 0
    fi

    return 1
}

login_user() {
    log_step "Проверка авторизации Tailscale"

    if is_tailscale_authenticated; then
        log_ok "Устройство уже авторизовано в Tailscale."
        return 0
    fi

    log_warn "Устройство не авторизовано в Tailscale."

    if _url="$(extract_login_url)"; then
        printf '\n'
        log_info "Перейдите по ссылке для авторизации:"
        printf '    %s\n\n' "$_url"
    else
        printf '\n'
        log_info "Для авторизации выполните:"
        printf '    tailscale up %s\n\n' "$TAILSCALE_UP_ARGS"
    fi

    log_info "После входа включите Exit Node в админке Tailscale:"
    printf '    https://login.tailscale.com/admin/machines\n\n'
}

# =============================================================================
# Итоговая проверка
# =============================================================================

verify_installation() {
    _ok=0

    if ! verify_tailscale_binaries; then
        _ok=1
    fi

    if ! is_daemon_running; then
        log_error "Проверка: tailscaled не запущен."
        _ok=1
    fi

    if ! uci_section_exists network "$NET_INTERFACE"; then
        log_error "Проверка: интерфейс $NET_INTERFACE не найден в UCI."
        _ok=1
    fi

    if ! firewall_zone_exists "$FW_ZONE"; then
        log_error "Проверка: firewall-зона $FW_ZONE не найдена."
        _ok=1
    fi

    return "$_ok"
}

# =============================================================================
# Вывод информации
# =============================================================================

print_banner() {
    printf '\n'
    printf '=========================================\n'
    printf '%s\n' "$SCRIPT_TITLE"
    printf '=========================================\n'
    printf '\n'
}

print_system_summary() {
    log_info "OpenWrt version : ${SYS_VERSION}"
    log_info "Architecture    : ${SYS_ARCH}"
    log_info "Package manager : ${SYS_PM}"
    log_info "Free space      : ${SYS_FREE_KIB} KiB"
    printf '\n'
}

print_final_report() {
    _auth_state="не авторизовано"
    _daemon_state="остановлен"
    _ts_ip=""

    if is_tailscale_authenticated; then
        _auth_state="авторизовано"
    fi

    if is_daemon_running; then
        _daemon_state="работает"
    fi

    _ts_ip="$(tailscale ip -4 2>/dev/null || true)"

    printf '\n'
    printf '=========================================\n'
    printf ' Установка Tailscale завершена\n'
    printf '=========================================\n'
    printf '\n'
    log_ok "Пакет          : установлен"
    log_ok "Сервис         : ${_daemon_state}"
    log_ok "Авторизация    : ${_auth_state}"
    log_ok "Exit Node      : настроен (${TAILSCALE_UP_ARGS})"

    if [ -n "$_ts_ip" ]; then
        log_info "Tailscale IPv4 : ${_ts_ip}"
    fi

    printf '\n'
    log_info "Проверка статуса : tailscale status"
    log_info "Админка Tailscale: https://login.tailscale.com/admin/machines"
    printf '\n'
}

# =============================================================================
# Точка входа
# =============================================================================

main() {
    require_root

    detect_system
    print_banner
    print_system_summary
    validate_environment

    install_dependencies
    ensure_tailscale_installed
    manage_service
    configure_network
    enable_ip_forwarding
    configure_exit_node
    login_user

    if verify_installation; then
        print_final_report
    else
        log_warn "Установка завершена с предупреждениями — проверьте сообщения выше."
        print_final_report
        exit 1
    fi
}

main "$@"

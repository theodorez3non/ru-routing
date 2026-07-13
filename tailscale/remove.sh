#!/bin/sh
#
# Tailscale — полное удаление для OpenWrt 24.x / 25.x
#
# Безопасно останавливает Tailscale, удаляет пакет, runtime-файлы
# и (при наличии) UCI-настройки от прежних версий установщика.
# Не затрагивает зоны lan/wan и не удаляет целые секции firewall по индексу.
#
# Совместимость: BusyBox ash (/bin/sh), opkg (24.x), apk (25.x)
#

set -u

# =============================================================================
# Константы (согласованы с install.sh)
# =============================================================================

readonly SCRIPT_TITLE="Tailscale removal for OpenWrt"

readonly TAILSCALE_PKG="tailscale"
readonly TAILSCALE_INIT_DEFAULT="/etc/init.d/tailscale"
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
readonly FORWARDING_BACKUP="/etc/tailscale/.forwarding_orig"

readonly PROCESS_STOP_WAIT_SECS=2

# =============================================================================
# Состояние
# =============================================================================

SYS_ARCH=""
SYS_VERSION=""
SYS_PM="unknown"
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
    if [ -x "$TAILSCALE_INIT_DEFAULT" ]; then
        TAILSCALE_INIT_PATH="$TAILSCALE_INIT_DEFAULT"
        return 0
    fi
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
        "$FW_RULE_SSH"|"$FW_RULE_HTTP"|"$FW_RULE_HTTPS"|"$FW_RULE_WEB")
            return 0
            ;;
        Allow-Tailscale-*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# =============================================================================
# Остановка Tailscale
# =============================================================================

stop_tailscale_process() {
    if ! is_process_running tailscaled; then
        log_info "Процесс tailscaled не запущен."
        return 0
    fi

    if have_cmd tailscale; then
        log_info "Выполнение tailscale down..."
        tailscale down 2>/dev/null || true
    fi

    if have_cmd pidof; then
        _pid="$(pidof tailscaled 2>/dev/null || true)"
        if [ -n "$_pid" ]; then
            log_info "Завершение tailscaled (SIGTERM)..."
            kill "$_pid" 2>/dev/null || true
            sleep "$PROCESS_STOP_WAIT_SECS"
            if is_process_running tailscaled; then
                log_warn "Принудительное завершение tailscaled (SIGKILL)..."
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
    return 0
}

stop_tailscale_service() {
    log_step "Остановка Tailscale"

    if resolve_init_script; then
        log_info "Остановка init-сервиса..."
        "$TAILSCALE_INIT_PATH" stop 2>/dev/null || true
        "$TAILSCALE_INIT_PATH" disable 2>/dev/null || true
    else
        log_info "Init-скрипт не найден — останавливаем процесс напрямую."
    fi

    stop_tailscale_process || log_warn "tailscaled мог остаться в памяти до перезагрузки."
}

# =============================================================================
# Удаление интерфейса tailscale0
# =============================================================================

remove_kernel_interface() {
    log_step "Удаление интерфейса ${TAILSCALE_IFACE}"

    if ! interface_exists; then
        log_info "Интерфейс ${TAILSCALE_IFACE} не найден — пропуск."
        return 0
    fi

    ip link set dev "$TAILSCALE_IFACE" down 2>/dev/null || true

    if ip link delete dev "$TAILSCALE_IFACE" 2>/dev/null; then
        log_ok "Интерфейс ${TAILSCALE_IFACE} удалён (ip link delete)."
        return 0
    fi

    if ip tuntap del mode tun dev "$TAILSCALE_IFACE" 2>/dev/null; then
        log_ok "Интерфейс ${TAILSCALE_IFACE} удалён (ip tuntap del)."
        return 0
    fi

    if interface_exists; then
        log_warn "Не удалось удалить ${TAILSCALE_IFACE}. Перезагрузка очистит интерфейс."
        return 1
    fi

    log_ok "Интерфейс ${TAILSCALE_IFACE} удалён."
    return 0
}

# =============================================================================
# UCI — безопасное удаление (legacy-настройки установщика)
# =============================================================================

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
        log_info "Удаление network.${NET_INTERFACE}..."
        uci delete "network.${NET_INTERFACE}" || return 1
        log_ok "Секция network.${NET_INTERFACE} удалена."
    else
        log_info "network.${NET_INTERFACE} не найден — пропуск."
    fi
}

remove_firewall_zones() {
    _removed=0

    for _zone in "$FW_ZONE" "$FW_ZONE_LEGACY"; do
        _idx="$(firewall_zone_index_by_name "$_zone" 2>/dev/null || true)"
        while [ -n "$_idx" ]; do
            log_info "Удаление firewall-зоны '${_zone}' (index ${_idx})..."
            uci delete "firewall.@zone[${_idx}]" || return 1
            _removed=1
            _idx="$(firewall_zone_index_by_name "$_zone" 2>/dev/null || true)"
        done
    done

    if [ "$_removed" -eq 1 ]; then
        log_ok "Firewall-зоны Tailscale удалены."
    else
        log_info "Firewall-зоны Tailscale не найдены — пропуск."
    fi
}

remove_firewall_forwardings() {
    _count="$(firewall_anonymous_section_count forwarding)"
    _removed=0
    _idx=$((_count - 1))

    while [ "$_idx" -ge 0 ]; do
        _src="$(uci -q get "firewall.@forwarding[${_idx}].src" 2>/dev/null || true)"
        _dest="$(uci -q get "firewall.@forwarding[${_idx}].dest" 2>/dev/null || true)"

        if is_tailscale_zone_name "$_src" || is_tailscale_zone_name "$_dest"; then
            log_info "Удаление forwarding: ${_src} -> ${_dest}"
            uci delete "firewall.@forwarding[${_idx}]" || return 1
            _removed=1
        fi

        _idx=$((_idx - 1))
    done

    if [ "$_removed" -eq 1 ]; then
        log_ok "Forwarding Tailscale удалены."
    else
        log_info "Forwarding Tailscale не найдены — пропуск."
    fi
}

remove_firewall_rules() {
    _count="$(firewall_anonymous_section_count rule)"
    _removed=0
    _idx=$((_count - 1))

    while [ "$_idx" -ge 0 ]; do
        _name="$(uci -q get "firewall.@rule[${_idx}].name" 2>/dev/null || true)"
        _src="$(uci -q get "firewall.@rule[${_idx}].src" 2>/dev/null || true)"
        _delete=0

        if is_tailscale_rule_name "$_name" || is_tailscale_zone_name "$_src"; then
            _delete=1
        fi

        if [ "$_delete" -eq 1 ]; then
            log_info "Удаление правила: ${_name:-@rule[${_idx}]}"
            uci delete "firewall.@rule[${_idx}]" || return 1
            _removed=1
        fi

        _idx=$((_idx - 1))
    done

    if [ "$_removed" -eq 1 ]; then
        log_ok "Правила firewall Tailscale удалены."
    else
        log_info "Правила firewall Tailscale не найдены — пропуск."
    fi
}

restore_ip_forwarding() {
    if [ ! -f "$FORWARDING_BACKUP" ]; then
        log_info "Резервная копия forwarding не найдена — пропуск."
        return 0
    fi

    _orig="$(cat "$FORWARDING_BACKUP" 2>/dev/null || true)"

    if [ "$_orig" = "1" ]; then
        log_info "Восстановление network.globals.forwarding=1..."
        uci set network.globals.forwarding='1'
    else
        log_info "Удаление network.globals.forwarding..."
        uci delete network.globals.forwarding 2>/dev/null || true
    fi

    rm -f "$FORWARDING_BACKUP"
    log_ok "IP forwarding восстановлен из резервной копии."
}

uci_commit_and_reload() {
    _changed=0

    if uci changes network 2>/dev/null | grep -q .; then
        uci commit network || die "Не удалось выполнить uci commit network."
        _changed=1
    fi

    if uci changes firewall 2>/dev/null | grep -q .; then
        uci commit firewall || die "Не удалось выполнить uci commit firewall."
        _changed=1
    fi

    if [ "$_changed" -eq 0 ]; then
        log_info "Изменений UCI нет — перезагрузка network/firewall не требуется."
        return 0
    fi

    log_info "Перезагрузка network и firewall..."
    /etc/init.d/network reload 2>/dev/null || log_warn "Перезагрузка network завершилась с предупреждением."
    /etc/init.d/firewall reload 2>/dev/null || log_warn "Перезагрузка firewall завершилась с предупреждением."
}

remove_legacy_uci_configuration() {
    log_step "Удаление UCI-настроек Tailscale (если есть)"

    remove_network_interface
    remove_firewall_rules
    remove_firewall_forwardings
    remove_firewall_zones
    restore_ip_forwarding
    uci_commit_and_reload

    log_ok "UCI-очистка завершена."
}

# =============================================================================
# Пакет и файлы
# =============================================================================

remove_tailscale_package() {
    log_step "Удаление пакета ${TAILSCALE_PKG}"

    case "$SYS_PM" in
        apk)
            if apk info -e "$TAILSCALE_PKG" >/dev/null 2>&1; then
                apk del "$TAILSCALE_PKG" || die "Не удалось удалить пакет через apk."
                log_ok "Пакет удалён через apk."
            else
                log_info "Пакет ${TAILSCALE_PKG} не установлен (apk)."
            fi
            ;;
        opkg)
            if opkg status "$TAILSCALE_PKG" 2>/dev/null | grep -q '^Status: install'; then
                opkg remove "$TAILSCALE_PKG" || die "Не удалось удалить пакет через opkg."
                log_ok "Пакет удалён через opkg."
            else
                log_info "Пакет ${TAILSCALE_PKG} не установлен (opkg)."
            fi
            ;;
        *)
            log_warn "Пакетный менеджер не найден — удаление пакета пропущено."
            ;;
    esac
}

remove_tailscale_files() {
    log_step "Удаление файлов Tailscale"

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
        log_ok "Удалено: $TAILSCALE_UP_LOG"
    fi

    if ls /tmp/tailscale* >/dev/null 2>&1; then
        rm -rf /tmp/tailscale*
        log_ok "Удалены временные файлы /tmp/tailscale*"
    fi
}

remove_fake_iptables_stubs() {
    log_step "Проверка фиктивных iptables (legacy)"

    for _bin in iptables ip6tables; do
        _path="/usr/bin/$_bin"
        if [ -f "$_path" ] && grep -q 'Фиктивный' "$_path" 2>/dev/null; then
            rm -f "$_path"
            log_ok "Удалён фиктивный $_bin (создан старым установщиком)."
        fi
    done
}

remove_rc_local_entries() {
    if [ ! -f /etc/rc.local ]; then
        return 0
    fi

    if grep -q 'tailscale' /etc/rc.local 2>/dev/null; then
        log_info "Удаление записей tailscale из /etc/rc.local..."
        sed -i '/tailscale/d' /etc/rc.local
        log_ok "Записи tailscale удалены из rc.local."
    fi
}

# =============================================================================
# Проверки
# =============================================================================

verify_core_firewall_zones() {
    _missing=""

    for _zone in lan wan; do
        if ! firewall_zone_index_by_name "$_zone" >/dev/null 2>&1; then
            _missing="${_missing} ${_zone}"
        fi
    done

    if [ -n "$_missing" ]; then
        log_warn "Отсутствуют базовые firewall-зоны:${_missing}"
        log_warn "Восстановите /etc/config/firewall из резервной копии."
        return 1
    fi

    log_ok "Базовые firewall-зоны (lan/wan) на месте."
    return 0
}

verify_removal() {
    _issues=0

    if is_process_running tailscaled; then
        log_warn "Процесс tailscaled всё ещё запущен."
        _issues=1
    fi

    if interface_exists; then
        log_warn "Интерфейс ${TAILSCALE_IFACE} всё ещё существует."
        _issues=1
    fi

    case "$SYS_PM" in
        apk)
            if apk info -e "$TAILSCALE_PKG" >/dev/null 2>&1; then
                log_warn "Пакет ${TAILSCALE_PKG} всё ещё установлен."
                _issues=1
            fi
            ;;
        opkg)
            if opkg status "$TAILSCALE_PKG" 2>/dev/null | grep -q '^Status: install'; then
                log_warn "Пакет ${TAILSCALE_PKG} всё ещё установлен."
                _issues=1
            fi
            ;;
    esac

    return "$_issues"
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
    printf '\n'
}

print_final_report() {
    printf '\n'
    printf '=========================================\n'
    printf ' Удаление Tailscale завершено\n'
    printf '=========================================\n'
    printf '\n'

    if verify_removal; then
        log_warn "Остались артефакты Tailscale — рекомендуется перезагрузка."
    else
        log_ok "Tailscale полностью удалён из системы."
    fi

    printf '\n'
}

prompt_reboot() {
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        log_info "Неинтерактивный режим. При необходимости выполните: reboot"
        return 0
    fi

    printf '\n'
    log_info "Для полной очистки рекомендуется перезагрузить роутер."
    printf 'Перезагрузить сейчас? (y/N): '
    read -r _answer

    case "$_answer" in
        y|Y|yes|YES)
            log_info "Перезагрузка..."
            reboot
            ;;
        *)
            log_info "Перезагрузка отменена. Выполните 'reboot' позже при необходимости."
            ;;
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

    stop_tailscale_service
    remove_kernel_interface
    remove_legacy_uci_configuration
    remove_tailscale_package
    remove_tailscale_files
    remove_fake_iptables_stubs
    remove_rc_local_entries
    verify_core_firewall_zones || true
    print_final_report
    prompt_reboot
}

main "$@"

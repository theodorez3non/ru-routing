#!/bin/sh
#
# Tailscale — полное удаление для OpenWrt 24.x / 25.x
#
# Безопасно удаляет пакет, конфигурацию и только те UCI-секции,
# которые относятся к Tailscale. Восстанавливает исходное состояние
# IPv4 forwarding, если оно было изменено установщиком.
#
# Совместимость: BusyBox ash (/bin/sh), opkg (24.x), apk (25.x)
#
# Обновлён для совместимости с новым установщиком (поддержка зеркал, таймаутов и т.д.)
#

set -u

# =============================================================================
# Константы (согласованы с install.sh)
# =============================================================================

readonly SCRIPT_TITLE="Tailscale removal for OpenWrt"

readonly TAILSCALE_PKG="tailscale"
readonly TAILSCALE_INIT_DEFAULT="/etc/init.d/tailscale"

readonly NET_INTERFACE="tailscale"
readonly FW_ZONE="tailscale"
readonly FW_ZONE_LEGACY="tailscaleZone"

readonly FW_RULE_SSH="Allow-Tailscale-SSH"
readonly FW_RULE_HTTP="Allow-Tailscale-HTTP"
readonly FW_RULE_HTTPS="Allow-Tailscale-HTTPS"

readonly TAILSCALE_STATE_DIR="/etc/tailscale"
readonly TAILSCALE_LIB_DIR="/var/lib/tailscale"
readonly TAILSCALE_RUN_DIR="/var/run/tailscale"
readonly TAILSCALE_TMP_LOG="/tmp/tailscale_up.log"
readonly FORWARDING_BACKUP="/etc/tailscale/.forwarding_orig"

# =============================================================================
# Состояние
# =============================================================================

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

is_process_running() {
    _name="$1"
    if have_cmd pidof; then
        pidof "$_name" >/dev/null 2>&1 && return 0
    else
        ps -w | grep -v grep | grep -q "[${_name%?}]${_name#?}" && return 0
    fi
    return 1
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

# Проверяем, что имя правила начинается с "Allow-Tailscale-" (все наши правила)
is_tailscale_rule_name() {
    case "$1" in
        Allow-Tailscale-*) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# Остановка сервиса и процессов
# =============================================================================

stop_tailscale() {
    log_step "Остановка Tailscale"

    if is_process_running tailscaled; then
        if have_cmd tailscale; then
            log_info "Выполнение tailscale down..."
            tailscale down 2>/dev/null || true
        fi
    fi

    if resolve_init_script; then
        log_info "Остановка init-сервиса..."
        "$TAILSCALE_INIT_PATH" stop 2>/dev/null || true
        "$TAILSCALE_INIT_PATH" disable 2>/dev/null || true
        log_ok "Сервис остановлен."
    else
        log_info "Init-скрипт не найден — пропускаем остановку сервиса."
    fi

    # Принудительно убиваем процесс, если остался
    if is_process_running tailscaled; then
        log_warn "Процесс tailscaled всё ещё работает. Принудительное завершение..."
        if have_cmd pidof; then
            kill -9 "$(pidof tailscaled)" 2>/dev/null || true
        else
            kill -9 "$(ps -w | grep -v grep | grep tailscaled | awk '{print $1}')" 2>/dev/null || true
        fi
        sleep 1
        if is_process_running tailscaled; then
            log_warn "Не удалось завершить tailscaled. Перезагрузите роутер вручную."
        else
            log_ok "Процесс завершён."
        fi
    fi
}

# =============================================================================
# UCI — безопасное удаление
# =============================================================================

firewall_zone_index_by_name() {
    _zone="$1"; _idx=0
    while uci -q get "firewall.@zone[${_idx}]" >/dev/null 2>&1; do
        _name="$(uci -q get "firewall.@zone[${_idx}].name" 2>/dev/null || true)"
        [ "$_name" = "$_zone" ] && { printf '%s' "$_idx"; return 0; }
        _idx=$((_idx + 1))
    done
    return 1
}

firewall_anonymous_section_count() {
    _type="$1"; _idx=0
    while uci -q get "firewall.@${_type}[${_idx}]" >/dev/null 2>&1; do
        _idx=$((_idx + 1))
    done
    printf '%s' "$_idx"
}

remove_network_interface() {
    if uci -q get "network.${NET_INTERFACE}" >/dev/null 2>&1; then
        log_info "Удаление network.${NET_INTERFACE}..."
        uci delete "network.${NET_INTERFACE}" || return 1
        log_ok "Интерфейс ${NET_INTERFACE} удалён."
    else
        log_info "Интерфейс ${NET_INTERFACE} не найден — пропуск."
    fi
}

remove_firewall_zones() {
    _removed=0
    for _zone in "$FW_ZONE" "$FW_ZONE_LEGACY"; do
        _idx="$(firewall_zone_index_by_name "$_zone" 2>/dev/null || true)"
        while [ -n "$_idx" ]; do
            log_info "Удаление зоны '${_zone}' (index ${_idx})..."
            uci delete "firewall.@zone[${_idx}]" || return 1
            _removed=1
            _idx="$(firewall_zone_index_by_name "$_zone" 2>/dev/null || true)"
        done
    done
    [ "$_removed" -eq 1 ] && log_ok "Firewall-зоны Tailscale удалены." || log_info "Зоны не найдены — пропуск."
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
    [ "$_removed" -eq 1 ] && log_ok "Forwarding удалены." || log_info "Forwarding не найдены — пропуск."
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
    [ "$_removed" -eq 1 ] && log_ok "Правила удалены." || log_info "Правила не найдены — пропуск."
}

restore_ip_forwarding() {
    if [ -f "$FORWARDING_BACKUP" ]; then
        _orig="$(cat "$FORWARDING_BACKUP" 2>/dev/null || echo "")"
        if [ -n "$_orig" ]; then
            log_info "Восстановление network.globals.forwarding = '$_orig'..."
            if [ "$_orig" = "1" ]; then
                uci set network.globals.forwarding='1'
            else
                uci delete network.globals.forwarding 2>/dev/null || true
            fi
        else
            # Если было пусто — удаляем параметр
            log_info "Удаление network.globals.forwarding (был не установлен до установки)."
            uci delete network.globals.forwarding 2>/dev/null || true
        fi
        rm -f "$FORWARDING_BACKUP"
        log_ok "Forwarding восстановлен."
    else
        log_info "Файл резервной копии forwarding не найден — пропускаем восстановление."
    fi
}

uci_commit_and_reload() {
    log_info "Сохранение изменений UCI..."
    if uci changes network 2>/dev/null | grep -q .; then
        uci commit network || die "Ошибка uci commit network."
    fi
    if uci changes firewall 2>/dev/null | grep -q .; then
        uci commit firewall || die "Ошибка uci commit firewall."
    fi
    log_info "Перезагрузка network и firewall..."
    /etc/init.d/network reload 2>/dev/null || log_warn "Перезагрузка network с предупреждением."
    /etc/init.d/firewall reload 2>/dev/null || log_warn "Перезагрузка firewall с предупреждением."
}

remove_uci_configuration() {
    log_step "Удаление UCI-конфигурации Tailscale"
    remove_network_interface
    remove_firewall_rules
    remove_firewall_forwardings
    remove_firewall_zones
    restore_ip_forwarding
    uci_commit_and_reload
    log_ok "UCI-конфигурация очищена."
}

# =============================================================================
# Пакет и файлы
# =============================================================================

remove_tailscale_package() {
    log_step "Удаление пакета Tailscale"
    case "$SYS_PM" in
        apk)
            if apk info -e "$TAILSCALE_PKG" >/dev/null 2>&1; then
                apk del "$TAILSCALE_PKG" || die "Не удалось удалить через apk."
                log_ok "Пакет удалён через apk."
            else
                log_info "Пакет не установлен (apk)."
            fi
            ;;
        opkg)
            if opkg status "$TAILSCALE_PKG" 2>/dev/null | grep -q '^Status: install'; then
                opkg remove "$TAILSCALE_PKG" || die "Не удалось удалить через opkg."
                log_ok "Пакет удалён через opkg."
            else
                log_info "Пакет не установлен (opkg)."
            fi
            ;;
        *)
            log_warn "Пакетный менеджер не найден — удаление пакета пропущено."
            ;;
    esac
}

remove_tailscale_files() {
    log_step "Удаление файлов конфигурации"
    [ -d "$TAILSCALE_STATE_DIR" ] && { rm -rf "$TAILSCALE_STATE_DIR"; log_ok "Удалено: $TAILSCALE_STATE_DIR"; }
    [ -d "$TAILSCALE_LIB_DIR" ] && { rm -rf "$TAILSCALE_LIB_DIR"; log_ok "Удалено: $TAILSCALE_LIB_DIR"; }
    [ -d "$TAILSCALE_RUN_DIR" ] && { rm -rf "$TAILSCALE_RUN_DIR"; log_ok "Удалено: $TAILSCALE_RUN_DIR"; }
    # Удаляем возможные другие runtime-файлы
    rm -rf /tmp/tailscale* 2>/dev/null
    log_info "Удалены временные файлы /tmp/tailscale* (если были)."

    [ -f /etc/config/tailscale ] && { rm -f /etc/config/tailscale; log_ok "Удалено: /etc/config/tailscale"; }
    [ -f "$TAILSCALE_TMP_LOG" ] && { rm -f "$TAILSCALE_TMP_LOG"; log_ok "Удалён временный лог: $TAILSCALE_TMP_LOG"; }
}

remove_rc_local_entries() {
    [ ! -f /etc/rc.local ] && return 0
    if grep -q 'tailscale' /etc/rc.local 2>/dev/null; then
        log_info "Удаление записей tailscale из /etc/rc.local..."
        sed -i '/tailscale/d' /etc/rc.local
        log_ok "Записи удалены."
    fi
}

# =============================================================================
# Проверки после удаления
# =============================================================================

verify_core_firewall_zones() {
    _missing=""
    for _zone in lan wan; do
        firewall_zone_index_by_name "$_zone" >/dev/null 2>&1 || _missing="${_missing} ${_zone}"
    done
    if [ -n "$_missing" ]; then
        log_warn "Отсутствуют базовые зоны:${_missing}"
        log_warn "Возможно, предыдущее удаление повредило конфигурацию."
        log_warn "Восстановите /etc/config/firewall из резервной копии."
        return 1
    fi
    log_ok "Базовые зоны (lan/wan) на месте."
    return 0
}

# =============================================================================
# Завершение
# =============================================================================

print_banner() {
    printf '\n=========================================\n%s\n=========================================\n\n' "$SCRIPT_TITLE"
}

print_summary() {
    log_info "Package manager : ${SYS_PM}"
    printf '\n'
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
    detect_package_manager
    print_banner
    print_summary
    stop_tailscale
    remove_uci_configuration
    remove_tailscale_package
    remove_tailscale_files
    remove_rc_local_entries
    verify_core_firewall_zones || true
    printf '\n'
    log_ok "Tailscale удалён."
    prompt_reboot
}

main "$@"
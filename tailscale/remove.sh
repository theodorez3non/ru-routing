#!/bin/sh
# Полное удаление Tailscale и всех настроек

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ "$(id -u)" != "0" ] && error "Запускайте от root"

info "Останавливаем Tailscale..."
tailscale down 2>/dev/null || true
/etc/init.d/tailscale stop 2>/dev/null || true
/etc/init.d/tailscale disable 2>/dev/null || true

info "Удаляем пакет через apk (если установлен)..."
apk del tailscale 2>/dev/null || info "Пакет не найден через apk"

info "Удаляем бинарные файлы (если остались)..."
rm -f /usr/sbin/tailscaled /usr/sbin/tailscale /usr/bin/tailscale /usr/bin/tailscaled
rm -rf /tmp/tailscale

info "Удаляем конфигурацию tailscale..."
rm -rf /var/lib/tailscale /etc/tailscale

info "Удаляем сетевой интерфейс и зону файрвола..."
uci delete network.tailscale 2>/dev/null || true

# Удаляем все правила и зоны, связанные с tailscale
uci -q delete firewall.@zone[-1] 2>/dev/null || true
uci -q show firewall | grep -E '\.src=tailscale|\.dest=tailscale' | cut -d'=' -f1 | while read cfg; do
    uci delete "$cfg" 2>/dev/null || true
done
uci -q show firewall | grep -E '\.name=Allow-Tailscale' | cut -d'=' -f1 | while read cfg; do
    uci delete "$cfg" 2>/dev/null || true
done

uci commit firewall
uci commit network
/etc/init.d/firewall reload
/etc/init.d/network reload

info "Удаляем автозапуск из rc.local..."
sed -i '/tailscale up/d' /etc/rc.local

info "Удаляем init-скрипт Tailscale..."
rm -f /etc/init.d/tailscale

info "Чистка завершена. Tailscale удалён."

# Предложение перезагрузить роутер
if [ -t 0 ] && [ -t 1 ]; then
    echo ""
    echo "Для полной очистки рекомендуется перезагрузить роутер."
    printf "Перезагрузить сейчас? (y/N): "
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS])
            info "Перезагрузка..."
            reboot
            ;;
        *)
            info "Перезагрузка отменена. Вы можете перезагрузить позже командой 'reboot'."
            ;;
    esac
else
    info "Неинтерактивный режим. Рекомендуется перезагрузить роутер вручную командой 'reboot'."
fi
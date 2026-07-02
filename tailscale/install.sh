#!/bin/sh
# Установка Tailscale + exit node + автозапуск + автоопределение подсети для OpenWrt 25.12 (apk)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ "$(id -u)" != "0" ] && error "Запускайте от root"

# Определение архитектуры
ARCH=$(uname -m)
case "$ARCH" in
    mips|mipsel) TAILSCALE_ARCH="mips" ;;
    armv7l) TAILSCALE_ARCH="arm" ;;
    aarch64) TAILSCALE_ARCH="arm64" ;;
    x86_64) TAILSCALE_ARCH="amd64" ;;
    *) error "Неподдерживаемая архитектура: $ARCH" ;;
esac
info "Архитектура: $ARCH -> $TAILSCALE_ARCH"

# Проверка свободного места
FREE_SPACE_MB=$(df / | awk 'NR==2 {print int($4/1024)}')
info "Свободно в / : ${FREE_SPACE_MB} MiB"

if [ "$FREE_SPACE_MB" -lt 25 ]; then
    warn "Мало места. Установка во временную /tmp"
    INSTALL_DIR="/tmp/tailscale"
    mkdir -p "$INSTALL_DIR"
    BIN_DIR="$INSTALL_DIR"
else
    INSTALL_DIR="/usr/sbin"
    BIN_DIR="$INSTALL_DIR"
fi

# Функция установки через apk
install_via_apk() {
    info "Попытка установки через apk..."
    if command -v apk >/dev/null 2>&1; then
        apk update
        apk add tailscale && return 0
    fi
    return 1
}

# Функция установки через скачивание бинарника
install_via_download() {
    info "Скачивание бинарных файлов..."
    wget -O "${BIN_DIR}/tailscaled" "https://pkgs.tailscale.com/stable/${TAILSCALE_ARCH}/tailscaled" || error "Не скачался tailscaled"
    wget -O "${BIN_DIR}/tailscale" "https://pkgs.tailscale.com/stable/${TAILSCALE_ARCH}/tailscale" || error "Не скачался tailscale"
    chmod +x "${BIN_DIR}/tailscaled" "${BIN_DIR}/tailscale"
    if [ "$INSTALL_DIR" = "/tmp/tailscale" ]; then
        ln -sf "${BIN_DIR}/tailscale" /usr/bin/tailscale
        ln -sf "${BIN_DIR}/tailscaled" /usr/sbin/tailscaled
    fi
}

# Установка
if [ "$FREE_SPACE_MB" -ge 25 ] && install_via_apk; then
    info "Установлено через apk"
else
    install_via_download
fi

command -v tailscale >/dev/null 2>&1 || error "Tailscale не установлен"

# --- Автоопределение локальной подсети ---
get_lan_subnet() {
    local lan_ip=$(uci get network.lan.ipaddr 2>/dev/null)
    local lan_mask=$(uci get network.lan.netmask 2>/dev/null)
    if [ -n "$lan_ip" ] && [ -n "$lan_mask" ]; then
        # Пробуем ipcalc.sh (встроенный в OpenWrt)
        if command -v ipcalc.sh >/dev/null 2>&1; then
            subnet=$(ipcalc.sh "$lan_ip" "$lan_mask" | grep NETWORK | cut -d= -f2)
            if [ -n "$subnet" ]; then
                echo "$subnet"
                return 0
            fi
        fi
        # fallback: используем ip addr
        local iface=$(uci get network.lan.ifname 2>/dev/null || echo "br-lan")
        local addr=$(ip -4 addr show "$iface" 2>/dev/null | grep inet | awk '{print $2}')
        if [ -n "$addr" ]; then
            # addr имеет вид 192.168.1.1/24, заменяем последний октет на 0
            local network=$(echo "$addr" | sed 's/\.[0-9]*\//.0\//')
            echo "$network"
            return 0
        fi
    fi
    return 1
}

LAN_SUBNET=$(get_lan_subnet)
if [ -n "$LAN_SUBNET" ]; then
    info "Определена локальная подсеть: $LAN_SUBNET"
else
    warn "Не удалось определить локальную подсеть, параметр --advertise-routes не будет добавлен"
fi

# Формируем команду Tailscale
TAILSCALE_CMD="tailscale up --accept-dns=false --advertise-exit-node --ssh --netfilter-mode=off"
if [ -n "$LAN_SUBNET" ]; then
    TAILSCALE_CMD="$TAILSCALE_CMD --advertise-routes=$LAN_SUBNET"
fi

# Настройка сети и файрвола
info "Настройка сети и файрвола..."

uci set network.tailscale=interface
uci set network.tailscale.device='tailscale0'
uci set network.tailscale.proto='unmanaged'
uci set network.tailscale.auto='1'

uci add firewall zone
uci set firewall.@zone[-1].name='tailscale'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'
uci add_list firewall.@zone[-1].network='tailscale'

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='tailscale'
uci set firewall.@forwarding[-1].dest='lan'

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='tailscale'
uci set firewall.@forwarding[-1].dest='wan'

uci add firewall rule
uci set firewall.@rule[-1].name='Allow-Tailscale-SSH'
uci set firewall.@rule[-1].src='tailscale'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port='22'
uci set firewall.@rule[-1].target='ACCEPT'

uci add firewall rule
uci set firewall.@rule[-1].name='Allow-Tailscale-Web'
uci set firewall.@rule[-1].src='tailscale'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port='80 443'
uci set firewall.@rule[-1].target='ACCEPT'

uci commit network
uci commit firewall
/etc/init.d/network reload
/etc/init.d/firewall reload

# Включаем IP-форвардинг
sysctl -w net.ipv4.ip_forward=1
uci set network.globals.forwarding='1'
uci commit network

# Настройка автозапуска демона
if [ ! -f "/etc/init.d/tailscale" ]; then
    cat > /etc/init.d/tailscale <<EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/sbin/tailscaled
    procd_set_param respawn
    procd_close_instance
}
EOF
    chmod +x /etc/init.d/tailscale
fi
/etc/init.d/tailscale enable
/etc/init.d/tailscale start

# Запуск туннеля сейчас
info "Запускаем Tailscale с параметрами exit node..."
$TAILSCALE_CMD || {
    warn "Не удалось запустить туннель автоматически"
    info "Попробуйте вручную: $TAILSCALE_CMD"
}

# Добавляем автозапуск туннеля после перезагрузки (в rc.local)
if ! grep -q "tailscale up" /etc/rc.local; then
    if [ ! -f /etc/rc.local ]; then
        echo "#!/bin/sh" > /etc/rc.local
        echo "exit 0" >> /etc/rc.local
        chmod +x /etc/rc.local
    fi
    # Экранируем знак & для sed
    CMD_ESC=$(echo "$TAILSCALE_CMD" | sed 's/&/\\&/g')
    sed -i "/exit 0/i sleep 10 && $CMD_ESC &" /etc/rc.local
    info "Добавлен автозапуск туннеля в rc.local"
fi

# Проверяем, есть ли ссылка для авторизации
sleep 2
if tailscale status 2>&1 | grep -q "https://login.tailscale.com"; then
    echo ""
    echo "================================================================"
    echo "Перейдите по ссылке для авторизации:"
    tailscale status 2>&1 | grep "https://login.tailscale.com" | head -1
    echo "================================================================"
else
    echo ""
    echo "Если авторизация не выполнена, выполните вручную:"
    echo "$TAILSCALE_CMD"
fi

echo ""
echo "После авторизации в админке Tailscale включите для этого устройства опцию 'Exit node'."
echo "Роутер будет доступен по Tailscale IP для веба и SSH."
echo "Туннель автоматически запустится после каждой перезагрузки."
if [ -n "$LAN_SUBNET" ]; then
    echo "Рекламируется подсеть: $LAN_SUBNET (для доступа к локальным устройствам)"
fi
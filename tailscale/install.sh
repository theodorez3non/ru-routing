#!/bin/sh
# Установка Tailscale + Exit Node + автозапуск для OpenWrt 25.12 (apk)
# Автоматическое определение локальной подсети с fallback-запросом

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Проверка прав
[ "$(id -u)" != "0" ] && error "Запускайте от root"

# --- Определение архитектуры ---
ARCH=$(uname -m)
case "$ARCH" in
    mips|mipsel) TAILSCALE_ARCH="mips" ;;
    armv7l) TAILSCALE_ARCH="arm" ;;
    aarch64) TAILSCALE_ARCH="arm64" ;;
    x86_64) TAILSCALE_ARCH="amd64" ;;
    *) error "Неподдерживаемая архитектура: $ARCH" ;;
esac
info "Архитектура: $ARCH -> $TAILSCALE_ARCH"

# --- Свободное место ---
FREE_SPACE_MB=$(df / | awk 'NR==2 {print int($4/1024)}')
info "Свободно в / : ${FREE_SPACE_MB} MiB"

# --- Функции установки ---
install_via_apk() {
    if command -v apk >/dev/null 2>&1; then
        info "Попытка установки через apk..."
        apk update
        apk add tailscale && return 0
    fi
    return 1
}

install_via_download() {
    warn "Установка через apk недоступна или не удалась. Скачиваем бинарники."
    if [ "$FREE_SPACE_MB" -lt 25 ]; then
        INSTALL_DIR="/tmp/tailscale"
        mkdir -p "$INSTALL_DIR"
        BIN_DIR="$INSTALL_DIR"
    else
        INSTALL_DIR="/usr/sbin"
        BIN_DIR="$INSTALL_DIR"
    fi
    info "Скачивание бинарных файлов в $BIN_DIR..."
    wget -O "${BIN_DIR}/tailscaled" "https://pkgs.tailscale.com/stable/${TAILSCALE_ARCH}/tailscaled" || error "Не скачался tailscaled"
    wget -O "${BIN_DIR}/tailscale" "https://pkgs.tailscale.com/stable/${TAILSCALE_ARCH}/tailscale" || error "Не скачался tailscale"
    chmod +x "${BIN_DIR}/tailscaled" "${BIN_DIR}/tailscale"
    if [ "$INSTALL_DIR" = "/tmp/tailscale" ]; then
        ln -sf "${BIN_DIR}/tailscale" /usr/bin/tailscale
        ln -sf "${BIN_DIR}/tailscaled" /usr/sbin/tailscaled
    fi
}

# --- Установка ---
if ! command -v tailscale >/dev/null 2>&1; then
    if [ "$FREE_SPACE_MB" -ge 25 ] && install_via_apk; then
        info "Tailscale успешно установлен через apk."
    else
        install_via_download
    fi
else
    info "Tailscale уже установлен."
fi

# Проверяем наличие исполняемых файлов
if ! command -v tailscale >/dev/null 2>&1; then
    error "Не удалось установить Tailscale."
fi

# --- Автоопределение локальной подсети ---
get_lan_subnet() {
    local lan_ip=$(uci get network.lan.ipaddr 2>/dev/null)
    local lan_mask=$(uci get network.lan.netmask 2>/dev/null)
    if [ -n "$lan_ip" ] && [ -n "$lan_mask" ]; then
        if command -v ipcalc.sh >/dev/null 2>&1; then
            subnet=$(ipcalc.sh "$lan_ip" "$lan_mask" | grep NETWORK | cut -d= -f2)
            [ -n "$subnet" ] && echo "$subnet" && return 0
        fi
        local iface=$(uci get network.lan.ifname 2>/dev/null || echo "br-lan")
        local addr=$(ip -4 addr show "$iface" 2>/dev/null | grep inet | awk '{print $2}')
        if [ -n "$addr" ]; then
            network=$(echo "$addr" | sed 's/\.[0-9]*\//.0\//')
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
    warn "Не удалось определить локальную подсеть автоматически."
    
    # Интерактивный запрос, если есть tty
    if [ -t 0 ] && [ -t 1 ]; then
        echo ""
        echo "Пожалуйста, укажите подсеть вашей локальной сети (например, 192.168.1.0/24)."
        echo "Если вы не хотите рекламировать маршруты, просто нажмите Enter."
        echo "Список доступных интерфейсов и их IP:"
        ip -4 addr show | grep -E 'inet ' | awk '{print $2, $NF}'
        echo ""
        printf "Введите подсеть (или оставьте пустым): "
        read -r user_subnet
        if [ -n "$user_subnet" ]; then
            LAN_SUBNET="$user_subnet"
            info "Используем подсеть: $LAN_SUBNET"
        else
            warn "Подсеть не указана, реклама маршрутов будет пропущена."
        fi
    else
        warn "Неинтерактивный режим, реклама маршрутов пропущена."
    fi
fi

# Формируем команду для tailscale up
TAILSCALE_CMD="tailscale up --accept-dns=false --advertise-exit-node --ssh --netfilter-mode=off"
if [ -n "$LAN_SUBNET" ]; then
    TAILSCALE_CMD="$TAILSCALE_CMD --advertise-routes=$LAN_SUBNET"
fi

# --- Настройка сети и файрвола (с проверками) ---
info "Настройка сети и файрвола..."

# Интерфейс tailscale
if ! uci get network.tailscale >/dev/null 2>&1; then
    uci set network.tailscale=interface
    uci set network.tailscale.device='tailscale0'
    uci set network.tailscale.proto='unmanaged'
    uci set network.tailscale.auto='1'
    info "Интерфейс tailscale создан."
else
    info "Интерфейс tailscale уже существует."
fi

# Зона файрвола tailscale
if ! uci show firewall | grep -q "zone.tailscale"; then
    uci add firewall zone
    uci set firewall.@zone[-1].name='tailscale'
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='REJECT'
    uci set firewall.@zone[-1].masq='1'
    uci set firewall.@zone[-1].mtu_fix='1'
    uci add_list firewall.@zone[-1].network='tailscale'
    info "Зона tailscale создана."
else
    info "Зона tailscale уже существует."
fi

# Forwarding tailscale -> lan
if ! uci show firewall | grep -q "forwarding.*src='tailscale'.*dest='lan'"; then
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='tailscale'
    uci set firewall.@forwarding[-1].dest='lan'
    info "Правило forwarding tailscale -> lan добавлено."
else
    info "Правило forwarding tailscale -> lan уже существует."
fi

# Forwarding tailscale -> wan
if ! uci show firewall | grep -q "forwarding.*src='tailscale'.*dest='wan'"; then
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='tailscale'
    uci set firewall.@forwarding[-1].dest='wan'
    info "Правило forwarding tailscale -> wan добавлено."
else
    info "Правило forwarding tailscale -> wan уже существует."
fi

# Правило для SSH
if ! uci show firewall | grep -q "rule.*name='Allow-Tailscale-SSH'"; then
    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-Tailscale-SSH'
    uci set firewall.@rule[-1].src='tailscale'
    uci set firewall.@rule[-1].proto='tcp'
    uci set firewall.@rule[-1].dest_port='22'
    uci set firewall.@rule[-1].target='ACCEPT'
    info "Правило Allow-Tailscale-SSH добавлено."
else
    info "Правило Allow-Tailscale-SSH уже существует."
fi

# Правило для веб-интерфейса
if ! uci show firewall | grep -q "rule.*name='Allow-Tailscale-Web'"; then
    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-Tailscale-Web'
    uci set firewall.@rule[-1].src='tailscale'
    uci set firewall.@rule[-1].proto='tcp'
    uci set firewall.@rule[-1].dest_port='80 443'
    uci set firewall.@rule[-1].target='ACCEPT'
    info "Правило Allow-Tailscale-Web добавлено."
else
    info "Правило Allow-Tailscale-Web уже существует."
fi

# Применение настроек
uci commit network
uci commit firewall
/etc/init.d/network reload
/etc/init.d/firewall reload

# --- Включение IP-форвардинга ---
info "Включаем IP-форвардинг..."
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || warn "Не удалось включить форвардинг через /proc"
uci set network.globals.forwarding='1' 2>/dev/null || warn "Не удалось установить uci параметр"
uci commit network 2>/dev/null || warn "Не удалось сохранить uci настройки"

# --- Настройка автозапуска демона ---
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
    info "Init-скрипт /etc/init.d/tailscale создан."
fi

# Включаем и запускаем демон
/etc/init.d/tailscale enable
/etc/init.d/tailscale start
info "Демон tailscaled запущен."

# --- Добавление автозапуска туннеля в rc.local ---
if ! grep -q "tailscale up" /etc/rc.local 2>/dev/null; then
    if [ ! -f /etc/rc.local ]; then
        echo "#!/bin/sh" > /etc/rc.local
        echo "exit 0" >> /etc/rc.local
        chmod +x /etc/rc.local
    fi
    # Экранируем & для sed
    CMD_ESC=$(echo "$TAILSCALE_CMD" | sed 's/&/\\&/g')
    sed -i "/exit 0/i sleep 10 && $CMD_ESC &" /etc/rc.local
    info "Автозапуск туннеля добавлен в /etc/rc.local."
else
    info "Автозапуск туннеля уже присутствует в /etc/rc.local."
fi

# --- Запуск туннеля сейчас ---
info "Запускаем туннель Tailscale..."
$TAILSCALE_CMD || {
    warn "Не удалось запустить туннель автоматически."
    info "Попробуйте выполнить вручную: $TAILSCALE_CMD"
}

# --- Вывод ссылки для авторизации ---
sleep 2
echo ""
echo "Проверяем статус Tailscale..."
if tailscale status 2>&1 | grep -q "https://login.tailscale.com"; then
    echo "================================================================"
    echo "Перейдите по ссылке для авторизации:"
    tailscale status 2>&1 | grep "https://login.tailscale.com" | head -1
    echo "================================================================"
else
    # Если ссылка не появилась, возможно, уже авторизованы или нужен ручной запуск
    if tailscale status 2>&1 | grep -q "Logged out"; then
        echo "================================================================"
        echo "Вы не авторизованы. Выполните вручную:"
        echo "$TAILSCALE_CMD"
        echo "После этого появится ссылка для входа."
        echo "================================================================"
    else
        echo "Tailscale уже авторизован или статус неизвестен."
        echo "Проверьте: tailscale status"
        tailscale status
    fi
fi

echo ""
echo "После авторизации в админке Tailscale включите для этого устройства опцию 'Exit node'."
echo "Роутер будет доступен по Tailscale IP для веба и SSH."
if [ -n "$LAN_SUBNET" ]; then
    echo "Рекламируется подсеть: $LAN_SUBNET (для доступа к локальным устройствам)."
fi
echo "Туннель автоматически запустится после перезагрузки."
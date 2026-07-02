#!/bin/sh
# Установка/перенастройка Tailscale + Exit Node для OpenWrt 25.12 (apk)
# Интерактивный выбор локальной подсети

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

# --- Проверка наличия Tailscale ---
if command -v tailscale >/dev/null 2>&1; then
    info "Tailscale уже установлен."
    if [ -t 0 ] && [ -t 1 ]; then
        echo ""
        printf "Хотите только перенастроить сеть/файрвол и перезапустить туннель? (y/N): "
        read -r reconf
        case "$reconf" in
            y|Y|yes|Yes)
                info "Продолжаем с перенастройкой."
                ;;
            *)
                info "Выход. Никаких изменений не внесено."
                exit 0
                ;;
        esac
    else
        info "Неинтерактивный режим: продолжаем с настройкой (без переустановки)."
    fi
else
    # --- Установка Tailscale ---
    install_via_apk() {
        if command -v apk >/dev/null 2>&1; then
            info "Попытка установки через apk..."
            apk update || return 1
            apk add tailscale || return 1
            return 0
        fi
        return 1
    }

    install_via_download() {
        warn "Установка через apk недоступна или не удалась. Скачиваем бинарники."
        if [ "$FREE_SPACE_MB" -lt 25 ]; then
            INSTALL_DIR="/tmp/tailscale"
            mkdir -p "$INSTALL_DIR" || return 1
            BIN_DIR="$INSTALL_DIR"
        else
            INSTALL_DIR="/usr/sbin"
            BIN_DIR="$INSTALL_DIR"
        fi
        info "Скачивание бинарных файлов в $BIN_DIR..."
        wget -O "${BIN_DIR}/tailscaled" "https://pkgs.tailscale.com/stable/${TAILSCALE_ARCH}/tailscaled" || return 1
        wget -O "${BIN_DIR}/tailscale" "https://pkgs.tailscale.com/stable/${TAILSCALE_ARCH}/tailscale" || return 1
        chmod +x "${BIN_DIR}/tailscaled" "${BIN_DIR}/tailscale" || return 1
        if [ "$INSTALL_DIR" = "/tmp/tailscale" ]; then
            ln -sf "${BIN_DIR}/tailscale" /usr/bin/tailscale || return 1
            ln -sf "${BIN_DIR}/tailscaled" /usr/sbin/tailscaled || return 1
        fi
        return 0
    }

    if [ "$FREE_SPACE_MB" -ge 25 ]; then
        if install_via_apk; then
            info "Tailscale успешно установлен через apk."
        else
            install_via_download || error "Не удалось установить Tailscale."
        fi
    else
        install_via_download || error "Не удалось установить Tailscale."
    fi

    # Проверяем наличие после установки
    if ! command -v tailscale >/dev/null 2>&1; then
        error "Не удалось установить Tailscale."
    fi
fi

# --- Определение подсети ---
get_lan_subnet() {
    local lan_ip=$(uci get network.lan.ipaddr 2>/dev/null)
    local lan_mask=$(uci get network.lan.netmask 2>/dev/null)
    if [ -n "$lan_ip" ] && [ -n "$lan_mask" ]; then
        if command -v ipcalc.sh >/dev/null 2>&1; then
            subnet=$(ipcalc.sh "$lan_ip" "$lan_mask" 2>/dev/null | grep NETWORK | cut -d= -f2)
            [ -n "$subnet" ] && echo "$subnet" && return 0
        fi
        if echo "$lan_mask" | grep -q "255.255.255.0"; then
            echo "$(echo "$lan_ip" | cut -d. -f1-3).0/24"
            return 0
        fi
    fi
    local iface="br-lan"
    local addr=$(ip -4 addr show "$iface" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
    if [ -n "$addr" ]; then
        echo "$addr" | sed 's/\.[0-9]*\//.0\//'
        return 0
    fi
    return 0
}

select_subnet_interactively() {
    local items=""
    local idx=0
    local iface_list=$(ip -4 addr show 2>/dev/null | grep -E '^[0-9]+:' | awk -F': ' '{print $2}')
    for iface in $iface_list; do
        case "$iface" in
            lo|tailscale*|dummy*) continue ;;
        esac
        addr=$(ip -4 addr show "$iface" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
        if [ -n "$addr" ] && ! echo "$addr" | grep -q '^fe80:'; then
            idx=$((idx + 1))
            items="$items$idx) $iface $addr\n"
            eval "iface_$idx='$iface'"
            eval "addr_$idx='$addr'"
        fi
    done

    if [ "$idx" -eq 0 ]; then
        warn "Не найдено ни одного интерфейса с IPv4-адресом."
        return 0
    fi

    echo ""
    echo "Доступные локальные сети (интерфейсы с IPv4):"
    printf "%b" "$items" | column -t -s ')' || echo "$items"
    echo ""
    printf "Выберите номер интерфейса для рекламы (0 для пропуска): "
    read -r choice

    if [ -z "$choice" ] || [ "$choice" -eq 0 ]; then
        warn "Реклама маршрутов отключена."
        return 0
    fi

    if ! echo "$choice" | grep -q '^[0-9]\+$' || [ "$choice" -gt "$idx" ] || [ "$choice" -lt 1 ]; then
        warn "Неверный номер."
        return 0
    fi

    eval "selected_addr=\$addr_$choice"
    eval "selected_iface=\$iface_$choice"
    info "Выбран интерфейс $selected_iface с адресом $selected_addr"

    if command -v ipcalc.sh >/dev/null 2>&1; then
        ip_part=$(echo "$selected_addr" | cut -d/ -f1)
        mask_part=$(echo "$selected_addr" | cut -d/ -f2)
        subnet=$(ipcalc.sh "$ip_part" "$mask_part" 2>/dev/null | grep NETWORK | cut -d= -f2)
        if [ -n "$subnet" ]; then
            echo "$subnet"
            return 0
        fi
    fi

    if echo "$selected_addr" | grep -q '/24$'; then
        echo "$selected_addr" | sed 's/\.[0-9]*\/24/.0\/24/'
        return 0
    fi

    warn "Не удалось вычислить подсеть для $selected_addr."
    printf "Введите вручную (например, 192.168.7.0/24) или оставьте пустым: "
    read -r manual_subnet
    [ -n "$manual_subnet" ] && echo "$manual_subnet"
    return 0
}

LAN_SUBNET=""
AUTO_SUBNET=$(get_lan_subnet)
if [ -n "$AUTO_SUBNET" ]; then
    info "Автоматически определена подсеть: $AUTO_SUBNET"
    if [ -t 0 ] && [ -t 1 ]; then
        printf "Использовать её? (Y/n): "
        read -r use_auto
        case "$use_auto" in
            n|N) ;;
            *) LAN_SUBNET="$AUTO_SUBNET" ;;
        esac
    else
        LAN_SUBNET="$AUTO_SUBNET"
    fi
fi

if [ -z "$LAN_SUBNET" ] && [ -t 0 ] && [ -t 1 ]; then
    SELECTED=$(select_subnet_interactively)
    [ -n "$SELECTED" ] && LAN_SUBNET="$SELECTED"
fi

if [ -z "$LAN_SUBNET" ] && [ -n "$TAILSCALE_SUBNET" ]; then
    LAN_SUBNET="$TAILSCALE_SUBNET"
    info "Используем подсеть из переменной окружения: $LAN_SUBNET"
fi

[ -z "$LAN_SUBNET" ] && warn "Реклама маршрутов будет пропущена."

TAILSCALE_CMD="tailscale up --accept-dns=false --advertise-exit-node --ssh --netfilter-mode=off"
[ -n "$LAN_SUBNET" ] && TAILSCALE_CMD="$TAILSCALE_CMD --advertise-routes=$LAN_SUBNET"

# --- Настройка сети и файрвола ---
info "Настройка сети и файрвола..."

if ! uci get network.tailscale >/dev/null 2>&1; then
    uci set network.tailscale=interface
    uci set network.tailscale.device='tailscale0'
    uci set network.tailscale.proto='unmanaged'
    uci set network.tailscale.auto='1'
    info "Интерфейс tailscale создан."
else
    info "Интерфейс tailscale уже существует."
fi

if ! uci show firewall 2>/dev/null | grep -q "zone.tailscale"; then
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

if ! uci show firewall 2>/dev/null | grep -q "forwarding.*src='tailscale'.*dest='lan'"; then
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='tailscale'
    uci set firewall.@forwarding[-1].dest='lan'
    info "Правило forwarding tailscale -> lan добавлено."
else
    info "Правило forwarding tailscale -> lan уже существует."
fi

if ! uci show firewall 2>/dev/null | grep -q "forwarding.*src='tailscale'.*dest='wan'"; then
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='tailscale'
    uci set firewall.@forwarding[-1].dest='wan'
    info "Правило forwarding tailscale -> wan добавлено."
else
    info "Правило forwarding tailscale -> wan уже существует."
fi

if ! uci show firewall 2>/dev/null | grep -q "rule.*name='Allow-Tailscale-SSH'"; then
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

if ! uci show firewall 2>/dev/null | grep -q "rule.*name='Allow-Tailscale-Web'"; then
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

/etc/init.d/tailscale enable
/etc/init.d/tailscale start
info "Демон tailscaled запущен."

# --- Автозапуск туннеля в rc.local ---
if ! grep -q "tailscale up" /etc/rc.local 2>/dev/null; then
    if [ ! -f /etc/rc.local ]; then
        echo "#!/bin/sh" > /etc/rc.local
        echo "exit 0" >> /etc/rc.local
        chmod +x /etc/rc.local
    fi
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
    info "Попробуйте вручную: $TAILSCALE_CMD"
}

# --- Вывод информации об авторизации ---
sleep 2
echo ""
echo "Проверяем статус Tailscale..."
STATUS_OUTPUT=$(tailscale status 2>&1)
if echo "$STATUS_OUTPUT" | grep -q "https://login.tailscale.com"; then
    echo "================================================================"
    echo "Перейдите по ссылке для авторизации:"
    echo "$STATUS_OUTPUT" | grep "https://login.tailscale.com" | head -1
    echo "================================================================"
else
    if echo "$STATUS_OUTPUT" | grep -q "Logged out"; then
        echo "================================================================"
        echo "Вы не авторизованы. Выполните вручную:"
        echo "$TAILSCALE_CMD"
        echo "После этого появится ссылка для входа."
        echo "================================================================"
    else
        echo "Текущий статус Tailscale:"
        echo "$STATUS_OUTPUT"
        echo ""
        echo "Если вы ещё не авторизованы, выполните:"
        echo "$TAILSCALE_CMD"
        echo "и перейдите по ссылке."
    fi
fi

echo ""
echo "После авторизации в админке Tailscale включите для этого устройства опцию 'Exit node'."
echo "Роутер будет доступен по Tailscale IP для веба и SSH."
[ -n "$LAN_SUBNET" ] && echo "Рекламируется подсеть: $LAN_SUBNET (для доступа к локальным устройствам)."
echo "Туннель автоматически запустится после перезагрузки."
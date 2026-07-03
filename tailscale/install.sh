#!/bin/sh
# Установка Tailscale + Exit Node + доступ к роутеру
# Поддержка OpenWrt 24.10 (opkg) и 25.12 (apk)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

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

# --- Определение пакетного менеджера ---
PKG_MANAGER="opkg"
if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    info "Используем пакетный менеджер: apk"
else
    info "Используем пакетный менеджер: opkg"
fi

# --- Установка зависимостей для скачивания ---
install_dependencies() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk add wget ca-bundle libustream-openssl kmod-tun 2>/dev/null || true
    else
        opkg update || return 1
        opkg install wget ca-bundle libustream-openssl kmod-tun 2>/dev/null || true
    fi
}

install_dependencies

# --- Функция для поиска tailscale в системе ---
find_tailscale() {
    # Проверяем стандартные пути
    for path in /usr/sbin/tailscale /usr/bin/tailscale /opt/bin/tailscale; do
        if [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    # Ищем через find (может быть долго, но надёжно)
    find /usr -name "tailscale" -type f -executable 2>/dev/null | head -1
    return 1
}

# --- Функция проверки доступности tailscale ---
check_tailscale() {
    # Добавляем /usr/sbin в PATH, если ещё нет
    if ! echo "$PATH" | grep -q "/usr/sbin"; then
        export PATH="/usr/sbin:$PATH"
    fi
    if command -v tailscale >/dev/null 2>&1; then
        return 0
    fi
    # Пробуем найти бинарник вручную
    TS_BIN=$(find_tailscale)
    if [ -n "$TS_BIN" ]; then
        # Создаём симлинк в /usr/bin, если он не в PATH
        if [ ! -f "/usr/bin/tailscale" ]; then
            ln -sf "$TS_BIN" /usr/bin/tailscale 2>/dev/null
        fi
        export PATH="/usr/bin:/usr/sbin:$PATH"
        command -v tailscale >/dev/null 2>&1 && return 0
    fi
    return 1
}

# --- Функции установки ---
install_via_package_manager() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        info "Попытка установки через apk..."
        apk update || return 1
        apk add tailscale || return 1
    else
        info "Попытка установки через opkg..."
        opkg update || return 1
        opkg install tailscale || return 1
    fi
    return 0
}

install_via_download() {
    warn "Установка через пакетный менеджер недоступна или не удалась. Скачиваем бинарники."
    if [ "$FREE_SPACE_MB" -lt 25 ]; then
        INSTALL_DIR="/tmp/tailscale"
        mkdir -p "$INSTALL_DIR" || return 1
        BIN_DIR="$INSTALL_DIR"
    else
        INSTALL_DIR="/usr/sbin"
        BIN_DIR="$INSTALL_DIR"
    fi
    info "Скачивание бинарных файлов в $BIN_DIR..."
    wget --no-check-certificate -O "${BIN_DIR}/tailscaled" "https://pkgs.tailscale.com/stable/${TAILSCALE_ARCH}/tailscaled" || return 1
    wget --no-check-certificate -O "${BIN_DIR}/tailscale" "https://pkgs.tailscale.com/stable/${TAILSCALE_ARCH}/tailscale" || return 1
    chmod +x "${BIN_DIR}/tailscaled" "${BIN_DIR}/tailscale" || return 1
    if [ "$INSTALL_DIR" = "/tmp/tailscale" ]; then
        ln -sf "${BIN_DIR}/tailscale" /usr/bin/tailscale || return 1
        ln -sf "${BIN_DIR}/tailscaled" /usr/sbin/tailscaled || return 1
    else
        # Если установили в /usr/sbin, создаём симлинк в /usr/bin для удобства
        ln -sf /usr/sbin/tailscale /usr/bin/tailscale 2>/dev/null || true
    fi
    # Добавляем /usr/sbin в PATH
    export PATH="/usr/sbin:/usr/bin:$PATH"
    return 0
}

# --- Основная установка ---
# Проверяем, доступен ли tailscale
if check_tailscale; then
    info "Tailscale уже установлен и доступен."
else
    # Пытаемся установить через пакетный менеджер
    if [ "$FREE_SPACE_MB" -ge 25 ]; then
        info "Попытка установки через пакетный менеджер..."
        if install_via_package_manager; then
            info "Установка через пакетный менеджер выполнена."
            # После установки проверяем снова
            if check_tailscale; then
                info "Tailscale успешно установлен."
            else
                warn "Пакет установлен, но бинарники не найдены. Пытаемся найти вручную..."
                TS_BIN=$(find_tailscale)
                if [ -n "$TS_BIN" ]; then
                    info "Найден бинарник: $TS_BIN"
                    ln -sf "$TS_BIN" /usr/bin/tailscale 2>/dev/null
                    export PATH="/usr/bin:/usr/sbin:$PATH"
                    if command -v tailscale >/dev/null 2>&1; then
                        info "Tailscale теперь доступен."
                    else
                        warn "Не удалось добавить tailscale в PATH. Выполните вручную:"
                        echo "  export PATH=/usr/sbin:\$PATH"
                        echo "  tailscale up ..."
                    fi
                else
                    warn "Бинарники не найдены. Пробуем скачать вручную..."
                    install_via_download || error "Не удалось установить Tailscale."
                fi
            fi
        else
            warn "Установка через пакетный менеджер не удалась. Пробуем скачать бинарники..."
            install_via_download || error "Не удалось установить Tailscale."
        fi
    else
        warn "Мало свободного места. Пробуем установить в /tmp..."
        install_via_download || error "Не удалось установить Tailscale."
    fi
fi

# Финальная проверка
if ! check_tailscale; then
    error "Не удалось найти tailscale. Попробуйте перезагрузить роутер и запустить скрипт снова."
fi

# --- Формируем команду запуска (без рекламы подсетей) ---
TAILSCALE_CMD="tailscale up --accept-dns=false --advertise-exit-node --ssh --netfilter-mode=off"

# --- Проверка существования зоны wan ---
if ! uci show firewall 2>/dev/null | grep -q "zone.wan"; then
    warn "Зона 'wan' не найдена в файрволе. Убедитесь, что ваш интернет-интерфейс добавлен в зону 'wan'."
    warn "Без этого exit node работать не будет."
fi

# --- Настройка сети и файрвола (минималистично) ---
info "Настройка сети и файрвола..."

# 1. Интерфейс tailscale
if ! uci get network.tailscale >/dev/null 2>&1; then
    uci set network.tailscale=interface
    uci set network.tailscale.device='tailscale0'
    uci set network.tailscale.proto='unmanaged'
    uci set network.tailscale.auto='1'
    info "Интерфейс tailscale создан."
else
    info "Интерфейс tailscale уже существует."
fi

# 2. Зона файрвола tailscale
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

# 3. Правило форвардинга: tailscale -> wan (для exit node)
if ! uci show firewall 2>/dev/null | grep -q "forwarding.*src='tailscale'.*dest='wan'"; then
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='tailscale'
    uci set firewall.@forwarding[-1].dest='wan'
    info "Правило forwarding tailscale -> wan добавлено."
else
    info "Правило forwarding tailscale -> wan уже существует."
fi

# 4. Разрешить SSH из Tailscale
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

# 5. Разрешить веб-интерфейс (порты 80, 443) из Tailscale
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

# Применяем настройки
uci commit network
uci commit firewall
/etc/init.d/network reload
/etc/init.d/firewall reload

# --- Включение IP-форвардинга (необходимо для exit node) ---
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

# --- Запуск туннеля ---
info "Запускаем туннель Tailscale..."
$TAILSCALE_CMD || {
    warn "Не удалось запустить туннель автоматически."
    info "Попробуйте вручную: $TAILSCALE_CMD"
}

# --- Информация об авторизации ---
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
echo "Туннель автоматически запустится после перезагрузки."
echo ""
echo "ВНИМАНИЕ: доступ к локальной сети через Tailscale не рекламируется."
echo "Если нужен доступ к другим устройствам в локальной сети, добавьте вручную:"
echo "  tailscale up --advertise-routes=<ваша_подсеть>"
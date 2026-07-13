# Tailscale Exit Node для OpenWrt

Автоматическая установка и настройка Tailscale на OpenWrt 24.10 / 25.12 (с `apk` или `opkg`) в режиме **Exit Node**.  
Скрипт работает на системах с блокировками провайдера — поддерживает **зеркала репозиториев**, настройку времени и авторизацию по ключу.

---

## 🚀 Быстрая установка

Подключитесь к роутеру по SSH и выполните:

```bash
sh <(wget -O - https://raw.githubusercontent.com/theodorez3non/ru-routing/main/tailscale/install.sh)
```

Если у провайдера блокируются репозитории OpenWrt, укажите зеркало:

```bash
sh <(wget -O - https://raw.githubusercontent.com/theodorez3non/ru-routing/main/tailscale/install.sh) --mirror https://mirrors.tuna.tsinghua.edu.cn/openwrt
```

Если у вас есть заранее сгенерированный ключ авторизации Tailscale:

```bash
sh <(wget -O - https://raw.githubusercontent.com/theodorez3non/ru-routing/main/tailscale/install.sh) --mirror https://mirrors.tuna.tsinghua.edu.cn/openwrt --auth-key tskey-xxxxxx
```

Скрипт автоматически:
- Установит Tailscale через штатный пакетный менеджер (`apk` или `opkg`)
- Настроит часовой пояс `Europe/Moscow` (MSK-3)
- Создаст сетевой интерфейс `tailscale0`
- Настроит файрвол (зона `tailscale`, forwarding в `wan`, правила для SSH, HTTP, HTTPS)
- Включит IP-форвардинг
- Запустит Tailscale с параметрами:
  ```
  --advertise-exit-node --accept-dns=false --netfilter-mode=off --ssh
  ```
- Авторизует устройство, если передан ключ `--auth-key`, иначе выведет ссылку для входа в веб-админку
- Добавит сервис в автозапуск (через `init.d enable`)

После установки в веб-админке Tailscale включите для этого устройства опцию **Exit node**.

---

## 🔧 Требования

- **OpenWrt 24.10 или 25.12** (с `apk` / `opkg`)
- **Архитектура**: любая, поддерживаемая Tailscale (mips, armv7l, aarch64, x86_64)
- **Свободная память**: >10 МБ (рекомендуется >25 МБ)
- **Права root**
- Интерфейс `wan` должен существовать (для настройки forwarding)

---

## 📋 Поддерживаемые опции командной строки

| Опция | Описание |
|-------|----------|
| `--mirror <URL>` | Заменить официальные репозитории OpenWrt на указанное зеркало (например, `https://mirrors.tuna.tsinghua.edu.cn/openwrt`) |
| `--auth-key <ключ>` | Использовать ключ авторизации Tailscale для автоматического входа |

---

## 🖥️ Использование после установки

- **Авторизация**: Если не использовали `--auth-key`, скрипт выведет ссылку для входа.
- **Доступ к роутеру**:
  - Веб-интерфейс: `http://<Tailscale_IP>`
  - SSH: `ssh root@<Tailscale_IP>`
- **Доступ к локальной сети**: Все устройства в вашей локальной сети становятся доступны через Tailscale (так как Exit Node рекламирует маршрут по умолчанию).

---

## 🗑️ Деинсталляция

```bash
sh <(wget -O - https://raw.githubusercontent.com/theodorez3non/ru-routing/main/tailscale/remove.sh)
```

Скрипт полностью удаляет:
- Пакет `tailscale`
- UCI-секции: интерфейс `tailscale`, зону `tailscale`, все связанные правила и forwardings
- IP‑forwarding (если был включён только для Tailscale)
- Файлы конфигурации (`/etc/tailscale`, `/var/lib/tailscale`, `/etc/config/tailscale`)
- Временные логи (`/tmp/tailscale_up.log`)
- Записи из `/etc/rc.local` (если были)

После удаления рекомендуется перезагрузить роутер.

---

## ⚠️ Примечания

- **Блокировки провайдера**: Для работы Tailscale необходимо, чтобы следующие домены были доступны (добавьте их в обход, если используете фильтры):
  - `*.tailscale.com`
  - `login.tailscale.com`
  - `controlplane.tailscale.com`
  - `derp*.tailscale.com`
- **Firewall**: Скрипт использует `--netfilter-mode=off`, поэтому управление файрволом полностью через UCI. Это предотвращает конфликты с `nftables` в OpenWrt 25.12.
- **Временная зона**: По умолчанию устанавливается `Europe/Moscow` – измените в скрипте переменные `TIMEZONE_NAME` и `TIMEZONE_STRING` при необходимости.
- **Обновление**: Скрипт идемпотентен – при повторном запуске он не переустанавливает пакет, если он уже есть, а только обновляет конфигурацию.

---

## 📁 Структура репозитория

```
tailscale/
├── install.sh      # Установка и настройка
└── remove.sh       # Полное удаление
```

---

## 📦 Пример полной установки с зеркалом и ключом

```bash
sh install.sh --mirror https://mirrors.tuna.tsinghua.edu.cn/openwrt --auth-key tskey-xxxxxx
```

---

## 🐛 Диагностика

Если туннель не поднимается, проверьте:

```bash
tailscale status
tailscale bugreport
```

Убедитесь, что демон запущен:

```bash
ps | grep tailscaled
```
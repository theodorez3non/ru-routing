# DNS-over-HTTPS (DoH) для OpenWrt

Автоматическая установка и настройка DNS-over-HTTPS на OpenWrt с использованием `https-dns-proxy`.  
Скрипт настраивает шифрованный DNS-канал, перенаправляет `dnsmasq` на локальный DoH-прокси и поддерживает выбор провайдера.

---

## 🚀 Быстрая установка

Подключитесь к роутеру по SSH и выполните:

```bash
sh <(wget -O - https://raw.githubusercontent.com/theodorez3non/ru-routing/main/doh/install.sh)
```

С указанием провайдера и порта:

```bash
sh <(wget -O - https://raw.githubusercontent.com/theodorez3non/ru-routing/main/doh/install.sh) --provider google --port 5353
```

Скрипт автоматически:
- Установит `https-dns-proxy` (и опционально `luci-app-https-dns-proxy`)
- Настроит DoH-прокси с выбранным провайдером (по умолчанию Cloudflare)
- Перенастроит `dnsmasq` для использования локального прокси
- Включит автозапуск сервиса
- Выполнит проверку через `nslookup`

---

## 🔧 Поддерживаемые опции командной строки

| Опция | Описание |
|-------|----------|
| `--provider <провайдер>` | Выбор DNS-провайдера: `cloudflare` (по умолчанию), `google`, `quad9`, `adguard` |
| `--port <порт>` | Порт для локального DoH-прокси (по умолчанию `5053`) |

---

## 📋 Поддерживаемые провайдеры

| Провайдер | URL |
|-----------|-----|
| Cloudflare | `https://cloudflare-dns.com/dns-query` |
| Google    | `https://dns.google/dns-query` |
| Quad9     | `https://dns.quad9.net/dns-query` |
| AdGuard   | `https://dns.adguard.com/dns-query` |

---

## 📦 Примеры использования

### Установка с Cloudflare (по умолчанию)
```bash
sh install.sh
```

### Установка с Google DNS и портом 5353
```bash
sh install.sh --provider google --port 5353
```

### Установка с Quad9
```bash
sh install.sh --provider quad9
```

---

## 🗑️ Деинсталляция

```bash
sh <(wget -O - https://raw.githubusercontent.com/theodorez3non/ru-routing/main/doh/remove.sh)
```

Скрипт полностью удаляет:
- Пакет `https-dns-proxy` (и `luci-app-https-dns-proxy`, если установлен)
- UCI-конфигурацию `https-dns-proxy`
- Настройки `dnsmasq` (удаляет `127.0.0.1#<порт>`, `noresolv` и фиктивный `resolvfile`)
- Останавливает и отключает сервис

После удаления рекомендуется перезагрузить роутер.

---

## 🖥️ Проверка работы

После установки выполните:

```bash
nslookup openwrt.org 127.0.0.1
```

Если всё настроено правильно, вы увидите корректный ответ от DNS-сервера.

Для проверки используемого DNS-провайдера:

```bash
nslookup whoami.akamai.net 127.0.0.1
```

---

## ⚠️ Примечания

- **Совместимость**: работает на OpenWrt с `opkg` (24.10) и `apk` (25.12).
- **LUCI**: веб-интерфейс устанавливается опционально, но не является обязательным.
- **Порт**: по умолчанию `5053` — не конфликтует с другими службами.
- **Блокировки**: если DoH-сервер блокируется провайдером, попробуйте другой провайдер или используйте прокси.

---

## 📁 Структура репозитория

```
doh/
├── install.sh      # Установка и настройка DoH
└── remove.sh       # Полное удаление DoH
```

---

## 🐛 Диагностика

Если DNS не работает, проверьте:

```bash
# Статус сервиса
/etc/init.d/https-dns-proxy status

# Логи
logread | grep -i dns

# Проверка резолвинга
nslookup openwrt.org 127.0.0.1
```
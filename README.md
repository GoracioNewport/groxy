# groxy

**Двухуровневый WireGuard с селективной маршрутизацией по белому списку доменов и GeoIP.**

Российские сервисы — напрямую с IP вашего российского VPS. Всё остальное — через зарубежный VPS. Один WireGuard-туннель на клиенте, всё разделение происходит на сервере.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Проблема

Российские сайты (банки, госуслуги, маркетплейсы) часто отказывают зарубежным IP. Иностранные сайты — наоборот. Классический VPN решает только одну сторону: либо ты «всегда в РФ», либо «всегда в загранице».

`groxy` решает обе:

- `*.ru` и всё, что хостится в российских AS — идёт **напрямую** с IP вашего российского сервера, локальные сервисы видят русский IP.
- Всё остальное — **через зарубежный сервер**, иностранные сервисы видят его IP.

Клиент при этом подключается **один раз** и не переключает профили.

## Как работает

```
            ┌────────────────────────────┐
            │  Bridge (российский VPS)   │
   client ──▶ wg0 ─┐                     │
   any device      │                     │
                   ▼ mangle PREROUTING   │
                ┌─────────────┐          │
                │ dst в RU?   │──── да ──▶ eth0 (egress) ──▶ интернет
                │ (DNS + GeoIP)│         │   (с IP bridge'a)
                └──────┬──────┘          │
                       │ нет             │
                       ▼                 │
                      wg1 ───────────────┼──▶ Portal (зарубежный VPS) ──▶ интернет
                                         │      (с IP portal'a)
            └────────────────────────────┘
```

Разделение работает в трёх уровнях:

1. **DNS-based** (динамический). `dnsmasq` на bridge при резолве доменов из whitelist'a кладёт полученные IP в kernel-ipset `vpn_domains`. Mangle-правило снимает с этих пакетов метку → они идут через main routing table напрямую.
2. **GeoIP** (статический). Daily-cron качает список российских CIDR-диапазонов в ipset `ru_cidrs`. Тот же mangle карвит эти направления. Защищает от приложений, которые обходят dnsmasq (например, мобильные клиенты с захардкоженным DoH).
3. Всё остальное идёт через wg1 → portal.

## Требования

- **Два VPS** под Debian 12 (bookworm) или 13 (trixie). Один в РФ, один за пределами.
- root-доступ на обоих.
- Открытые UDP-порты для WireGuard на портале и bridge'е (groxy сам выбирает случайный из 49152-65535, либо задаёшь флагом).
- Прямая сетевая видимость между bridge и portal по выбранному UDP-порту.

> Ubuntu, Fedora, Arch не тестируются (есть warning, но не блокируется). nftables-only хосты — проверь, что `iptables`-shim установлен.

## Быстрый старт

### 1. Развернуть portal (зарубежный VPS)

```sh
ssh root@portal-vps
apt update && apt install -y git
git clone https://github.com/GoracioNewport/groxy /opt/groxy
/opt/groxy/groxy init portal
```

Создан peer-узел WireGuard на portal'е, без peer'ов. Все нужные конфиги — в `/etc/groxy/portal/`.

### 2. Зарегистрировать bridge на portal'е

```sh
# на portal-VPS
/opt/groxy/groxy portal add-bridge moscow-1 > /root/moscow-1.profile
```

В `/root/moscow-1.profile` теперь портал-профиль — структурированный текст, который надо передать на bridge. **Внутри лежит preshared key** — передавай через защищённый канал (scp), не через мессенджер.

```sh
# переправить scp'ом на bridge:
scp /root/moscow-1.profile root@bridge-vps:/root/
```

### 3. Развернуть bridge (российский VPS)

```sh
ssh root@bridge-vps
apt update && apt install -y git
git clone https://github.com/GoracioNewport/groxy /opt/groxy
/opt/groxy/groxy init bridge --portal-profile=/root/moscow-1.profile
```

В последней строке вывода будет публичный ключ bridge'a. Скопируй.

### 4. Активировать peer на portal'е

```sh
# на portal-VPS
/opt/groxy/groxy portal accept-bridge moscow-1 --pubkey=<bridge-pubkey>
```

Handshake bridge ↔ portal состоится в течение ~25 секунд.

### 5. Добавить клиента

```sh
# на bridge-VPS
/opt/groxy/groxy bridge add-client phone --qr
```

В stdout будет WireGuard-конфиг (можно `> phone.conf`), в stderr — ASCII-QR. Сканируй из мобильного WireGuard-приложения.

Для десктопа: сохрани конфиг в файл, импортируй в WireGuard-app:
```sh
/opt/groxy/groxy bridge add-client laptop > laptop.conf
```

### 6. Проверить, что работает

```sh
# с клиента после подключения:
curl https://yandex.ru/internet  # должен показать ваш РОССИЙСКИЙ IP (bridge'a)
curl https://api.ipify.org       # должен показать ЗАРУБЕЖНЫЙ IP (portal'a)
```

## Команды

### Общие

| Команда | Что делает |
|---|---|
| `groxy status` | Диагностика: роль, сервисы, peer'ы, ipset-стати, последние fetch'ы, warnings |
| `groxy apply` | Перегенерация всех конфигов из state'a + restart нужных сервисов |
| `groxy uninstall [--yes]` | Снос: stop+disable сервисов, удаление rendered-файлов, бэкап state'a в `/etc/groxy.bak.<ts>` |
| `groxy version` | Версия |

### Portal-сторона

| Команда | Что делает |
|---|---|
| `groxy init portal [--public-ip=X] [--port=N] [--subnet=CIDR] [--iface=NAME]` | Установка роли. Все флаги опциональны — авто-детектится |
| `groxy portal add-bridge <name> [--portal-name=<friendly>]` | Создаёт peer-запись, генерит PSK, печатает portal-profile в stdout |
| `groxy portal accept-bridge <name> --pubkey=<key>` | Активирует peer (записывает pubkey, рендерит wg0.conf, рестартит wg-quick) |
| `groxy portal list-bridges` | Табличка всех зарегистрированных bridge'ей с статусом active/pending |
| `groxy portal remove-bridge <name> [--yes]` | Удаление peer'a |

### Bridge-сторона: клиенты

| Команда | Что делает |
|---|---|
| `groxy init bridge --portal-profile=<file>` | Установка роли с импортом portal-профиля. Поднимает wg0 для клиентов, wg1 в portal, dnsmasq, ipset, mangle, timer |
| `groxy bridge add-client <name> [--qr]` | Создаёт WG-клиента. Конфиг в stdout, опционально QR в stderr |
| `groxy bridge list-clients` | Табличка клиентов |
| `groxy bridge remove-client <name> [--yes]` | Удаление |

### Bridge-сторона: multi-portal (failover)

| Команда | Что делает |
|---|---|
| `groxy bridge add-portal <name> --profile=<file>` | Импорт второго portal-профиля без переключения активного |
| `groxy bridge list-portals` | Все известные portal'ы, активный отмечен `*` |
| `groxy bridge use-portal <name>` | Переключить активный portal (regen wg1.conf + restart wg-quick@wg1). Прозрачно для клиентских wg0-сессий |
| `groxy bridge remove-portal <name> [--yes]` | Удаление. Отказ если portal активный |

### Bridge-сторона: whitelist & GeoIP

| Команда | Что делает |
|---|---|
| `groxy bridge whitelist update` | Скачать opencck-список доменов, обновить ipset `vpn_domains` через dnsmasq |
| `groxy bridge whitelist reload` | Перечитать локальный `custom.txt`, restart dnsmasq |
| `groxy bridge whitelist set-source <url>` | Сменить URL источника opencck-списка |
| `groxy bridge geoip update` | Скачать CIDR-список российских IP, перенаполнить ipset `ru_cidrs` (атомарно) |
| `groxy bridge geoip set-source <url>` | Сменить URL источника CIDR-списка |
| `groxy bridge settings get` | Показать состояние трёх тогглов |
| `groxy bridge settings set <opencck\|custom\|geoip> <on\|off>` | Включить/выключить feed (с немедленным применением) |

## Маршрутизация: три источника whitelist'a

groxy комбинирует три независимых источника информации для решения "ходить ли direct'ом":

### 1. opencck — DNS-список из сети (default: ON)

URL по умолчанию: `russia.iplist.opencck.org/?format=text&data=domains` (~20 тысяч RU-доменов, обновляется проектом opencck).

```sh
# Просмотр текущего источника:
cat /etc/groxy/bridge/whitelist/source-url

# Сменить:
groxy bridge whitelist set-source https://my-list.example.com/domains.txt
groxy bridge whitelist update
```

Daily-timer (`groxy-whitelist-update.timer`) скачивает список раз в сутки.

### 2. custom — DNS-список из локального файла (default: ON)

Файл `/etc/groxy/bridge/whitelist/custom.txt`. По одной строке на запись. Поддерживается wildcard через `*.foo` (эквивалентно просто `foo` — dnsmasq матчит суффикс):

```
# /etc/groxy/bridge/whitelist/custom.txt
*.ru
sub.example.com
my-specific-site.org
```

После правки:
```sh
groxy bridge whitelist reload
```

Дефолтное содержимое — одна строка `*.ru` (заворачивает весь .ru в direct).

### 3. geoip — статический CIDR-список (default: ON)

URL по умолчанию: `ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone` (~8600 aggregated CIDR'ов). Daily-timer наполняет ipset `ru_cidrs`. Полезен для случаев, когда:

- Клиент использует DNS-over-HTTPS (тогда dnsmasq не видит запрос → vpn_domains не наполняется), но направление всё равно карвится по IP.
- Сервис hardcodes IP (Telegram, например).

### Тогглы

Каждый источник отключаемый:

```sh
groxy bridge settings set opencck off   # отключить DNS-cron-feed
groxy bridge settings set geoip off     # отключить GeoIP-feed  
groxy bridge settings set custom off    # отключить локальный список
```

`off` → файл `/etc/dnsmasq.d/00-opencck.conf` / `50-custom.conf` удаляется (для DNS-feed'ов), либо `ipset flush ru_cidrs` (для GeoIP). Mangle-правила остаются — просто не находят совпадений → весь трафик идёт через portal.

`set` мгновенно применяет изменения; restart дополнительно не нужен.

## Файловая структура

Декларативное состояние:

```
/etc/groxy/
├── role                           # "portal" | "bridge"
├── version                        # версия groxy
├── portal/                        # если portal
│   ├── private.key, public.key
│   ├── server.env                 # PUBLIC_IP, LISTEN_PORT, TUNNEL_SUBNET, EGRESS_IFACE
│   └── bridges/<name>.peer        # peer-записи для каждого bridge
└── bridge/                        # если bridge
    ├── private.key, public.key    # wg1 keypair
    ├── current-portal             # имя активного portal'a
    ├── settings.env               # WHITELIST_OPENCCK/CUSTOM/GEOIP
    ├── portals/<name>/            # один или больше portal'ов
    │   ├── portal.env
    │   └── portal-public.key
    ├── wg0/                       # сторона клиентов
    │   ├── private.key, public.key
    │   ├── server.env             # SUBNET, LISTEN_PORT, PUBLIC_IP
    │   └── clients/<name>.peer
    └── whitelist/
        ├── custom.txt             # руками
        ├── source-url             # URL opencck-источника
        ├── opencck.txt            # автообновляемый
        ├── geoip-source-url       # URL CIDR-источника
        └── ru_cidrs.list          # автообновляемый
```

Рабочие конфиги (`/etc/wireguard/wg{0,1}.conf`, `/etc/dnsmasq.conf`, `/etc/dnsmasq.d/*.conf`, `/etc/ipset/ipset.conf`, systemd-юниты) — **полностью генерируются** из state'a командой `apply`. Прямое редактирование рабочих файлов теряется при следующем `apply`.

## Multi-portal failover

Если основной portal лёг, переключение занимает 5 секунд:

```sh
# заранее: добавить второй portal
groxy bridge add-portal germany --profile=/root/germany.profile
# получишь pubkey bridge'a, нужно отдать админу второго portal'a
# на germany-portal:
groxy portal accept-bridge moscow-1 --pubkey=<тот же pubkey>

# когда первый помрёт:
groxy bridge use-portal germany
# wg1 переподнимается, handshake к germany сходится за ~25s
# клиентские wg0-сессии не падают
```

Один bridge всегда имеет одну identity (wg1 keypair). Каждый portal видит его как peer с разным `TUNNEL_BRIDGE_IP` (который тот portal сам назначил).

## Что не работает

- **DoH/DoT в клиентских приложениях**. Если клиент резолвит мимо dnsmasq (например, Firefox с DNS-over-HTTPS) — vpn_domains не наполнится. Спасает GeoIP-feed для значительной части случаев. Полная защита потребует DNAT'a клиентского DNS-трафика, что выходит за рамки v1.
- **IPv6**. Отключён осознанно. Все туннели только v4.
- **CDN-балансировка с разными IP**. Если bridge и клиент резолвят домен в разные IP (CDN раздаёт по геолокации) — наполнение ipset на bridge'е не поможет, потому что клиент использует другой IP. Решается тем, что клиент **обязан** использовать DNS bridge'a (поле `DNS = 10.66.66.1` в клиентском конфиге; groxy ставит его автоматически).
- **DPI/блокировка WireGuard** на стороне ISP. WG-трафик не маскируется. На текущий момент в РФ заметных проблем нет, но это может измениться.
- **Защита от утечки IP клиента**, если он сам отключит туннель. groxy — не kill-switch.

## Поведение при недоступности feed-источников

Все network-fetch'и устойчивы к сетевым сбоям:

- HTTP 4xx/5xx, timeout, DNS-fail → старые файлы и ipset'ы **сохраняются**, dnsmasq не рестартится.
- Если источник отдаёт мусор (HTTP 200 + HTML-страница ошибки) — новые данные применяются. Защита от этой ситуации не реализована (но рассматривается).

## Диагностика

```sh
groxy status                                       # общая картина
wg show                                            # WG-handshake'ы
ipset list vpn_domains | head -20                  # IP в DNS-карв-ауте
ipset list ru_cidrs | grep -c "/"                  # счётчик GeoIP-CIDR'ов
journalctl -u wg-quick@wg1 -b --no-pager | tail    # лог wg-quick
systemctl list-timers groxy-whitelist-update.timer # когда следующий refresh

# проверка, что конкретный IP попадёт под carve-out:
ipset test vpn_domains 77.88.55.55                 # exit 0 = да
ipset test ru_cidrs 77.88.55.55                    # exit 0 = да
```

## Версионирование и миграции

Версия в `/etc/groxy/version` после init'a. На текущий момент проект в pre-1.0 (`0.1.0-dev`) — структура state'a может меняться без обратной совместимости. Стабильную семантику получит после `1.0.0`.

## Лицензия

[MIT](LICENSE).

## Благодарности

- Списки RU-доменов: [opencck](https://opencck.org/)
- CIDR-блоки РФ: [ipdeny.com](https://www.ipdeny.com/)
- Спецификация и архитектура — отдельная история; см. [docs/](docs/) (если выложены).

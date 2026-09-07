# Стенд 3x-ui / Xray — результаты и вердикт

Дата: 2026-08-10. Стенд поднят **параллельно** боевому groxy, прод не тронут.

Узлы стенда (оба удаляются после экспериментов):
- `moscow-25000-01` (193.233.246.86, Debian 13, RU) — роль bridge: WireGuard-inbound.
- `nether-2000-01` (194.150.220.208, Debian 12, NL) — роль portal: Reality-inbound (выход).

Тестовый WG-клиент — нативный WireGuard в изолированном network namespace на nether
(чтобы не задеть боевые `wg0`, `killer-bot`, `tinyproxy`).

Софт: Xray-core 26.3.27 (ручной стенд) и 3x-ui **v3.6.0** (Xray 26.7.28 в комплекте).

---

## 1. Что подтверждено фактами на стенде

### 1.1. Sniffing доменов для WireGuard-inbound — РАБОТАЕТ (главный вопрос)

Схема: WG-inbound + `sniffing.destOverride=[tls,http,quic]` на bridge; routing по доменам;
два freedom-outbound с разными тегами.

Доказательство однозначное: соединение на IP Google `142.251.154.119:443` ушло в outbound
`foreign`, **хотя правило матчит только домен `google.com`, а правила по этому IP нет**.
Значит Xray реконструировал TCP-поток из WG-инкапсуляции, вытащил SNI и смаршрутизировал
по домену. В access-log:

```
taking detour [foreign] for [tcp:www.google.com:443]
tunneling request to tcp:www.google.com:443 via 194.150.220.208:8443
```

Вывод: главное преимущество текущей схемы (**тупой нативный WG-клиент** на роутерах/ТВ)
сохраняется, а carve-out делается по **домену**, а не по IP.

### 1.2. Полный каскад Reality — проверен по exit-IP

Путь: WG-клиент → `moscow-25000-01` (WG-in, sniff+route) → Reality-outbound →
`nether-2000-01` (Reality-in) → интернет.

| Запрос | Правило | Факт. exit-IP | Ожидание |
|---|---|---|---|
| `api.ipify.org` | → foreign | **194.150.220.208** (nether, NL) | портал ✓ |
| `ipinfo.io/ip` (дефолт/direct) | → direct | **193.233.246.86** (moscow, RU) | напрямую RU ✓ |

Критерий успеха стенда выполнен: RU-ресурсы идут напрямую с российского IP, зарубежные —
через выход, маршрутизация **по доменам**.

### 1.3. Масштаб домен-листа

19 700 доменов (объём opencck-фида) в routing: загрузка конфига **14 мс**, RSS Xray **35 МБ**,
маршрутизация остаётся корректной. Держит легко.

### 1.4. Throughput / статистика (явное требование пользователя)

Xray Stats API (`StatsService`) отдаёт счётчики per-inbound и per-outbound:

```
inbound  >>> wgin    >>> uplink/downlink   ← весь трафик через этот узел
outbound >>> foreign >>> uplink/downlink   ← ушедшее через портал
outbound >>> direct  >>> uplink/downlink   ← напрямую с RU-IP
```

Счётчики висят **на интерфейсах inbound/outbound, а не на пирах**, поэтому **не обнуляются
при add/remove клиента** — прямое лекарство от проблемы v1 №5 (обнуление per-peer счётчиков
при рестарте `wg-quick@wg0`). Это и есть «сквозной throughput по узлу + разбивка
портал/напрямую».

### 1.5. Control plane в 3x-ui v3.6.0 — реальная мультинода (не маркетинг)

Схема таблицы `nodes` в БД установленного бинаря подтверждает, что панель уже реализует
почти всё, что `V2-ROADMAP.md` планировал писать на Go:

| Поле в `nodes` | Что закрывает из роадмапа |
|---|---|
| `api_token`, `tls_verify_mode`, `pinned_cert_sha256` | gRPC/mTLS-подключение агента к нодам |
| `outbound_tag` (на ноду) | каскад: нода уходит через заданный outbound (Reality к порталу) |
| `config_dirty`, `inbounds_adopted_at` | reconcile desired→actual |
| `last_heartbeat`, `latency_ms`, `cpu_pct`, `mem_pct`, `net_up/down`, `xray_state` | health-чеки + метрики по узлу |
| `inbound_sync_mode`, `inbound_tags` | синхронизация инбаундов с нод |
| `node_client_traffics(node_id,email,up,down)`, `client_global_traffics` | per-client трафик по узлам и сквозной по парку |

Дополнительно из коробки: Postgres как общий стор для мультиноды (= «БД как источник
правды»), REST API + Swagger, Telegram-бот, per-client квоты/сроки/IP-лимиты/QR/подписки,
fail2ban + IP-limit jail (ставятся автоматически). Мультинода вызревала с 2024 г.
(v3.3–3.5: node/sync hardening, per-node outbound, mTLS) — не бета.

---

## 2. Найденные грабли (факты стенда)

- **Reality `dest = www.microsoft.com` ломает splice в Xray v26**: клиент получает EOF даже
  по loopback, сервер молча релеит на настоящий microsoft, клиент отвергает чужой
  сертификат. `dest = dl.google.com` работает. Донорский сайт должен быть splice-совместим.
- **WG-inbound в Xray — userspace gVisor TUN** («WG inbound doesn't support kernel TUN yet»).
  Функционально работает, но это не kernel-WG: небольшой оверхед на CPU/латентность на нагрузке.
- **У WG-пиров в Xray нет per-client идентичности (`email`)**. Модель панели «per-client
  трафик/квота» построена вокруг email-идентифицируемых клиентов (VLESS/Trojan/…). То есть
  нативный WG-клиент = **нет per-client учёта/квот в панели** (придётся считать по WG-пирам
  отдельно, как в v1). Это ключевой размен за «тупой WG-клиент».

---

## 3. Что НЕ проверено на стенде (честно)

- Живая регистрация и sync второй ноды end-to-end (ставилась одна нода; схема БД доказывает
  наличие механизма, но поведение sync/mTLS вживую не гонялось).
- Автопереключение портал→резерв (у Xray есть observatory + balancer для failover на уровне
  outbound; оркестрация failover самой панелью не проверялась).
- Per-WG-peer статистика именно в панели.

---

## 4. Вердикт

**Data plane — Xray выигрывает уверенно.** Domain-based carve-out для нативных WG-клиентов
работает, снимает целый класс багов v1 (ipset `vpn_domains` без TTL и ложные carve-out'ы —
проблема №1; необходимость foreign-denylist во многом отпадает), и даёт интерфейсную
статистику throughput, устойчивую к рестартам пиров (проблема №5).

**Control plane — 3x-ui v3.6.0 уже реализует ~80% того, что роадмап собирался писать на Go**:
центральная панель как источник правды, ноды по mTLS, reconcile, heartbeat/метрики,
per-client трафик по парку, квоты/сроки, TG-бот, REST API. Писать это самим — по большей
части дублирование.

**Рекомендация:** сменить курс с «пишем Go control plane» на «берём 3x-ui + Xray, пишем
только тонкую обвязку, которой не хватает»:
1. Глубокий мониторинг (Prometheus + Grafana + Loki + alerting) — роадмап и так планировал
   писать его отдельно, панельных метрик для алертов недостаточно.
2. Failover-оркестрация, если balancer/observatory Xray не покроет сценарий портал→резерв.
3. Разрешить размен «нативный WG ⇄ per-client квоты»: решить — оставить тупой WG и считать
   по пирам, или увести клиентов на Reality/VLESS ради полного управления в панели, или
   гибрид (WG для роутеров/ТВ + Reality для телефонов, где важны обфускация и квоты).

**Обязательно до принятия решения:** поднять реальную пару 3x-ui (master + нода по mTLS,
Postgres) и подтвердить вживую (а) каскад bridge→portal под управлением панели и
(б) per-WG-client учёт. Это единственное, чего стенд не покрыл.

Дополнительный аргумент вне велосипеда: обычный WireGuard в РФ в 2026 массово опознаётся
ТСПУ; Reality как второй протокол — вопрос выживания. Xray закрывает и это (тот же стек,
тот же control plane), а самописная схема — нет.

---

## 5. Состояние стенда (для самостоятельного осмотра)

- Ручной каскад Xray продолжает работать: `moscow-25000-01` (WG-in :51822, конфиг в
  `/root/xray-stand/config.json`) → Reality → `nether-2000-01` (:8443,
  `/root/xray-stand/reality.json`). Тестовый WG-клиент — netns `wgtest` на nether.
- Панель 3x-ui: `http://193.233.246.86:32573/standpanel/`, логин `standadmin`
  (пароль выдан в чате сессии). Управление: `x-ui` на узле. Панель слушает 0.0.0.0 —
  прикрыта fail2ban + случайными кредами; при желании забиндить локально: `x-ui` → settings.
- Санитарная задача выполнена: мёртвый пир `biosentivo` (`rZo4Ax…`, Selectel) снят с `wg0`
  nether и вычищен из `/etc/wireguard/wg0.conf`; `killer-bot` и `tinyproxy` не затронуты.

Снос стенда: на каждом узле `x-ui uninstall` (панель) и `pkill -x xray` + `rm -rf
/root/xray-stand` (ручной каскад); netns — `ip netns del wgtest` на nether. `nether-2000-01`
пользователь удаляет сам.

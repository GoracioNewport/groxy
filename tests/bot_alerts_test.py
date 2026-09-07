#!/usr/bin/env python3
"""Контракт правил алертов и доставки. Запуск: python3 tests/bot_alerts_test.py"""

import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bot"))

from groxy_bot import net, telegram  # noqa: E402
from groxy_bot.alerts import (  # noqa: E402
    AlertState,
    Condition,
    NodeState,
    Thresholds,
    evaluate,
)
from groxy_bot.cli import Client, PortalLink, Snapshot  # noqa: E402
from groxy_bot.delivery import Delivery  # noqa: E402

NOW = 1_800_000_000
T = Thresholds()

passed = 0
failed = 0


def check(what, want, got):
    global passed, failed
    if want == got:
        print(f"  ok   {what}")
        passed += 1
    else:
        print(f"  FAIL {what}: ожидалось {want!r}, получено {got!r}")
        failed += 1


def keys(conditions):
    return sorted(c.key for c in conditions)


def client(name, handshake):
    return Client(name, "10.66.66.2", "k" * 43 + "=", None, handshake, 0, 0)


HEALTHY_NODE = NodeState(
    load1=0.1,
    mem_used=1_000_000_000,
    mem_total=4_000_000_000,
    disk_used=3_000_000_000,
    disk_total=30_000_000_000,
    cpu_count=2,
    resolver_answers=True,
)

HEALTHY = Snapshot(
    generated_at=NOW,
    portal=PortalLink("nether", "1.2.3.4:5", NOW - 20, 0, 0),
    clients=(client("alpha", NOW - 60),),
)

print("== всё в порядке ==")
check("тревог нет", [], keys(evaluate(HEALTHY, HEALTHY_NODE, T, NOW)))

print("== портал ==")
stale = Snapshot(NOW, PortalLink("nether", "1.2.3.4:5", NOW - 900, 0, 0), HEALTHY.clients)
check("протухший handshake", ["portal_handshake"], keys(evaluate(stale, HEALTHY_NODE, T, NOW)))
never = Snapshot(NOW, PortalLink("nether", None, 0, 0, 0), HEALTHY.clients)
check("ни одного handshake", ["portal_handshake"], keys(evaluate(never, HEALTHY_NODE, T, NOW)))
none_portal = Snapshot(NOW, None, HEALTHY.clients)
check("портал не выбран", ["portal_missing"], keys(evaluate(none_portal, HEALTHY_NODE, T, NOW)))

print("== узел ==")
no_dns = NodeState(0.1, 1, 4, 1, 30, 2, resolver_answers=False)
check("резолвер не отвечает", True, "dns" in keys(evaluate(HEALTHY, no_dns, T, NOW)))
full_disk = NodeState(0.1, 1_000_000_000, 4_000_000_000, 29_000_000_000, 30_000_000_000, 2, True)
check("диск", True, "disk" in keys(evaluate(HEALTHY, full_disk, T, NOW)))
full_mem = NodeState(0.1, 3_900_000_000, 4_000_000_000, 3, 30, 2, True)
check("память", True, "memory" in keys(evaluate(HEALTHY, full_mem, T, NOW)))
busy = NodeState(9.0, 1, 4, 1, 30, 2, True)
check("нагрузка", True, "load" in keys(evaluate(HEALTHY, busy, T, NOW)))

print("== отсутствующая метрика не даёт ложной тревоги ==")
# На другом ядре или в контейнере файла может не быть. Считать None за ноль
# значило бы поднять тревогу о занятом диске там, где его не измерили.
blind = NodeState(None, None, None, None, None, 2, True)
check("нет метрик — нет тревог по ним", [], keys(evaluate(HEALTHY, blind, T, NOW)))

print("== молчащие клиенты сведены в один алерт ==")
silent = Snapshot(
    NOW,
    HEALTHY.portal,
    tuple(client(f"c{i}", NOW - 40 * 86400) for i in range(10)),
)
found = evaluate(silent, HEALTHY_NODE, T, NOW)
check("ровно один алерт на всех", ["clients_silent"], keys(found))
check("названо число", True, "10" in found[0].text)
# Тридцать шесть сообщений подряд — способ научить владельца не читать бота.
check("имена перечислены не все", True, "и ещё 5" in found[0].text)

print("== «ни разу» не считается молчанием ==")
# Это обычно свежий профиль, который человеку ещё не поставили, а не
# потерянный доступ.
fresh = Snapshot(NOW, HEALTHY.portal, (client("new", 0),))
check("тревоги нет", [], keys(evaluate(fresh, HEALTHY_NODE, T, NOW)))


print("== классификатор Xray ==")
# Выключенный классификатор — норма: узел классифицирует по меткам, как делал
# всегда. Включённый и неработающий — остановка всего TCP и UDP клиентов, и это
# отдельная тревога, а не строка в общей: разные поломки с разной срочностью.
off = NodeState(0.1, 1, 4, 1, 30, 2, True, xray_alive=None)
check("выключен — тревоги нет", [], keys(evaluate(HEALTHY, off, T, NOW)))
alive = NodeState(0.1, 1, 4, 1, 30, 2, True, xray_alive=True)
check("работает — тревоги нет", [], keys(evaluate(HEALTHY, alive, T, NOW)))
dead = NodeState(0.1, 1, 4, 1, 30, 2, True, xray_alive=False)
found_x = evaluate(HEALTHY, dead, T, NOW)
check("лежит — тревога", ["xray"], keys(found_x))
check("сказано, что стоит весь трафик", True, "стоит" in found_x[0].text)
# Своим ключом, а не общим с резолвером: одна тревога гасила бы вторую.
both = NodeState(0.1, 1, 4, 1, 30, 2, False, xray_alive=False)
check("две поломки — две тревоги", ["dns", "xray"], keys(evaluate(HEALTHY, both, T, NOW)))

print("== метрики портала ==")
from groxy_bot.portal import PortalMetrics  # noqa: E402


def portal(**kwargs):
    base = dict(
        name="nether",
        load1=0.1,
        cpu_count=1,
        mem_used=300_000_000,
        mem_total=1_000_000_000,
        disk_used=3_000_000_000,
        disk_total=10_000_000_000,
        conntrack_count=100,
        conntrack_max=65536,
        uptime=1000,
    )
    base.update(kwargs)
    return PortalMetrics(**base)


check("здоровый портал — тревог нет", [], keys(evaluate(HEALTHY, HEALTHY_NODE, T, NOW, portal())))
check(
    "conntrack у потолка",
    True,
    "portal_conntrack" in keys(evaluate(HEALTHY, HEALTHY_NODE, T, NOW, portal(conntrack_count=60000))),
)
check(
    "диск портала",
    True,
    "portal_disk" in keys(evaluate(HEALTHY, HEALTHY_NODE, T, NOW, portal(disk_used=9_500_000_000))),
)
# Ключи по порталу и по бриджу обязаны различаться: это разные поломки с
# разными действиями, и один ключ на двоих гасил бы вторую, пока держится первая.
both = evaluate(HEALTHY, full_disk, T, NOW, portal(disk_used=9_500_000_000))
check("диск бриджа и диск портала — две отдельные тревоги", ["disk", "portal_disk"], keys(both))

print("== reporter не установлен ==")
# До порталов руки доходят позже, чем до бриджа. Отсутствие метрик не повод
# для тревоги: молчание reporter'а видно в журнале, а не в Telegram.
check("наблюдение за бриджом продолжается", [], keys(evaluate(HEALTHY, HEALTHY_NODE, T, NOW, None)))


def make_state():
    db = sqlite3.connect(":memory:")
    db.row_factory = sqlite3.Row
    return AlertState(db)


print("== алерт не срабатывает сразу ==")
state = make_state()
cond = [Condition("disk", "Диск занят на 99%.")]
problems, recovered = state.reconcile(cond, T, NOW)
check("первое обнаружение молчит", ([], []), (problems, recovered))
problems, _ = state.reconcile(cond, T, NOW + T.settle_seconds - 1)
check("до выдержки всё ещё молчит", [], problems)
problems, _ = state.reconcile(cond, T, NOW + T.settle_seconds)
check("после выдержки сообщает", 1, len(problems))
check("текст с предупреждением", True, problems[0].startswith("⚠️"))

print("== о том же не сообщают дважды ==")
problems, _ = state.reconcile(cond, T, NOW + T.settle_seconds + 60)
check("повтора нет", [], problems)

print("== напоминание раз в сутки ==")
problems, _ = state.reconcile(cond, T, NOW + T.settle_seconds + T.remind_seconds)
check("через сутки напомнил", 1, len(problems))
check("сказано, что всё ещё", True, "Всё ещё" in problems[0])

print("== восстановление ==")
problems, recovered = state.reconcile([], T, NOW + T.settle_seconds + T.remind_seconds + 60)
check("сообщил о норме", 1, len(recovered))
check("текст про норму", True, recovered[0].startswith("✅"))
check("состояние очищено", [], list(state.active()))

print("== о невыстрелившем не сообщают, что оно в норме ==")
# Условие продержалось меньше выдержки и ушло. Человек о нём не знал, и
# «снова в норме» было бы сообщением ни о чём.
state = make_state()
state.reconcile(cond, T, NOW)
problems, recovered = state.reconcile([], T, NOW + 10)
check("молчание в обе стороны", ([], []), (problems, recovered))

print("== состояние переживает перезапуск ==")
db = sqlite3.connect(":memory:")
db.row_factory = sqlite3.Row
state = AlertState(db)
state.reconcile(cond, T, NOW)
state.reconcile(cond, T, NOW + T.settle_seconds)
# Новый объект поверх той же базы — это и есть перезапуск бота.
restarted = AlertState(db)
problems, _ = restarted.reconcile(cond, T, NOW + T.settle_seconds + 60)
check("после перезапуска не перевыпускает", [], problems)


class FakeApi:
    """Telegram, у которого один путь работает, а другой нет."""

    def __init__(self, working_device):
        self.working = working_device
        self.sent = []

    def send_via(self, chat_id, text, device):
        if device != self.working:
            raise net.TransportError("timed out", device)
        self.sent.append((chat_id, device, text))


print("== лестница доставки ==")
api = FakeApi(working_device="wg1")
d = Delivery(api=api, tunnel_device="wg1", chat_ids=frozenset({1}))
check("доставлено", True, d.send("тревога"))
check("ушло через туннель", "wg1", api.sent[0][1])
# Прямой путь пробуется первым, даже зная, что он закрыт: фильтр могут снять,
# и тогда алерты перестанут зависеть от туннеля, о падении которого сообщают.
check("прямой путь пробовался первым", 1, len(api.sent))

print("== смена пути замечена ==")
api = FakeApi(working_device=None)
d = Delivery(api=api, tunnel_device="wg1", chat_ids=frozenset({1}))
d.send("первая")
check("первая ушла напрямую", None, api.sent[0][1])
check("о смене пути не сообщено — сравнивать было не с чем", 1, len(api.sent))
api.working = "wg1"
d.send("вторая")
texts = [t for _, _, t in api.sent]
check("сообщено о смене пути", True, any("сменился" in t for t in texts))

print("== не доставлено ни одним путём ==")
api = FakeApi(working_device="ничего")
d = Delivery(api=api, tunnel_device="wg1", chat_ids=frozenset({1}))
check("честно возвращает False", False, d.send("тревога", attempts=1))

print("== повтор дожидается, пока туннель поднимется ==")
# Самое важное сообщение — «переключился на резервный портал» — рождается
# сразу после перезапуска туннеля, когда handshake ещё не сошёлся. Первая
# попытка там обречена, а второго шанса сообщению никто не даст: состояние
# переключения уже изменилось, и текст не повторится.


class LateApi(FakeApi):
    def __init__(self):
        super().__init__(working_device="wg1")
        self.calls = 0

    def send_via(self, chat_id, text, device):
        self.calls += 1
        if self.calls <= 2:
            raise net.TransportError("timed out", device)
        super().send_via(chat_id, text, device)


api = LateApi()
d = Delivery(api=api, tunnel_device="wg1", chat_ids=frozenset({1}))
check("со второй попытки дошло", True, d.send("переключился", attempts=3, pause=0))
check("сообщение отправлено ровно раз", 1, len(api.sent))

print("== отказ Telegram тоже роняет ступень, а не доставку ==")


class RefusingApi(FakeApi):
    def send_via(self, chat_id, text, device):
        if device is None:
            raise telegram.TelegramError("Bad Request", 400)
        self.sent.append((chat_id, device, text))


api = RefusingApi(working_device="wg1")
d = Delivery(api=api, tunnel_device="wg1", chat_ids=frozenset({1}))
check("перешли на следующую ступень", True, d.send("тревога"))

print()
print(f"прошло: {passed}, упало: {failed}")
sys.exit(1 if failed else 0)

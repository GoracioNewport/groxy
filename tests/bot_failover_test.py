#!/usr/bin/env python3
"""Контракт автопереключения. Запуск: python3 tests/bot_failover_test.py

Ни сети, ни узла: CLI и пробы подменены. Проверяется то, что дороже всего
ошибиться, — когда переключаться и когда не надо.
"""

import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bot"))

from groxy_bot.cli import CliError, PortalInfo, PortalLink, Snapshot  # noqa: E402
from groxy_bot.failover import Failover, FailoverPolicy  # noqa: E402

NOW = 1_800_000_000
POLICY = FailoverPolicy()

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


def snapshot(handshake, name="nether"):
    portal = (
        None
        if name is None
        else PortalLink(
            name=name,
            endpoint="194.150.220.208:61285",
            latest_handshake=handshake,
            rx=0,
            tx=0,
            tunnel_address="10.77.77.1",
        )
    )
    return Snapshot(generated_at=NOW, portal=portal, clients=())


class FakeGroxy:
    def __init__(self, portals=None, fail_switch=False):
        self.portals = portals if portals is not None else [
            PortalInfo("nether", True, "194.150.220.208", 61285, "10.77.77.1"),
            PortalInfo("sweden", False, "84.22.149.145", 65192, "10.77.77.1"),
        ]
        self.switched = []
        self.fail_switch = fail_switch

    def list_portals(self):
        return tuple(self.portals)

    def use_portal(self, name):
        if self.fail_switch:
            raise CliError("не вышло", 1, "")
        self.switched.append(name)


def make(groxy=None, alive=True, policy=POLICY):
    db = sqlite3.connect(":memory:")
    db.row_factory = sqlite3.Row
    f = Failover(db, groxy or FakeGroxy(), "wg1", policy)
    f.probe_public = staticmethod(lambda address, port=22: alive)
    f._standby = lambda ip: None
    return f


print("== здоровый портал ==")
f = make()
check("ничего не делаем", None, f.evaluate(snapshot(NOW - 30), NOW))

print("== моргнувший handshake не рвёт соединения ==")
# Первая неудачная проверка только засекает время. Переключаться по ней значит
# рвать зарубежный трафик тридцати шести людям из-за одной потерянной секунды.
f = make()
check("первый раз молчим", None, f.evaluate(snapshot(NOW - 400), NOW))
check("и второй, пока не выдержано", None, f.evaluate(snapshot(NOW - 500), NOW + 100))
check("переключения не было", [], f._groxy.switched)

print("== портал не отвечает достаточно долго ==")
groxy = FakeGroxy()
f = make(groxy)
f.evaluate(snapshot(NOW - 400), NOW)
message = f.evaluate(snapshot(NOW - 600), NOW + POLICY.switch_after_seconds)
check("переключились", ["sweden"], groxy.switched)
check("сообщено", True, message is not None and "sweden" in message)
check("названа причина", True, "не отвечал" in message)
# Возврат автоматом не делается: он стоит того же обрыва, а вынужденным не
# является.
check("сказано, что обратно сам не вернётся", True, "не вернусь" in message)

print("== выздоровление до выдержки отменяет переключение ==")
groxy = FakeGroxy()
f = make(groxy)
f.evaluate(snapshot(NOW - 400), NOW)
f.evaluate(snapshot(NOW - 10), NOW + 100)
f.evaluate(snapshot(NOW - 400), NOW + 200)
# Отсчёт пошёл заново, значит к NOW+200+выдержка ещё рано.
check("переключения не было", [], groxy.switched)

print("== второй раз подряд не мотаемся ==")
groxy = FakeGroxy()
f = make(groxy)
f.evaluate(snapshot(NOW - 400), NOW)
f.evaluate(snapshot(NOW - 600), NOW + POLICY.switch_after_seconds)
check("одно переключение", 1, len(groxy.switched))
later = NOW + POLICY.switch_after_seconds + 60
f.evaluate(snapshot(later - 400), later)
f.evaluate(snapshot(later - 600), later + POLICY.switch_after_seconds)
check("второго не случилось — держит пауза", 1, len(groxy.switched))

print("== переключаться некуда ==")
groxy = FakeGroxy(portals=[PortalInfo("nether", True, "194.150.220.208", 61285, "10.77.77.1")])
f = make(groxy)
f.evaluate(snapshot(NOW - 400), NOW)
message = f.evaluate(snapshot(NOW - 600), NOW + POLICY.switch_after_seconds)
check("сообщено об этом", True, message is not None and "некуда" in message)
# Повторять это каждую минуту — значит превратить в фон.
again = f.evaluate(snapshot(NOW - 700), NOW + POLICY.switch_after_seconds + 60)
check("но только один раз", None, again)

print("== запасной портал тоже лежит ==")
groxy = FakeGroxy()
f = make(groxy, alive=False)
f.evaluate(snapshot(NOW - 400), NOW)
message = f.evaluate(snapshot(NOW - 600), NOW + POLICY.switch_after_seconds)
check("не переключились на мёртвый", [], groxy.switched)
check("сообщено, что дело не в портале", True, message is not None and "не в портале" in message)

print("== переключение сорвалось ==")
groxy = FakeGroxy(fail_switch=True)
f = make(groxy)
f.evaluate(snapshot(NOW - 400), NOW)
message = f.evaluate(snapshot(NOW - 600), NOW + POLICY.switch_after_seconds)
check("сказано, что нужны руки", True, message is not None and "руки" in message)

print("== портала нет вовсе ==")
# Автопереключением это не лечится: непонятно, с чего переключать.
f = make()
check("молчим", None, f.evaluate(snapshot(NOW, name=None), NOW))

print("== прежний портал ожил ==")
groxy = FakeGroxy()
f = make(groxy)
f.evaluate(snapshot(NOW - 400), NOW)
f.evaluate(snapshot(NOW - 600), NOW + POLICY.switch_after_seconds)
after = NOW + POLICY.switch_after_seconds + 10
message = f.evaluate(snapshot(after - 10, name="sweden"), after)
check("предложено вернуться", True, message is not None and "снова отвечает" in message)
check("сказано про цену", True, "секунд обрыва" in message)
repeat = f.evaluate(snapshot(after - 5, name="sweden"), after + 60)
check("предложение не повторяется", None, repeat)

print("== ручное переключение ведёт себя как автоматическое ==")
# Иначе человек нажимает кнопку, а через пятнадцать минут получает тревогу о
# мёртвом боте от портала, с которого сам же ушёл.
groxy = FakeGroxy()
f = make(groxy)
warned = []
f._standby = lambda ip: warned.append(ip)
f.announce_manual_switch("sweden")
check("прежний портал предупреждён", ["10.77.77.1"], warned)
check("пауза от мотания взведена", True, f._int("last_switch_at") is not None)

print()
print(f"прошло: {passed}, упало: {failed}")
sys.exit(1 if failed else 0)

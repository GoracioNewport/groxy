#!/usr/bin/env python3
"""Контракт хранилища снимков. Запуск: python3 tests/bot_store_test.py

Без сторонних библиотек и без узла: база живёт во временном каталоге.
"""

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bot"))

from groxy_bot.store import NodeSample, PeerSample, Store  # noqa: E402

KEY_A = "AAAAbhlvc+RRzf7QW6OI5Mx/+upeuiHjQFRWEHHGN1E="
KEY_B = "BBBBbhlvc+RRzf7QW6OI5Mx/+upeuiHjQFRWEHHGN1E="

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


def peer(key, name, rx, tx, handshake=0):
    return PeerSample(
        public_key=key,
        name=name,
        address="10.66.66.2",
        endpoint=None,
        latest_handshake=handshake,
        rx=rx,
        tx=tx,
    )


EMPTY_NODE = NodeSample(None, None, None, None, None, None, None)


def totals_for(store, key):
    for row in store.totals():
        if row["public_key"] == key:
            return row
    return None


with tempfile.TemporaryDirectory() as tmp:
    db = Path(tmp) / "history.db"
    store = Store(db)

    print("== первая встреча профиля ==")
    store.record(1000, [peer(KEY_A, "alpha", 500, 700)], EMPTY_NODE)
    row = totals_for(store, KEY_A)
    # Интерфейс мог работать до первого запуска бота: обнулять сумму значило
    # бы выбросить весь трафик, накопленный до этого момента.
    check("сумма берёт текущее значение счётчика", 500, row["total_rx"])
    check("отдано тоже", 700, row["total_tx"])
    check("обнулений не было", 0, row["resets"])

    print("== обычный рост счётчика ==")
    store.record(1060, [peer(KEY_A, "alpha", 800, 900)], EMPTY_NODE)
    row = totals_for(store, KEY_A)
    check("к сумме прибавилась разность", 800, row["total_rx"])
    check("отдано", 900, row["total_tx"])
    check("обнулений по-прежнему нет", 0, row["resets"])

    print("== счётчик ядра обнулился ==")
    # Перезагрузка узла или подъём интерфейса. Разность была бы отрицательной,
    # и сумма за неделю просела бы ровно на весь трафик до перезагрузки.
    store.record(1120, [peer(KEY_A, "alpha", 30, 40)], EMPTY_NODE)
    row = totals_for(store, KEY_A)
    check("сумма не уменьшилась", 830, row["total_rx"])
    check("отдано не уменьшилось", 940, row["total_tx"])
    check("обнуление посчитано", 1, row["resets"])

    print("== рост после обнуления ==")
    store.record(1180, [peer(KEY_A, "alpha", 130, 140)], EMPTY_NODE)
    row = totals_for(store, KEY_A)
    check("считается от нового основания", 930, row["total_rx"])
    check("второго обнуления не насчитано", 1, row["resets"])

    print("== переименование не раздваивает историю ==")
    # Клиент опознаётся по ключу: имя меняется командой rename-client, и
    # привязка к имени дала бы две записи об одном человеке.
    store.record(1240, [peer(KEY_A, "alpha-new", 200, 200)], EMPTY_NODE)
    rows = [r for r in store.totals() if r["public_key"] == KEY_A]
    check("запись по-прежнему одна", 1, len(rows))
    check("имя обновилось на последнее известное", "alpha-new", rows[0]["name"])
    # 930 плюс разность 200 − 130: переименование не сбивает счёт и не
    # начинает сумму заново.
    check("сумма продолжила расти сквозь переименование", 1000, rows[0]["total_rx"])

    print("== снимки старше недели сносятся ==")
    store.record(2_000_000, [peer(KEY_B, "beta", 1, 1)], EMPTY_NODE)
    store.record(2_000_060, [peer(KEY_B, "beta", 2, 2)], EMPTY_NODE)
    total_before_prune = totals_for(store, KEY_A)["total_rx"]
    removed = store.prune(now=2_000_100)
    check("старые снимки удалены", 5, removed)
    check("свежие остались", 2, len(store.peer_history(KEY_B, since=0)))
    # Сумма — величина, которую обнулять нечем и незачем, ретеншн её не трогает.
    check(
        "суммы пережили уборку",
        total_before_prune,
        totals_for(store, KEY_A)["total_rx"],
    )

    print("== удаление профиля забывает сумму, но не историю ==")
    # Проверяется на KEY_B: его снимки свежие и уборку пережили, а значит
    # видно, что forget_peer их не трогает. На KEY_A это было бы незаметно —
    # его снимки к этому моменту снесены по сроку.
    store.forget_peer(KEY_B)
    check("суммы больше нет", None, totals_for(store, KEY_B))
    # Снимки остаются: в них профиль честно существовал, и вопросы о прошлом
    # они закрывают.
    check("снимки сохранены", 2, len(store.peer_history(KEY_B, since=0)))

    print("== повторный снимок за ту же секунду не ломает вставку ==")
    # Таймер может сработать дважды в одну секунду после подвисания.
    store.record(2_000_060, [peer(KEY_B, "beta", 3, 3)], EMPTY_NODE)
    check("дубля строк не появилось", 2, len(store.peer_history(KEY_B, since=0)))

    store.close()

print()
print(f"прошло: {passed}, упало: {failed}")
sys.exit(1 if failed else 0)

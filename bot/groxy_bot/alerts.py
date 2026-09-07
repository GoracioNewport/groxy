"""Правила алертов и их состояние.

Два решения определяют устройство модуля.

**Алерт срабатывает не сразу.** Условие обязано продержаться заданное время,
прежде чем о нём сообщат. Иначе всплеск нагрузки на десять секунд и моргнувший
handshake дают пару сообщений «сломалось / починилось», и через неделю их
перестают читать — а вместе с ними и настоящие.

**Состояние живёт в базе, а не в памяти.** Перезапуск бота не должен
перевыпускать все действующие алерты заново: после падения человек получил бы
десяток сообщений о том, что уже знает, и ни одного нового.

Молчание про клиентов сведено в один алерт, а не в тридцать шесть: профилей
много, они замолкают пачками после отпуска или смены телефона, и по сообщению
на каждого — это способ научить владельца не читать бота.
"""

from __future__ import annotations

import os
import sqlite3
import time
from dataclasses import dataclass

from .cli import Snapshot

SCHEMA = """
CREATE TABLE IF NOT EXISTS alerts (
    key         TEXT PRIMARY KEY,
    first_seen  INTEGER NOT NULL,
    notified_at INTEGER,
    detail      TEXT
);
"""


@dataclass(frozen=True)
class Thresholds:
    # Handshake с порталом. WireGuard с keepalive обновляет его каждые 25
    # секунд, так что пять минут — это уже не «редко ходит трафик».
    portal_handshake_seconds: int = 300
    disk_used_fraction: float = 0.85
    memory_used_fraction: float = 0.90
    # Нагрузка на ядро. Двойка — это очередь вдвое длиннее числа ядер, то
    # есть узел не справляется, а не «занят».
    load_per_cpu: float = 2.0
    client_silent_days: int = 30
    # Занятость таблицы соединений на портале. Через него идёт весь зарубежный
    # трафик парка, и упереться в потолок здесь реальнее, чем в процессор:
    # на nether ядро вывело из 960 МБ памяти значение 8192.
    conntrack_used_fraction: float = 0.80
    # Сколько условие должно продержаться, прежде чем о нём сообщат.
    settle_seconds: int = 180
    # Повтор о том, что всё ещё сломано. Раз в сутки: реже — забудется,
    # чаще — превратится в фон.
    remind_seconds: int = 86400

    @classmethod
    def from_env(cls) -> "Thresholds":
        def num(name: str, default):
            raw = os.environ.get(name)
            if raw is None:
                return default
            try:
                return type(default)(raw)
            except ValueError:
                return default

        return cls(
            portal_handshake_seconds=num("GROXY_ALERT_PORTAL_SECONDS", 300),
            disk_used_fraction=num("GROXY_ALERT_DISK", 0.85),
            memory_used_fraction=num("GROXY_ALERT_MEMORY", 0.90),
            load_per_cpu=num("GROXY_ALERT_LOAD", 2.0),
            client_silent_days=num("GROXY_ALERT_SILENT_DAYS", 30),
            conntrack_used_fraction=num("GROXY_ALERT_CONNTRACK", 0.80),
            settle_seconds=num("GROXY_ALERT_SETTLE", 180),
            remind_seconds=num("GROXY_ALERT_REMIND", 86400),
        )


@dataclass(frozen=True)
class Condition:
    key: str
    text: str


@dataclass(frozen=True)
class NodeState:
    """То, что известно об узле помимо снимка WireGuard."""

    load1: float | None
    mem_used: int | None
    mem_total: int | None
    disk_used: int | None
    disk_total: int | None
    cpu_count: int
    resolver_answers: bool


def evaluate(
    snapshot: Snapshot,
    node: NodeState,
    thresholds: Thresholds,
    now: int,
    portal: "PortalMetrics | None" = None,
) -> list[Condition]:
    """Что не в порядке прямо сейчас. Без учёта истории и без отправки.

    `portal=None` означает, что метрик портала нет — reporter не установлен
    или не ответил. Это не повод для тревоги сам по себе: наблюдение обязано
    работать и без него, потому что до порталов руки доходят позже, чем до
    бриджа. Молчание reporter'а видно в журнале, а не в Telegram.
    """
    found: list[Condition] = []

    if snapshot.portal is None:
        # Без портала зарубежный трафик не идёт никуда. Это не «деградация»,
        # а половина сервиса.
        found.append(Condition("portal_missing", "Активный портал не выбран."))
    else:
        age = now - snapshot.portal.latest_handshake if snapshot.portal.latest_handshake else None
        if age is None:
            found.append(
                Condition(
                    "portal_handshake",
                    f"С порталом {snapshot.portal.name} не было ни одного handshake.",
                )
            )
        elif age > thresholds.portal_handshake_seconds:
            found.append(
                Condition(
                    "portal_handshake",
                    f"Handshake с порталом {snapshot.portal.name} протух: "
                    f"{age // 60} мин. Зарубежный трафик, скорее всего, не идёт.",
                )
            )

    if not node.resolver_answers:
        found.append(
            Condition(
                "dns",
                "Резолвер на туннельном адресе не отвечает. У клиентов не "
                "работают имена — ни российские, ни зарубежные.",
            )
        )

    if node.disk_total and node.disk_used is not None:
        used = node.disk_used / node.disk_total
        if used > thresholds.disk_used_fraction:
            found.append(
                Condition("disk", f"Диск занят на {used * 100:.0f}%.")
            )

    if node.mem_total and node.mem_used is not None:
        used = node.mem_used / node.mem_total
        if used > thresholds.memory_used_fraction:
            found.append(
                Condition("memory", f"Память занята на {used * 100:.0f}%.")
            )

    if node.load1 is not None and node.cpu_count:
        per_cpu = node.load1 / node.cpu_count
        if per_cpu > thresholds.load_per_cpu:
            found.append(
                Condition(
                    "load",
                    f"Нагрузка {node.load1:.1f} на {node.cpu_count} ядра — "
                    f"узел не справляется.",
                )
            )

    if portal is not None:
        found.extend(_portal_conditions(portal, thresholds))

    silent_cutoff = now - thresholds.client_silent_days * 86400
    # «Ни разу не подключался» сюда не входит: это обычно свежий профиль,
    # который человеку ещё не поставили, а не потерянный доступ.
    silent = [
        c
        for c in snapshot.clients
        if c.latest_handshake and c.latest_handshake < silent_cutoff
    ]
    if silent:
        names = ", ".join(sorted(c.name for c in silent)[:5])
        more = f" и ещё {len(silent) - 5}" if len(silent) > 5 else ""
        found.append(
            Condition(
                "clients_silent",
                f"Профилей молчит больше {thresholds.client_silent_days} дней: "
                f"{len(silent)} — {names}{more}.",
            )
        )

    return found


def _portal_conditions(portal, thresholds: Thresholds) -> list[Condition]:
    """Тревоги по метрикам портала.

    Ключи с приставкой `portal_`, чтобы не смешаться с одноимёнными по бриджу:
    диск кончился на портале и диск кончился на бридже — разные поломки с
    разными действиями, и один ключ на двоих гасил бы вторую, пока держится
    первая.
    """
    found: list[Condition] = []

    if portal.conntrack_count is not None and portal.conntrack_max:
        used = portal.conntrack_count / portal.conntrack_max
        if used > thresholds.conntrack_used_fraction:
            found.append(
                Condition(
                    "portal_conntrack",
                    f"Портал {portal.name}: таблица соединений занята на "
                    f"{used * 100:.0f}% ({portal.conntrack_count} из "
                    f"{portal.conntrack_max}). Новые соединения начнут рваться.",
                )
            )

    if portal.disk_total and portal.disk_used is not None:
        used = portal.disk_used / portal.disk_total
        if used > thresholds.disk_used_fraction:
            found.append(
                Condition(
                    "portal_disk",
                    f"Портал {portal.name}: диск занят на {used * 100:.0f}%.",
                )
            )

    if portal.mem_total and portal.mem_used is not None:
        used = portal.mem_used / portal.mem_total
        if used > thresholds.memory_used_fraction:
            found.append(
                Condition(
                    "portal_memory",
                    f"Портал {portal.name}: память занята на {used * 100:.0f}%.",
                )
            )

    if portal.load1 is not None and portal.cpu_count:
        per_cpu = portal.load1 / portal.cpu_count
        if per_cpu > thresholds.load_per_cpu:
            found.append(
                Condition(
                    "portal_load",
                    f"Портал {portal.name}: нагрузка {portal.load1:.1f} "
                    f"на {portal.cpu_count} ядра.",
                )
            )

    return found


class AlertState:
    """Что уже сообщено и когда. Живёт в той же базе, что и снимки."""

    def __init__(self, db: sqlite3.Connection) -> None:
        self._db = db
        self._db.executescript(SCHEMA)

    def reconcile(
        self, conditions: list[Condition], thresholds: Thresholds, now: int
    ) -> tuple[list[str], list[str]]:
        """Сверяет найденное с уже известным.

        Возвращает две пачки готовых к отправке сообщений: о поломках и о
        восстановлении. Само ничего не отправляет — доставка отдельно, потому
        что она умеет отказывать и выбирать путь.
        """
        current = {c.key: c for c in conditions}
        known = {
            row["key"]: row
            for row in self._db.execute("SELECT * FROM alerts")
        }

        problems: list[str] = []
        recovered: list[str] = []

        for key, condition in current.items():
            row = known.get(key)
            if row is None:
                # Замечено впервые. Молчим, пока не продержится: всплеск на
                # десять секунд не повод будить человека.
                self._db.execute(
                    "INSERT INTO alerts (key, first_seen, notified_at, detail)"
                    " VALUES (?, ?, NULL, ?)",
                    (key, now, condition.text),
                )
                continue

            settled = now - row["first_seen"] >= thresholds.settle_seconds
            if row["notified_at"] is None:
                if settled:
                    problems.append(f"⚠️ {condition.text}")
                    self._db.execute(
                        "UPDATE alerts SET notified_at = ?, detail = ? WHERE key = ?",
                        (now, condition.text, key),
                    )
            elif now - row["notified_at"] >= thresholds.remind_seconds:
                since = (now - row["first_seen"]) // 3600
                problems.append(f"⚠️ Всё ещё, уже {since} ч: {condition.text}")
                self._db.execute(
                    "UPDATE alerts SET notified_at = ?, detail = ? WHERE key = ?",
                    (now, condition.text, key),
                )

        for key, row in known.items():
            if key in current:
                continue
            # О восстановлении сообщаем только если сообщали о поломке.
            # Иначе человек получил бы «снова в норме» о том, чего не видел.
            if row["notified_at"] is not None:
                recovered.append(f"✅ Снова в норме: {row['detail']}")
            self._db.execute("DELETE FROM alerts WHERE key = ?", (key,))

        return problems, recovered

    def active(self) -> list[sqlite3.Row]:
        return list(
            self._db.execute(
                "SELECT * FROM alerts WHERE notified_at IS NOT NULL ORDER BY first_seen"
            )
        )


def cpu_count() -> int:
    return os.cpu_count() or 1


def now_epoch() -> int:
    return int(time.time())

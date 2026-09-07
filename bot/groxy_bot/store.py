"""Хранилище снимков: sqlite на бридже, снимок раз в минуту, неделя истории.

Отвечает на вопрос «почему подвисло в 21:30» запросом к таблице. Графиков нет,
долгого хранения нет — на них ушёл бы Prometheus, от которого отказались.

Две вещи, ради которых модуль сложнее, чем «вставить строку».

Счётчики WireGuard живут в ядре и обнуляются при перезагрузке узла или подъёме
интерфейса. Разность двух соседних снимков после такого обнуления получилась бы
отрицательной, а сумма за неделю — заниженной ровно на весь трафик до
перезагрузки. Поэтому суммы копятся отдельно, поверх счётчиков.

Клиента опознаём по публичному ключу, а не по имени: имя меняется командой
`rename-client`, и история, привязанная к имени, при переименовании раздвоилась
бы. Имя хранится тоже, но как последнее известное.
"""

from __future__ import annotations

import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

RETENTION_DAYS = 7

SCHEMA = """
CREATE TABLE IF NOT EXISTS peer_samples (
    taken_at         INTEGER NOT NULL,
    public_key       TEXT    NOT NULL,
    name             TEXT    NOT NULL,
    address          TEXT,
    endpoint         TEXT,
    latest_handshake INTEGER NOT NULL,
    rx               INTEGER NOT NULL,
    tx               INTEGER NOT NULL,
    PRIMARY KEY (taken_at, public_key)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS peer_samples_by_key
    ON peer_samples (public_key, taken_at);

CREATE TABLE IF NOT EXISTS node_samples (
    taken_at   INTEGER PRIMARY KEY,
    load1      REAL,
    mem_used   INTEGER,
    mem_total  INTEGER,
    disk_used  INTEGER,
    disk_total INTEGER,
    portal     TEXT,
    portal_handshake INTEGER
);

-- Накопленные суммы поверх счётчиков ядра. last_rx/last_tx — значение из
-- прошлого снимка; если новое меньше, счётчик обнулился, и к сумме
-- прибавляется новое значение целиком, а не разность.
CREATE TABLE IF NOT EXISTS peer_totals (
    public_key TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    total_rx   INTEGER NOT NULL DEFAULT 0,
    total_tx   INTEGER NOT NULL DEFAULT 0,
    last_rx    INTEGER NOT NULL DEFAULT 0,
    last_tx    INTEGER NOT NULL DEFAULT 0,
    resets     INTEGER NOT NULL DEFAULT 0,
    first_seen INTEGER NOT NULL,
    last_seen  INTEGER NOT NULL
);
"""


@dataclass(frozen=True)
class PeerSample:
    public_key: str
    name: str
    address: str | None
    endpoint: str | None
    latest_handshake: int
    rx: int
    tx: int


@dataclass(frozen=True)
class NodeSample:
    load1: float | None
    mem_used: int | None
    mem_total: int | None
    disk_used: int | None
    disk_total: int | None
    portal: str | None
    portal_handshake: int | None


class Store:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        # Файл создаётся под umask, то есть обычно доступным на чтение всем.
        # В базе лежат endpoint'ы клиентов — адреса, с которых люди
        # подключались, — и объёмы их трафика. Секретов нет, но и класть это
        # под общий доступ незачем.
        #
        # Создаётся заранее, до connect: sqlite открыл бы файл сам, и между
        # созданием и chmod осталось бы окно.
        if not path.exists():
            path.touch(mode=0o600)
        else:
            path.chmod(0o600)
        # isolation_level=None — распоряжаемся транзакциями сами: снимок
        # пишется одной, иначе половина клиентов может оказаться записанной,
        # а половина нет, и разность на следующем шаге посчитается по дыре.
        self._db = sqlite3.connect(str(path), isolation_level=None)
        self._db.row_factory = sqlite3.Row
        # WAL: снимок пишется раз в минуту, а читают его команды бота в тот же
        # момент. Без WAL читатель блокирует писателя, и снимок пропускается.
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("PRAGMA synchronous=NORMAL")
        self._db.executescript(SCHEMA)

    def close(self) -> None:
        self._db.close()

    def record(
        self,
        taken_at: int,
        peers: Iterable[PeerSample],
        node: NodeSample,
    ) -> None:
        peers = list(peers)
        self._db.execute("BEGIN")
        try:
            self._db.executemany(
                """INSERT OR REPLACE INTO peer_samples
                   (taken_at, public_key, name, address, endpoint,
                    latest_handshake, rx, tx)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                [
                    (
                        taken_at,
                        p.public_key,
                        p.name,
                        p.address,
                        p.endpoint,
                        p.latest_handshake,
                        p.rx,
                        p.tx,
                    )
                    for p in peers
                ],
            )
            self._db.execute(
                """INSERT OR REPLACE INTO node_samples
                   (taken_at, load1, mem_used, mem_total, disk_used, disk_total,
                    portal, portal_handshake)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    taken_at,
                    node.load1,
                    node.mem_used,
                    node.mem_total,
                    node.disk_used,
                    node.disk_total,
                    node.portal,
                    node.portal_handshake,
                ),
            )
            for peer in peers:
                self._accumulate(taken_at, peer)
            self._db.execute("COMMIT")
        except Exception:
            self._db.execute("ROLLBACK")
            raise

    def _accumulate(self, taken_at: int, peer: PeerSample) -> None:
        row = self._db.execute(
            "SELECT total_rx, total_tx, last_rx, last_tx, resets"
            " FROM peer_totals WHERE public_key = ?",
            (peer.public_key,),
        ).fetchone()

        if row is None:
            # Первая встреча. Текущее значение счётчика ядра — уже накопленный
            # трафик: интерфейс мог работать до первого запуска бота, и
            # обнулять сумму значило бы потерять его.
            self._db.execute(
                """INSERT INTO peer_totals
                   (public_key, name, total_rx, total_tx, last_rx, last_tx,
                    resets, first_seen, last_seen)
                   VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)""",
                (
                    peer.public_key,
                    peer.name,
                    peer.rx,
                    peer.tx,
                    peer.rx,
                    peer.tx,
                    taken_at,
                    taken_at,
                ),
            )
            return

        # Счётчик ядра меньше прошлого — он обнулился: перезагрузка узла или
        # подъём интерфейса. Разность здесь была бы отрицательной, поэтому
        # прибавляется новое значение целиком.
        #
        # Проверяются rx и tx по отдельности: обнуляются они всегда вместе, но
        # трактовать пару как одно значит поверить, что снимок атомарен
        # относительно ядра. Он не атомарен.
        reset = peer.rx < row["last_rx"] or peer.tx < row["last_tx"]
        if reset:
            delta_rx, delta_tx = peer.rx, peer.tx
        else:
            delta_rx = peer.rx - row["last_rx"]
            delta_tx = peer.tx - row["last_tx"]

        self._db.execute(
            """UPDATE peer_totals
               SET name = ?, total_rx = ?, total_tx = ?, last_rx = ?,
                   last_tx = ?, resets = ?, last_seen = ?
               WHERE public_key = ?""",
            (
                peer.name,
                row["total_rx"] + delta_rx,
                row["total_tx"] + delta_tx,
                peer.rx,
                peer.tx,
                row["resets"] + (1 if reset else 0),
                taken_at,
                peer.public_key,
            ),
        )

    def prune(self, now: int | None = None) -> int:
        """Сносит снимки старше недели. Суммы в peer_totals не трогает.

        Разделение намеренное: история подробностей нужна на неделю, а сумма
        трафика по профилю — величина, которую обнулять нечем и незачем.
        """
        cutoff = (now if now is not None else int(time.time())) - RETENTION_DAYS * 86400
        cursor = self._db.execute("DELETE FROM peer_samples WHERE taken_at < ?", (cutoff,))
        removed = cursor.rowcount
        self._db.execute("DELETE FROM node_samples WHERE taken_at < ?", (cutoff,))
        return removed

    def forget_peer(self, public_key: str) -> None:
        """Убирает профиль из накопленных сумм после удаления клиента.

        Снимки остаются: они отвечают на вопросы о прошлом, и в них профиль
        честно существовал. А вот сумма живого профиля, оставшаяся от
        удалённого, при повторном заведении того же имени приписала бы новому
        клиенту чужой трафик — ключ-то будет уже другой, но имя то же, и в
        списках это выглядело бы одним человеком.
        """
        self._db.execute("DELETE FROM peer_totals WHERE public_key = ?", (public_key,))

    def totals(self) -> list[sqlite3.Row]:
        return list(
            self._db.execute(
                "SELECT * FROM peer_totals ORDER BY total_rx + total_tx DESC"
            )
        )

    def peer_history(self, public_key: str, since: int) -> list[sqlite3.Row]:
        return list(
            self._db.execute(
                "SELECT * FROM peer_samples WHERE public_key = ? AND taken_at >= ?"
                " ORDER BY taken_at",
                (public_key, since),
            )
        )

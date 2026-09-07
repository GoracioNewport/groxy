"""Автопереключение портала.

Логика живёт здесь, а действие — в CLI: переключает `groxy bridge use-portal`,
который берёт общую блокировку, перерендеривает `wg1.conf` и перезапускает
интерфейс. Бот только решает, когда его позвать.

Три решения определяют устройство.

**Переключение стоит всем клиентам нескольких секунд зарубежного трафика.**
Поэтому оно не происходит по одной неудачной проверке: портал должен быть
нездоров непрерывно заданное время. Моргнувший handshake — не повод рвать
соединения тридцати шести людям.

**Обратно автоматически не возвращаемся.** Переключение туда вынужденное,
возврат — нет, и второй обрыв человек должен получить в удобное ему время, а
не ночью. Бот сообщает, что основной портал ожил, и даёт кнопку.

**Живость проверяется двумя независимыми путями.** Возраст handshake говорит о
туннеле, проба на публичный адрес — об узле. Без второй пробы падение туннеля
неотличимо от падения узла, и бот мог бы переключиться на портал, который сам
лежит.
"""

from __future__ import annotations

import logging
import socket
import sqlite3
import time
from dataclasses import dataclass

from . import cli, net

log = logging.getLogger(__name__)

SCHEMA = """
CREATE TABLE IF NOT EXISTS failover (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""

# Порт для пробы, независимой от туннеля. sshd — единственная служба, которая
# на порталах есть всегда и отвечает на TCP. Это признак «узел жив», а не
# «туннель заработает»: последнее без переключения не проверить никак.
PROBE_PORT = 22
PROBE_TIMEOUT = 5.0

# Порт reporter'а на портале. Значение продублировано из модуля portal
# намеренно: импорт оттуда завёл бы круг, а число одно и меняется вместе.
PORTAL_REPORTER_PORT = 9101


@dataclass(frozen=True)
class FailoverPolicy:
    # Handshake старше этого — портал считается нездоровым. WireGuard с
    # keepalive обновляет его каждые 25 секунд.
    unhealthy_after_seconds: int = 180
    # Сколько держаться нездоровым, прежде чем переключаться.
    switch_after_seconds: int = 180
    # Не переключаться повторно раньше этого срока. Защита от мотания
    # туда-сюда, когда лежит не портал, а что-то общее.
    cooldown_seconds: int = 1800


class Failover:
    def __init__(
        self,
        db: sqlite3.Connection,
        groxy: cli.Groxy,
        device: str,
        policy: FailoverPolicy | None = None,
    ) -> None:
        self._db = db
        self._db.executescript(SCHEMA)
        self._groxy = groxy
        self._device = device
        self._policy = policy or FailoverPolicy()

    # -- состояние ----------------------------------------------------------

    def _get(self, key: str) -> str | None:
        row = self._db.execute(
            "SELECT value FROM failover WHERE key = ?", (key,)
        ).fetchone()
        return row["value"] if row else None

    def _set(self, key: str, value: str) -> None:
        self._db.execute(
            "INSERT OR REPLACE INTO failover (key, value) VALUES (?, ?)",
            (key, str(value)),
        )

    def _clear(self, key: str) -> None:
        self._db.execute("DELETE FROM failover WHERE key = ?", (key,))

    def _int(self, key: str) -> int | None:
        raw = self._get(key)
        if raw is None:
            return None
        try:
            return int(raw)
        except ValueError:
            return None

    # -- пробы --------------------------------------------------------------

    @staticmethod
    def probe_public(address: str, port: int = PROBE_PORT) -> bool:
        """Отвечает ли узел на публичном адресе, мимо туннеля.

        Соединение сразу закрывается: нам нужен только факт, что оно
        установилось. Отказ в соединении и таймаут одинаково означают
        «недоступен» — различать их незачем, действие одно.
        """
        try:
            with socket.create_connection((address, port), timeout=PROBE_TIMEOUT):
                return True
        except OSError:
            return False

    def _standby(self, tunnel_ip: str) -> None:
        """Просит портал больше не ждать пингов.

        Без этого watchdog прежнего активного портала через пятнадцать минут
        пришлёт «бот не отвечает» — пинги-то к нему больше не ходят. Попытка
        не обязана удаться: если портал лёг, сказать ему всё равно нечего, а
        текст тревоги про переключение предупреждает.
        """
        try:
            net.get_json(
                tunnel_ip, PORTAL_REPORTER_PORT, "/standby", device=self._device,
                timeout=PROBE_TIMEOUT,
            )
            log.info("портал %s переведён в режим ожидания", tunnel_ip)
        except net.TransportError as exc:
            log.info("не удалось предупредить портал %s: %s", tunnel_ip, exc)

    def announce_manual_switch(self, target: str) -> None:
        """Готовит состояние к переключению, сделанному человеком.

        Ручное переключение обязано вести себя как автоматическое во всём, что
        касается последствий: прежний портал надо предупредить, чтобы его
        watchdog не счёл бота умершим, и отсчёт «нездоров» сбросить. Иначе
        человек нажимает кнопку, а через пятнадцать минут получает тревогу о
        мёртвом боте от портала, с которого сам же ушёл.
        """
        try:
            portals = self._groxy.list_portals()
        except cli.CliError as exc:
            log.info("не удалось прочитать порталы перед ручным переключением: %s", exc)
            portals = ()
        current = next((p for p in portals if p.active), None)
        if current and current.tunnel_portal_ip and current.name != target:
            self._standby(current.tunnel_portal_ip)
            self._set("switched_from", current.name)
        self._set("last_switch_at", int(time.time()))
        self._clear("unhealthy_since")
        self._clear("return_offered")

    # -- решение ------------------------------------------------------------

    def evaluate(self, snapshot: cli.Snapshot, now: int) -> str | None:
        """Один круг. Возвращает текст для отправки владельцу, если есть что.

        Ничего не отправляет сама: доставка умеет отказывать и выбирать путь,
        и смешивать её с решением значило бы, что неудачная отправка меняет
        состояние переключения.
        """
        policy = self._policy

        if snapshot.portal is None:
            # Портал не выбран вовсе — это чинится руками, автопереключением
            # такое не лечится: непонятно, с чего переключать.
            return None

        age = now - snapshot.portal.latest_handshake if snapshot.portal.latest_handshake else None
        healthy = age is not None and age <= policy.unhealthy_after_seconds

        if healthy:
            if self._int("unhealthy_since") is not None:
                log.info("портал %s снова здоров", snapshot.portal.name)
                self._clear("unhealthy_since")
            return self._maybe_offer_return(snapshot, now)

        since = self._int("unhealthy_since")
        if since is None:
            self._set("unhealthy_since", now)
            log.info(
                "портал %s нездоров (handshake %s) — засекаю",
                snapshot.portal.name,
                "никогда" if age is None else f"{age} с",
            )
            return None

        if now - since < policy.switch_after_seconds:
            return None

        last_switch = self._int("last_switch_at")
        if last_switch is not None and now - last_switch < policy.cooldown_seconds:
            log.info(
                "переключение отложено: прошлое было %d мин назад",
                (now - last_switch) // 60,
            )
            return None

        return self._switch_away(snapshot, now, age)

    def _switch_away(
        self, snapshot: cli.Snapshot, now: int, age: int | None
    ) -> str | None:
        current = snapshot.portal.name if snapshot.portal else ""
        try:
            portals = self._groxy.list_portals()
        except cli.CliError as exc:
            log.error("не удалось прочитать список порталов: %s", exc)
            return None

        candidates = [p for p in portals if p.name != current and p.endpoint]
        if not candidates:
            # Сообщаем один раз: без запасного портала переключаться некуда, и
            # повторять это каждую минуту значит превратить в фон.
            if self._get("no_candidate_reported") != current:
                self._set("no_candidate_reported", current)
                return (
                    f"🚨 Портал {current} не отвечает, а переключиться некуда: "
                    f"второго зарегистрированного портала нет."
                )
            return None
        self._clear("no_candidate_reported")

        alive = [p for p in candidates if self.probe_public(p.endpoint)]
        if not alive:
            if self._get("no_alive_reported") != current:
                self._set("no_alive_reported", current)
                names = ", ".join(p.name for p in candidates)
                return (
                    f"🚨 Портал {current} не отвечает, и запасные тоже: {names}. "
                    f"Похоже, дело не в портале."
                )
            return None
        self._clear("no_alive_reported")

        target = alive[0]
        # Предупреждаем прежний портал до переключения, пока туннель до него
        # ещё может работать.
        if snapshot.portal and snapshot.portal.tunnel_address:
            self._standby(snapshot.portal.tunnel_address)

        log.warning("переключаюсь с %s на %s", current, target.name)
        try:
            self._groxy.use_portal(target.name)
        except cli.CliError as exc:
            log.error("переключение не удалось: %s", exc)
            return (
                f"🚨 Портал {current} не отвечает, а переключиться на "
                f"{target.name} не вышло: {exc}. Нужны руки."
            )

        self._set("last_switch_at", now)
        self._set("switched_from", current)
        self._clear("unhealthy_since")
        self._clear("return_offered")

        detail = "ни одного handshake" if age is None else f"handshake {age // 60} мин"
        return (
            f"⚠️ Переключился на резервный портал {target.name}.\n\n"
            f"Причина: {current} не отвечал — {detail}. Клиенты потеряли "
            f"зарубежный трафик на несколько секунд.\n\n"
            f"Обратно автоматически не вернусь: второй обрыв стоит того же, а "
            f"выбрать для него время лучше вам."
        )

    def _maybe_offer_return(self, snapshot: cli.Snapshot, now: int) -> str | None:
        """Сообщает, что прежний портал ожил, — один раз.

        Возврат не делается сам: он стоит клиентам такого же обрыва, как уход,
        и вынужденным не является.
        """
        previous = self._get("switched_from")
        if not previous or self._get("return_offered") == previous:
            return None

        try:
            portals = self._groxy.list_portals()
        except cli.CliError:
            return None
        match = next((p for p in portals if p.name == previous), None)
        if match is None or not match.endpoint:
            return None
        if not self.probe_public(match.endpoint):
            return None

        self._set("return_offered", previous)
        return (
            f"ℹ️ Прежний портал {previous} снова отвечает.\n\n"
            f"Сейчас работает {snapshot.portal.name if snapshot.portal else '?'}. "
            f"Вернуться можно кнопкой в меню — это ещё несколько секунд обрыва "
            f"у всех, поэтому выберите время."
        )


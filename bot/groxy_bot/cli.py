"""Единственное место, где бот вызывает groxy.

Логика живёт в CLI, а не здесь: CLI вызывается человеком напрямую в любой
момент, поэтому блокировка и идемпотентность обязаны быть именно там, иначе
ручной запуск обойдёт защиту бота. Этот модуль — только вызов и разбор.

Между ботом и CLI нет сети, поэтому нет и класса отказов «команда выполнилась,
а ответ не дошёл». Есть другой: команда выполнилась, а бот умер до отправки
ответа в Telegram. Его закрывает не этот модуль, а идемпотентность самих
команд.
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
from dataclasses import dataclass
from typing import Any

# Коды возврата groxy, объявленные в lib/common.sh. Числа, а не текст ошибки:
# текст меняется, код — контракт.
EXIT_EXISTS = 10  # имя уже занято
EXIT_BUSY = 11  # другая операция держит блокировку

# Бот работает под своим пользователем, а CLI требует root: файлы пиров лежат
# с правами 600, а `wg show` без root ничего не показывает. Правило в sudoers
# узкое, только на перечисленные подкоманды `groxy bridge`.
SUDO = "/usr/bin/sudo"

DEFAULT_TIMEOUT = 60.0


class CliError(Exception):
    """Команда не выполнилась. Код возврата и stderr разнесены нарочно."""

    def __init__(self, message: str, returncode: int, stderr: str) -> None:
        super().__init__(message)
        self.returncode = returncode
        self.stderr = stderr

    @property
    def name_taken(self) -> bool:
        return self.returncode == EXIT_EXISTS

    @property
    def busy(self) -> bool:
        return self.returncode == EXIT_BUSY


@dataclass(frozen=True)
class Client:
    name: str
    address: str
    public_key: str
    endpoint: str | None
    latest_handshake: int  # эпоха; 0 — ни разу
    rx: int
    tx: int


@dataclass(frozen=True)
class PortalLink:
    name: str
    endpoint: str | None
    latest_handshake: int
    rx: int
    tx: int


@dataclass(frozen=True)
class Snapshot:
    generated_at: int
    portal: PortalLink | None
    clients: tuple[Client, ...]


class Groxy:
    def __init__(self, binary: str, timeout: float = DEFAULT_TIMEOUT) -> None:
        self._binary = binary
        self._timeout = timeout

    @staticmethod
    def _prefix() -> list[str]:
        """Через sudo — только когда мы не root.

        Безусловный sudo тащил бы зависимость туда, где её не нужно: на узле,
        где снимок запускает systemd от root, sudo может быть не установлен
        вовсе — проверено на moscow-25000-01. А в обычном случае, когда бот
        работает под groxy-bot, префикс на месте.

        Решение принимается по фактическому uid, а не по настройке: настройка
        разошлась бы с тем, кто на самом деле запустил процесс, и разошлась бы
        молча.
        """
        return [] if os.geteuid() == 0 else [SUDO, "-n"]

    def _run(self, args: list[str]) -> str:
        argv = [*self._prefix(), self._binary, "bridge", *args]
        try:
            done = subprocess.run(
                argv,
                capture_output=True,
                text=True,
                timeout=self._timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            # Таймаут — не «не сработало». Команда могла успеть сделать своё
            # дело; повторять её вслепую нельзя, и вызывающий должен об этом
            # узнать отдельным сообщением, а не увидеть обычную ошибку.
            raise CliError(
                f"команда не ответила за {self._timeout:.0f} с — состояние неизвестно",
                returncode=-1,
                stderr="",
            ) from exc
        except OSError as exc:
            # Программу не удалось запустить вовсе: нет sudo, нет самого
            # groxy, не хватает прав на файл. Без этой ветки наружу вылетал
            # голый FileNotFoundError со стеком на пол-экрана — проверено на
            # узле без установленного sudo. Вызывающий ждёт CliError и обязан
            # его получить, чтобы отличить «не запустилось» от «упало».
            raise CliError(
                f"не удалось запустить {argv[0]}: {exc.strerror or exc}",
                returncode=-2,
                stderr="",
            ) from exc

        if done.returncode != 0:
            # stderr сохраняется целиком: там log() из groxy с причиной. В Telegram
            # он не уходит — вызывающий решает, что показать человеку.
            raise CliError(
                f"groxy bridge {' '.join(args)} вернул {done.returncode}",
                returncode=done.returncode,
                stderr=done.stderr.strip(),
            )
        return done.stdout

    @staticmethod
    def _parse_json(raw: str, what: str) -> Any:
        try:
            return json.loads(raw)
        except ValueError as exc:
            raise CliError(
                f"{what}: ответ CLI не разобрался как JSON ({len(raw)} байт)",
                returncode=0,
                stderr="",
            ) from exc

    def stats(self, name: str | None = None) -> Snapshot:
        args = ["stats", "--json"] if name is None else ["stats", name, "--json"]
        data = self._parse_json(self._run(args), "stats")

        portal_raw = data.get("portal")
        portal = None
        if portal_raw:
            portal = PortalLink(
                name=portal_raw["name"],
                endpoint=portal_raw.get("endpoint"),
                latest_handshake=int(portal_raw.get("latest_handshake", 0)),
                rx=int(portal_raw.get("rx", 0)),
                tx=int(portal_raw.get("tx", 0)),
            )

        clients = tuple(
            Client(
                name=item["name"],
                address=item["address"],
                public_key=item["public_key"],
                endpoint=item.get("endpoint"),
                latest_handshake=int(item.get("latest_handshake", 0)),
                rx=int(item.get("rx", 0)),
                tx=int(item.get("tx", 0)),
            )
            for item in data.get("clients", [])
        )
        return Snapshot(
            generated_at=int(data["generated_at"]), portal=portal, clients=clients
        )

    def add_client(self, name: str) -> tuple[str, str]:
        """Создаёт профиль. Возвращает адрес и готовый конфиг клиента.

        Приватный ключ существует ровно здесь и больше нигде: узел его
        генерирует, отдаёт один раз и забывает. Поэтому конфиг возвращается
        значением, а не пишется в файл, и вызывающий обязан отправить его и не
        сохранять.
        """
        data = self._parse_json(self._run(["add-client", name, "--json"]), "add-client")
        config = base64.b64decode(data["config_b64"]).decode("utf-8")
        return data["address"], config

    def remove_client(self, name: str) -> None:
        self._run(["remove-client", name, "--yes"])

    def rename_client(self, old: str, new: str) -> None:
        self._run(["rename-client", old, new])

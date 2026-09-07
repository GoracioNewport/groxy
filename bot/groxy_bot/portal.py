"""Чтение метрик активного портала через служебный туннель.

Адрес портала приходит из `groxy bridge stats --json`, а не из чтения
`/etc/groxy` напрямую. Первая версия читала файлы состояния сама и молча ничего
не находила: каталог `bridge/` имеет права 700 — в нём приватный ключ
интерфейса, — и бот под своим пользователем туда просто не входит. Отказ
выглядел как «портал не настроен», то есть как исправная работа.

Это тот же принцип, что и во всём остальном: состояние читает CLI, у бота нет
второго пути к нему.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass

from . import net
from .cli import PortalLink

log = logging.getLogger(__name__)

REPORTER_PORT = int(os.environ.get("GROXY_REPORTER_PORT", "9101"))


@dataclass(frozen=True)
class PortalMetrics:
    name: str
    load1: float | None
    cpu_count: int
    mem_used: int | None
    mem_total: int | None
    disk_used: int | None
    disk_total: int | None
    conntrack_count: int | None
    conntrack_max: int | None
    uptime: int | None


def ping(address: str, device: str, timeout: float = 5.0) -> bool:
    """Отмечается на портале как живой.

    Это половина watchdog'а: портал ждёт отметку и кричит в Telegram, если она
    перестала приходить. Бот сам о своей смерти сообщить не может — он и есть
    единственный канал наружу с бриджа.

    Неудача не поднимается наверх: пинг — побочная обязанность, и ронять из-за
    него чтение метрик значило бы, что упавший watchdog уносит с собой ещё и
    наблюдение за порталом.
    """
    try:
        net.get_json(address, REPORTER_PORT, "/ping", device=device, timeout=timeout)
        return True
    except net.TransportError as exc:
        log.info("пинг до портала не прошёл: %s", exc)
        return False


def fetch(
    link: PortalLink | None, device: str, timeout: float = 8.0
) -> PortalMetrics | None:
    """Метрики активного портала, или None, если не ответил.

    Запрос уходит с привязкой к устройству туннеля. Иначе он не уйдёт вовсе:
    адрес `wg1` на бридже — это /32, маршрута на подсеть туннеля нет, и пакет
    к порталу отправился бы в основную таблицу через WAN. Проверено на живом
    узле.

    None — не ошибка и не молчание: reporter может быть просто не установлен,
    и наблюдение обязано работать и без него, потому что установлен он будет
    не раньше, чем до портала дойдут руки.
    """
    if link is None:
        log.info("метрики портала не читаем: активный портал не выбран")
        return None
    if not link.tunnel_address:
        # Молчать здесь нельзя. Именно так выглядела прошлая поломка: бот не
        # мог прочитать состояние сам, адрес приходил пустым, и наблюдение за
        # порталом просто не происходило — без единой строки в журнале.
        log.info(
            "метрики портала не читаем: CLI не отдал адрес портала в туннеле"
        )
        return None

    ping(link.tunnel_address, device)

    try:
        data = net.get_json(
            link.tunnel_address,
            REPORTER_PORT,
            "/metrics",
            device=device,
            timeout=timeout,
        )
    except net.TransportError as exc:
        log.info("портал %s не отдал метрики: %s", link.name, exc)
        return None

    def num(key: str):
        value = data.get(key)
        return value if isinstance(value, (int, float)) else None

    return PortalMetrics(
        name=link.name,
        load1=num("load1"),
        cpu_count=int(data.get("cpu_count") or 1),
        mem_used=num("mem_used"),
        mem_total=num("mem_total"),
        disk_used=num("disk_used"),
        disk_total=num("disk_total"),
        conntrack_count=num("conntrack_count"),
        conntrack_max=num("conntrack_max"),
        uptime=num("uptime"),
    )

"""Чтение метрик активного портала через служебный туннель.

Адрес портала внутри туннеля берётся из состояния groxy — того же файла
`portal.env`, по которому собран `wg1`. Зашивать 10.77.77.1 значило бы завести
второй источник правды о том, где портал.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from pathlib import Path

from . import net

log = logging.getLogger(__name__)

GROXY_DIR = Path(os.environ.get("GROXY_DIR", "/etc/groxy"))
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


def _read_env_field(path: Path, key: str) -> str | None:
    """Достаёт одно поле KEY=VALUE, не исполняя файл.

    То же решение, что и в CLI: peer- и portal-файлы — это состояние, а не
    код, и `source` над ними однажды дал бы им переопределять переменные
    читающего.
    """
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            name, sep, value = line.partition("=")
            if sep and name.strip() == key:
                return value.strip()
    except OSError:
        return None
    return None


def active_portal_address() -> tuple[str, str] | None:
    """Имя активного портала и его адрес внутри туннеля."""
    try:
        name = (GROXY_DIR / "bridge" / "current-portal").read_text().strip()
    except OSError:
        return None
    if not name:
        return None
    env = GROXY_DIR / "bridge" / "portals" / name / "portal.env"
    address = _read_env_field(env, "TUNNEL_PORTAL_IP")
    if not address:
        return None
    return name, address


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


def fetch(device: str, timeout: float = 8.0) -> PortalMetrics | None:
    """Метрики активного портала, или None, если не ответил.

    Запрос уходит с привязкой к устройству туннеля. Иначе он не уйдёт вовсе:
    адрес `wg1` на бридже — это /32, маршрута на подсеть туннеля нет, и пакет
    к порталу отправился бы в основную таблицу через WAN. Проверено на живом
    узле.

    None — не ошибка и не молчание: reporter может быть просто не установлен,
    и наблюдение обязано работать и без него, потому что установлен он будет
    не раньше, чем до портала дойдут руки.
    """
    found = active_portal_address()
    if found is None:
        return None
    name, address = found

    try:
        data = net.get_json(
            address, REPORTER_PORT, "/metrics", device=device, timeout=timeout
        )
    except net.TransportError as exc:
        log.info("портал %s не отдал метрики: %s", name, exc)
        return None

    def num(key: str):
        value = data.get(key)
        return value if isinstance(value, (int, float)) else None

    ping(address, device)

    return PortalMetrics(
        name=name,
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

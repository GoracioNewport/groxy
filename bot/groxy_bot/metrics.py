"""Метрики самого узла: нагрузка, память, диск.

Читаются напрямую из /proc и statvfs, а не через groxy. Правило «логика живёт в
CLI» появилось из-за блокировки и идемпотентности изменяющих команд — здесь
ничего не меняется, и заводить ради `cat /proc/meminfo` подкоманду означало бы
обряд без содержания.

Ни одно чтение не обязано удаться: на другом ядре или в контейнере файла может
не быть. Отсутствующая метрика становится None и доезжает до базы как NULL —
снимок без памяти полезнее отсутствующего снимка.
"""

from __future__ import annotations

import os
from pathlib import Path

PROC = Path(os.environ.get("GROXY_BOT_PROC", "/proc"))


def load1() -> float | None:
    """Средняя нагрузка за минуту."""
    try:
        first = (PROC / "loadavg").read_text().split()[0]
        return float(first)
    except (OSError, ValueError, IndexError):
        return None


def memory() -> tuple[int | None, int | None]:
    """Занято и всего, в байтах.

    Занятым считается total − available, а не total − free. MemFree на узле с
    работающим кэшем показывает единицы процентов и вечно выглядит как
    «память кончается»; MemAvailable — оценка ядра, сколько реально можно
    занять без свопа, то есть ровно то, о чём стоит присылать алерт.
    """
    values: dict[str, int] = {}
    try:
        for line in (PROC / "meminfo").read_text().splitlines():
            key, _, rest = line.partition(":")
            if key in ("MemTotal", "MemAvailable"):
                try:
                    values[key] = int(rest.split()[0]) * 1024
                except (ValueError, IndexError):
                    pass
    except OSError:
        return None, None

    total = values.get("MemTotal")
    available = values.get("MemAvailable")
    if total is None or available is None:
        return None, total
    return total - available, total


def disk(path: str = "/") -> tuple[int | None, int | None]:
    """Занято и всего на разделе, в байтах.

    Занятое считается как total − free, а не через used-блоки: под пользователя
    резервируется часть раздела, и «свободно» для root и для всех остальных —
    разные числа. Алерт нужен по тому, что видит обычный процесс.
    """
    try:
        st = os.statvfs(path)
    except OSError:
        return None, None
    total = st.f_blocks * st.f_frsize
    free = st.f_bavail * st.f_frsize
    return total - free, total

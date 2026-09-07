"""Проверки, для которых мало прочитать состояние — нужно спросить систему.

Каждая отвечает «работает или нет» и никогда не поднимает исключение наружу:
проверка, уронившая наблюдателя, хуже отсутствующей.
"""

from __future__ import annotations

import os
import socket
import struct
import subprocess

# Куда стучаться, чтобы проверить резолвер клиентов. Это адрес бриджа внутри
# wg0 — тот самый, который прописан клиентам в поле DNS.
DEFAULT_RESOLVER = os.environ.get("GROXY_BOT_RESOLVER", "10.66.66.1")

# Имя, которым проверяем резолвер. Российское и заведомо живое: зарубежное
# ходило бы через портал, и проверка резолвера заодно проверяла бы туннель,
# то есть при падении туннеля кричала бы про DNS.
PROBE_NAME = os.environ.get("GROXY_BOT_PROBE_NAME", "ya.ru")


def _dns_query(name: str) -> bytes:
    """Собирает минимальный DNS-запрос типа A. Без библиотек.

    Идентификатор случайный: резолвер вправе отбросить повтор с тем же id как
    дубликат, и фиксированное значение превратило бы вторую проверку подряд в
    ложную тревогу.
    """
    ident = int.from_bytes(os.urandom(2), "big")
    header = struct.pack(">HHHHHH", ident, 0x0100, 1, 0, 0, 0)
    question = b"".join(
        bytes([len(part)]) + part.encode("ascii") for part in name.split(".")
    )
    return header + question + b"\x00" + struct.pack(">HH", 1, 1)


def resolver_answers(
    address: str = DEFAULT_RESOLVER, name: str = PROBE_NAME, timeout: float = 3.0
) -> bool:
    """Отвечает ли dnsmasq на туннельном адресе.

    Это проверка сквозная, а не осмотр сокетов: `ss` без root не покажет, чей
    сокет, а `systemctl is-active dnsmasq` соврёт ровно в том случае, ради
    которого проверка и нужна — демон жив, но не слушает на wg0. Такое здесь
    уже случалось, из-за гонки при подъёме интерфейса.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.settimeout(timeout)
        sock.sendto(_dns_query(name), (address, 53))
        data, _ = sock.recvfrom(512)
    except OSError:
        return False
    finally:
        sock.close()

    if len(data) < 12:
        return False
    # Младшие четыре бита второго флагового байта — RCODE. Ненулевой означает
    # отказ: демон жив и отвечает, но резолвить не может, и это тоже поломка.
    return (data[3] & 0x0F) == 0


def xray_classifier_state(enabled: str, unit: str = "groxy-xray") -> bool | None:
    """Работает ли классификатор, или None, если он выключен настройкой.

    Различать обязательно. Выключенный классификатор — это норма: узел
    классифицирует по меткам, как делал всегда. Включённый и неработающий —
    это остановка всего TCP и UDP клиентов, и молчать об этом нельзя.

    Состояние переключателя приходит аргументом из снимка CLI, а не читается
    здесь из /etc/groxy. Первая версия читала файл сама и всегда получала
    отказ: каталог bridge/ имеет права 700, бот туда не входит, — а выглядело
    это как «выключен», то есть как норма. Та же ошибка уже была с адресом
    портала, и правило то же: состояние читает CLI.
    """
    if enabled != "on":
        return None
    return service_active(unit)


def service_active(unit: str) -> bool:
    """`systemctl is-active` — работает и без root."""
    try:
        done = subprocess.run(
            ["systemctl", "is-active", "--quiet", unit],
            capture_output=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return done.returncode == 0

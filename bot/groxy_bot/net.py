"""Исходящие HTTPS-запросы бота, с выбором пути наружу.

Бридж не видит Telegram напрямую: ICMP до `api.telegram.org` проходит, TCP на
443 молча тонет — адресная фильтрация у провайдера. Поэтому каждый запрос
должен уметь сказать, каким путём он идёт.

Путь выбирается привязкой сокета к устройству (`SO_BINDTODEVICE`), а не
адресом источника и не пометкой пакета. Замеры на боевом бридже 07.09
(ядро 6.1, Debian 12), под непривилегированным пользователем:

    напрямую              таймаут
    SO_MARK=0x1           EPERM — нужен CAP_NET_ADMIN
    SO_BINDTODEVICE=wg1   302 от Telegram
    привязка к 10.77.77.2 таймаут

Привязка к адресу задаёт источник, но не маршрут: пакет уходит по основной
таблице и упирается в тот же фильтр. Метка сработала бы, но требует
capability, а главное — она уводит через портал ВЕСЬ трафик процесса, и тогда
первая ступень доставки алертов, попытка уйти напрямую, становится
недостижимой. Выбор устройства делается на каждом сокете отдельно, поэтому
лестница остаётся выполнимой.

Непривилегированный `SO_BINDTODEVICE` разрешён с ядра 5.7; на более старом
ядре конструктор соединения поднимет `PermissionError`, и это лучше молчаливой
неудачи.
"""

from __future__ import annotations

import http.client
import json
import socket
import ssl
from typing import Any

# Никакого «попробовать ещё раз через минуту» внутри: повторами и лестницей
# путей заведует вызывающий, который один знает, идёт ли речь об алерте или об
# ответе на нажатие кнопки.
DEFAULT_TIMEOUT = 20.0


class TransportError(Exception):
    """Запрос не ушёл или ответ не разобрался. Несёт путь, которым шли."""

    def __init__(self, message: str, device: str | None) -> None:
        super().__init__(message)
        self.device = device


def _bound_socket(host: str, port: int, device: str | None, timeout: float | None):
    """Сокет, привязанный к устройству и уже соединённый.

    Штатный `http.client` умеет `source_address`, то есть привязку к адресу, —
    именно то, что здесь не работает. Отсюда собственный сокет.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        if isinstance(timeout, (int, float)):
            sock.settimeout(timeout)
        if device:
            # bytes, не str: ядро ждёт имя устройства как есть.
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, device.encode())
        sock.connect((host, port))
    except OSError:
        sock.close()
        raise
    return sock


class _BoundHTTPConnection(http.client.HTTPConnection):
    """HTTP без TLS, привязанный к устройству.

    Нужен для reporter'а на портале: он слушает внутри служебного туннеля, и
    TLS там был бы обрядом — попасть на этот адрес может только тот, у кого
    уже есть ключ от туннеля.

    Привязка обязательна и по другой причине, чем у Telegram. Адрес `wg1` на
    бридже — это /32, маршрута на подсеть туннеля нет, и пакет к 10.77.77.1
    уходит в основную таблицу через WAN и умирает там. Проверено на живом
    узле. Альтернатива — добавить маршрут в шаблон wg1, но это перезапуск
    интерфейса и окно обслуживания ради одного чтения метрик.
    """

    def __init__(self, host: str, device: str | None = None, **kwargs: Any) -> None:
        super().__init__(host, **kwargs)
        self._device = device

    def connect(self) -> None:
        self.sock = _bound_socket(self.host, self.port, self._device, self.timeout)


class _BoundHTTPSConnection(http.client.HTTPSConnection):
    """HTTPS-соединение, привязанное к сетевому устройству."""

    def __init__(self, host: str, device: str | None = None, **kwargs: Any) -> None:
        super().__init__(host, **kwargs)
        self._device = device

    def connect(self) -> None:
        sock = _bound_socket(self.host, self.port, self._device, self.timeout)
        try:
            # server_hostname обязателен: на привязанном сокете имя хоста
            # ниоткуда больше не берётся, а без него TLS соединится и с чужим
            # сертификатом.
            self.sock = self._context.wrap_socket(sock, server_hostname=self.host)
        except OSError:
            sock.close()
            raise


def post_json(
    host: str,
    path: str,
    payload: dict[str, Any],
    *,
    device: str | None = None,
    timeout: float = DEFAULT_TIMEOUT,
) -> dict[str, Any]:
    """POST с телом JSON, ответ разбирается как JSON.

    `device=None` означает «напрямую, как ляжет маршрут». Любая сетевая
    неудача и любой неразобранный ответ приходят как `TransportError` —
    вызывающему не приходится ловить полдюжины разных типов, чтобы решить,
    пробовать ли следующий путь.
    """
    body = json.dumps(payload).encode()
    conn = _BoundHTTPSConnection(
        host,
        device=device,
        timeout=timeout,
        context=ssl.create_default_context(),
    )
    try:
        conn.request(
            "POST",
            path,
            body=body,
            headers={"Content-Type": "application/json", "Content-Length": str(len(body))},
        )
        response = conn.getresponse()
        raw = response.read()
    except OSError as exc:
        raise TransportError(f"{type(exc).__name__}: {exc}", device) from exc
    finally:
        conn.close()

    try:
        parsed = json.loads(raw)
    except ValueError as exc:
        # Тело в текст ошибки не кладём: у Telegram в ответе может оказаться
        # токен, если запрос был составлен неудачно, а текст ошибки уедет
        # в лог и в само сообщение алерта.
        raise TransportError(
            f"ответ не разобрался как JSON (HTTP {response.status}, {len(raw)} байт)",
            device,
        ) from exc

    if not isinstance(parsed, dict):
        raise TransportError(f"ожидался объект JSON, пришло {type(parsed).__name__}", device)
    return parsed


def get_json(
    host: str,
    port: int,
    path: str,
    *,
    device: str | None = None,
    timeout: float = 10.0,
) -> dict[str, Any]:
    """GET по обычному HTTP, ответ разбирается как JSON.

    Отдельно от post_json, потому что адресат другой по существу: reporter на
    портале внутри туннеля, без TLS и без токена. Смешивать их в одной функции
    с флагом значило бы, что однажды запрос к Telegram уйдёт без шифрования.
    """
    conn = _BoundHTTPConnection(host, device=device, port=port, timeout=timeout)
    try:
        conn.request("GET", path)
        response = conn.getresponse()
        raw = response.read()
        status = response.status
    except OSError as exc:
        raise TransportError(f"{type(exc).__name__}: {exc}", device) from exc
    finally:
        conn.close()

    if status != 200:
        raise TransportError(f"HTTP {status} от {host}:{port}{path}", device)

    try:
        parsed = json.loads(raw)
    except ValueError as exc:
        raise TransportError(
            f"ответ не разобрался как JSON ({len(raw)} байт)", device
        ) from exc
    if not isinstance(parsed, dict):
        raise TransportError(f"ожидался объект JSON, пришло {type(parsed).__name__}", device)
    return parsed

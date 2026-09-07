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


class _BoundHTTPSConnection(http.client.HTTPSConnection):
    """HTTPS-соединение, привязанное к сетевому устройству.

    Штатный `http.client` умеет `source_address`, то есть привязку к адресу, —
    именно то, что здесь не работает. Поэтому переопределяется `connect`:
    сокет создаётся вручную, на него ставится `SO_BINDTODEVICE`, и только
    потом идёт TLS.
    """

    def __init__(self, host: str, device: str | None = None, **kwargs: Any) -> None:
        super().__init__(host, **kwargs)
        self._device = device

    def connect(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            if isinstance(self.timeout, (int, float)):
                sock.settimeout(self.timeout)
            if self._device:
                # bytes, не str: ядро ждёт имя устройства как есть.
                sock.setsockopt(
                    socket.SOL_SOCKET, socket.SO_BINDTODEVICE, self._device.encode()
                )
            sock.connect((self.host, self.port))
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

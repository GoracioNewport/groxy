"""Тексты и клавиатуры. Ни сети, ни вызовов CLI — чистые функции.

Разделение не ради красоты: так вид сообщений проверяется набором тестов без
узла, без Telegram и без токена. Отдельно это стоит того, потому что именно в
текстах живут решения, которые легко испортить незаметно, — например, что
«выдать конфиг» означает перевыпуск, а старое устройство при этом отваливается.
"""

from __future__ import annotations

import time
from typing import Sequence

from .cli import Client, Snapshot

# Возраст handshake, после которого клиент считается офлайн. WireGuard шлёт
# keepalive раз в 25 секунд, так что три минуты — это не «давно не заходил», а
# «связи нет прямо сейчас».
ONLINE_WITHIN_SECONDS = 180


def human_bytes(value: int) -> str:
    step = 1024.0
    amount = float(value)
    for unit in ("Б", "КиБ", "МиБ", "ГиБ", "ТиБ"):
        if amount < step or unit == "ТиБ":
            return f"{amount:.0f} {unit}" if unit == "Б" else f"{amount:.1f} {unit}"
        amount /= step
    return f"{amount:.1f} ТиБ"


def human_age(epoch: int, now: int | None = None) -> str:
    """«3 мин назад» для прошедшего момента. Ноль — «никогда»."""
    if not epoch:
        return "никогда"
    delta = (now if now is not None else int(time.time())) - epoch
    if delta < 0:
        # Часы узла могли перевестись назад. «Только что» честнее, чем
        # отрицательный возраст, и не заставляет читателя гадать.
        return "только что"
    if delta < 60:
        return f"{delta} с назад"
    if delta < 3600:
        return f"{delta // 60} мин назад"
    if delta < 86400:
        return f"{delta // 3600} ч назад"
    return f"{delta // 86400} дн назад"


def is_online(client: Client, now: int | None = None) -> bool:
    if not client.latest_handshake:
        return False
    moment = now if now is not None else int(time.time())
    return moment - client.latest_handshake <= ONLINE_WITHIN_SECONDS


def clients_list(snapshot: Snapshot, now: int | None = None) -> str:
    moment = now if now is not None else int(time.time())
    online = [c for c in snapshot.clients if is_online(c, moment)]

    lines = [f"Профилей: {len(snapshot.clients)}, на связи: {len(online)}"]

    if snapshot.portal:
        lines.append(
            f"Портал {snapshot.portal.name}: "
            f"{human_age(snapshot.portal.latest_handshake, moment)}"
        )
    else:
        # Отсутствие портала — не мелочь оформления: без него зарубежный
        # трафик никуда не идёт, и молчать об этом нельзя.
        lines.append("Портал: не выбран")

    return "\n".join(lines)


def client_card(client: Client, now: int | None = None) -> str:
    moment = now if now is not None else int(time.time())
    status = "на связи" if is_online(client, moment) else "офлайн"
    lines = [
        f"{client.name} — {status}",
        f"Адрес: {client.address}",
        f"Handshake: {human_age(client.latest_handshake, moment)}",
        f"Принято: {human_bytes(client.rx)}, отдано: {human_bytes(client.tx)}",
    ]
    if client.endpoint:
        lines.append(f"Подключение с: {client.endpoint}")
    return "\n".join(lines)


def summary(snapshot: Snapshot, now: int | None = None) -> str:
    moment = now if now is not None else int(time.time())
    total_rx = sum(c.rx for c in snapshot.clients)
    total_tx = sum(c.tx for c in snapshot.clients)
    online = [c for c in snapshot.clients if is_online(c, moment)]
    # «Ни разу» и «давно» — разные вещи: первое обычно значит, что человеку
    # выдали конфиг и он его не поставил, второе — что перестал пользоваться.
    never = [c for c in snapshot.clients if not c.latest_handshake]

    lines = [
        f"Профилей: {len(snapshot.clients)}",
        f"На связи сейчас: {len(online)}",
        f"Ни разу не подключались: {len(never)}",
        f"Трафик с последней перезагрузки: {human_bytes(total_rx)} принято, "
        f"{human_bytes(total_tx)} отдано",
    ]
    if snapshot.portal:
        lines.append(
            f"Портал {snapshot.portal.name}: "
            f"{human_age(snapshot.portal.latest_handshake, moment)}, "
            f"{human_bytes(snapshot.portal.rx)} / {human_bytes(snapshot.portal.tx)}"
        )
    return "\n".join(lines)


# -- клавиатуры -------------------------------------------------------------
#
# callback_data ограничен 64 байтами, и имя профиля туда влезает не всегда:
# validate_peer_name разрешает до 63 символов. Поэтому в кнопку кладётся
# порядковый номер в списке, а не имя, — а список бот перечитывает на каждое
# нажатие. Иначе длинное имя обрезалось бы, и кнопка «удалить» указала бы на
# соседа.


def main_menu() -> list[list[dict[str, str]]]:
    return [
        [
            {"text": "Профили", "callback_data": "list"},
            {"text": "Сводка", "callback_data": "summary"},
        ],
        [
            {"text": "Тревоги", "callback_data": "alerts"},
            {"text": "Порталы", "callback_data": "portals"},
        ],
        [{"text": "Добавить профиль", "callback_data": "add"}],
    ]


def portals_text(portals: Sequence) -> str:
    if not portals:
        return "Порталов не зарегистрировано."
    lines = ["Порталы:", ""]
    for item in portals:
        mark = "▶" if item.active else " "
        lines.append(f"{mark} {item.name} — {item.endpoint or 'адрес неизвестен'}")
    lines.append("")
    # Цена названа до нажатия, а не после: переключение рвёт зарубежный трафик
    # у всех, и человек должен знать это, глядя на кнопку.
    lines.append(
        "Переключение перезапускает туннель — все клиенты теряют зарубежный "
        "трафик на несколько секунд."
    )
    return "\n".join(lines)


def portals_keyboard(portals: Sequence) -> list[list[dict[str, str]]]:
    rows: list[list[dict[str, str]]] = []
    for index, item in enumerate(portals):
        if item.active:
            continue
        rows.append(
            [{"text": f"Перейти на {item.name}", "callback_data": f"portal:{index}"}]
        )
    rows.append([{"text": "← Назад", "callback_data": "menu"}])
    return rows


def portal_confirm_keyboard(index: int) -> list[list[dict[str, str]]]:
    return [
        [{"text": "Да, переключить", "callback_data": f"portal!:{index}"}],
        [{"text": "Отмена", "callback_data": "portals"}],
    ]


def alerts_text(rows: Sequence, now: int | None = None) -> str:
    """Действующие тревоги.

    Пустой список — это содержательный ответ, а не отсутствие ответа: человек
    спросил именно затем, чтобы узнать, всё ли тихо.
    """
    if not rows:
        return "Действующих тревог нет."
    moment = now if now is not None else int(time.time())
    lines = [f"Действующих тревог: {len(rows)}", ""]
    for row in rows:
        lines.append(f"⚠️ {row['detail']}")
        lines.append(f"   с {human_age(row['first_seen'], moment)}")
    return "\n".join(lines)


def clients_keyboard(clients: Sequence[Client], now: int | None = None) -> list[list[dict[str, str]]]:
    moment = now if now is not None else int(time.time())
    rows: list[list[dict[str, str]]] = []
    for index, client in enumerate(clients):
        mark = "•" if is_online(client, moment) else "◦"
        rows.append(
            [{"text": f"{mark} {client.name}", "callback_data": f"peer:{index}"}]
        )
    rows.append([{"text": "← Назад", "callback_data": "menu"}])
    return rows


def client_keyboard(index: int) -> list[list[dict[str, str]]]:
    return [
        [
            {"text": "Перевыпустить конфиг", "callback_data": f"reissue:{index}"},
            {"text": "Переименовать", "callback_data": f"rename:{index}"},
        ],
        [{"text": "Удалить", "callback_data": f"rm:{index}"}],
        [{"text": "← К списку", "callback_data": "list"}],
    ]


def confirm_keyboard(action: str, index: int) -> list[list[dict[str, str]]]:
    """Второе нажатие для опасного действия.

    Отдельным экраном, а не всплывающим вопросом: удаление профиля и
    перевыпуск конфига необратимы — приватный ключ не хранится нигде, и
    отменить их нечем. Нажатие мимо в списке из тридцати шести строк стоит
    человеку доступа.
    """
    return [
        [{"text": "Да, точно", "callback_data": f"{action}!:{index}"}],
        [{"text": "Отмена", "callback_data": f"peer:{index}"}],
    ]


CONFIRM_TEXTS = {
    "rm": (
        "Удалить профиль «{name}»?\n\n"
        "Устройство потеряет доступ сразу. Вернуть тот же конфиг нельзя — "
        "приватный ключ не хранится ни здесь, ни на узле."
    ),
    "reissue": (
        "Перевыпустить конфиг для «{name}»?\n\n"
        "Это выдача нового ключа: старое устройство отвалится и потребует "
        "нового конфига. Показать существующий невозможно — приватный ключ "
        "отдаётся один раз и нигде не хранится."
    ),
}

"""Минимальный клиент Bot API: длинное опрашивание, отправка, кнопки.

Библиотеки нет намеренно — на боевом узле не хочется ни venv, ни пакета с
автообновлениями, а выкат остаётся одним `git pull`, тем же, что и у CLI.
Взамен здесь ровно то, что нужно: `getUpdates`, `sendMessage`, `editMessageText`,
`answerCallbackQuery`, `sendDocument`.

Webhook не используется: он потребовал бы входящего доступа снаружи к бриджу и
сертификата, тогда как опрашивание уходит тем же путём, что и всё остальное.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Any, Iterator

from . import net

API_HOST = "api.telegram.org"

# Telegram держит соединение открытым до истечения таймаута, если обновлений
# нет. Тридцать секунд — обычная величина; сетевой таймаут обязан быть заметно
# больше, иначе каждое пустое ожидание выглядело бы обрывом.
LONG_POLL_SECONDS = 30
_NET_TIMEOUT = LONG_POLL_SECONDS + 15

log = logging.getLogger(__name__)


class TelegramError(Exception):
    """Telegram ответил, но отказом. Несёт код и описание."""

    def __init__(self, description: str, error_code: int | None) -> None:
        super().__init__(description)
        self.description = description
        self.error_code = error_code

    @property
    def unauthorized(self) -> bool:
        """Токен не принят. Повторять бессмысленно, надо чинить руками."""
        return self.error_code == 401


@dataclass(frozen=True)
class Update:
    update_id: int
    chat_id: int | None
    user_id: int | None
    text: str | None
    callback_data: str | None
    callback_id: str | None
    message_id: int | None


class Telegram:
    def __init__(self, token: str, device: str | None) -> None:
        self._token = token
        # Устройство для выхода наружу. None означает «как ляжет маршрут»;
        # на боевом бридже прямой путь к Telegram закрыт провайдером, поэтому
        # здесь стоит туннель. См. модуль net.
        self._device = device
        self._offset = 0

    def _call(self, method: str, payload: dict[str, Any]) -> Any:
        path = f"/bot{self._token}/{method}"
        # Токен внутри пути. В текст ошибки путь не попадает никогда — иначе
        # первый же сбой сети записал бы токен в журнал.
        body = net.post_json(
            API_HOST, path, payload, device=self._device, timeout=_NET_TIMEOUT
        )
        if not body.get("ok"):
            raise TelegramError(
                str(body.get("description", "без описания")),
                body.get("error_code"),
            )
        return body.get("result")

    def get_me(self) -> str:
        """Проверяет токен и возвращает @имя бота.

        Вызывается один раз при старте. Без этого негодный токен обнаружился бы
        только на первом опрашивании, вперемешку с сетевыми обрывами, и в
        журнале выглядел бы как проблема связи. Заодно это первая проверка
        того, что выбранный путь наружу вообще работает.
        """
        result = self._call("getMe", {})
        return str(result.get("username", "?"))

    # -- приём ---------------------------------------------------------------

    def poll(self) -> Iterator[Update]:
        """Одно длинное опрашивание. Отдаёт разобранные обновления.

        Смещение двигается только по факту разбора: подтвердить обновление
        раньше, чем оно обработано, значит потерять его при падении бота.
        Telegram считает подтверждёнными все обновления до offset, и вернуть
        их назад нельзя.
        """
        result = self._call(
            "getUpdates",
            {
                "offset": self._offset,
                "timeout": LONG_POLL_SECONDS,
                # Остальные типы боту не нужны, а лишние обновления пришлось
                # бы отбрасывать уже после доставки.
                "allowed_updates": ["message", "callback_query"],
            },
        )
        for raw in result or []:
            update = _parse_update(raw)
            self._offset = max(self._offset, update.update_id + 1)
            yield update

    def drop_pending(self) -> None:
        """Отбрасывает обновления, накопившиеся, пока бот лежал.

        Вызывается один раз при старте. Иначе после часа простоя бот разом
        исполнит очередь нажатий, которые человек давно передумал делать, —
        а среди них может оказаться удаление профиля.
        """
        result = self._call("getUpdates", {"offset": -1, "timeout": 0})
        for raw in result or []:
            self._offset = max(self._offset, int(raw["update_id"]) + 1)

    # -- отправка ------------------------------------------------------------

    def send(
        self,
        chat_id: int,
        text: str,
        *,
        keyboard: list[list[dict[str, str]]] | None = None,
    ) -> int:
        payload: dict[str, Any] = {"chat_id": chat_id, "text": text}
        if keyboard is not None:
            payload["reply_markup"] = json.dumps({"inline_keyboard": keyboard})
        result = self._call("sendMessage", payload)
        return int(result["message_id"])

    def edit(
        self,
        chat_id: int,
        message_id: int,
        text: str,
        *,
        keyboard: list[list[dict[str, str]]] | None = None,
    ) -> None:
        payload: dict[str, Any] = {
            "chat_id": chat_id,
            "message_id": message_id,
            "text": text,
        }
        if keyboard is not None:
            payload["reply_markup"] = json.dumps({"inline_keyboard": keyboard})
        try:
            self._call("editMessageText", payload)
        except TelegramError as exc:
            # «Сообщение не изменилось» — не ошибка: так отвечает Telegram,
            # когда человек нажал кнопку, ничего не меняющую. Ронять из-за
            # этого обработчик значило бы оставить нажатие без ответа.
            if "message is not modified" not in exc.description:
                raise

    def answer_callback(self, callback_id: str, text: str = "") -> None:
        """Гасит «часики» на кнопке. Без этого Telegram крутит их 30 секунд."""
        self._call("answerCallbackQuery", {"callback_query_id": callback_id, "text": text})


def _parse_update(raw: dict[str, Any]) -> Update:
    update_id = int(raw["update_id"])

    message = raw.get("message")
    if message:
        return Update(
            update_id=update_id,
            chat_id=_dig(message, "chat", "id"),
            user_id=_dig(message, "from", "id"),
            text=message.get("text"),
            callback_data=None,
            callback_id=None,
            message_id=message.get("message_id"),
        )

    callback = raw.get("callback_query")
    if callback:
        return Update(
            update_id=update_id,
            chat_id=_dig(callback, "message", "chat", "id"),
            user_id=_dig(callback, "from", "id"),
            text=None,
            callback_data=callback.get("data"),
            callback_id=callback.get("id"),
            message_id=_dig(callback, "message", "message_id"),
        )

    # Тип, который не просили. Обновление всё равно возвращается, чтобы
    # смещение сдвинулось и оно не приходило снова.
    return Update(update_id, None, None, None, None, None, None)


def _dig(source: dict[str, Any], *keys: str) -> Any:
    """Достаёт вложенное поле, отдавая None вместо исключения.

    Разбор идёт по данным из сети: недостающее поле — обычное дело, а не
    повод уронить цикл опрашивания и остаться без бота до перезапуска.
    """
    current: Any = source
    for key in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current

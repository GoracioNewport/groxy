"""Доставка алертов: лестница путей и отдельный крик о деградации самой доставки.

Порядок попыток — сначала напрямую, потом через туннель. Сегодня прямой путь на
боевом бридже закрыт фильтром провайдера и не сработает, и всё же он остаётся
первой ступенью: фильтр могут снять, и тогда алерты перестанут зависеть от
туннеля, о падении которого как раз и сообщают. Проверять это дешевле, чем
однажды обнаружить, что кричать было нечем.

Переход на запасной путь — сам по себе повод сообщить, и сообщение уходит уже
по живому пути. Иначе деградация доставки остаётся незамеченной ровно до
момента, когда доставки не станет вовсе.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

from . import net, telegram

log = logging.getLogger(__name__)


@dataclass
class Delivery:
    api: telegram.Telegram
    tunnel_device: str
    chat_ids: frozenset[int]

    # Каким путём ушло прошлое сообщение. Нужно, чтобы заметить смену пути:
    # без памяти о прошлом «ушли на запасной» пришлось бы слать при каждой
    # отправке, а это фон, а не сигнал.
    _last_path: str | None = None

    def send(self, text: str) -> bool:
        """Отправляет всем допущенным. True, если хоть кому-то дошло."""
        delivered = False
        for chat_id in sorted(self.chat_ids):
            if self._send_one(chat_id, text):
                delivered = True
        if not delivered:
            # Единственный случай, когда сказать некому. Пишем в журнал —
            # его прочитают, когда придут разбираться, почему тихо.
            log.error("алерт не доставлен ни одним путём: %s", text)
        return delivered

    def _send_one(self, chat_id: int, text: str) -> bool:
        # Кортеж, а не словарь: порядок здесь и есть смысл.
        ladder: tuple[tuple[str, str | None], ...] = (
            ("напрямую", None),
            (f"через {self.tunnel_device}", self.tunnel_device),
        )

        for label, device in ladder:
            try:
                self.api.send_via(chat_id, text, device)
            except (net.TransportError, telegram.TelegramError) as exc:
                log.info("путь «%s» не сработал: %s", label, exc)
                continue

            self._note_path(label, chat_id)
            return True
        return False

    def _note_path(self, label: str, chat_id: int) -> None:
        if self._last_path == label:
            return
        previous, self._last_path = self._last_path, label
        if previous is None:
            # Первая отправка за жизнь процесса. Сообщать «путь сменился»
            # не о чем — сравнивать не с чем.
            log.info("алерты уходят %s", label)
            return
        log.warning("путь доставки сменился: %s → %s", previous, label)
        try:
            # Уходит уже по новому, живому пути — тому самому, которым только
            # что удалось отправить.
            self.api.send_via(
                chat_id,
                f"ℹ️ Путь доставки алертов сменился: было «{previous}», "
                f"стало «{label}».",
                self.tunnel_device if label != "напрямую" else None,
            )
        except (net.TransportError, telegram.TelegramError):
            # Сообщение о смене пути — не то, ради чего стоит ронять доставку
            # самого алерта. Он уже ушёл.
            log.info("сообщить о смене пути не удалось")

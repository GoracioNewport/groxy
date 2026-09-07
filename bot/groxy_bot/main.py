"""Цикл бота: длинное опрашивание, разбор нажатий, вызовы CLI.

Устройство простое нарочно. Один поток, никакой очереди, никакого состояния на
диске: всё, что бот помнит между сообщениями, — это на каком шаге стоит диалог
у каждого допущенного чата. Потерять это при перезапуске не страшно, а хранить
значило бы, что после падения бот доделает действие, о котором человек уже
забыл.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass

from . import cli, config, net, telegram, ui

log = logging.getLogger("groxy-bot")

# Пауза после сетевой неудачи. Растёт до потолка, чтобы упавшая связь не
# превращалась в поток запросов, но и не уходила в получасовые паузы: бот —
# единственный способ узнать, что на узле что-то не так.
RETRY_MIN_SECONDS = 5
RETRY_MAX_SECONDS = 120


@dataclass
class Pending:
    """Чего бот ждёт от человека текстом."""

    action: str  # 'add' или 'rename'
    target: str | None = None  # имя профиля для 'rename'


class Bot:
    def __init__(self, cfg: config.Config) -> None:
        self._cfg = cfg
        self._api = telegram.Telegram(cfg.token, cfg.tunnel_device)
        self._groxy = cli.Groxy(cfg.groxy_bin)
        self._pending: dict[int, Pending] = {}
        # Список профилей, показанный в последний раз этому чату. Кнопки несут
        # порядковый номер, а не имя: в callback_data 64 байта, а имя бывает
        # до 63 символов, и длинное просто не влезло бы вместе с действием.
        self._shown: dict[int, list[cli.Client]] = {}

    # -- вход ---------------------------------------------------------------

    def run(self) -> None:
        name = self._api.get_me()
        log.info("бот @%s, токен %s", name, self._cfg.redacted_token())
        log.info("допущено chat_id: %s", sorted(self._cfg.allowed_chat_ids))

        # Очередь, накопившаяся пока бот лежал, отбрасывается: иначе после
        # часа простоя он разом исполнит нажатия, которые человек давно
        # передумал делать, а среди них может быть удаление профиля.
        self._api.drop_pending()

        delay = RETRY_MIN_SECONDS
        while True:
            try:
                for update in self._api.poll():
                    self._dispatch(update)
                delay = RETRY_MIN_SECONDS
            except telegram.TelegramError as exc:
                if exc.unauthorized:
                    # Токен не примут и через минуту. Выходим с ошибкой, пусть
                    # systemd покажет это в журнале как отказ, а не крутит
                    # вечную петлю с одинаковой строкой.
                    log.error("Telegram не принял токен: %s", exc.description)
                    raise SystemExit(3)
                log.warning("Telegram отказал: %s", exc.description)
                time.sleep(delay)
                delay = min(delay * 2, RETRY_MAX_SECONDS)
            except net.TransportError as exc:
                log.warning("сеть (через %s): %s", exc.device or "напрямую", exc)
                time.sleep(delay)
                delay = min(delay * 2, RETRY_MAX_SECONDS)

    # -- разбор -------------------------------------------------------------

    def _dispatch(self, update: telegram.Update) -> None:
        if update.chat_id is None:
            return

        # Проверяются оба: chat_id — куда отвечать, user_id — кто нажал. В
        # группе они разные, и сверять только chat_id значило бы пускать любого
        # участника чата, куда бота однажды добавили.
        allowed = self._cfg.allowed_chat_ids
        if update.chat_id not in allowed or (
            update.user_id is not None and update.user_id not in allowed
        ):
            log.warning(
                "отказано: chat_id=%s user_id=%s", update.chat_id, update.user_id
            )
            # Молча, без ответа. Ответ подтвердил бы постороннему, что бот
            # живой и чей-то.
            if update.callback_id:
                self._api.answer_callback(update.callback_id)
            return

        try:
            if update.callback_data is not None:
                self._on_callback(update)
            elif update.text is not None:
                self._on_text(update)
        except cli.CliError as exc:
            log.error("CLI: %s (stderr: %s)", exc, exc.stderr)
            self._api.send(update.chat_id, self._explain(exc))
        except Exception:
            # Ошибка в обработке одного нажатия не должна ронять бота: он
            # единственный канал, по которому вообще что-то видно.
            log.exception("необработанная ошибка")
            self._api.send(update.chat_id, "Что-то сломалось. Подробности в журнале узла.")

    @staticmethod
    def _explain(exc: cli.CliError) -> str:
        if exc.name_taken:
            return "Имя уже занято. Возьмите другое."
        if exc.busy:
            return "Узел занят другой операцией. Повторите через несколько секунд."
        if exc.returncode == -1:
            # Таймаут: команда могла успеть сделать своё дело. Предлагать
            # «повторите» здесь нельзя — повтор создания профиля с тем же
            # именем упрётся в занятое имя, а повтор удаления сработает.
            return (
                "Команда не ответила вовремя. Что успело произойти — неизвестно; "
                "посмотрите список профилей, прежде чем повторять."
            )
        return "Команда не выполнилась. Подробности в журнале узла."

    # -- нажатия ------------------------------------------------------------

    def _on_callback(self, update: telegram.Update) -> None:
        chat_id = update.chat_id
        assert chat_id is not None
        data = update.callback_data or ""
        if update.callback_id:
            self._api.answer_callback(update.callback_id)

        action, _, argument = data.partition(":")

        if action == "menu":
            self._show_menu(chat_id, update.message_id)
        elif action == "list":
            self._show_list(chat_id, update.message_id)
        elif action == "summary":
            self._show_summary(chat_id, update.message_id)
        elif action == "add":
            self._pending[chat_id] = Pending("add")
            self._api.send(chat_id, "Пришлите имя профиля. Буквы, цифры, дефис, точка.")
        elif action == "peer":
            self._show_client(chat_id, update.message_id, argument)
        elif action in ("rm", "reissue"):
            self._ask_confirm(chat_id, update.message_id, action, argument)
        elif action == "rm!":
            self._do_remove(chat_id, argument)
        elif action == "reissue!":
            self._do_reissue(chat_id, argument)
        elif action == "rename":
            client = self._client_at(chat_id, argument)
            if client is None:
                self._show_list(chat_id, update.message_id)
                return
            self._pending[chat_id] = Pending("rename", client.name)
            self._api.send(chat_id, f"Новое имя для «{client.name}»?")

    def _on_text(self, update: telegram.Update) -> None:
        chat_id = update.chat_id
        assert chat_id is not None
        text = (update.text or "").strip()

        if text.startswith("/"):
            # Команда отменяет незаконченный диалог: человек передумал и
            # набрал что-то другое, и подставлять его слова в прошлый вопрос
            # значило бы создать профиль с именем «/summary».
            self._pending.pop(chat_id, None)
            self._on_command(chat_id, text)
            return

        pending = self._pending.pop(chat_id, None)
        if pending is None:
            self._show_menu(chat_id, None)
            return

        if pending.action == "add":
            self._do_add(chat_id, text)
        elif pending.action == "rename" and pending.target:
            self._groxy.rename_client(pending.target, text)
            self._api.send(chat_id, f"«{pending.target}» теперь «{text}».")
            self._show_list(chat_id, None)

    def _on_command(self, chat_id: int, text: str) -> None:
        command = text.split()[0].lstrip("/").split("@")[0]
        if command in ("start", "menu", "help"):
            self._show_menu(chat_id, None)
        elif command in ("list", "clients"):
            self._show_list(chat_id, None)
        elif command in ("stat", "summary"):
            self._show_summary(chat_id, None)
        elif command == "add":
            parts = text.split(maxsplit=1)
            if len(parts) == 2:
                self._do_add(chat_id, parts[1].strip())
            else:
                self._pending[chat_id] = Pending("add")
                self._api.send(chat_id, "Пришлите имя профиля.")
        else:
            self._show_menu(chat_id, None)

    # -- экраны -------------------------------------------------------------

    def _show_menu(self, chat_id: int, message_id: int | None) -> None:
        text = "groxy — управление профилями"
        if message_id is None:
            self._api.send(chat_id, text, keyboard=ui.main_menu())
        else:
            self._api.edit(chat_id, message_id, text, keyboard=ui.main_menu())

    def _show_list(self, chat_id: int, message_id: int | None) -> None:
        snapshot = self._groxy.stats()
        self._shown[chat_id] = list(snapshot.clients)
        text = ui.clients_list(snapshot)
        keyboard = ui.clients_keyboard(snapshot.clients)
        if message_id is None:
            self._api.send(chat_id, text, keyboard=keyboard)
        else:
            self._api.edit(chat_id, message_id, text, keyboard=keyboard)

    def _show_summary(self, chat_id: int, message_id: int | None) -> None:
        snapshot = self._groxy.stats()
        text = ui.summary(snapshot)
        keyboard = ui.main_menu()
        if message_id is None:
            self._api.send(chat_id, text, keyboard=keyboard)
        else:
            self._api.edit(chat_id, message_id, text, keyboard=keyboard)

    def _show_client(self, chat_id: int, message_id: int | None, argument: str) -> None:
        client = self._client_at(chat_id, argument)
        if client is None:
            self._show_list(chat_id, message_id)
            return
        # Карточка рисуется по свежему чтению, а не по списку из памяти:
        # между показом списка и нажатием проходят минуты, и handshake за это
        # время устаревает.
        snapshot = self._groxy.stats(client.name)
        fresh = snapshot.clients[0] if snapshot.clients else client
        index = int(argument)
        text = ui.client_card(fresh)
        keyboard = ui.client_keyboard(index)
        if message_id is None:
            self._api.send(chat_id, text, keyboard=keyboard)
        else:
            self._api.edit(chat_id, message_id, text, keyboard=keyboard)

    def _ask_confirm(
        self, chat_id: int, message_id: int | None, action: str, argument: str
    ) -> None:
        client = self._client_at(chat_id, argument)
        if client is None:
            self._show_list(chat_id, message_id)
            return
        text = ui.CONFIRM_TEXTS[action].format(name=client.name)
        keyboard = ui.confirm_keyboard(action, int(argument))
        if message_id is None:
            self._api.send(chat_id, text, keyboard=keyboard)
        else:
            self._api.edit(chat_id, message_id, text, keyboard=keyboard)

    # -- действия -----------------------------------------------------------

    def _do_add(self, chat_id: int, name: str) -> None:
        _address, conf = self._groxy.add_client(name)
        self._send_config(chat_id, name, conf)

    def _do_remove(self, chat_id: int, argument: str) -> None:
        client = self._client_at(chat_id, argument)
        if client is None:
            self._show_list(chat_id, None)
            return
        self._groxy.remove_client(client.name)
        self._api.send(chat_id, f"Профиль «{client.name}» удалён.")
        self._show_list(chat_id, None)

    def _do_reissue(self, chat_id: int, argument: str) -> None:
        client = self._client_at(chat_id, argument)
        if client is None:
            self._show_list(chat_id, None)
            return
        name = client.name
        # Именно удалить и создать заново, а не «показать конфиг»: приватный
        # ключ отдаётся один раз и нигде не хранится, поэтому другого способа
        # выдать рабочий конфиг не существует. Порядок важен — add-client при
        # занятом имени откажет отдельным кодом.
        self._groxy.remove_client(name)
        _address, conf = self._groxy.add_client(name)
        self._send_config(chat_id, name, conf)

    def _send_config(self, chat_id: int, name: str, conf: str) -> None:
        # Конфиг уходит одним сообщением и нигде не сохраняется: в нём
        # приватный ключ, которого нет больше нигде. В журнал он тоже не
        # попадает — записывается только имя.
        log.info("выдан конфиг профиля '%s'", name)
        self._api.send(chat_id, f"Конфиг «{name}»:")
        self._api.send(chat_id, conf)
        self._api.send(
            chat_id,
            "Сохраните его сейчас: приватный ключ отдаётся один раз и на узле "
            "не хранится. Показать его повторно нельзя — только перевыпустить, "
            "и тогда старое устройство отвалится.",
        )

    # -- вспомогательное ----------------------------------------------------

    def _client_at(self, chat_id: int, argument: str) -> cli.Client | None:
        """Профиль по номеру кнопки из последнего показанного списка.

        Возвращает None, если список устарел или номер вне его. Это не
        редкость: человек мог оставить сообщение открытым, а профиль за это
        время удалили с другого устройства. Молча промахнуться по соседней
        строке гораздо хуже, чем показать список заново.
        """
        try:
            index = int(argument)
        except ValueError:
            return None
        clients = self._shown.get(chat_id)
        if not clients or index < 0 or index >= len(clients):
            return None
        return clients[index]


def main() -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(levelname)s %(message)s"
    )
    try:
        cfg = config.load()
    except config.ConfigError as exc:
        log.error("конфигурация: %s", exc)
        return 2
    Bot(cfg).run()
    return 0

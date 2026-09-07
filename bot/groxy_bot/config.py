"""Конфигурация бота: токен, список допущенных, пути наружу.

Состояние живёт в `/etc/groxy/bot/` рядом с остальным состоянием groxy, а не в
переменных окружения юнита: токен в `Environment=` виден любому пользователю
через `systemctl show` и оседает в журнале при каждом перезапуске.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path

DEFAULT_DIR = Path(os.environ.get("GROXY_BOT_DIR", "/etc/groxy/bot"))

# Токен BotFather: <числовой id>:<35 символов из base64url>. Проверяется формой,
# а не длиной, чтобы обрезанный при копировании файл был отвергнут сразу, а не
# превратился в вечное «Unauthorized» из Telegram.
_TOKEN_RE = re.compile(r"^\d{5,}:[A-Za-z0-9_-]{30,}$")


class ConfigError(Exception):
    """Конфигурация не годится. Текст безопасно показывать в логе."""


@dataclass(frozen=True)
class Paths:
    """То, что нужно снапшоттеру. Секретов здесь нет намеренно.

    Снимок раз в минуту не разговаривает с Telegram, поэтому и токена не
    читает: программа, которая не держит секрета, не может его уронить в
    журнал. Побочно снимки начинают собираться раньше, чем заведён бот.
    """

    groxy_bin: str
    db_path: Path


@dataclass(frozen=True)
class Config:
    token: str
    allowed_chat_ids: frozenset[int]
    # Устройство, которым бот выходит наружу, когда прямой путь не работает.
    # Про выбор именно устройства — см. модуль net.
    tunnel_device: str
    paths: Paths

    @property
    def groxy_bin(self) -> str:
        return self.paths.groxy_bin

    @property
    def db_path(self) -> Path:
        return self.paths.db_path

    def redacted_token(self) -> str:
        """Токен для лога: только id бота, секретная половина не печатается."""
        bot_id = self.token.split(":", 1)[0]
        return f"{bot_id}:…[{len(self.token)} симв.]"


def _read_secret(path: Path) -> str:
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise ConfigError(f"нет файла {path}") from exc
    except PermissionError as exc:
        raise ConfigError(
            f"нет прав на {path} — файл должен принадлежать пользователю бота"
        ) from exc
    # Перевод строки в конце файла — норма, `printf` и любой редактор его
    # ставят. Внутренние пробелы норму не составляют и режутся тоже: токен с
    # приклеенным пробелом даёт неотличимое «Unauthorized».
    return raw.strip()


def _parse_allowlist(text: str) -> frozenset[int]:
    """Разбирает список chat_id: по одному на строку, `#` — комментарий.

    Пустой список — ошибка, а не «пускать всех». Бот выдаёт и отзывает доступ
    к VPN, и файл, опустевший из-за неудачной правки, не должен молча открыть
    его кому угодно.
    """
    ids: set[int] = set()
    for lineno, line in enumerate(text.splitlines(), start=1):
        stripped = line.split("#", 1)[0].strip()
        if not stripped:
            continue
        try:
            ids.add(int(stripped))
        except ValueError as exc:
            raise ConfigError(
                f"строка {lineno} списка допущенных не число: {stripped!r}"
            ) from exc
    if not ids:
        raise ConfigError("список допущенных пуст — бот не запускается")
    return frozenset(ids)


def load_paths() -> Paths:
    return Paths(
        groxy_bin=os.environ.get("GROXY_BIN", "/opt/groxy/groxy"),
        db_path=Path(os.environ.get("GROXY_BOT_DB", "/var/lib/groxy-bot/history.db")),
    )


def load(directory: Path | None = None) -> Config:
    base = directory or DEFAULT_DIR

    token = _read_secret(base / "token")
    if not _TOKEN_RE.match(token):
        # Само значение в текст ошибки не попадает: она уедет в журнал.
        raise ConfigError(
            f"токен в {base / 'token'} не похож на токен BotFather "
            f"(получено {len(token)} символов)"
        )

    allowed = _parse_allowlist(_read_secret(base / "allowed-chat-ids"))

    return Config(
        token=token,
        allowed_chat_ids=allowed,
        tunnel_device=os.environ.get("GROXY_BOT_DEVICE", "wg1"),
        paths=load_paths(),
    )

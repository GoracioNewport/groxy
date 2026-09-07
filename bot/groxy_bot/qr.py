"""QR-код конфига картинкой.

Рисуется внешним `qrencode`, а не своей реализацией: кодирование QR — это
маски, коррекция ошибок Рида — Соломона и таблицы версий, то есть несколько
сотен строк, которые надо было бы ещё и проверять. Утилита уже стоит на
бридже, её ставит `add-client --qr`.

Конфиг передаётся через stdin, а не аргументом командной строки: в нём
приватный ключ клиента, а аргументы видны всей системе в `ps` и оседают в
журнале вызовов.
"""

from __future__ import annotations

import logging
import shutil
import subprocess

log = logging.getLogger(__name__)


def available() -> bool:
    return shutil.which("qrencode") is not None


def render(text: str, timeout: float = 10.0) -> bytes | None:
    """PNG с QR-кодом, или None, если нарисовать не вышло.

    None — не повод ронять выдачу конфига: сам конфиг уже создан, ключ отдан
    один раз, и отказать на этапе картинки значило бы оставить человека без
    доступа из-за отсутствующей утилиты.
    """
    if not available():
        log.info("qrencode не установлен — QR не рисуем")
        return None
    try:
        done = subprocess.run(
            # -o - : на stdout; -t PNG : растр, а не ANSI; -s 6 : размер
            # модуля, чтобы код читался с экрана телефона без увеличения;
            # -m 2 : поля, без них некоторые сканеры не находят код.
            ["qrencode", "-o", "-", "-t", "PNG", "-s", "6", "-m", "2"],
            input=text.encode(),
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        log.info("qrencode не отработал: %s", exc)
        return None

    if done.returncode != 0 or not done.stdout:
        # stderr в лог не кладём: qrencode эхом отдаёт входные данные в
        # некоторых ошибках, а на входе приватный ключ.
        log.info("qrencode вернул %d без картинки", done.returncode)
        return None
    return done.stdout

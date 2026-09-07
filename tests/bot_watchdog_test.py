#!/usr/bin/env python3
"""Контракт watchdog'а. Запуск: python3 tests/bot_watchdog_test.py

Проверяется решающая логика: когда кричать, когда молчать и когда сообщить о
возвращении. Ничего никуда не отправляется — `send` подменён.
"""

import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "bot" / "bin" / "groxy-watchdog"

passed = 0
failed = 0


def check(what, want, got):
    global passed, failed
    if want == got:
        print(f"  ok   {what}")
        passed += 1
    else:
        print(f"  FAIL {what}: ожидалось {want!r}, получено {got!r}")
        failed += 1


def load(config_dir, ping_path, state_path, silence=900, grace=900):
    """Загружает скрипт как модуль с заданным окружением."""
    os.environ.update(
        {
            "GROXY_BOT_DIR": str(config_dir),
            "GROXY_REPORTER_PING": str(ping_path),
            "GROXY_WATCHDOG_STATE": str(state_path),
            "GROXY_WATCHDOG_SILENCE": str(silence),
            "GROXY_WATCHDOG_GRACE": str(grace),
        }
    )
    # Загрузчик задаётся явно: у файла нет расширения .py, и по имени
    # importlib его не опознаёт.
    loader = importlib.machinery.SourceFileLoader("watchdog", str(SCRIPT))
    spec = importlib.util.spec_from_loader("watchdog", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    config_dir = tmp / "bot"
    config_dir.mkdir()
    (config_dir / "token").write_text("8210566628:AAHfakefakefakefakefakefakefake123\n")
    (config_dir / "allowed-chat-ids").write_text("# владелец\n754067951\n")
    ping = tmp / "last-ping"
    state = tmp / "state.json"

    wd = load(config_dir, ping, state)

    sent = []
    wd.send = lambda token, chat_id, text: sent.append(text) or True

    now = int(time.time())

    print("== свежий пинг — тишина ==")
    ping.write_text(f"{now}\n")
    wd.main()
    check("ничего не отправлено", [], sent)

    print("== отметки нет и мы только что начали ==")
    # После установки юнита бот ещё не успел прислать первый пинг. Кричать об
    # этом значит поднимать тревогу при каждом развёртывании.
    state.unlink(missing_ok=True)
    ping.unlink()
    sent.clear()
    wd.main()
    check("молчит в отсрочку", [], sent)

    print("== портал, которому бот никогда не пинговал ==")
    # Резервный портал: бот пингует только активный, через туннель до
    # резервного он не достаёт вовсе. Судить о живости бота такому порталу не
    # по чему, и старая отметка от ручной пробы не должна превращаться в
    # тревогу. Поймано на sweden, где следующий запуск закричал бы ложно.
    state.write_text(json.dumps({"first_run": now - 10_000}))
    ping.write_text(f"{now - 5000}\n")
    sent.clear()
    wd.main()
    check("молчит, раз пингов никогда не видел", [], sent)

    print("== молчание дольше порога ==")
    # Отсрочка истекла, и пинги раньше приходили: подделываем и то, и другое.
    state.write_text(json.dumps({"first_run": now - 10_000, "seen_ping": True}))
    ping.write_text(f"{now - 5000}\n")
    sent.clear()
    wd.main()
    check("одно сообщение", 1, len(sent))
    check("сказано, что бот молчит", True, "молчит" in sent[0])
    check("названо, кто пишет", True, "watchdog" in sent[0])
    check("одной строкой", 1, len(sent[0].strip().splitlines()))

    print("== о том же не кричат каждые пять минут ==")
    sent.clear()
    wd.main()
    check("повтора нет", [], sent)

    print("== бот вернулся ==")
    ping.write_text(f"{now}\n")
    sent.clear()
    wd.main()
    check("одно сообщение о возвращении", 1, len(sent))
    check("текст про связь", True, "снова на связи" in sent[0])

    print("== и о возвращении тоже не повторяется ==")
    sent.clear()
    wd.main()
    check("повтора нет", [], sent)

    print("== отметка исчезла после того, как была ==")
    # Reporter переустановили, каталог почистили. Отсрочка уже истекла, значит
    # это настоящее молчание, а не «ещё не начиналось».
    ping.unlink()
    sent.clear()
    wd.main()
    check("тревога поднята", 1, len(sent))
    check("сказано про отсутствие пингов", True, "ни одного пинга" in sent[0])

    print("== битая отметка считается молчанием ==")
    # Обрыв записи оставил бы мусор. Считать его свежим пингом означало бы
    # молчать при мёртвом боте.
    state.write_text(
        json.dumps({"first_run": now - 10_000, "quiet": False, "seen_ping": True})
    )
    ping.write_text("не число")
    sent.clear()
    wd.main()
    check("тревога поднята", 1, len(sent))

    print("== бот ушёл на другой портал ==")
    # Пинги прекратились не потому, что бот умер, а потому что он переключился.
    # Reporter пишет сюда слово по просьбе бота ДО переключения.
    state.write_text(json.dumps({"first_run": now - 10_000, "seen_ping": True}))
    ping.write_text("standby\n")
    sent.clear()
    wd.main()
    check("тревоги нет", [], sent)
    saved = json.loads(state.read_text())
    # Право судить сбрасывается: иначе после возврата на этот портал первая же
    # проверка сравнивала бы с историей от прошлой жизни.
    check("право судить сброшено", False, saved.get("seen_ping"))

    print("== после ожидания портал снова становится активным ==")
    ping.write_text(f"{now}\n")
    sent.clear()
    wd.main()
    check("молчит: пинг свежий", [], sent)
    check("право судить набрано заново", True, json.loads(state.read_text())["seen_ping"])

print()
print(f"прошло: {passed}, упало: {failed}")
sys.exit(1 if failed else 0)

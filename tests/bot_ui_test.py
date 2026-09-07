#!/usr/bin/env python3
"""Контракт представления и доступа. Запуск: python3 tests/bot_ui_test.py

Ни сети, ни узла, ни токена: Telegram и CLI подменены.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bot"))

from groxy_bot import ui  # noqa: E402
from groxy_bot.cli import Client, PortalLink, Snapshot  # noqa: E402
from groxy_bot.config import Config, ConfigError, Paths, _parse_allowlist  # noqa: E402
from groxy_bot.main import Bot  # noqa: E402
from groxy_bot.telegram import Update  # noqa: E402

NOW = 1_800_000_000

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


def client(name, handshake, rx=0, tx=0, endpoint=None):
    return Client(
        name=name,
        address="10.66.66.2",
        public_key="k" * 43 + "=",
        endpoint=endpoint,
        latest_handshake=handshake,
        rx=rx,
        tx=tx,
    )


ONLINE = client("alpha", NOW - 30, rx=1024, tx=2048, endpoint="1.2.3.4:5678")
STALE = client("beta", NOW - 4000)
NEVER = client("gamma", 0)

SNAPSHOT = Snapshot(
    generated_at=NOW,
    portal=PortalLink("nether", "198.51.100.7:61285", NOW - 20, 4096, 8192),
    clients=(ONLINE, STALE, NEVER),
)

print("== возраст ==")
check("никогда", "никогда", ui.human_age(0, NOW))
check("секунды", "30 с назад", ui.human_age(NOW - 30, NOW))
check("минуты", "5 мин назад", ui.human_age(NOW - 300, NOW))
check("дни", "2 дн назад", ui.human_age(NOW - 2 * 86400, NOW))
# Часы узла могли перевестись назад. Отрицательный возраст заставил бы читателя
# гадать, а «только что» безвреден.
check("будущее не даёт отрицательного возраста", "только что", ui.human_age(NOW + 60, NOW))

print("== онлайн ==")
check("свежий handshake — на связи", True, ui.is_online(ONLINE, NOW))
check("протухший — офлайн", False, ui.is_online(STALE, NOW))
check("ни разу не подключался — офлайн", False, ui.is_online(NEVER, NOW))

print("== список ==")
text = ui.clients_list(SNAPSHOT, NOW)
check("считает профили", True, "Профилей: 3" in text)
check("считает тех, кто на связи", True, "на связи: 1" in text)
check("называет портал", True, "nether" in text)

print("== портала нет — об этом сказано прямо ==")
# Без портала зарубежный трафик никуда не идёт. Пропустить строку означало бы
# показать нормально выглядящий экран при сломанной половине сервиса.
no_portal = Snapshot(generated_at=NOW, portal=None, clients=(ONLINE,))
check("строка про отсутствие портала", True, "не выбран" in ui.clients_list(no_portal, NOW))

print("== сводка ==")
summary = ui.summary(SNAPSHOT, NOW)
check("отделяет «ни разу» от «давно»", True, "Ни разу не подключались: 1" in summary)

print("== карточка ==")
card = ui.client_card(ONLINE, NOW)
check("статус", True, "на связи" in card)
check("endpoint показан", True, "1.2.3.4:5678" in card)
check("у офлайн-профиля endpoint не выдуман", False, "Подключение с" in ui.client_card(NEVER, NOW))

print("== кнопки ==")
rows = ui.clients_keyboard(SNAPSHOT.clients, NOW)
datas = [b["callback_data"] for row in rows for b in row]
check("по кнопке на профиль плюс возврат", 4, len(datas))
# 64 байта — предел callback_data, а имя профиля бывает до 63 символов.
# Поэтому в кнопке номер, а не имя: иначе длинное имя обрезалось бы и кнопка
# «удалить» указала бы на соседа.
long_name = client("x" * 63, NOW)
long_rows = ui.clients_keyboard([long_name], NOW)
check(
    "длинное имя не раздувает callback_data",
    True,
    all(len(b["callback_data"].encode()) <= 64 for row in long_rows for b in row),
)

print("== подтверждение опасного ==")
for action in ("rm", "reissue"):
    kb = ui.confirm_keyboard(action, 2)
    datas = [b["callback_data"] for row in kb for b in row]
    check(f"{action}: подтверждение отличается от самого действия", True, f"{action}!:2" in datas)
    check(f"{action}: есть отмена", True, "peer:2" in datas)
check(
    "текст про удаление предупреждает о невозвратности",
    True,
    "нельзя" in ui.CONFIRM_TEXTS["rm"].format(name="alpha"),
)
check(
    "текст про перевыпуск предупреждает, что старое устройство отвалится",
    True,
    "отвалится" in ui.CONFIRM_TEXTS["reissue"].format(name="alpha"),
)

print("== список допущенных ==")
check("разбирает числа", {1, 2}, set(_parse_allowlist("1\n# комментарий\n2\n")))
try:
    _parse_allowlist("# только комментарий\n")
    check("пустой список — отказ", "ConfigError", "ничего не поднялось")
except ConfigError:
    check("пустой список — отказ", "ConfigError", "ConfigError")
try:
    _parse_allowlist("не число\n")
    check("нечисло — отказ", "ConfigError", "ничего не поднялось")
except ConfigError:
    check("нечисло — отказ", "ConfigError", "ConfigError")

print("== токен не печатается целиком ==")
cfg = Config(
    token="8210566628:AAHsecretsecretsecretsecretsecret1",
    allowed_chat_ids=frozenset({754067951}),
    tunnel_device="wg1",
    paths=Paths(groxy_bin="/opt/groxy/groxy", db_path=Path("/tmp/x.db")),
)
redacted = cfg.redacted_token()
check("секретная половина скрыта", False, "AAHsecret" in redacted)
check("id бота виден", True, redacted.startswith("8210566628:"))


class FakeApi:
    def __init__(self):
        self.sent = []
        self.answered = []
        self.documents = []
        self.photos = []

    def send(self, chat_id, text, keyboard=None):
        self.sent.append((chat_id, text))
        return 1

    def send_document(self, chat_id, content, filename, caption=""):
        self.documents.append((filename, content, caption))

    def send_photo(self, chat_id, image, caption=""):
        self.photos.append((image, caption))

    def edit(self, chat_id, message_id, text, keyboard=None):
        self.sent.append((chat_id, text))

    def answer_callback(self, callback_id, text=""):
        self.answered.append(callback_id)

    def get_me(self):
        return "test_bot"

    def drop_pending(self):
        pass


class FakeGroxy:
    def __init__(self):
        self.calls = []

    def stats(self, name=None):
        self.calls.append(("stats", name))
        return SNAPSHOT

    def add_client(self, name):
        self.calls.append(("add", name))
        return "10.66.66.9", "[Interface]\nPrivateKey = секрет\n"

    def remove_client(self, name):
        self.calls.append(("remove", name))

    def rename_client(self, old, new):
        self.calls.append(("rename", old, new))


def make_bot():
    bot = Bot.__new__(Bot)
    bot._cfg = cfg
    bot._api = FakeApi()
    bot._groxy = FakeGroxy()
    bot._pending = {}
    bot._shown = {}
    return bot


print("== доступ ==")
bot = make_bot()
bot._dispatch(Update(1, chat_id=999, user_id=999, text="/list", callback_data=None,
                     callback_id=None, message_id=1))
check("посторонний чат не получает ответа", 0, len(bot._api.sent))
check("и CLI не вызывается", 0, len(bot._groxy.calls))

bot = make_bot()
# В группе chat_id и user_id разные. Сверять только чат значило бы пускать
# любого участника, куда бота однажды добавили.
bot._dispatch(Update(1, chat_id=754067951, user_id=42, text="/list", callback_data=None,
                     callback_id=None, message_id=1))
check("чужой пользователь в допущенном чате отклонён", 0, len(bot._api.sent))

bot = make_bot()
bot._dispatch(Update(1, chat_id=754067951, user_id=754067951, text="/list",
                     callback_data=None, callback_id=None, message_id=None))
check("владелец получает ответ", 1, len(bot._api.sent))

print("== удаление требует двух нажатий ==")
bot = make_bot()
bot._shown[754067951] = list(SNAPSHOT.clients)
bot._dispatch(Update(1, chat_id=754067951, user_id=754067951, text=None,
                     callback_data="rm:0", callback_id="c1", message_id=5))
check("первое нажатие не удаляет", [], [c for c in bot._groxy.calls if c[0] == "remove"])
bot._dispatch(Update(2, chat_id=754067951, user_id=754067951, text=None,
                     callback_data="rm!:0", callback_id="c2", message_id=5))
check("второе удаляет", [("remove", "alpha")], [c for c in bot._groxy.calls if c[0] == "remove"])

print("== устаревшая кнопка не бьёт по соседу ==")
bot = make_bot()
bot._shown[754067951] = [ONLINE]
bot._dispatch(Update(1, chat_id=754067951, user_id=754067951, text=None,
                     callback_data="rm!:2", callback_id="c1", message_id=5))
check("номера вне списка — ничего не удалено", [], [c for c in bot._groxy.calls if c[0] == "remove"])

print("== команда отменяет незаконченный диалог ==")
bot = make_bot()
bot._pending[754067951] = __import__("groxy_bot.main", fromlist=["Pending"]).Pending("add")
bot._dispatch(Update(1, chat_id=754067951, user_id=754067951, text="/summary",
                     callback_data=None, callback_id=None, message_id=None))
check("профиль с именем «/summary» не создан", [], [c for c in bot._groxy.calls if c[0] == "add"])
check("диалог сброшен", {}, bot._pending)

print("== перевыпуск — это пересоздание ==")
bot = make_bot()
bot._shown[754067951] = list(SNAPSHOT.clients)
bot._dispatch(Update(1, chat_id=754067951, user_id=754067951, text=None,
                     callback_data="reissue!:0", callback_id="c1", message_id=5))
order = [c[0] for c in bot._groxy.calls if c[0] in ("remove", "add")]
# Порядок обязателен: add-client при занятом имени отказывает отдельным кодом.
check("сначала удаление, потом создание", ["remove", "add"], order)
check("конфиг ушёл файлом", 1, len(bot._api.documents))
check("имя файла по профилю", "alpha.conf", bot._api.documents[0][0])
check(
    "человека предупредили, что ключ отдаётся один раз",
    True,
    "один раз" in bot._api.documents[0][2],
)

print("== конфиг всё равно доходит, если файл не ушёл ==")
# Человек остался бы с созданным профилем и без единого способа им
# воспользоваться: ключ отдаётся один раз, второй попытки не будет.
from groxy_bot import net as net_module  # noqa: E402

bot = make_bot()
bot._shown[754067951] = list(SNAPSHOT.clients)
bot._api.send_document = lambda *a, **k: (_ for _ in ()).throw(
    net_module.TransportError("timed out", "wg1")
)
bot._dispatch(Update(1, chat_id=754067951, user_id=754067951, text=None,
                     callback_data="reissue!:0", callback_id="c1", message_id=5))
check("конфиг отдан текстом", True, any("[Interface]" in t for _, t in bot._api.sent))
check(
    "предупреждение тоже",
    True,
    any("один раз" in t for _, t in bot._api.sent),
)

print()
print(f"прошло: {passed}, упало: {failed}")
sys.exit(1 if failed else 0)

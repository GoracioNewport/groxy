# groxy

Двухуровневый WireGuard с селективной маршрутизацией по белому списку доменов:
российский VPS (**bridge**) принимает клиентов, заворачивает трафик в зарубежный
VPS (**portal**), но домены из whitelist'a отпускает напрямую — российские
сервисы видят российский IP.

**Статус:** WIP. Этап 1 — каркас.

## Установка (предварительный план)

```sh
git clone https://github.com/GoracioNewport/groxy /opt/groxy
cd /opt/groxy
sudo ./groxy init portal
# или
sudo ./groxy init bridge --portal-profile=<file>
```

## Поддерживаемые ОС

- Debian 12 (bookworm)

## Лицензия

MIT — см. [LICENSE](LICENSE).

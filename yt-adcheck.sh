#!/usr/bin/env bash
# Определяет, будет ли на YouTube реклама с текущего egress-IP.
#
# Реклама зависит от страны, которую Google присваивает IP: в РФ Google рекламу
# не показывает с 2022 года. Поэтому достаточно спросить у самого YouTube, какую
# страну он видит — RU означает "рекламы не будет".
#
# Запускать на узле, чей IP проверяем (или через прокси этого узла).
#
# Прямая проверка рекламных слотов через innertube-API больше не работает:
# анонимный WEB-клиент требует PoToken, ANDROID-клиент отдаёт FAILED_PRECONDITION.
#
# Оговорка: у залогиненного пользователя YouTube может брать страну аккаунта,
# а не IP — тогда RU-адрес от рекламы не спасёт.

UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36'

IP=$(curl -s --max-time 8 https://api.ipify.org)
# SOCS/CONSENT обходят страницу согласия, которую YouTube показывает с EU-адресов
HP=$(curl -s --max-time 15 -A "$UA" -H 'Accept-Language: en-US,en;q=0.9' \
     -H 'Cookie: SOCS=CAI; CONSENT=YES+1' https://www.youtube.com/)
CC=$(printf '%s' "$HP" | grep -oE '"GL":"[A-Z]{2}"' | head -1 | cut -d'"' -f4)

echo "IP=${IP:-<не определён>}"
case "$CC" in
    RU) echo "  страна у YouTube: RU  → рекламы НЕТ" ;;
    "") echo "  страна у YouTube: не определена (страница согласия или блокировка)" ;;
    *)  echo "  страна у YouTube: $CC  → реклама ЕСТЬ" ;;
esac

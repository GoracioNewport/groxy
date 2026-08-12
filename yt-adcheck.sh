#!/usr/bin/env bash
# YouTube ad-region probe for the current egress IP
IP=$(curl -s --max-time 8 https://api.ipify.org)
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36'
HP=$(curl -s --max-time 15 -A "$UA" -H 'Accept-Language: en-US,en;q=0.9' -H 'Cookie: SOCS=CAI; CONSENT=YES+1' https://www.youtube.com/)
CC=$(printf '%s' "$HP" | grep -oE '"GL":"[A-Z]{2}"|"countryCode":"[A-Z]{2}"' | sort -u | tr '\n' ' ')
RESP=$(curl -s --max-time 20 -A "$UA" -H 'Content-Type: application/json' -H 'Cookie: SOCS=CAI' \
  'https://www.youtube.com/youtubei/v1/player?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false' \
  -d '{"context":{"client":{"clientName":"WEB","clientVersion":"2.20240710.01.00","hl":"en","gl":""}},"videoId":"dQw4w9WgXcQ"}')
ADS=$(printf '%s' "$RESP" | grep -oE 'adPlacements|adSlots|playerAds' | sort -u | tr '\n' ' ')
PCC=$(printf '%s' "$RESP" | grep -oE '"countryCode":"[A-Z]{2}"|"gl":"[A-Z]{2}"' | sort -u | tr '\n' ' ')
STATUS=$(printf '%s' "$RESP" | grep -oE '"status":"[A-Za-z_]+"' | head -1)
echo "IP=$IP"
echo "  youtube ytcfg country : ${CC:-<none/consent-wall>}"
echo "  player response country: ${PCC:-<none>}  ${STATUS}"
echo "  player ad slots        : ${ADS:-NONE (no ads served)}"

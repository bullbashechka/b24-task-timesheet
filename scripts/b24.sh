#!/bin/bash
# Calls one Bitrix24 REST method through the development webhook.
# The webhook URL comes from the macOS Keychain (item b24-dev-webhook) and is masked in every output.
# Usage: scripts/b24.sh <method> ['<json params>'] [--write] [--save <file>] [--bad-token]
#   --write      allow the methods that create or delete test data;
#   --save FILE  also write the masked answer to FILE;
#   --bad-token  spoil the webhook token to record the "webhook rejected" answer.
# Exit codes: 0 — answer without error, 1 — Bitrix24 or transport error, 2 — usage or environment error.
# Must run outside the Claude Code sandbox: the sandbox has no Keychain access.

set -u
KEYCHAIN_ITEM="b24-dev-webhook"

READ_METHODS=" user.get user.current tasks.task.list tasks.task.get tasks.task.getFields
  crm.company.get crm.company.list crm.company.fields crm.requisite.list crm.requisite.fields
  crm.requisite.preset.list crm.requisite.preset.field.list sonet_group.get sonet_group.user.get "
WRITE_METHODS=" sonet_group.create sonet_group.user.add sonet_group.delete
  crm.company.add crm.company.delete crm.requisite.add crm.requisite.delete
  tasks.task.add tasks.task.update tasks.task.complete tasks.task.delete "

usage() { sed -n '4,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

METHOD="${1:-}"; [ -n "$METHOD" ] || usage; shift
PARAMS='{}'
if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then PARAMS="$1"; shift; fi
WRITE=0; SAVE=""; BAD_TOKEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --write) WRITE=1 ;;
    --save) SAVE="${2:-}"; [ -n "$SAVE" ] || usage; shift ;;
    --bad-token) BAD_TOKEN=1 ;;
    *) usage ;;
  esac
  shift
done

echo "$PARAMS" | jq -e 'type == "object"' >/dev/null 2>&1 || { echo "Параметры должны быть JSON-объектом." >&2; exit 2; }

# Every method, including each command inside batch, must be on a list; write methods need --write.
check_method() {
  if printf '%s' "$READ_METHODS" | tr -s ' \n' '\n\n' | grep -qx "$1"; then return 0; fi
  if printf '%s' "$WRITE_METHODS" | tr -s ' \n' '\n\n' | grep -qx "$1"; then
    [ "$WRITE" = 1 ] && return 0
    echo "Метод $1 меняет данные Битрикс24: нужен флаг --write." >&2; exit 2
  fi
  echo "Метода $1 нет в белом списке scripts/b24.sh." >&2; exit 2
}
if [ "$METHOD" = "batch" ]; then
  COMMANDS="$(echo "$PARAMS" | jq -r '.cmd // {} | .[] | split("?")[0]')"
  [ -n "$COMMANDS" ] || { echo "В batch нет команд (cmd)." >&2; exit 2; }
  while IFS= read -r CMD; do check_method "$CMD"; done <<< "$COMMANDS"
else
  check_method "$METHOD"
fi

WEBHOOK="$(security find-generic-password -s "$KEYCHAIN_ITEM" -w 2>/dev/null)"
if [ -z "$WEBHOOK" ]; then
  echo "В Связке ключей нет записи $KEYCHAIN_ITEM. Выполните в Терминале:" >&2
  echo "  security add-generic-password -a \"\$USER\" -s $KEYCHAIN_ITEM -w" >&2
  exit 2
fi
WEBHOOK="${WEBHOOK%/}/"
TOKEN="$(printf '%s' "$WEBHOOK" | sed -E 's#^.*/rest/[0-9]+/([^/]+)/$#\1#')"
if ! printf '%s' "$WEBHOOK" | grep -Eq '^https://[^/]+/rest/[0-9]+/[A-Za-z0-9]+/$'; then
  echo "Запись $KEYCHAIN_ITEM не похожа на адрес вебхука (https://<портал>/rest/<id>/<токен>/)." >&2
  exit 2
fi
if [ "$BAD_TOKEN" = 1 ]; then WEBHOOK="${WEBHOOK%"$TOKEN/"}invalidtoken0000/"; fi

mask() { sed -E -e "s#$TOKEN#***#g" -e 's#/rest/[0-9]+/[A-Za-z0-9]+#/rest/***#g'; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# The URL goes to curl through stdin, so it does not show up in the process list either.
HTTP_CODE="$(printf 'url = "%s%s.json"\n' "$WEBHOOK" "$METHOD" | curl --config - -sS --max-time 30 \
  -X POST -H 'Content-Type: application/json' --data-binary "$PARAMS" \
  -o "$TMP/body" -w '%{http_code}' 2>"$TMP/err")"
CURL_EXIT=$?
unset WEBHOOK

if [ "$CURL_EXIT" -ne 0 ]; then
  echo "Ошибка соединения (curl $CURL_EXIT):" >&2
  mask < "$TMP/err" >&2
  exit 1
fi

mask < "$TMP/body" > "$TMP/masked"
if jq . "$TMP/masked" > "$TMP/pretty" 2>/dev/null; then OUT="$TMP/pretty"; else OUT="$TMP/masked"; fi
cat "$OUT"
if [ -n "$SAVE" ]; then mkdir -p "$(dirname "$SAVE")"; cp "$OUT" "$SAVE"; fi
echo "HTTP $HTTP_CODE" >&2

if [ "$HTTP_CODE" -ge 400 ] || jq -e 'has("error")' "$OUT" >/dev/null 2>&1; then exit 1; fi
exit 0

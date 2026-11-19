#!/bin/bash
# Calls the OpenAI API with the development key. Only two requests exist: POST /v1/responses and GET /v1/models/<id>.
# The key is the secret openai-dev-key (common.sh: macOS Keychain or a Windows DPAPI file) and is masked in every output.
# Usage: scripts/openai.sh responses @<body.json> [--save FILE] [--bad-key] [--max-time N]
#        scripts/openai.sh models <model id> [--save FILE] [--bad-key] [--max-time N]
#   --save FILE   also write the masked answer to FILE;
#   --bad-key     send a wrong key (the stored one is not even read) to record the "key rejected" answer;
#   --max-time N  limit of the whole request in seconds, default 60.
# Prints the masked answer to stdout, "HTTP <code> <seconds>" to stderr.
# Exit codes: 0 — answer without error, 1 — OpenAI or transport error, 2 — usage or environment error.
# Must run outside the Claude Code sandbox: the sandbox has no access to the secret store.
# The request body is a file, never printed. Do not put real task texts into it before the decisions of stage 14 allow it.

set -u
. "$(dirname "$0")/common.sh"
SECRET_NAME="openai-dev-key"
BASE_URL="https://api.openai.com/v1"

usage() { sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
refuse() { echo "$1" >&2; exit 2; }

ACTION="${1:-}"; [ -n "$ACTION" ] || usage; shift
BODY_FILE=""
case "$ACTION" in
  responses)
    BODY_ARG="${1:-}"; [ -n "$BODY_ARG" ] || usage; shift
    [ "${BODY_ARG#@}" != "$BODY_ARG" ] || refuse "Тело запроса задаётся как @файл."
    BODY_FILE="${BODY_ARG#@}"
    [ -f "$BODY_FILE" ] || refuse "Нет файла тела запроса: $BODY_FILE"
    jq -e 'type == "object"' "$BODY_FILE" >/dev/null 2>&1 || refuse "Тело запроса должно быть JSON-объектом."
    METHOD=POST; URL="$BASE_URL/responses"
    ;;
  models)
    MODEL="${1:-}"; [ -n "$MODEL" ] || usage; shift
    # The id is checked as a plain string: no slash, glob, brace, quote or newline can reach the URL.
    if ! printf '%s' "$MODEL" | LC_ALL=C grep -Eqx '[A-Za-z0-9][A-Za-z0-9._:-]*' || [ "$(printf '%s\n' "$MODEL" | wc -l)" -ne 1 ]; then
      refuse "Недопустимое имя модели."
    fi
    METHOD=GET; URL="$BASE_URL/models/$MODEL"
    ;;
  *) usage ;;
esac

SAVE=""; BAD_KEY=0; MAX_TIME=60
while [ $# -gt 0 ]; do
  case "$1" in
    --save) SAVE="${2:-}"; [ -n "$SAVE" ] || usage; shift ;;
    --bad-key) BAD_KEY=1 ;;
    --max-time) MAX_TIME="${2:-}"; printf '%s' "$MAX_TIME" | grep -Eqx '[0-9]{1,3}' || usage; shift ;;
    *) usage ;;
  esac
  shift
done

if [ "$BAD_KEY" = 1 ]; then
  KEY="sk-invalidkey0000000000000000000000"
else
  KEY="$(secret_get "$SECRET_NAME")"
  if [ -z "$KEY" ]; then
    echo "Ключ OpenAI ($SECRET_NAME) не сохранён. Выполните в своём терминале:" >&2
    echo "  $(secret_hint "$SECRET_NAME")" >&2
    exit 2
  fi
  if ! printf '%s' "$KEY" | grep -Eq '^sk-[A-Za-z0-9_-]{20,}$'; then
    echo "Секрет $SECRET_NAME не похож на ключ OpenAI (sk-…)." >&2
    exit 2
  fi
fi

# Every sk-… string is masked, not only ours.
mask() { sed -E -e "s#$KEY#sk-***#g" -e 's#sk-[A-Za-z0-9_-]{8,}#sk-***#g'; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ARGS=(--globoff --proto =https -sS --max-time "$MAX_TIME" -X "$METHOD" -o "$TMP/body" -w '%{http_code} %{time_total}')
if [ "$METHOD" = POST ]; then ARGS+=(-H 'Content-Type: application/json' --data-binary "@$(native_path "$BODY_FILE")"); fi
# The URL and the key go to curl through stdin, so they do not show up in the process list.
RESULT="$(printf 'url = "%s"\nheader = "Authorization: Bearer %s"\n' "$URL" "$KEY" | curl --config - "${ARGS[@]}" 2>"$TMP/err")"
CURL_EXIT=$?

if [ "$CURL_EXIT" -ne 0 ]; then
  echo "Ошибка соединения (curl $CURL_EXIT):" >&2
  mask < "$TMP/err" >&2
  exit 1
fi
HTTP_CODE="${RESULT%% *}"; SECONDS_TOTAL="${RESULT#* }"

mask < "$TMP/body" > "$TMP/masked"
if jq . "$TMP/masked" > "$TMP/pretty" 2>/dev/null; then OUT="$TMP/pretty"; else OUT="$TMP/masked"; fi
cat "$OUT"
if [ -n "$SAVE" ]; then mkdir -p "$(dirname "$SAVE")"; cp "$OUT" "$SAVE"; fi
echo "HTTP $HTTP_CODE $SECONDS_TOTAL" >&2

if [ "$HTTP_CODE" -ge 400 ] || jq -e 'type == "object" and has("error") and .error != null' "$OUT" >/dev/null 2>&1; then exit 1; fi
exit 0

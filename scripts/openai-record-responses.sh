#!/bin/bash
# Records the OpenAI answers used by the tests into the text common templates б24тТест_ОтветИИ_<случай>
# of the test extension. The live answers come from scripts/openai.sh on the INVENTED material of scripts/openai-test/
# (never real task texts or real formulations: the repository is public). Fields that repeat the request or identify
# the caller are cut, organization ids and key fragments are masked. "_Синтетика" answers are built here by hand:
# OpenAI can't produce them on demand.
# Usage: scripts/openai-record-responses.sh [free|paid]
#   free  the answers that cost nothing: key rejected, model missing, the synthetic ones, and «no credits» (recorded
#         once while the balance is zero, never overwritten: set FORCE=1 to do it again);
#   paid  the answers that need credit: success, the check request, the cut-off answer, and «refusal» built from success.
#   no argument: both.
# Environment: EFFORT (reasoning effort of the success answer, default medium), MAX_TOKENS (default 4000).
# Needs the key (secret openai-dev-key) except for «key rejected». Must run outside the Claude Code sandbox.

set -euo pipefail
. "$(dirname "$0")/common.sh"
OPENAI="$ROOT/scripts/openai.sh"
EXT_DIR="$ROOT/src/cfe/Б24ТабельИзЗадачиТесты"
TEMPLATES="$EXT_DIR/CommonTemplates"
PREFIX="б24тТест_ОтветИИ_"
WORK="$ROOT/.local/ai/live"
EFFORT="${EFFORT:-medium}"; MAX_TOKENS="${MAX_TOKENS:-4000}"
MODE="${1:-all}"
mkdir -p "$WORK"

# Cut: instructions, user, safety_identifier, prompt_cache_key, metadata. Masked: org-… and proj_… ids, sk-… fragments.
SANITIZE='del(.instructions, .user, .safety_identifier, .prompt_cache_key, .metadata)
  | walk(if type == "string" then gsub("org-[A-Za-z0-9]+"; "org-***") | gsub("proj_[A-Za-z0-9]+"; "proj_***") | gsub("sk-[A-Za-z0-9_*-]+"; "sk-***") else . end)'

ensure_template() { # case: creates the metadata and registers the template if it is new
  [ -f "$TEMPLATES/$PREFIX$1.xml" ] || "$PY" "$ROOT/scripts/add-common-template.py" "$(native_path "$EXT_DIR")" "$PREFIX$1" "Ответ OpenAI: $1" >/dev/null
}
write_json() { # case, JSON on stdin
  ensure_template "$1"
  { printf '\xef\xbb\xbf'; jq . | awk '{ printf "%s\r\n", $0 }'; } > "$TEMPLATES/$PREFIX$1/Ext/Template.txt"
  echo "$PREFIX$1"
}
write_text() { # case, raw text on stdin (not JSON, maybe empty)
  ensure_template "$1"
  { printf '\xef\xbb\xbf'; cat; } > "$TEMPLATES/$PREFIX$1/Ext/Template.txt"
  echo "$PREFIX$1"
}
body_of() { tail -c +4 "$TEMPLATES/$PREFIX$1/Ext/Template.txt" | tr -d '\r'; }

live() { # case, body file [, flags of openai.sh]: calls OpenAI (errors too) and records the answer
  local CASE="$1" BODYFILE="$2"; shift 2
  "$OPENAI" responses "@$BODYFILE" --save "$WORK/$CASE.json" "$@" >/dev/null 2>&1 || true
  jq -e 'type == "object"' "$WORK/$CASE.json" >/dev/null || { echo "$CASE: ответ не JSON" >&2; exit 1; }
  jq "$SANITIZE" "$WORK/$CASE.json" | write_json "$CASE"
}
body() { "$ROOT/scripts/openai-body.sh" "$@" > "$WORK/body.json"; echo "$WORK/body.json"; }

free() {
  live КлючОтклонён "$(body aiUpdate "обновил бк до 3.0.72.1" low 100)" --bad-key
  live МодельНедоступна "$(body aiUpdate "обновил бк до 3.0.72.1" low 100 gpt-5.6-luna-nonexistent)"

  # «No credits» only exists while the balance is zero: record it once and keep it.
  if [ -n "${FORCE:-}" ] || [ ! -s "$TEMPLATES/$PREFIX"НетСредств/Ext/Template.txt ] \
     || [ "$(wc -c < "$TEMPLATES/$PREFIX"НетСредств/Ext/Template.txt)" -lt 20 ]; then
    live НетСредств "$(body aiUpdate "обновил бк до 3.0.72.1" low 100)"
    body_of НетСредств | jq -e '.error.code == "credit_balance_exhausted"' >/dev/null 2>&1 \
      || echo "ВНИМАНИЕ: НетСредств записан не как credit_balance_exhausted: на счёте есть деньги, макет не годится." >&2
  else
    echo "${PREFIX}НетСредств: уже записан, не трогаю (FORCE=1 — перезаписать)"
  fi

  echo '{"error":{"message":"Rate limit reached for gpt-5.6-luna in organization org-*** on requests per min (RPM): Limit 5000, Used 5000, Requested 1. Please try again in 12ms. Visit https://platform.openai.com/account/rate-limits to learn more.","type":"requests","param":null,"code":"rate_limit_exceeded"}}' | write_json ЛимитЗапросов_Синтетика
  echo '{"error":{"message":"The server had an error while processing your request. Sorry about that!","type":"server_error","param":null,"code":null}}' | write_json ОшибкаСервера_Синтетика
  echo '<html><head><title>502 Bad Gateway</title></head><body><h1>502 Bad Gateway</h1></body></html>' | write_text НеJSON_Синтетика
  printf '' | write_text Пустой_Синтетика
}

paid() {
  live Успех "$(body aiUpdate "обновил бк до 3.0.72.1" "$EFFORT" "$MAX_TOKENS")"
  jq -n --arg model gpt-5.6-luna '{model: $model, input: "Ответь одним словом: готов", store: false, max_output_tokens: 200, reasoning: {effort: "none"}}' > "$WORK/check.json"
  live ПроверкаИИ "$WORK/check.json"
  live Оборванный "$(body aiUpdate "обновил бк до 3.0.72.1" "$EFFORT" 16)"
  # A refusal of the model, built from the success answer: the message holds a refusal item instead of the text.
  body_of Успех | jq '.output |= map(if .type == "message" then .content = [{type: "refusal", refusal: "I am sorry, I cannot help with that request."}] else . end)' \
    | write_json Отказ_Синтетика
}

case "$MODE" in
  free) free ;;
  paid) paid ;;
  all) free; paid ;;
  *) sed -n '9,11p' "$0" >&2; exit 2 ;;
esac

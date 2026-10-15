#!/bin/bash
# Records the Bitrix24 answers used by the tests into the text common templates б24тТест_Ответ_<метод>_<случай>
# of the test extension. Answers come from the test data of scripts/b24-test-data.sh through scripts/b24.sh,
# then lose real names, e-mails, photos and the portal domain. "_Синтетика" answers are built here by hand:
# the portal can't produce them on demand.
# Usage: scripts/b24-record-responses.sh
# Must run outside the Claude Code sandbox, like scripts/b24.sh.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B24="$ROOT/scripts/b24.sh"
IDS="$ROOT/scripts/b24-test-data.ids.json"
TEMPLATES="$ROOT/src/cfe/Б24ТабельИзЗадачиТесты/CommonTemplates"
PREFIX="б24тТест_Ответ_"

[ -f "$IDS" ] || { echo "Нет $IDS: сначала scripts/b24-test-data.sh create" >&2; exit 2; }
set -a; . "$ROOT/.env"; set +a
id() { jq -r "$1" "$IDS"; }
DEV=30; ACCOMPLICE=50
GROUP="$(id .project)"
SINCE="$(date -v-30d '+%d.%m.%Y') 00:00:00"
TASK_SELECT='["ID","TITLE","CREATED_BY","RESPONSIBLE_ID","ACCOMPLICES","AUDITORS","STATUS","REAL_STATUS","GROUP_ID","UF_CRM_TASK","DEADLINE","CLOSED_DATE","ACTIVITY_DATE","CREATED_DATE"]'
RQ_SELECT='["ID","ENTITY_TYPE_ID","ENTITY_ID","PRESET_ID","NAME","SORT","ACTIVE","RQ_BIN","RQ_IIN","RQ_INN"]'
STATUS_FILTER="\"::SUBFILTER-ST\":{\"::LOGIC\":\"OR\",\"!REAL_STATUS\":5,\">=CLOSED_DATE\":\"$SINCE\"}"

# Real people become «Тест Пользователь <id>», e-mails become example.com, photos and the domain disappear.
SANITIZE='
  walk(
    if type == "object" and has("name") and has("icon") then
      .name = "Тест Пользователь \(.id)" | .icon = "" | (if has("workPosition") then .workPosition = "" else . end)
    elif type == "string" then
      gsub("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]+"; "test@example.com")
      | gsub("https?://[A-Za-z0-9.-]*toofirmagem[A-Za-z0-9.-]*"; "https://test.bitrix24.kz")
    else . end
  )'

write_template() { # case name, JSON on stdin
  local FILE="$TEMPLATES/$PREFIX$1/Ext/Template.txt"
  [ -f "$TEMPLATES/$PREFIX$1.xml" ] || { echo "Нет макета $PREFIX$1 в тестовом расширении." >&2; exit 2; }
  mkdir -p "$(dirname "$FILE")"
  { printf '\xef\xbb\xbf'; jq . | awk '{ printf "%s\r\n", $0 }'; } > "$FILE"
  echo "$PREFIX$1"
}

record() { # case name, method, params [, extra jq filter] [, --bad-token]
  local CASE="$1" METHOD="$2" PARAMS="$3" FILTER="${4:-.}" FLAG="${5:-}"
  local TMP; TMP="$(mktemp)"
  "$B24" "$METHOD" "$PARAMS" --save "$TMP" $FLAG >/dev/null 2>&1 || true
  jq -e 'type == "object"' "$TMP" >/dev/null || { echo "$CASE: ответ не JSON" >&2; rm -f "$TMP"; exit 1; }
  jq "$SANITIZE | $FILTER" "$TMP" | write_template "$CASE"
  rm -f "$TMP"
}

record user_get_Найден user.get "{\"FILTER\":{\"EMAIL\":\"$TEST_USER_EMAIL\",\"ACTIVE\":true}}" \
  '.result |= map({ID, ACTIVE, NAME: "Тест", LAST_NAME: "Тестов", EMAIL: "Test.User@Example.com"})'
record user_get_НеНайден user.get '{"FILTER":{"EMAIL":"nobody@example.com","ACTIVE":true}}'

record tasks_task_list_ПостановщикИлиИсполнитель tasks.task.list \
  "{\"filter\":{\"GROUP_ID\":$GROUP,\"::SUBFILTER-R\":{\"::LOGIC\":\"OR\",\"CREATED_BY\":$DEV,\"RESPONSIBLE_ID\":$DEV},$STATUS_FILTER},\"select\":$TASK_SELECT,\"order\":{\"ID\":\"asc\"}}"
record tasks_task_list_Соисполнитель tasks.task.list \
  "{\"filter\":{\"GROUP_ID\":$GROUP,\"ACCOMPLICE\":$ACCOMPLICE,$STATUS_FILTER},\"select\":$TASK_SELECT,\"order\":{\"ID\":\"asc\"}}"
record tasks_task_list_Страница1 tasks.task.list '{"filter":{"TITLE":"ТЕСТ"},"select":["ID"],"order":{"ID":"asc"},"start":0}'
record tasks_task_list_Страница2 tasks.task.list '{"filter":{"TITLE":"ТЕСТ"},"select":["ID"],"order":{"ID":"asc"},"start":50}'

record tasks_task_get_Найдена tasks.task.get "{\"taskId\":$(id .tasks.observer),\"select\":$TASK_SELECT}"
record tasks_task_get_НеНайдена tasks.task.get "{\"taskId\":999999999,\"select\":$TASK_SELECT}"

record crm_company_get_Найдена crm.company.get "{\"id\":$(id .companies.dalstroy)}"
record crm_company_get_НеНайдена crm.company.get '{"id":999999999}'
record crm_company_list_Названия crm.company.list \
  "{\"filter\":{\"ID\":[$(id .companies.dalstroy),$(id .companies.arkharov),$(id .companies.dup)]},\"select\":[\"ID\",\"TITLE\"]}"

for PAIR in БИН:dalstroy ИИН:arkharov ДваРеквизита:dalstroy2 Пусто:norq; do
  record "crm_requisite_list_${PAIR%%:*}" crm.requisite.list \
    "{\"filter\":{\"ENTITY_TYPE_ID\":4,\"ENTITY_ID\":$(id ".companies.${PAIR#*:}")},\"select\":$RQ_SELECT,\"order\":{\"SORT\":\"ASC\",\"ID\":\"ASC\"}}"
done

record sonet_group_get_Проект sonet_group.get "{\"FILTER\":{\"ID\":$GROUP}}"
record Ошибка_НеверныйВебхук user.current '{}' . --bad-token

# Synthetic answers. A Russian company: the BIN answer with the number moved to RQ_INN of a Russian preset.
jq '.result |= map(.PRESET_ID = "7" | .NAME = "Российская организация" | .RQ_INN = .RQ_BIN | .RQ_BIN = null)' \
  <(tail -c +4 "$TEMPLATES/${PREFIX}crm_requisite_list_БИН/Ext/Template.txt" | tr -d '\r') \
  | write_template crm_requisite_list_ИНН_Синтетика
# Error bodies as documented for QUERY_LIMIT_EXCEEDED (HTTP 503) and INTERNAL_SERVER_ERROR (HTTP 500).
echo '{"error":"QUERY_LIMIT_EXCEEDED","error_description":"Too many requests"}' | write_template Ошибка_ЛимитЗапросов_Синтетика
echo '{"error":"INTERNAL_SERVER_ERROR","error_description":"Internal server error"}' | write_template Ошибка_Сервер_Синтетика

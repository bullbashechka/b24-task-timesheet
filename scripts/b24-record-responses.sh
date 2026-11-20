#!/bin/bash
# Records the Bitrix24 answers used by the tests into the text common templates б24тТест_Ответ_<метод>_<случай>
# of the test extension. Answers come from the test data of scripts/b24-test-data.sh through scripts/b24.sh,
# then lose real names, e-mails, photos and the portal domain. "_Синтетика" answers are built here by hand:
# the portal can't produce them on demand.
# Usage: scripts/b24-record-responses.sh [stage14|stage17|stage22-noscope|stage22]
#   stage14  record only the answers added in stage 14 (no TEST_USER_EMAIL needed for them).
#   stage17  record only the answers added in stage 17 (descriptions of the tasks aiLong and aiQuotes).
#   stage22-noscope  the answer of the chat history method to a webhook WITHOUT the right «Чат и уведомления»
#            (run it before the right is added; it can't be recorded afterwards).
#   stage22  the answers of the task chats (stage 22): needs the right and the own test tasks with comments.
# Must run outside the Claude Code sandbox, like scripts/b24.sh.

set -euo pipefail
. "$(dirname "$0")/common.sh"
B24="$ROOT/scripts/b24.sh"
IDS="$ROOT/scripts/b24-test-data.ids.json"
TEMPLATES="$ROOT/src/cfe/Б24ТабельИзЗадачиТесты/CommonTemplates"
PREFIX="б24тТест_Ответ_"

if [ -n "${1:-}" ] && ! printf '%s' "$1" | grep -Eqx 'stage14|stage17|stage22-noscope|stage22'; then
  echo "Неизвестный режим $1: допустимы stage14, stage17, stage22-noscope, stage22 или без параметров (всё)." >&2; exit 2
fi
[ -f "$IDS" ] || { echo "Нет $IDS: сначала scripts/b24-test-data.sh create" >&2; exit 2; }
# .env is read, not executed: only TEST_USER_EMAIL is needed.
TEST_USER_EMAIL="$(env_value TEST_USER_EMAIL | tr -d "\"'")"
if ! printf '%s' "${1:-}" | grep -Eqx 'stage14|stage17|stage22-noscope|stage22'; then
  [ -n "$TEST_USER_EMAIL" ] || { echo "В $ROOT/.env нет TEST_USER_EMAIL" >&2; exit 2; }
fi
id() { jq -r "$1" "$IDS"; }
DEV=30; ACCOMPLICE=50
GROUP="$(id .project)"
SINCE="$(date_shift -30 '%d.%m.%Y') 00:00:00"
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

TMP=""; trap 'rm -f "$TMP"' EXIT
record() { # case name, method, params [, extra jq filter] [, --bad-token]
  local CASE="$1" METHOD="$2" PARAMS="$3" FILTER="${4:-.}" FLAG="${5:-}"
  TMP="$(mktemp)"
  "$B24" "$METHOD" "$PARAMS" --save "$TMP" $FLAG >/dev/null 2>&1 || true
  jq -e 'type == "object"' "$TMP" >/dev/null || { echo "$CASE: ответ не JSON" >&2; rm -f "$TMP"; exit 1; }
  jq "$SANITIZE | $FILTER" "$TMP" | write_template "$CASE"
  rm -f "$TMP"
}

# Stage 14: a task with its description (BB-code), the fields of the product list plus DESCRIPTION.
# The task aiTerms is invented: a test surname, version and BIN «99…».
stage14() {
  local TASK
  TASK="$(id .tasks.aiTerms)"
  record tasks_task_get_Описание tasks.task.get \
    "{\"taskId\":$TASK,\"select\":[\"ID\",\"TITLE\",\"DESCRIPTION\",\"CREATED_BY\",\"RESPONSIBLE_ID\",\"ACCOMPLICES\",\"STATUS\",\"GROUP_ID\",\"UF_CRM_TASK\",\"DEADLINE\",\"CLOSED_DATE\",\"ACTIVITY_DATE\"]}"
}
if [ "${1:-}" = stage14 ]; then stage14; exit 0; fi

# Stage 17: the description of a long task with every kind of markup (aiLong), of a task with quotes and the signs
# < > & (aiQuotes, to see how Bitrix24 returns them) and a synthetic answer whose description is HTML, as in old tasks
# (descriptionInBbcode «N»). Same select as stage 14.
stage17() {
  local SELECT='["ID","TITLE","DESCRIPTION","CREATED_BY","RESPONSIBLE_ID","ACCOMPLICES","STATUS","GROUP_ID","UF_CRM_TASK","DEADLINE","CLOSED_DATE","ACTIVITY_DATE"]'
  record tasks_task_get_ОписаниеДлинное tasks.task.get "{\"taskId\":$(id .tasks.aiLong),\"select\":$SELECT}"
  record tasks_task_get_Кавычки tasks.task.get "{\"taskId\":$(id .tasks.aiQuotes),\"select\":$SELECT}"
  record tasks_task_get_ОписаниеHTML_Синтетика tasks.task.get "{\"taskId\":$(id .tasks.aiQuotes),\"select\":$SELECT}"     '.result.task.descriptionInBbcode = "N" | .result.task.description = "<b>Настройка</b><br>ТОО &quot;Ромашка&quot; &amp; ИП &lt;Тестов&gt;<br>Версия 3.0.99.1<br><br><ul><li>Загрузка выписки</li></ul>&nbsp;Конец"'
}
if [ "${1:-}" = stage17 ]; then stage17; exit 0; fi

# Stage 22, part 1: the real answer of a webhook without the right «Чат и уведомления» (scope `im`): HTTP 401,
# `insufficient_scope`. The portal answers before it looks at the chat, so any chat id will do.
stage22_noscope() {
  record im_dialog_messages_get_НетПрава im.dialog.messages.get '{"DIALOG_ID":"chat999999999","LIMIT":1}'
}
if [ "${1:-}" = stage22-noscope ]; then stage22_noscope; exit 0; fi

# Stage 22: the chat of a task (im.dialog.messages.get) and the task field CHAT_ID. Real answers come from the own test
# tasks (invented texts): aiCommentMany (a system message and two comments), aiUpdate (system messages only) and
# aiCommentLong (56 messages: two pages). The people are replaced by scripts/sanitize-im.jq. The answer «no right» is
# recorded earlier (stage22-noscope): it can't be produced once the webhook has the right.
body_of() { tail -c +4 "$TEMPLATES/$PREFIX$1/Ext/Template.txt" | tr -d '\r'; }
record_im() { # case name, method, params [, extra jq filter]
  local CASE="$1" METHOD="$2" PARAMS="$3" FILTER="${4:-.}"
  TMP="$(mktemp)"
  "$B24" "$METHOD" "$PARAMS" --save "$TMP" >/dev/null 2>&1 || true
  jq -e 'type == "object"' "$TMP" >/dev/null || { echo "$CASE: ответ не JSON" >&2; rm -f "$TMP"; exit 1; }
  jq -f "$ROOT/scripts/sanitize-im.jq" "$TMP" | jq "$FILTER" | write_template "$CASE"
  rm -f "$TMP"
}
chat_of() { # task key → the chat number of the task
  "$B24" tasks.task.get "{\"taskId\":$(id ".tasks.$1"),\"select\":[\"ID\",\"CHAT_ID\"]}" 2>/dev/null | jq -r '.result.task.chatId'
}

# The pieces of a synthetic chat: a message and a user in the shape of the real answers.
IM_DEFS='
  def msg($id; $author; $date; $text; $params): {id: $id, chat_id: 6032, author_id: $author, date: $date, text: $text,
    unread: false, uuid: null, replaces: [], params: $params, disappearing_date: null};
  def user($id): {id: $id, active: true, name: "Тест Пользователь \($id)", first_name: "Тест\($id)",
    last_name: "Тестов\($id)", bot: false, type: "user"};'

stage22() {
  local CHAT LAST SELECT
  # No access: the portal answers so for a chat that does not exist; a chat the caller may not read gives the same code.
  record_im im_dialog_messages_get_НетДоступа im.dialog.messages.get '{"DIALOG_ID":"chat999999999","LIMIT":1}'

  CHAT="$(chat_of aiCommentMany)"
  record_im im_dialog_messages_get_Обычный im.dialog.messages.get "{\"DIALOG_ID\":\"chat$CHAT\",\"LIMIT\":50}"
  # A message number that is older than every message: the portal answers with empty lists.
  record_im im_dialog_messages_get_Пусто im.dialog.messages.get "{\"DIALOG_ID\":\"chat$CHAT\",\"LIMIT\":50,\"LAST_ID\":1}"
  record_im im_dialog_messages_get_ТолькоСистемные im.dialog.messages.get "{\"DIALOG_ID\":\"chat$(chat_of aiUpdate)\",\"LIMIT\":50}"

  # A picture and a reply with a quote, added by hand in the browser to the chat of aiCommentName (the script can only
  # write text). The file is a message with an empty text and params.FILE_ID, the picture is in files[]; the reply carries
  # no trace of the quote: only its own text.
  record_im im_dialog_messages_get_ФайлИЦитата im.dialog.messages.get "{\"DIALOG_ID\":\"chat$(chat_of aiCommentName)\",\"LIMIT\":50}"

  CHAT="$(chat_of aiCommentLong)"
  record_im im_dialog_messages_get_Страница1 im.dialog.messages.get "{\"DIALOG_ID\":\"chat$CHAT\",\"LIMIT\":50}"
  LAST="$("$B24" im.dialog.messages.get "{\"DIALOG_ID\":\"chat$CHAT\",\"LIMIT\":50}" 2>/dev/null | jq '[.result.messages[].id] | min')"
  record_im im_dialog_messages_get_Страница2 im.dialog.messages.get "{\"DIALOG_ID\":\"chat$CHAT\",\"LIMIT\":50,\"LAST_ID\":$LAST}"

  SELECT='["ID","TITLE","DESCRIPTION","CREATED_BY","RESPONSIBLE_ID","ACCOMPLICES","STATUS","GROUP_ID","UF_CRM_TASK","DEADLINE","CLOSED_DATE","ACTIVITY_DATE","CHAT_ID"]'
  record tasks_task_get_ЧатЗадачи tasks.task.get "{\"taskId\":$(id .tasks.aiCommentName),\"select\":$SELECT}"
  body_of tasks_task_get_ЧатЗадачи | jq '.result.task.chatId = null' | write_template tasks_task_get_БезЧата_Синтетика

  # Messages of several days around the border of the day of a timesheet (19.11.2026, the portal writes +03:00):
  # 18.11 23:59:59, 19.11 00:00:00, 19.11 23:59:59, 20.11 00:00:00, and a system message in the middle of the day.
  jq -n "$IM_DEFS"'
    {result: {chat_id: 6032, messages: [
        msg(288140; 26; "2026-11-20T00:00:00+03:00"; "Комментарий следующего дня."; []),
        msg(288139; 30; "2026-11-19T23:59:59+03:00"; "Комментарий вечера дня табеля."; []),
        msg(288138; 26; "2026-11-19T00:00:00+03:00"; "Комментарий начала дня табеля."; []),
        msg(288137; 30; "2026-11-18T23:59:59+03:00"; "Комментарий предыдущего дня."; []),
        msg(288136; 0; "2026-11-19T12:00:00+03:00"; "[USER=30]Тест Пользователь 30[/USER] изменил крайний срок задачи"; {NOTIFY: "N"})],
      users: [user(30), user(26)], files: []}}' | write_template im_dialog_messages_get_РазныеДни_Синтетика

  # Comments of other people: the product tells «свой» by author_id and never passes the numbers or names on.
  jq -n "$IM_DEFS"'
    {result: {chat_id: 6032, messages: [
        msg(288152; 30; "2026-11-19T15:00:00+03:00"; "Поставил, проверьте, пожалуйста."; []),
        msg(288151; 26; "2026-11-19T14:00:00+03:00"; "[USER=30]Тест Пользователь 30[/USER], Ирина Сергеевна просит поставить 1С-Коннект."; []),
        msg(288150; 28; "2026-11-19T13:00:00+03:00"; "Пётр Николаевич уточнил, что нужен 1С-Коннект и на второй ПК."; []),
        msg(288149; 0; "2026-11-19T12:00:00+03:00"; "[USER=26]Тест Пользователь 26[/USER] создал [URL=/workgroups/group/38/tasks/task/view/10740/]задачу[/URL]"; {NOTIFY: "N"})],
      users: [user(30), user(26), user(28)], files: []}}' | write_template im_dialog_messages_get_ЧужиеАвторы_Синтетика

  # A full page from the middle of a long chat: the next page is asked with LAST_ID = the lowest number of this one.
  jq -n "$IM_DEFS"'
    {result: {chat_id: 6032, messages: [range(288249; 288199; -1) as $i
        | msg($i; (if $i % 2 == 0 then 30 else 26 end); "2026-11-19T12:00:00+03:00"; "Комментарий \($i)."; [])],
      users: [user(30), user(26)], files: []}}' | write_template im_dialog_messages_get_СредняяСтраница_Синтетика
}
if [ "${1:-}" = stage22 ]; then stage22; exit 0; fi

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

# The body of a recorded template: without the BOM and the CR of its CRLF lines.
# (A pipe, not <(…): jq.exe on Windows can't open the /proc/…/fd path of a process substitution.)
body_of() { tail -c +4 "$TEMPLATES/$PREFIX$1/Ext/Template.txt" | tr -d '\r'; }

# Synthetic answers. A Russian company: the BIN answer with the number moved to RQ_INN of a Russian preset.
body_of crm_requisite_list_БИН \
  | jq '.result |= map(.PRESET_ID = "7" | .NAME = "Российская организация" | .RQ_INN = .RQ_BIN | .RQ_BIN = null)' \
  | write_template crm_requisite_list_ИНН_Синтетика
# Error bodies as documented for QUERY_LIMIT_EXCEEDED (HTTP 503) and INTERNAL_SERVER_ERROR (HTTP 500).
echo '{"error":"QUERY_LIMIT_EXCEEDED","error_description":"Too many requests"}' | write_template Ошибка_ЛимитЗапросов_Синтетика
echo '{"error":"INTERNAL_SERVER_ERROR","error_description":"Internal server error"}' | write_template Ошибка_Сервер_Синтетика

# Stage 5: answers for the client tests.
record user_admin_Да user.admin '{}'
record tasks_task_list_Пусто tasks.task.list '{"filter":{"ID":0},"select":["ID"]}'
record crm_company_list_Пусто crm.company.list '{"filter":{"ID":[999999999]},"select":["ID","TITLE"]}'
record sonet_group_get_НеНайден sonet_group.get '{"FILTER":{"ID":999999999}}'

body_of user_admin_Да | jq '.result = false' | write_template user_admin_Нет_Синтетика
# Stage 6: an inactive user, and two different users matching the addresses of one employee.
body_of user_get_Найден | jq '.result[0].ACTIVE = false' | write_template user_get_Неактивный_Синтетика
body_of user_get_Найден \
  | jq '.result += [{ID: "31", ACTIVE: true, NAME: "Тест", LAST_NAME: "Двойник", EMAIL: "Test.User.Second@Example.com"}] | .total = 2' \
  | write_template user_get_ДваПользователя_Синтетика
# A middle page of a task list: 50 more ids, and `next` points to the third page.
body_of tasks_task_list_Страница1 \
  | jq '.result.tasks = [range(100001; 100051) | {id: tostring, group: []}] | .next = 100 | .total = 120' \
  | write_template tasks_task_list_СредняяСтраница_Синтетика
# System error bodies as documented at https://apidocs.bitrix24.com/error-codes.html
echo '{"error":"insufficient_scope","error_description":"The request requires higher privileges than provided by the webhook token"}' | write_template Ошибка_НетПрава_Синтетика
echo '{"error":"ERROR_METHOD_NOT_FOUND","error_description":"Method not found!"}' | write_template Ошибка_МетодНеНайден_Синтетика
echo '{"error":"ACCESS_DENIED","error_description":"Access denied!"}' | write_template Ошибка_ДоступЗапрещён_Синтетика
echo '{"error":"OPERATION_TIME_LIMIT","error_description":"Method is blocked due to operation time limit"}' | write_template Ошибка_ВремяМетода_Синтетика

# Stage 8: all test companies and their requisites in one answer each, as the product asks (one call for the whole list).
ALL="$(jq -c '[.companies[]]' "$IDS")"
record crm_company_list_НаборС6 crm.company.list "{\"filter\":{\"ID\":$ALL},\"select\":[\"ID\",\"TITLE\"]}"
record crm_requisite_list_НаборС6 crm.requisite.list \
  "{\"filter\":{\"ENTITY_TYPE_ID\":4,\"ENTITY_ID\":$ALL},\"select\":$RQ_SELECT,\"order\":{\"SORT\":\"ASC\",\"ID\":\"ASC\"}}"

# Stage 14 (also runs alone: scripts/b24-record-responses.sh stage14).
stage14
stage17
stage22

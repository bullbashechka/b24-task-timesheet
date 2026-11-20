#!/bin/bash
# Stage 22: checks of the chats of tasks through the development webhook (scripts/b24.sh).
# Answers about OTHER people's tasks are never shown or saved: the script prints only numbers and codes, and its
# jq filters build the printed lines from numbers, never from texts. `own` shows the chat of an own test task
# (invented texts), with the people replaced (scripts/sanitize-im.jq).
# Usage: scripts/b24-chat-check.sh owner
#        scripts/b24-chat-check.sh candidates      tasks of the last 30 days the webhook owner has no role in
#        scripts/b24-chat-check.sh old-count       how many tasks of the window have no chat or old comments
#        scripts/b24-chat-check.sh access ID…      does the portal give the chat of such a task to the webhook owner?
#        scripts/b24-chat-check.sh own KEY ['{"LAST_ID":N}']   the chat of an own test task (task key of ids.json)
# Exit codes: 0 — done, 1 — a check failed (Bitrix24 refused, the chat changed), 2 — usage or setup error.
# Must run outside the Claude Code sandbox, like scripts/b24.sh.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/common.sh"
B24="$DIR/b24.sh"
IDS="$DIR/b24-test-data.ids.json"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HTTP=""

call() { # method params [--write]: the answer goes to $TMP/body and never to the screen, HTTP gets the status
  local RC
  "$B24" "$@" > "$TMP/body" 2> "$TMP/err"; RC=$?
  HTTP="$(sed -n 's/^HTTP \([0-9]*\).*/\1/p' "$TMP/err" | tail -n 1)"
  if [ "$RC" = 2 ]; then cat "$TMP/err" >&2; exit 2; fi
  jq -e 'type == "object"' "$TMP/body" >/dev/null 2>&1 || echo '{"error":"NOT_JSON"}' > "$TMP/body"
}

owner_id() { call user.current '{}'; jq -r '.result.ID // empty' "$TMP/body"; }

# The role of the webhook owner in a task and its chat: "member|outsider|none CHAT GROUP" (numbers only).
task_facts() { # task id, owner id
  call tasks.task.get "{\"taskId\":$1,\"select\":[\"ID\",\"CREATED_BY\",\"RESPONSIBLE_ID\",\"ACCOMPLICES\",\"AUDITORS\",\"GROUP_ID\",\"CHAT_ID\"]}"
  jq -r --arg me "$2" '
    (.result | if type == "object" then .task else null end) as $t
    | if $t == null then "none 0 0"
      else (([$t.createdBy, $t.responsibleId] + ($t.accomplices // []) + ($t.auditors // []) | map(tostring)) | index($me)) as $i
        | "\(if $i == null then "outsider" else "member" end) \($t.chatId // 0) \($t.groupId // 0)"
      end' "$TMP/body"
}

read_chat() { call im.dialog.messages.get "{\"DIALOG_ID\":\"chat$1\",\"LIMIT\":50}"; }

# One line about the answer in $TMP/body: counts and codes, no texts.
summary() {
  jq -r 'if .error then "ошибка \(.error)"
    else (.result.messages // []) as $m
      | "сообщений \($m | length), системных \([$m[] | select(.author_id == 0)] | length), новейшее \([$m[].id] | max // 0), коды системных [\([$m[] | select(.author_id == 0) | .params.CODE? // empty | tostring] | join(","))]"
    end' "$TMP/body"
}
newest() { jq -r '[(.result.messages // [])[].id] | max // 0' "$TMP/body"; }

access() {
  local ME T FACTS KIND CHAT GROUP MAX1 COUNT1 MAX2 COUNT2 OK=0 FAILED=0 CHECKED=0
  ME="$(owner_id)"
  [ -n "$ME" ] || { echo "Номер владельца вебхука не получен." >&2; exit 1; }
  for T in "$@"; do
    printf '%s' "$T" | grep -Eqx '[0-9]+' || { echo "Номер задачи: $T — не число." >&2; exit 2; }
    FACTS="$(task_facts "$T" "$ME")"
    read -r KIND CHAT GROUP <<< "$FACTS"
    case "$KIND" in
      none) echo "Задача $T: не найдена"; FAILED=1; continue ;;
      member) echo "Задача $T: владелец вебхука — участник, для проверки не годится"; continue ;;
    esac
    CHECKED=$((CHECKED + 1))
    if [ "$CHAT" = 0 ]; then echo "Задача $T (проект $GROUP): чата нет (chatId пуст)"; continue; fi
    read_chat "$CHAT"
    echo "Задача $T (проект $GROUP, чат $CHAT): чтение 1: HTTP $HTTP, $(summary)"
    if [ "$(jq -r '.error // empty' "$TMP/body")" != "" ]; then FAILED=1; continue; fi
    MAX1="$(newest)"; COUNT1="$(jq '.result.messages | length' "$TMP/body")"
    read_chat "$CHAT"
    MAX2="$(newest)"; COUNT2="$(jq '.result.messages | length' "$TMP/body")"
    if [ "$MAX2" != "$MAX1" ] || [ "$COUNT2" != "$COUNT1" ]; then
      echo "  СТОП: после чтения в чате появилось сообщение (было $COUNT1, стало $COUNT2). Новые: авторы и коды:" \
        "$(jq -r --argjson m "$MAX1" '[(.result.messages // [])[] | select(.id > $m) | "\(.author_id)/\(.params.CODE? // "-" | tostring)"] | join(" ")' "$TMP/body")"
      FAILED=1
      break # the first sign that reading changes a chat stops the check: no more colleagues' chats are touched
    else
      echo "  чтение 2: те же сообщения, новых нет"
      OK=$((OK + 1))
    fi
  done
  echo "ИТОГ: чат отдан в $OK из $CHECKED проверенных задач"
  [ "$FAILED" = 0 ] || exit 1
}

# The tasks of the window: open or closed in the last 30 days, newest first, 10 pages (500 tasks) at most, as one JSON
# line per task in $TMP/tasks.jsonl: numbers only (id, project, closed, chat, old comments, the webhook owner's role).
load_tasks() { # owner id
  local SINCE START=0 PAGE=0 MAX_PAGES=10 NEXT
  SINCE="$(date_shift -30 '%d.%m.%Y') 00:00:00"
  : > "$TMP/tasks.jsonl"
  while [ "$PAGE" -lt "$MAX_PAGES" ]; do
    call tasks.task.list "{\"filter\":{\"::SUBFILTER-ST\":{\"::LOGIC\":\"OR\",\"!REAL_STATUS\":5,\">=CLOSED_DATE\":\"$SINCE\"}},\"select\":[\"ID\",\"CREATED_BY\",\"RESPONSIBLE_ID\",\"ACCOMPLICES\",\"AUDITORS\",\"GROUP_ID\",\"STATUS\",\"REAL_STATUS\",\"CHAT_ID\",\"FORUM_TOPIC_ID\",\"COMMENTS_COUNT\"],\"order\":{\"ID\":\"desc\"},\"start\":$START}"
    if [ "$(jq -r '.error // empty' "$TMP/body")" != "" ]; then echo "tasks.task.list: ошибка $(jq -r '.error' "$TMP/body")" >&2; exit 1; fi
    TOTAL="$(jq -r '.total // 0' "$TMP/body")"
    jq -c --arg me "$1" '.result.tasks[] | {id: (.id | tonumber), group: ((.groupId // "0") | tonumber), closed: ((.realStatus // .status) == "5"),
        chat: ((.chatId // "0") | tonumber), forum: (.forumTopicId != null and .forumTopicId != "0"), old: ((.commentsCount // "0") | tonumber),
        member: (([.createdBy, .responsibleId] + (.accomplices // []) + (.auditors // []) | map(tostring)) | index($me) != null)}' "$TMP/body" >> "$TMP/tasks.jsonl"
    NEXT="$(jq -r '.next // empty' "$TMP/body")"
    PAGE=$((PAGE + 1))
    [ -n "$NEXT" ] || break
    START="$NEXT"
  done
  PAGES="$PAGE"
  echo "Просмотрено задач: $(wc -l < "$TMP/tasks.jsonl" | tr -d ' ') из $TOTAL (страниц $PAGES)"
}

# Tasks that are open or were closed in the last 30 days, in which the webhook owner has no role at all.
candidates() {
  local ME TOTAL PAGES G MEMBERS
  ME="$(owner_id)"
  [ -n "$ME" ] || { echo "Номер владельца вебхука не получен." >&2; exit 1; }
  load_tasks "$ME"
  echo "Вне проекта, владелец не участник: закрытых $(jq -s '[.[] | select(.member | not) | select(.group == 0) | select(.closed)] | length' "$TMP/tasks.jsonl"), открытых $(jq -s '[.[] | select(.member | not) | select(.group == 0) | select(.closed | not)] | length' "$TMP/tasks.jsonl")"
  echo "  примеры закрытых: $(jq -s -r '[.[] | select(.member | not) | select(.group == 0) | select(.closed) | .id][:5] | join(" ")' "$TMP/tasks.jsonl")"
  # Projects in which the owner is not a member: the groups of the closed outsider tasks, 8 at most.
  echo "В проектах (владелец не участник задачи), группы закрытых задач:"
  for G in $(jq -s -r '[.[] | select(.member | not) | select(.group != 0) | select(.closed) | .group] | unique[:8] | .[]' "$TMP/tasks.jsonl"); do
    call sonet_group.user.get "{\"ID\":$G}"
    MEMBERS="$(jq -r --arg me "$ME" 'if .error then "?" else ([(.result // [])[] | (.USER_ID // .user_id) | tostring] | index($me) != null | tostring) end' "$TMP/body")"
    echo "  проект $G: владелец состоит: $MEMBERS; закрытые задачи: $(jq -s -r --argjson g "$G" '[.[] | select(.member | not) | select(.group == $g) | select(.closed) | .id][:3] | join(" ")' "$TMP/tasks.jsonl")"
  done
}

# How many tasks of the window have no chat (their comments are not readable) and how many have old comments.
old_count() {
  local ME TOTAL PAGES
  ME="$(owner_id)"
  [ -n "$ME" ] || { echo "Номер владельца вебхука не получен." >&2; exit 1; }
  load_tasks "$ME"
  jq -s -r '"Без чата (chatId пуст): \([.[] | select(.chat == 0)] | length), из них закрытых \([.[] | select(.chat == 0 and .closed)] | length)
"
    + "С чатом: \([.[] | select(.chat != 0)] | length)
"
    + "С номером темы старых комментариев (forumTopicId): \([.[] | select(.forum)] | length)
"
    + "Самые старые номера задач без чата: \([.[] | select(.chat == 0) | .id] | sort[:5] | join(" "))
"
    + "Самая новая задача без чата: \([.[] | select(.chat == 0) | .id] | max // 0)"' "$TMP/tasks.jsonl"
}

# The tasks of the window that have old comments (forumTopicId): are the old comments in the chat too?
# Prints per task: the old comment counter and the number of the non-system messages of the chat (numbers only).
forum_check() {
  local ME TOTAL PAGES T LINE
  ME="$(owner_id)"
  [ -n "$ME" ] || { echo "Номер владельца вебхука не получен." >&2; exit 1; }
  load_tasks "$ME"
  for T in $(jq -s -r '[.[] | select(.forum)] | .[:15] | .[] | "\(.id):\(.chat):\(.old):\(.closed)"' "$TMP/tasks.jsonl"); do
    IFS=: read -r ID CHAT OLD CLOSED <<< "$T"
    read_chat "$CHAT"
    echo "Задача $ID: старых комментариев $OLD, закрыта $CLOSED; чат: HTTP $HTTP, $(summary),"       "обычных сообщений $(jq '[(.result.messages // [])[] | select(.author_id != 0)] | length' "$TMP/body")"
  done
}

# The chat of an own test task, as the portal returns it, with the people replaced.
own() {
  local KEY="${1:-}" EXTRA="${2:-}" TASK ME FACTS KIND CHAT GROUP
  [ -n "$EXTRA" ] || EXTRA='{}'
  [ -n "$KEY" ] || { echo "Нужен ключ задачи." >&2; exit 2; }
  TASK="$(jq -r --arg k "$KEY" '.tasks[$k] // empty' "$IDS" 2>/dev/null)"
  [ -n "$TASK" ] || { echo "Задачи $KEY нет в $IDS." >&2; exit 2; }
  ME="$(owner_id)"
  FACTS="$(task_facts "$TASK" "$ME")"
  read -r KIND CHAT GROUP <<< "$FACTS"
  [ "$CHAT" != 0 ] || { echo "У задачи $KEY ($TASK) нет chatId." >&2; exit 1; }
  echo "Задача $KEY ($TASK): роль владельца вебхука — $KIND, чат $CHAT"
  # Chat and comment fields of the task itself (an own task: invented data).
  call tasks.task.get "{\"taskId\":$TASK}"
  jq -c '(.result.task // {}) | with_entries(select(.key | test("chat|forum|comment"; "i")))' "$TMP/body"
  call im.dialog.messages.get "$(jq -cn --arg d "chat$CHAT" --argjson x "$EXTRA" '{DIALOG_ID: $d, LIMIT: 50} + $x')"
  echo "HTTP $HTTP, $(summary)"
  jq -f "$DIR/sanitize-im.jq" "$TMP/body"
}

case "${1:-}" in
  owner) echo "Владелец вебхука: $(owner_id)" ;;
  candidates) candidates ;;
  old-count) old_count ;;
  forum-check) forum_check ;;
  access) shift; [ $# -gt 0 ] || { echo "Нужны номера задач." >&2; exit 2; }; access "$@" ;;
  own) shift; own "$@" ;;
  *) sed -n '5,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac

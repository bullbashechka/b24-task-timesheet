#!/bin/bash
# UI check of the 1C windows without a human: builds the external data processor tools/ui-check, starts a 1C test
# client (/TESTCLIENT) and a test manager (/TESTMANAGER /Execute) on the local base, and prints what the user would
# see plus the error entries of the event log.
#
#   scripts/ui-check.sh [scenario] [--user "1C user name"]
#
# Scenarios are procedures of tools/ui-check (default «окно»). Task numbers come from scripts/b24-test-data.ids.json (see
# scripts/b24-test-data.sh create-tasks) and are passed to the processor as «tasks=ключ:номер,…»; each scenario lists the
# keys it needs:
#   окно, поиск, чужой — none; строка — ownDalstroy, ownNoCompany; список, контрагенты — the whole set;
#   права — observer, outside; сотрудник — ownDalstroy; безтеста — outside; ии — aiUpdate, aiNoValue, aiNoMatch,
#   aiCommentName, aiCommentMany, aiCommentDays (AI switched on with the development key in the settings of the base; the
#   scenario switches «Передавать ИИ комментарии задачи» on for С26–С28 and off again in any case, восстановить switches it
#   off too; the days of the comments of aiCommentDays are read from its chat, dates only, as days=); ии-настройки — aiNoValue
#   (the settings form: nothing is written); ии-отказы — aiNoValue (the windows with the flag off, switched off while the
#   window is open, a wrong model, no connection with OpenAI through scripts/block-proxy.py as the proxy of the user: the
#   flag, the model and the proxy are put back in any case; a fresh client, because after the settings form the wait handlers
#   of the test client work unreliably); ии-сотрудник — ownDalstroy (run with
#   --user "[ТЕСТ] Сотрудник"); безопасность — the keys of the webhook and of OpenAI are searched in the event log and in the
#   files listed in .local/ui-check/leak-files.txt, the texts of the test tasks, comments, passwords and drafts
#   (.local/ui-check/leak-texts.txt) only in the event log; восстановить — puts the base back after an interrupted run
#   (test mode on with the project, «[ТЕСТ] Сотрудник» unlinked, scenario timesheets deleted, the proxy, the model and the
#   «[ТЕСТ]» formulation of the AI scenarios removed).
# --user runs only the test client (what the user sees) under another 1C user (сотрудник, чужой: "[ТЕСТ] Сотрудник"); the
# test manager always runs under the registry user, who can read the event log.
# Exit codes: 0 all checks passed, 1 some failed, 2 environment not ready (no report, build error, timeout).
#
# Works on macOS and on Windows (Git Bash, see scripts/common.sh). Must run outside the Claude Code sandbox: 1C exits
# with 134 inside it. The script starts exactly two 1C processes and kills only those: the client behind the 1c MCP
# server and the user's own sessions are never touched. On Windows the platform is started by scripts/v8run.py (Git Bash
# would rewrite the 1C switches as paths), which writes the process id to a file; cleanup kills that process tree.

set -u
. "$(dirname "$0")/common.sh"
cd "$ROOT" || exit 2

REGISTRY="$ROOT/.v8-project.json"
OUT="$ROOT/.local/ui-check"
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-}
SCENARIO="окно"
USER_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --user)
      [ -n "${2:-}" ] || { echo "ENV: --user needs a 1C user name"; exit 2; }
      USER_OVERRIDE="$2"; shift 2 ;;
    *) SCENARIO="$1"; shift ;;
  esac
done

[ -f "$REGISTRY" ] || { echo "ENV: no $REGISTRY"; exit 2; }
V8PATH="$(registry_value .v8path)"
BASE_PATH="$(registry_value '.databases[0].path')"
BASE_USER="$(registry_value '.databases[0].user')"
CLIENT_USER=${USER_OVERRIDE:-$BASE_USER}
if [ "$IS_WINDOWS" = 1 ]; then
  V8CLIENT="$V8PATH\\1cv8c.exe"
  [ -f "$(cygpath -u "$V8CLIENT")" ] || { echo "ENV: no $V8CLIENT"; exit 2; }
  # This PC uses its license key: with /UseHwLicenses- the client does not start (see run-tests.sh).
  LICENSE_ARGS=()
else
  V8CLIENT="$V8PATH/1cv8c"
  [ -x "$V8CLIENT" ] || { echo "ENV: no $V8CLIENT"; exit 2; }
  LICENSE_ARGS=(/UseHwLicenses-)
fi

# A client under another user needs his roles; the platform update after loading an extension can take them away.
if [ -n "$USER_OVERRIDE" ] && [ "$SCENARIO" != "роли" ]; then
  "$0" роли | grep -E '^(Роли|ENV|ИТОГ)' | head -3
fi

mkdir -p "$OUT"
rm -f "$OUT/report.txt" "$OUT/build.log" "$OUT/client.log" "$OUT/manager.log" "$OUT/client.pid" "$OUT/manager.pid"

echo "== building tools/ui-check"
if ! "$PY" .claude/skills/epf-build/scripts/epf-build.py -SourceFile tools/ui-check/src/UiCheck.xml \
     -OutputFile "$(native_path "$OUT/UiCheck.epf")" -V8Path "$V8PATH" -Checks off > "$OUT/build.log" 2>&1; then
  tail -20 "$OUT/build.log"
  echo "ENV: build failed"
  exit 2
fi

IDS=scripts/b24-test-data.ids.json
case "$SCENARIO" in
  строка) NEEDS="ownDalstroy ownNoCompany" ;;
  список|контрагенты) NEEDS="dalstroy arkharov dalstroy2 norq nobin kikinda dup twoCompanies noCompany observer outside ownDalstroy ownNoCompany" ;;
  права) NEEDS="observer outside" ;;
  сотрудник) NEEDS="ownDalstroy" ;;
  безтеста) NEEDS="outside" ;;
  ии) NEEDS="aiUpdate aiNoValue aiNoMatch aiCommentName aiCommentMany aiCommentDays" ;;
  ии-настройки|ии-отказы) NEEDS="aiNoValue" ;;
  ии-сотрудник) NEEDS="ownDalstroy" ;;
  *) NEEDS="" ;;
esac
for KEY in $NEEDS; do
  [ -n "$(jq -r --arg k "$KEY" '.tasks[$k] // empty' "$IDS" 2>/dev/null)" ] \
    || { echo "ENV: no task $KEY in $IDS (scripts/b24-test-data.sh create-tasks $KEY)"; exit 2; }
done
# The AI scenarios work on the real tasks of the portal: a task deleted there gives an empty answer, which the window
# reports as «задача недоступна» and the scenario would blame the AI. The portal is asked for the number only.
case "$SCENARIO" in
  ии|ии-настройки|ии-отказы|ии-сотрудник)
    for KEY in $NEEDS; do
      ID=$(jq -r --arg k "$KEY" '.tasks[$k]' "$IDS")
      [ -n "$(scripts/b24.sh tasks.task.get "{\"taskId\": $ID, \"select\": [\"ID\"]}" 2>/dev/null | jq -r '.result.task.id // empty' 2>/dev/null)" ] \
        || { echo "ENV: the task $KEY ($ID) is not on the portal (scripts/b24-test-data.sh create-tasks $KEY)"; exit 2; }
    done ;;
esac
TASKS=$(jq -r '.tasks | to_entries | map("\(.key):\(.value)") | join(",")' "$IDS" 2>/dev/null)
PROJECT=$(jq -r '.project // 0' "$IDS" 2>/dev/null)

# «список»: the day the completed test task was closed (the 30-day boundary is counted from it, not from today)
CLOSED=""
if [ "$SCENARIO" = "список" ]; then
  CLOSED=$(scripts/b24.sh tasks.task.get "{\"taskId\": $(jq -r '.tasks.dalstroy' "$IDS"), \"select\": [\"ID\", \"CLOSED_DATE\"]}" 2>/dev/null \
    | jq -r '.result.task.closedDate // empty | .[0:10]')
  [ -n "$CLOSED" ] || { echo "ENV: the task dalstroy has no closedDate on the portal"; exit 2; }
fi

# «ии»: the days of the comments of aiCommentDays (С28), from its chat: dates only, no texts. The chat dates are in the
# portal time zone, the days are the local ones, as the timesheet date is.
chat_days() {
  local CHAT
  CHAT=$(scripts/b24.sh tasks.task.get "{\"taskId\": $1, \"select\": [\"ID\", \"CHAT_ID\"]}" 2>/dev/null | jq -r '.result.task.chatId // empty' 2>/dev/null)
  [ -n "$CHAT" ] || return 0
  scripts/b24.sh im.dialog.messages.get "{\"DIALOG_ID\": \"chat$CHAT\", \"LIMIT\": 50}" 2>/dev/null | "$PY" -I -X utf8 -c '
import json, sys
from datetime import datetime
data = json.load(sys.stdin)
days = sorted({datetime.fromisoformat(m["date"]).astimezone().strftime("%Y-%m-%d")
               for m in data.get("result", {}).get("messages", []) if m.get("author_id")})
print(",".join(days))
'
}
DAYS=""
if [ "$SCENARIO" = "ии" ]; then
  DAYS=$(chat_days "$(jq -r '.tasks.aiCommentDays' "$IDS")" | tr -d '\r')
  case "$DAYS" in *,*) ;; *) echo "ENV: the comments of aiCommentDays are written on one day only (b24-test-data.sh add-comments aiCommentDays day2)"; exit 2 ;; esac
fi

# «безопасность»: text files to search for the keys of the webhook and of OpenAI (tracked files and the local reports and
# logs), as the platform sees their paths; and the texts of the test tasks, their comments, the passwords and the drafts of
# the examples, which must not be in the event log (one text per line, from the files of the repository)
LEAK_FILES=""
LEAK_TEXTS=""
if [ "$SCENARIO" = "безопасность" ]; then
  LEAK_FILES="$OUT/leak-files.txt"
  { git -c core.quotepath=off ls-files | grep -E '\.(bsl|xml|md|sh|json|txt|log|py|yml|yaml|html|js|ts|mxl)$'
    find .local/tests .local/ui-check .local/logs -type f \( -name '*.xml' -o -name '*.log' -o -name '*.txt' -o -name '*.json' -o -name '*.md' \) 2>/dev/null
    find .local/ai -maxdepth 2 -path '.local/ai/live-*' -type f \( -name '*.txt' -o -name '*.json' \) 2>/dev/null
  } | sort -u | sed "s|^|$ROOT/|" | if [ "$IS_WINDOWS" = 1 ]; then cygpath -w -f -; else cat; fi > "$LEAK_FILES"
  LEAK_TEXTS="$OUT/leak-texts.txt"
  "$PY" -I -X utf8 - "$ROOT" > "$LEAK_TEXTS" <<'PYEOF'
import json, pathlib, sys

root = pathlib.Path(sys.argv[1])
lines = set()


def add(text):
    text = " ".join(str(text).split())
    if len(text) >= 15:
        lines.add(text)


def walk(node):
    if isinstance(node, dict):
        if str(node.get("key", "")).startswith("ai"):
            add(node.get("title", ""))
            name = node.get("descriptionFile")
            if name:
                for part in (root / "scripts/b24-test-data" / name).read_text(encoding="utf-8-sig").splitlines():
                    add(part)
            for comment in node.get("comments", []):
                add(comment.get("text", ""))
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)


walk(json.load(open(root / "scripts/b24-test-data.json", encoding="utf-8-sig")))
lines.update(("Qwerty123", "Abc12345", "Qwe123rty"))
base = root / "src/cfe/Б24ТабельИзЗадачиТесты/CommonTemplates"
for name in ("б24тТест_ПримерыИИ", "б24тТест_ПримерыИИКомментарии"):
    for example in json.load(open(base / name / "Ext/Template.txt", encoding="utf-8-sig")):
        add(example.get("черновик", ""))
        for comment in example.get("комментарии", []):
            add(comment.get("текст", ""))
print("\n".join(sorted(lines)))
PYEOF
  [ -s "$LEAK_TEXTS" ] || { echo "ENV: no texts for the search in the event log"; exit 2; }
fi

# Scenarios that wait for the platform and for the portal need more than 4 minutes.
if [ -z "$TIMEOUT_SECONDS" ]; then
  case "$SCENARIO" in
    сотрудник|ии-настройки|ии-отказы|ии-сотрудник) TIMEOUT_SECONDS=480 ;;
    ии) TIMEOUT_SECONDS=600 ;;
    безопасность) TIMEOUT_SECONDS=600 ;;
    список|контрагенты|безтеста) TIMEOUT_SECONDS=360 ;;
    *) TIMEOUT_SECONDS=240 ;;
  esac
fi

free_port() {
  "$PY" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
PORT=$(free_port)
SINCE=$(date +%Y%m%d%H%M%S)
CLIENT_PID=""
MANAGER_PID=""
PROXY_PID=""
PROXY_PORT=0
PROXY_LOG="$OUT/proxy.log"

# Starts the platform in the background with the arguments as 1C expects them (values in their own quotes). $1 is the
# file for the process id (Windows only); the caller takes the job id from $!.
start_v8() {
  local PIDFILE="$1"; shift
  if [ "$IS_WINDOWS" = 1 ]; then
    MSYS_NO_PATHCONV=1 "$PY" "$(native_path "$ROOT/scripts/v8run.py")" --pidfile "$(native_path "$PIDFILE")" -- \
      "$V8CLIENT" "$@" &
  else
    local ARGS=()
    local A
    # On macOS the arguments go as a list: the framing quotes of /F"…" would become part of the value.
    for A in "$@"; do
      if [ "${A:0:1}" = "/" ] && [ "${A: -1}" = '"' ] && [[ "${A:0:${#A}-1}" == *'"'* ]]; then
        A="${A%\"}"; A="${A/\"/}"
      fi
      ARGS+=("$A")
    done
    "$V8CLIENT" "${ARGS[@]}" &
  fi
}

cleanup() {
  if [ "$IS_WINDOWS" = 1 ]; then
    for F in "$OUT/manager.pid" "$OUT/client.pid" "$OUT/proxy.pid"; do
      [ -s "$F" ] && MSYS_NO_PATHCONV=1 taskkill /PID "$(tr -cd '0-9' < "$F")" /T /F >/dev/null 2>&1
      rm -f "$F"
    done
  fi
  for pid in $MANAGER_PID $CLIENT_PID $PROXY_PID; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  sleep 1
  for pid in $MANAGER_PID $CLIENT_PID $PROXY_PID; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    [ -n "$pid" ] && wait "$pid" 2>/dev/null
  done
}
trap cleanup EXIT

port_open() {
  "$PY" -c 'import socket, sys; s = socket.socket(); s.settimeout(1); sys.exit(s.connect_ex(("127.0.0.1", int(sys.argv[1]))))' "$PORT"
}

# «ии-отказы»: the local proxy that cuts only OpenAI (С21, no connection); the scenario puts it into the settings of the
# proxy of the user and takes it out again
if [ "$SCENARIO" = "ии-отказы" ]; then
  PROXY_PORT=$(free_port)
  rm -f "$OUT/proxy.pid" "$PROXY_LOG"
  "$PY" "$(native_path "$ROOT/scripts/block-proxy.py")" "$PROXY_PORT" --pidfile "$(native_path "$OUT/proxy.pid")" \
    --log "$(native_path "$PROXY_LOG")" &
  PROXY_PID=$!
  sleep 1
  echo "== local proxy on port $PROXY_PORT (cuts openai.com only)"
fi

echo "== test client on port $PORT as «${CLIENT_USER}»"
start_v8 "$OUT/client.pid" ENTERPRISE "/F\"$BASE_PATH\"" "/N\"$CLIENT_USER\"" /TESTCLIENT "-TPort$PORT" \
  /DisableStartupDialogs /DisableStartupMessages /DisableUnrecoverableErrorMessage "${LICENSE_ARGS[@]}" \
  "/Out\"$(native_path "$OUT/client.log")\""
CLIENT_PID=$!

WAITED=0
until port_open; do
  kill -0 "$CLIENT_PID" 2>/dev/null || { echo "ENV: test client exited"; cat "$OUT/client.log" 2>/dev/null; exit 2; }
  [ "$WAITED" -ge 90 ] && { echo "ENV: test client did not start in 90 s"; exit 2; }
  sleep 1
  WAITED=$((WAITED + 1))
done

echo "== test manager as «${BASE_USER}», scenario «${SCENARIO}»"
REPORT_NATIVE="$(native_path "$OUT/report.txt")"
LEAK_NATIVE=""
[ -n "$LEAK_FILES" ] && LEAK_NATIVE="$(native_path "$LEAK_FILES")"
TEXTS_NATIVE=""
[ -n "$LEAK_TEXTS" ] && TEXTS_NATIVE="$(native_path "$LEAK_TEXTS")"
start_v8 "$OUT/manager.pid" ENTERPRISE "/F\"$BASE_PATH\"" "/N\"$BASE_USER\"" /TESTMANAGER \
  "/Execute\"$(native_path "$OUT/UiCheck.epf")\"" \
  "/C\"out=$REPORT_NATIVE;port=$PORT;scenario=$SCENARIO;since=$SINCE;tasks=$TASKS;project=$PROJECT;closed=$CLOSED;files=$LEAK_NATIVE;days=$DAYS;proxy=$PROXY_PORT;texts=$TEXTS_NATIVE\"" \
  /DisableStartupDialogs /DisableStartupMessages /DisableUnrecoverableErrorMessage "${LICENSE_ARGS[@]}" \
  "/Out\"$(native_path "$OUT/manager.log")\""
MANAGER_PID=$!

# The processor writes the report with a final «ИТОГ:» line and then exits; the script does not wait for the
# manager process to disappear: the report is enough.
WAITED=0
while kill -0 "$MANAGER_PID" 2>/dev/null; do
  grep -q '^ИТОГ:' "$OUT/report.txt" 2>/dev/null && break
  [ "$WAITED" -ge "$TIMEOUT_SECONDS" ] && { echo "ENV: test manager did not finish in $TIMEOUT_SECONDS s"; break; }
  sleep 2
  WAITED=$((WAITED + 2))
done

if [ ! -f "$OUT/report.txt" ]; then
  echo "ENV: no report"
  cat "$OUT/manager.log" 2>/dev/null
  exit 2
fi

# The report is UTF-8 with BOM (CRLF on Windows); webhook keys never reach it (the processor hides everything after
# «/rest/» on every write and fails the check if the text had one).
sed '1s/^\xEF\xBB\xBF//' "$OUT/report.txt" | tr -d '\r'
if [ -n "$PROXY_PID" ] && [ -f "$PROXY_LOG" ]; then
  echo "== local proxy: cut $(grep -c '^blocked' "$PROXY_LOG") connection(s) to OpenAI, let through $(grep -c '^allowed' "$PROXY_LOG")"
fi
if tr -d '\r' < "$OUT/report.txt" | grep -q '^ИТОГ: ПРОЙДЕНО'; then
  exit 0
fi
# No final line: the scenario hung or crashed, the report shows the last step.
if ! grep -q '^ИТОГ:' "$OUT/report.txt"; then
  echo "ENV: scenario did not finish"
  # Killing the processes skips the restore inside the run: put the base back (link of the test user, test mode).
  case "$SCENARIO" in
    сотрудник|безтеста|ии|ии-настройки|ии-отказы|ии-сотрудник)
      cleanup
      echo "== восстановление базы после прерванного прогона"
      "$0" восстановить | tail -5 ;;
  esac
  exit 2
fi
exit 1

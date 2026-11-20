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
#   права — observer, outside; сотрудник — ownDalstroy; безтеста — outside; ии — aiUpdate, aiNoValue, aiCommentName (AI
#   switched on with the development key in the settings of the base; the scenario switches «Передавать ИИ комментарии
#   задачи» on for С26 and off again in any case, восстановить switches it off too); безопасность — the key of the webhook is searched in the
#   event log and in the files listed in .local/ui-check/leak-files.txt; восстановить — puts the base back after an
#   interrupted run (test mode on with the project, «[ТЕСТ] Сотрудник» unlinked, scenario timesheets deleted).
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
  ии) NEEDS="aiUpdate aiNoValue aiCommentName" ;;
  *) NEEDS="" ;;
esac
for KEY in $NEEDS; do
  [ -n "$(jq -r --arg k "$KEY" '.tasks[$k] // empty' "$IDS" 2>/dev/null)" ] \
    || { echo "ENV: no task $KEY in $IDS (scripts/b24-test-data.sh create-tasks $KEY)"; exit 2; }
done
TASKS=$(jq -r '.tasks | to_entries | map("\(.key):\(.value)") | join(",")' "$IDS" 2>/dev/null)
PROJECT=$(jq -r '.project // 0' "$IDS" 2>/dev/null)

# «список»: the day the completed test task was closed (the 30-day boundary is counted from it, not from today)
CLOSED=""
if [ "$SCENARIO" = "список" ]; then
  CLOSED=$(scripts/b24.sh tasks.task.get "{\"taskId\": $(jq -r '.tasks.dalstroy' "$IDS"), \"select\": [\"ID\", \"CLOSED_DATE\"]}" 2>/dev/null \
    | jq -r '.result.task.closedDate // empty | .[0:10]')
  [ -n "$CLOSED" ] || { echo "ENV: the task dalstroy has no closedDate on the portal"; exit 2; }
fi

# «безопасность»: text files to search for the webhook key (tracked files and the local reports and logs), as the
# platform sees their paths
LEAK_FILES=""
if [ "$SCENARIO" = "безопасность" ]; then
  LEAK_FILES="$OUT/leak-files.txt"
  { git -c core.quotepath=off ls-files | grep -E '\.(bsl|xml|md|sh|json|txt|log|py|yml|yaml|html|js|ts|mxl)$'
    find .local/tests .local/ui-check .local/logs -type f \( -name '*.xml' -o -name '*.log' -o -name '*.txt' -o -name '*.json' -o -name '*.md' \) 2>/dev/null
  } | sort -u | sed "s|^|$ROOT/|" | if [ "$IS_WINDOWS" = 1 ]; then cygpath -w -f -; else cat; fi > "$LEAK_FILES"
fi

# Scenarios that wait for the platform and for the portal need more than 4 minutes.
if [ -z "$TIMEOUT_SECONDS" ]; then
  case "$SCENARIO" in
    сотрудник) TIMEOUT_SECONDS=480 ;;
    безопасность) TIMEOUT_SECONDS=600 ;;
    список|контрагенты|безтеста) TIMEOUT_SECONDS=360 ;;
    *) TIMEOUT_SECONDS=240 ;;
  esac
fi

PORT=$("$PY" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
SINCE=$(date +%Y%m%d%H%M%S)
CLIENT_PID=""
MANAGER_PID=""

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
    for F in "$OUT/manager.pid" "$OUT/client.pid"; do
      [ -s "$F" ] && MSYS_NO_PATHCONV=1 taskkill /PID "$(tr -cd '0-9' < "$F")" /T /F >/dev/null 2>&1
      rm -f "$F"
    done
  fi
  for pid in $MANAGER_PID $CLIENT_PID; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  sleep 1
  for pid in $MANAGER_PID $CLIENT_PID; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    [ -n "$pid" ] && wait "$pid" 2>/dev/null
  done
}
trap cleanup EXIT

port_open() {
  "$PY" -c 'import socket, sys; s = socket.socket(); s.settimeout(1); sys.exit(s.connect_ex(("127.0.0.1", int(sys.argv[1]))))' "$PORT"
}

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
start_v8 "$OUT/manager.pid" ENTERPRISE "/F\"$BASE_PATH\"" "/N\"$BASE_USER\"" /TESTMANAGER \
  "/Execute\"$(native_path "$OUT/UiCheck.epf")\"" \
  "/C\"out=$REPORT_NATIVE;port=$PORT;scenario=$SCENARIO;since=$SINCE;tasks=$TASKS;project=$PROJECT;closed=$CLOSED;files=$LEAK_NATIVE\"" \
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
if tr -d '\r' < "$OUT/report.txt" | grep -q '^ИТОГ: ПРОЙДЕНО'; then
  exit 0
fi
# No final line: the scenario hung or crashed, the report shows the last step.
if ! grep -q '^ИТОГ:' "$OUT/report.txt"; then
  echo "ENV: scenario did not finish"
  # Killing the processes skips the restore inside the run: put the base back (link of the test user, test mode).
  case "$SCENARIO" in
    сотрудник|безтеста)
      cleanup
      echo "== восстановление базы после прерванного прогона"
      "$0" восстановить | tail -5 ;;
  esac
  exit 2
fi
exit 1

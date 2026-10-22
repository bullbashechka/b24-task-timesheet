#!/bin/bash
# UI check of the 1C windows without a human: builds the external data processor tools/ui-check, starts a 1C test
# client (/TESTCLIENT) and a test manager (/TESTMANAGER /Execute) on the local base, and prints what the user would
# see plus the error entries of the event log.
#
#   scripts/ui-check.sh [scenario] [--user "1C user name"]
#
# Scenarios are procedures of tools/ui-check (default «окно»). --user runs only the test client (what the user sees)
# under another 1C user; the test manager always runs under the registry user, who can read the event log.
# Exit codes: 0 all checks passed, 1 some failed, 2 environment not ready (no report, build error, timeout).
#
# Must run outside the Claude Code sandbox: 1C exits with 134 inside it. The script starts exactly two 1C processes
# and kills only those: the client behind the 1c MCP server and the user's own sessions are never touched.

set -u
cd "$(dirname "$0")/.." || exit 2

REGISTRY=.v8-project.json
OUT=.local/ui-check
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-240}
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
json() { plutil -extract "$1" raw -o - "$REGISTRY"; }
V8PATH=$(json v8path)
BASE_PATH=$(json databases.0.path)
BASE_USER=$(json databases.0.user)
CLIENT_USER=${USER_OVERRIDE:-$BASE_USER}
[ -x "$V8PATH/1cv8c" ] || { echo "ENV: no $V8PATH/1cv8c"; exit 2; }

mkdir -p "$OUT"
rm -f "$OUT/report.txt" "$OUT/build.log" "$OUT/client.log" "$OUT/manager.log"

echo "== building tools/ui-check"
if ! python3 .claude/skills/epf-build/scripts/epf-build.py -SourceFile tools/ui-check/src/UiCheck.xml \
     -OutputFile "$OUT/UiCheck.epf" -V8Path "$V8PATH" -Checks off > "$OUT/build.log" 2>&1; then
  tail -20 "$OUT/build.log"
  echo "ENV: build failed"
  exit 2
fi

PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
SINCE=$(date +%Y%m%d%H%M%S)
CLIENT_PID=""
MANAGER_PID=""
cleanup() {
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

echo "== test client on port $PORT as «${CLIENT_USER}»"
"$V8PATH/1cv8c" ENTERPRISE /F"$BASE_PATH" /N"$CLIENT_USER" /TESTCLIENT -TPort$PORT \
  /DisableStartupDialogs /DisableStartupMessages /DisableUnrecoverableErrorMessage /UseHwLicenses- \
  /Out"$OUT/client.log" &
CLIENT_PID=$!

WAITED=0
until (echo > "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; do
  kill -0 "$CLIENT_PID" 2>/dev/null || { echo "ENV: test client exited"; cat "$OUT/client.log" 2>/dev/null; exit 2; }
  [ "$WAITED" -ge 90 ] && { echo "ENV: test client did not start in 90 s"; exit 2; }
  sleep 1
  WAITED=$((WAITED + 1))
done

echo "== test manager as «${BASE_USER}», scenario «${SCENARIO}»"
"$V8PATH/1cv8c" ENTERPRISE /F"$BASE_PATH" /N"$BASE_USER" /TESTMANAGER /Execute"$OUT/UiCheck.epf" \
  /C"out=$OUT/report.txt;port=$PORT;scenario=$SCENARIO;since=$SINCE" \
  /DisableStartupDialogs /DisableStartupMessages /DisableUnrecoverableErrorMessage /UseHwLicenses- \
  /Out"$OUT/manager.log" &
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

# The report is UTF-8 with BOM; webhook keys never reach it (the processor hides everything after «/rest/» on every
# write and fails the check if the text had one).
sed '1s/^\xEF\xBB\xBF//' "$OUT/report.txt"
if grep -q '^ИТОГ: ПРОЙДЕНО' "$OUT/report.txt"; then
  exit 0
fi
# No final line: the scenario hung or crashed, the report shows the last step.
grep -q '^ИТОГ:' "$OUT/report.txt" || { echo "ENV: scenario did not finish"; exit 2; }
exit 1

#!/bin/bash
# Runs the YAxUnit tests of the extension Б24ТабельИзЗадачиТесты in the local base.
# Exit codes: 0 — all green, 1 — failures, 2 — the environment is not ready (no result file).
# Base path, user and platform come from .v8-project.json (the first base in "databases").
# Works on macOS and on Windows (Git Bash): the platform is started by scripts/v8run.py.
# Must run outside the Claude Code sandbox: 1C exits with 134 inside it.

set -u
. "$(dirname "$0")/common.sh"
REGISTRY="$ROOT/.v8-project.json"
TEST_EXTENSION="Б24ТабельИзЗадачиТесты"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"

if [ ! -f "$REGISTRY" ]; then
  echo "Нет $REGISTRY. Создайте его по разделу Tooling в CLAUDE.md." >&2
  exit 2
fi

V8PATH="$(registry_value .v8path)"
BASE_PATH="$(registry_value '.databases[0].path')"
BASE_USER="$(registry_value '.databases[0].user')"
if [ "$IS_WINDOWS" = 1 ]; then V8CLIENT="$V8PATH\\1cv8c.exe"; else V8CLIENT="$V8PATH/1cv8c"; fi

# On the Mac there is no license key, and /UseHwLicenses- keeps the client from looking for one. On Windows this PC
# uses its key: with the switch the client does not start (its log then says "Цифровая подпись конфигурации неверна").
if [ "$IS_WINDOWS" = 1 ]; then LICENSE_ARGS=(); else LICENSE_ARGS=(/UseHwLicenses-); fi

OUT="$ROOT/.local/tests"
mkdir -p "$OUT"
rm -f "$OUT/exit-code.txt" "$OUT/junit.xml" "$OUT/yaxunit.log" "$OUT/1c.log"

# 1C reads the paths in its own (Windows or POSIX) form; jq escapes the backslashes.
# TEST_MODULES="б24тТест_СодержаниеИИ,б24тТест_Задачи" runs only these test modules (a quick red/green loop); the full
# run before a commit is without it.
MODULES='[]'
if [ -n "${TEST_MODULES:-}" ]; then MODULES="$(printf '%s' "$TEST_MODULES" | jq -R 'split(",")')"; fi
jq -n --arg ext "$TEST_EXTENSION" --argjson modules "$MODULES" \
  --arg report "$(native_path "$OUT/junit.xml")" \
  --arg code "$(native_path "$OUT/exit-code.txt")" \
  --arg log "$(native_path "$OUT/yaxunit.log")" \
  '{filter: ({extensions: [$ext]} + (if ($modules | length) > 0 then {modules: $modules} else {} end)),
    reportFormat: "jUnit", reportPath: $report, exitCode: $code,
    showReport: false, closeAfterTests: true, logging: {enable: true, file: $log, level: "debug"}}' \
  > "$OUT/yaxunit.json"

MSYS_NO_PATHCONV=1 "$PY" "$(native_path "$ROOT/scripts/v8run.py")" --timeout "$TIMEOUT_SECONDS" -- "$V8CLIENT" ENTERPRISE \
  "/F\"$BASE_PATH\"" "/N\"$BASE_USER\"" \
  "/C\"RunUnitTests=$(native_path "$OUT/yaxunit.json")\"" \
  /DisableStartupDialogs /DisableStartupMessages /DisableUnrecoverableErrorMessage \
  "${LICENSE_ARGS[@]}" "/Out\"$(native_path "$OUT/1c.log")\""
if [ $? = 124 ]; then
  echo "1С не завершилась за $TIMEOUT_SECONDS с, процесс остановлен." >&2
  exit 2
fi

if [ ! -f "$OUT/exit-code.txt" ]; then
  echo "Нет файла результата: тесты не выполнились. Лог YAxUnit: $OUT/yaxunit.log" >&2
  exit 2
fi

# 1C writes the file with a BOM and CRLF: keep digits only.
CODE="$(LC_ALL=C tr -cd '0-9' < "$OUT/exit-code.txt")"
TESTS=0
if [ -f "$OUT/junit.xml" ]; then
  TESTS="$(grep -o '<testcase ' "$OUT/junit.xml" | wc -l | tr -d ' ')"
  echo "Тестов: $TESTS. Отчёт: $OUT/junit.xml"
fi

# YAxUnit skips a test module that fails to compile and still reports success.
if grep -q '\[ERR\]' "$OUT/yaxunit.log" 2>/dev/null; then
  echo "RED: в журнале YAxUnit есть ошибки (например, тестовый модуль не скомпилировался):"
  grep -A3 '\[ERR\]' "$OUT/yaxunit.log" | head -20
  exit 1
fi
if [ "$TESTS" = "0" ]; then
  echo "RED: не выполнено ни одного теста."
  exit 1
fi

if [ "$CODE" = "0" ]; then
  echo "GREEN"
  exit 0
fi

echo "RED"
if [ -f "$OUT/junit.xml" ]; then
  "$PY" - "$(native_path "$OUT/junit.xml")" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

for case in ET.parse(sys.argv[1]).iter("testcase"):
    bad = case.find("failure")
    if bad is None:
        bad = case.find("error")
    if bad is not None:
        print("- %s: %s" % (case.get("classname", ""), (bad.get("message") or "")[:500]))
PYEOF
fi
exit 1

#!/bin/bash
# Checks the guards of scripts/b24.sh without the secret store and the network.
# The secret store is replaced by stubs for both systems: `security` (macOS Keychain) and `powershell.exe`
# with a fake %LOCALAPPDATA% (Windows, DPAPI file); curl is replaced by a stub too.
# Usage: scripts/b24-selftest.sh
# Exit codes: 0 — all checks pass, 1 — a check failed.

set -u
B24="$(cd "$(dirname "$0")" && pwd)/b24.sh"
TOKEN="faketoken123"

STUBS="$(mktemp -d)"; trap 'rm -rf "$STUBS"' EXIT
CALLS="$STUBS/calls"

# Both secret-store stubs print STUB_SECRET; an empty STUB_SECRET means "nothing stored".
cat > "$STUBS/security" <<EOF
#!/bin/bash
printf '%s\n' "\${STUB_SECRET-https://portal.bitrix24.kz/rest/1/$TOKEN/}"
EOF
cp "$STUBS/security" "$STUBS/powershell.exe"
if command -v cygpath >/dev/null 2>&1; then
  mkdir -p "$STUBS/appdata/b24-task-timesheet/secrets"
  : > "$STUBS/appdata/b24-task-timesheet/secrets/b24-dev-webhook.dpapi"
  LOCALAPPDATA="$(cygpath -w "$STUBS/appdata")"; export LOCALAPPDATA
fi

# Writes its arguments and the config from stdin to \$CALLS, answers with a body that contains the token.
cat > "$STUBS/curl" <<EOF
#!/bin/bash
mkdir -p "$CALLS"
N=\$(ls "$CALLS" | grep -c '\.args\$')
printf '%s\n' "\$@" > "$CALLS/\$N.args"
cat > "$CALLS/\$N.config"
OUT=""
while [ \$# -gt 0 ]; do
  [ "\$1" = "-o" ] && OUT="\$2"
  # The request body: a file given as @path is copied as it is, an inline body is written as it is.
  if [ "\$1" = "--data-binary" ]; then
    case "\$2" in
      @*) F="\${2#@}"; command -v cygpath >/dev/null 2>&1 && F="\$(cygpath -u "\$F")"; cp "\$F" "$CALLS/\$N.body" ;;
      *) printf '%s' "\$2" > "$CALLS/\$N.body" ;;
    esac
  fi
  shift
done
printf '{"result":true,"link":"https://portal.bitrix24.kz/rest/1/$TOKEN/user.get"}' > "\$OUT"
printf '200'
EOF
chmod +x "$STUBS/security" "$STUBS/powershell.exe" "$STUBS/curl"

FAILED=0
fail() { echo "FAIL: $1" >&2; FAILED=1; }

# Runs b24.sh with the stubs; sets CODE and OUTPUT.
run() {
  rm -rf "$CALLS"
  OUTPUT="$(PATH="$STUBS:$PATH" "$B24" "$@" 2>&1)"
  CODE=$?
}
curl_calls() { ls "$CALLS" 2>/dev/null | grep -c '\.args$'; }

# Refused before curl: exit code 2 and no request.
expect_refused() {
  local NAME="$1"; shift
  run "$@"
  [ "$CODE" = 2 ] || fail "$NAME: код $CODE, ожидался 2"
  [ "$(curl_calls)" = 0 ] || fail "$NAME: curl вызван $(curl_calls) раз"
}

# A read method passes, curl gets safe options and exactly one URL.
run user.get
[ "$CODE" = 0 ] || fail "user.get: код $CODE, ожидался 0 ($OUTPUT)"
[ "$(curl_calls)" = 1 ] || fail "user.get: curl вызван $(curl_calls) раз"
grep -qx -- '--globoff' "$CALLS/0.args" 2>/dev/null || fail "user.get: нет --globoff"
grep -A1 -x -- '--proto' "$CALLS/0.args" 2>/dev/null | grep -qx '=https' || fail "user.get: нет --proto =https"
[ "$(grep -c . "$CALLS/0.config" 2>/dev/null)" = 1 ] || fail "user.get: в конфиге curl не одна строка"
grep -qx 'url = "https://portal.bitrix24.kz/rest/1/'"$TOKEN"'/user.get.json"' "$CALLS/0.config" 2>/dev/null \
  || fail "user.get: неверный адрес в конфиге curl"
case "$OUTPUT" in *"$TOKEN"*) fail "user.get: токен в выводе" ;; esac

# The parameters reach Bitrix24 byte for byte, Cyrillic included, and only as a file: on Windows a native curl
# gets its command line in the ANSI code page, and the portal then sees broken JSON.
PARAMS_RU='{"fields":{"TITLE":"[ТЕСТ] Задача — «кавычки»","DESCRIPTION":"Строка 1\nСтрока 2"}}'
run tasks.task.add "$PARAMS_RU" --write
[ "$CODE" = 0 ] || fail "кириллица: код $CODE, ожидался 0 ($OUTPUT)"
grep -A1 -x -- '--data-binary' "$CALLS/0.args" 2>/dev/null | tail -1 | grep -q '^@' || fail "кириллица: тело не файлом (@путь)"
[ "$(cat "$CALLS/0.body" 2>/dev/null)" = "$PARAMS_RU" ] || fail "кириллица: тело дошло до curl не байт в байт"

# Write methods need --write.
expect_refused "tasks.task.add без --write" tasks.task.add
run tasks.task.add '{}' --write
[ "$CODE" = 0 ] || fail "tasks.task.add --write: код $CODE, ожидался 0"

# Patterns and curl globs must not pass as read methods.
expect_refused "шаблон-подстановка curl" 'tasks.task.[a-g][d-e][d-t]'
expect_refused "шаблон .*" '.*'
expect_refused "фигурные скобки" 'tasks.task.{get,add}'
expect_refused "перевод строки" $'user.get\nverbose'
expect_refused "кавычка" 'user.get"'
expect_refused "неизвестный метод" user.update

# batch: every command is checked the same way.
expect_refused "batch с шаблоном" batch '{"cmd":{"a":"tasks.task.[a-g][d-e][d-t]"}}'
expect_refused "batch с записью" batch '{"cmd":{"a":"tasks.task.add?fields[TITLE]=x"}}'
run batch '{"cmd":{"a":"user.get?ID=1","b":"tasks.task.get?taskId=1"}}'
[ "$CODE" = 0 ] || fail "batch с чтением: код $CODE, ожидался 0 ($OUTPUT)"

# No stored webhook: exit code 2, no request, a hint how to store it on this system.
STUB_SECRET="" run user.get
[ "$CODE" = 2 ] || fail "нет вебхука: код $CODE, ожидался 2"
[ "$(curl_calls)" = 0 ] || fail "нет вебхука: curl вызван $(curl_calls) раз"
if command -v cygpath >/dev/null 2>&1; then HINT="secret-set.ps1 b24-dev-webhook"; else HINT="security add-generic-password"; fi
case "$OUTPUT" in *"$HINT"*) ;; *) fail "нет вебхука: в подсказке нет «$HINT» ($OUTPUT)" ;; esac

# A stored value that is not a webhook address is refused and not shown.
STUB_SECRET="not-a-webhook-$TOKEN" run user.get
[ "$CODE" = 2 ] || fail "не адрес: код $CODE, ожидался 2"
[ "$(curl_calls)" = 0 ] || fail "не адрес: curl вызван $(curl_calls) раз"
case "$OUTPUT" in *"$TOKEN"*) fail "не адрес: значение в выводе" ;; esac

if [ "$FAILED" = 0 ]; then echo "b24.sh: все проверки пройдены"; fi
exit "$FAILED"

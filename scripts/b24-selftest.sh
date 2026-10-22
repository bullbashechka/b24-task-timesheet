#!/bin/bash
# Checks the guards of scripts/b24.sh without the Keychain and the network: security and curl are replaced by stubs.
# Usage: scripts/b24-selftest.sh
# Exit codes: 0 — all checks pass, 1 — a check failed.

set -u
B24="$(cd "$(dirname "$0")" && pwd)/b24.sh"
TOKEN="faketoken123"

STUBS="$(mktemp -d)"; trap 'rm -rf "$STUBS"' EXIT
CALLS="$STUBS/calls"

cat > "$STUBS/security" <<EOF
#!/bin/bash
echo "https://portal.bitrix24.kz/rest/1/$TOKEN/"
EOF

# Writes its arguments and the config from stdin to \$CALLS, answers with a body that contains the token.
cat > "$STUBS/curl" <<EOF
#!/bin/bash
mkdir -p "$CALLS"
N=\$(ls "$CALLS" | wc -l | tr -d ' ')
printf '%s\n' "\$@" > "$CALLS/\$N.args"
cat > "$CALLS/\$N.config"
OUT=""
while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && OUT="\$2"; shift; done
printf '{"result":true,"link":"https://portal.bitrix24.kz/rest/1/$TOKEN/user.get"}' > "\$OUT"
printf '200'
EOF
chmod +x "$STUBS/security" "$STUBS/curl"

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

if [ "$FAILED" = 0 ]; then echo "b24.sh: все проверки пройдены"; fi
exit "$FAILED"

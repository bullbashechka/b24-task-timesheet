#!/bin/bash
# Checks the guards of scripts/openai.sh without the secret store and the network.
# The secret store and curl are replaced by stubs (see scripts/b24-selftest.sh for the mechanism).
# Usage: scripts/openai-selftest.sh
# Exit codes: 0 — all checks pass, 1 — a check failed.

set -u
OPENAI="$(cd "$(dirname "$0")" && pwd)/openai.sh"
KEY="sk-testkey0123456789abcdefghij"

STUBS="$(mktemp -d)"; trap 'rm -rf "$STUBS"' EXIT
CALLS="$STUBS/calls"

# Both secret-store stubs print STUB_SECRET; an empty STUB_SECRET means "nothing stored".
cat > "$STUBS/security" <<EOF
#!/bin/bash
printf '%s\n' "\${STUB_SECRET-$KEY}"
EOF
cp "$STUBS/security" "$STUBS/powershell.exe"
if command -v cygpath >/dev/null 2>&1; then
  mkdir -p "$STUBS/appdata/b24-task-timesheet/secrets"
  : > "$STUBS/appdata/b24-task-timesheet/secrets/openai-dev-key.dpapi"
  LOCALAPPDATA="$(cygpath -w "$STUBS/appdata")"; export LOCALAPPDATA
fi

# Writes its arguments and the config from stdin to $CALLS. Answers with STUB_HTTP (default 200) and a body
# that contains the key and another sk- string, so that the masking can be checked.
cat > "$STUBS/curl" <<EOF
#!/bin/bash
mkdir -p "$CALLS"
N=\$(ls "$CALLS" | wc -l | tr -d ' ')
printf '%s\n' "\$@" > "$CALLS/\$N.args"
cat > "$CALLS/\$N.config"
OUT=""
while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && OUT="\$2"; shift; done
printf '{"id":"resp_1","echo":"$KEY","other":"sk-proj-abcdefghijklmnop12345"}' > "\$OUT"
printf '%s 0.123' "\${STUB_HTTP-200}"
EOF
chmod +x "$STUBS/security" "$STUBS/powershell.exe" "$STUBS/curl"

printf '{"model":"gpt-5.6-luna","input":"x"}' > "$STUBS/body.json"
printf '[1,2]' > "$STUBS/array.json"
printf 'not json' > "$STUBS/text.json"

FAILED=0
fail() { echo "FAIL: $1" >&2; FAILED=1; }

# Runs openai.sh with the stubs; sets CODE and OUTPUT.
run() {
  rm -rf "$CALLS"
  OUTPUT="$(PATH="$STUBS:$PATH" "$OPENAI" "$@" 2>&1)"
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

# responses: POST with the body file; safe curl options; the key only in the stdin config.
run responses "@$STUBS/body.json"
[ "$CODE" = 0 ] || fail "responses: код $CODE, ожидался 0 ($OUTPUT)"
[ "$(curl_calls)" = 1 ] || fail "responses: curl вызван $(curl_calls) раз"
grep -qx -- '--globoff' "$CALLS/0.args" 2>/dev/null || fail "responses: нет --globoff"
grep -A1 -x -- '--proto' "$CALLS/0.args" 2>/dev/null | grep -qx '=https' || fail "responses: нет --proto =https"
grep -qx -- '--data-binary' "$CALLS/0.args" 2>/dev/null || fail "responses: нет --data-binary"
[ "$(grep -c . "$CALLS/0.config" 2>/dev/null)" = 2 ] || fail "responses: в конфиге curl не две строки"
grep -qx 'url = "https://api.openai.com/v1/responses"' "$CALLS/0.config" 2>/dev/null || fail "responses: неверный адрес в конфиге curl"
grep -qx "header = \"Authorization: Bearer $KEY\"" "$CALLS/0.config" 2>/dev/null || fail "responses: нет заголовка с ключом в конфиге curl"
grep -q "$KEY" "$CALLS/0.args" 2>/dev/null && fail "responses: ключ в аргументах curl (виден в списке процессов)"
case "$OUTPUT" in *"$KEY"*) fail "responses: ключ в выводе" ;; esac
case "$OUTPUT" in *"sk-proj-abcdefghijklmnop12345"*) fail "responses: чужой sk- в выводе" ;; esac
case "$OUTPUT" in *"sk-***"*) ;; *) fail "responses: ключ не заменён на sk-***" ;; esac

# models: GET of one model id, no body.
run models gpt-5.6-luna
[ "$CODE" = 0 ] || fail "models: код $CODE, ожидался 0 ($OUTPUT)"
grep -qx 'url = "https://api.openai.com/v1/models/gpt-5.6-luna"' "$CALLS/0.config" 2>/dev/null || fail "models: неверный адрес"
grep -qx -- '--data-binary' "$CALLS/0.args" 2>/dev/null && fail "models: тело в GET"

# An error answer ends with code 1, the key is still masked.
STUB_HTTP=401 run models gpt-5.6-luna
[ "$CODE" = 1 ] || fail "HTTP 401: код $CODE, ожидался 1"
case "$OUTPUT" in *"$KEY"*) fail "HTTP 401: ключ в выводе" ;; esac

# --bad-key: a wrong key, the stored secret is not read at all.
STUB_SECRET="" run models gpt-5.6-luna --bad-key
[ "$CODE" = 0 ] || fail "--bad-key: код $CODE, ожидался 0 ($OUTPUT)"
grep -q 'Bearer sk-invalidkey' "$CALLS/0.config" 2>/dev/null || fail "--bad-key: в конфиге curl не ложный ключ"
grep -q "$KEY" "$CALLS/0.config" 2>/dev/null && fail "--bad-key: в конфиге сохранённый ключ"

# Only these two requests exist.
expect_refused "другой путь" files
expect_refused "другой путь chat/completions" chat/completions "@$STUBS/body.json"
expect_refused "responses без тела" responses
expect_refused "тело не @файл" responses "$STUBS/body.json"
expect_refused "нет файла тела" responses "@$STUBS/missing.json"
expect_refused "тело не объект" responses "@$STUBS/array.json"
expect_refused "тело не JSON" responses "@$STUBS/text.json"
expect_refused "models без id" models
expect_refused "id со слэшем" models '../files'
expect_refused "id с подстановкой curl" models 'gpt-[5]'
expect_refused "id с фигурными скобками" models 'gpt-{5,6}'
expect_refused "id с переводом строки" models $'gpt-5\nverbose'
expect_refused "id с кавычкой" models 'gpt"5'
expect_refused "лишний параметр" models gpt-5.6-luna --unknown

# No stored key: exit code 2, no request, a hint how to store it on this system.
STUB_SECRET="" run models gpt-5.6-luna
[ "$CODE" = 2 ] || fail "нет ключа: код $CODE, ожидался 2"
[ "$(curl_calls)" = 0 ] || fail "нет ключа: curl вызван $(curl_calls) раз"
if command -v cygpath >/dev/null 2>&1; then HINT="secret-set.ps1 openai-dev-key"; else HINT="security add-generic-password"; fi
case "$OUTPUT" in *"$HINT"*) ;; *) fail "нет ключа: в подсказке нет «$HINT» ($OUTPUT)" ;; esac

# A stored value that is not an API key is refused and not shown.
STUB_SECRET="not-a-key-0123456789abcdef" run models gpt-5.6-luna
[ "$CODE" = 2 ] || fail "не ключ: код $CODE, ожидался 2"
[ "$(curl_calls)" = 0 ] || fail "не ключ: curl вызван $(curl_calls) раз"
case "$OUTPUT" in *"not-a-key-0123456789abcdef"*) fail "не ключ: значение в выводе" ;; esac

if [ "$FAILED" = 0 ]; then echo "openai.sh: все проверки пройдены"; fi
exit "$FAILED"

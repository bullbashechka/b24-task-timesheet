#!/bin/bash
# Shared helpers for the scripts in scripts/. Source it: . "$(dirname "$0")/common.sh"
# Works on macOS and on Windows under Git Bash (MINGW). On macOS nothing changes against the old scripts.
#
# IS_WINDOWS          1 under Git Bash on Windows, 0 elsewhere.
# ROOT                repository root.
# jq                  on Windows: found in the winget folder if not on PATH, always called with -b
#                     (without it jq.exe writes CRLF).
# PY                  python interpreter (python3, or python on Windows).
# date_shift N FMT    today plus N days (N like +2 or -30), formatted with FMT.
# registry_value F    a field of .v8-project.json, F is a jq path like .v8path or .databases[0].path.
# env_value NAME      a value from .env (CR stripped), empty if absent.
# native_path P       P as the platform sees it: a Windows path on Windows, unchanged elsewhere.
# secret_get NAME     the stored secret NAME, empty if not stored. Never print it.
#                     macOS: Keychain item NAME (security find-generic-password).
#                     Windows: %LOCALAPPDATA%\b24-task-timesheet\secrets\NAME.dpapi, written by secret-set.ps1,
#                     readable only by the same Windows user on the same computer (DPAPI).
# secret_hint NAME    the command that stores NAME on this system (for error messages).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
  *) IS_WINDOWS=0 ;;
esac

if [ "$IS_WINDOWS" = 1 ]; then
  # A shell started before `winget install jqlang.jq` does not have its folder on PATH yet.
  if ! command -v jq >/dev/null 2>&1 && [ -n "${USERPROFILE:-}" ]; then
    for JQ_DIR in "$(cygpath -u "$USERPROFILE")"/AppData/Local/Microsoft/WinGet/Packages/jqlang.jq_*; do
      if [ -x "$JQ_DIR/jq.exe" ]; then PATH="$PATH:$JQ_DIR"; break; fi
    done
    unset JQ_DIR
  fi
  jq() { command jq -b "$@"; }
fi

# On Windows python3 may be the Microsoft Store stub, which is another interpreter without our packages.
if [ "$IS_WINDOWS" = 1 ]; then PY=python
elif command -v python3 >/dev/null 2>&1; then PY=python3
else PY=python; fi
# Python on Windows writes pipes in the ANSI code page unless told otherwise.
export PYTHONUTF8=1

date_shift() {
  if date -v+0d >/dev/null 2>&1; then date -v"$1"d "+$2"; else date -d "$1 days" "+$2"; fi
}

registry_value() { jq -r "$1 // empty" "$ROOT/.v8-project.json"; }

env_value() {
  [ -f "$ROOT/.env" ] || return 0
  sed -n "s/^$1=//p" "$ROOT/.env" | tr -d '\r' | tail -n 1
}

native_path() {
  if [ "$IS_WINDOWS" = 1 ]; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

secret_file() { printf '%s/b24-task-timesheet/secrets/%s.dpapi' "$(cygpath -u "$LOCALAPPDATA")" "$1"; }

secret_get() {
  if [ "$IS_WINDOWS" = 1 ]; then
    [ -n "${LOCALAPPDATA:-}" ] && [ -f "$(secret_file "$1")" ] || return 0
    # The file name goes in through an environment variable, so nothing is quoted into the command.
    B24_SECRET_FILE="$(cygpath -w "$(secret_file "$1")")" powershell.exe -NoProfile -NonInteractive -Command \
      '$s = (Get-Content -Raw -LiteralPath $env:B24_SECRET_FILE).Trim() | ConvertTo-SecureString; [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))' \
      2>/dev/null | tr -d '\r\n'
  else
    security find-generic-password -s "$1" -w 2>/dev/null
  fi
}

secret_hint() {
  if [ "$IS_WINDOWS" = 1 ]; then
    printf 'powershell -NoProfile -ExecutionPolicy Bypass -File scripts\\secret-set.ps1 %s' "$1"
  else
    printf 'security add-generic-password -a "$USER" -s %s -w' "$1"
  fi
}

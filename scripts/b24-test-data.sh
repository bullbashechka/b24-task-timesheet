#!/bin/bash
# Creates or deletes the Bitrix24 test data of PRD «Тестовые данные и приёмка» through scripts/b24.sh.
# The set is described in scripts/b24-test-data.json; created IDs go to scripts/b24-test-data.ids.json.
# Usage: scripts/b24-test-data.sh create|delete
# Exit codes: 0 — done, 1 — a Bitrix24 call failed (IDs created so far are kept), 2 — usage or setup error.
# Must run outside the Claude Code sandbox, like scripts/b24.sh.

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SPEC="$DIR/b24-test-data.json"
IDS="$DIR/b24-test-data.ids.json"
B24="$DIR/b24.sh"

call() { # method params → result JSON on stdout; stops the script on an error
  local OUT
  if ! OUT="$("$B24" "$1" "$2" --write 2>/dev/null)"; then
    echo "Ошибка $1: $(echo "$OUT" | jq -c '{error, error_description}' 2>/dev/null || echo "$OUT")" >&2
    exit 1
  fi
  echo "$OUT" | jq '.result'
}
spec() { jq -r "$@" "$SPEC"; }
TMP=""; trap 'rm -f "$TMP"' EXIT
save_id() { # path id
  TMP="$(mktemp)"
  jq --argjson id "$2" "$1 = \$id" "$IDS" > "$TMP" && mv "$TMP" "$IDS"
}
user() { spec --arg k "$1" '.users[$k]'; }

create() {
  [ ! -f "$IDS" ] || { echo "Данные уже созданы ($IDS). Сначала: $0 delete" >&2; exit 2; }
  if spec '[.users[], .presets[]] | any(. == null)' | grep -q true; then
    echo "В $SPEC не заполнены users или presets." >&2; exit 2
  fi
  echo '{"project": null, "companies": {}, "tasks": {}}' > "$IDS"

  local GROUP
  GROUP="$(call sonet_group.create "$(spec '{NAME: .project, PROJECT: "Y", VISIBLE: "N", OPENED: "N"}')")"
  save_id .project "$GROUP"
  call sonet_group.user.add "$(spec --argjson g "$GROUP" '{GROUP_ID: $g, USER_ID: [.users | to_entries[] | select(.key != "developer") | .value]}')" >/dev/null
  echo "Проект $GROUP"

  local KEY ID I N
  for KEY in $(spec '.companies[].key'); do
    ID="$(call crm.company.add "$(spec --arg k "$KEY" '.companies[] | select(.key == $k) | {fields: {TITLE: .title, OPENED: "Y"}}')")"
    save_id ".companies.$KEY" "$ID"
    N="$(spec --arg k "$KEY" '.companies[] | select(.key == $k) | .requisites | length')"
    for ((I = 0; I < N; I++)); do
      call crm.requisite.add "$(jq --arg k "$KEY" --argjson i "$I" --argjson id "$ID" '
        .presets as $p | .companies[] | select(.key == $k) | .requisites[$i] |
        {fields: ({ENTITY_TYPE_ID: 4, ENTITY_ID: $id, PRESET_ID: $p[.preset], NAME: .name, SORT: (($i + 1) * 10)} + .fields)}' "$SPEC")" >/dev/null
    done
    echo "Компания $KEY: $ID, реквизитов $N"
  done

  for KEY in $(spec '.tasks[].key'); do
    ID="$(call tasks.task.add "$(jq --arg k "$KEY" --argjson g "$GROUP" --slurpfile ids "$IDS" '
      .users as $u | .roles as $r | .tasks[] | select(.key == $k) | $r[.roles] as $role |
      {fields: ({
        TITLE: .title,
        CREATED_BY: $u[$role.creator],
        RESPONSIBLE_ID: $u[$role.responsible],
        ACCOMPLICES: [$role.accomplices[] | $u[.]],
        AUDITORS: [$role.auditors[] | $u[.]],
        UF_CRM_TASK: [.companies[] | "CO_\($ids[0].companies[.])"],
        TASK_CONTROL: "N"
      } + (if .inProject then {GROUP_ID: $g} else {} end))}' "$SPEC")" | jq '.task.id | tonumber')"
    save_id ".tasks.$KEY" "$ID"
    if [ "$(spec --arg k "$KEY" '.tasks[] | select(.key == $k) | .complete // false')" = true ]; then
      call tasks.task.complete "{\"taskId\": $ID}" >/dev/null
      echo "Задача $KEY: $ID, завершена"
    else
      echo "Задача $KEY: $ID"
    fi
  done
}

delete() {
  [ -f "$IDS" ] || { echo "Нет $IDS: удалять нечего." >&2; exit 2; }
  local KEY ID
  for KEY in $(jq -r '.tasks | keys[]' "$IDS"); do
    ID="$(jq -r --arg k "$KEY" '.tasks[$k]' "$IDS")"
    call tasks.task.delete "{\"taskId\": $ID}" >/dev/null
    jq --arg k "$KEY" 'del(.tasks[$k])' "$IDS" > "$IDS.tmp" && mv "$IDS.tmp" "$IDS"
    echo "Удалена задача $KEY: $ID"
  done
  for KEY in $(jq -r '.companies | keys[]' "$IDS"); do
    ID="$(jq -r --arg k "$KEY" '.companies[$k]' "$IDS")"
    call crm.company.delete "{\"id\": $ID}" >/dev/null
    jq --arg k "$KEY" 'del(.companies[$k])' "$IDS" > "$IDS.tmp" && mv "$IDS.tmp" "$IDS"
    echo "Удалена компания $KEY: $ID"
  done
  ID="$(jq -r '.project // empty' "$IDS")"
  if [ -n "$ID" ]; then
    call sonet_group.delete "{\"GROUP_ID\": $ID}" >/dev/null
    echo "Удалён проект $ID"
  fi
  rm -f "$IDS"
}

case "${1:-}" in
  create) create ;;
  delete) delete ;;
  *) sed -n '4p' "$0" | sed 's/^# //' >&2; exit 2 ;;
esac

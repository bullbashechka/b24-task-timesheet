#!/bin/bash
# Builds the body of POST /v1/responses from the invented test material in scripts/openai-test/ and one test task
# of scripts/b24-test-data.json. Prints the JSON to stdout. For the development runs and the recorded answers only:
# the formulations are invented «[ТЕСТ]» ones, the rules are a short draft (the real ones come in stage 17).
# Usage: scripts/openai-body.sh <task key> <draft text, "" for none> <reasoning effort> <max_output_tokens> [model]
#   reasoning effort: none, low, medium, high, xhigh, max.
set -euo pipefail
. "$(dirname "$0")/common.sh"
DIR="$ROOT/scripts/openai-test"
SPEC="$ROOT/scripts/b24-test-data.json"

KEY="${1:?task key}"; DRAFT="${2-}"; EFFORT="${3:?reasoning effort}"; MAX="${4:?max_output_tokens}"; MODEL="${5:-gpt-5.6-luna}"
TITLE="$(jq -r --arg k "$KEY" '.tasks[] | select(.key == $k) | .title' "$SPEC")"
FILE="$(jq -r --arg k "$KEY" '.tasks[] | select(.key == $k) | .descriptionFile // empty' "$SPEC")"
[ -n "$TITLE" ] || { echo "Нет задачи $KEY в $SPEC" >&2; exit 2; }
DESCRIPTION=""
[ -z "$FILE" ] || DESCRIPTION="$(tr -d '\r' < "$ROOT/scripts/b24-test-data/$FILE")"

# The formulations first (they are the same for every request), the task and the draft after them.
INPUT="$(printf 'Стандартные формулировки:\n%s\n\nНазвание задачи: %s\nОписание задачи: %s\nЧерновик сотрудника: %s\n' \
  "$(tr -d '\r' < "$DIR/formulations.txt")" "$TITLE" "$DESCRIPTION" "$DRAFT")"

jq -n --arg model "$MODEL" --arg input "$INPUT" --arg effort "$EFFORT" --argjson max "$MAX" \
  --rawfile instructions "$(native_path "$DIR/instructions.txt")" \
  --slurpfile schema "$(native_path "$DIR/schema.json")" '
  {model: $model, instructions: $instructions, input: $input, store: false, max_output_tokens: $max,
   reasoning: {effort: $effort},
   text: {format: {type: "json_schema", name: "timesheet_content", strict: true, schema: $schema[0]}}}'

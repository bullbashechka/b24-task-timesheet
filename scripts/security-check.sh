#!/bin/bash
# Static check of the webhook rules (PRD «Связь с Битрикс24 и безопасность», TASKS 11.1) over the BSL sources:
#   1. the HTTPS connection is created only in б24т_ТранспортHTTPS (so every Bitrix24 call goes through the stage 5 client);
#   2. the safe storage is read only by б24т_Настройки and б24т_Битрикс24, written and deleted only by б24т_Настройки;
#   3. forms never call б24т_Битрикс24, and б24т_Настройки is called only by the settings form;
#   4. no exported function returns the full webhook address (exported names with «АдресВебхука» are a fixed list);
#   5. the test extension and tools/ui-check read the safe storage only in the known places.
# Comment lines (//) are ignored. Patterns avoid Cyrillic ranges: the BSD grep of macOS compares bytes in them. Usage: scripts/security-check.sh. Exit codes: 0 clean, 1 a rule is broken.

set -u
cd "$(dirname "$0")/.." || exit 2

PRODUCT=src/cfe/Б24ТабельИзЗадачи
TESTS=src/cfe/Б24ТабельИзЗадачиТесты
FAILED=0

# hits <regex> <dir…>: «file:line» of non-comment code lines that match
hits() {
  local RE="$1"; shift
  grep -rnE --include='*.bsl' "$RE" "$@" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | cut -d: -f1,2
}

# only <rule> <regex> <allowed file regex> <dir…>: every hit must be in an allowed file
only() {
  local RULE="$1" RE="$2" ALLOWED="$3"; shift 3
  local BAD
  BAD="$(hits "$RE" "$@" | grep -vE "$ALLOWED")"
  if [ -n "$BAD" ]; then
    echo "НАРУШЕНИЕ: $RULE"
    echo "$BAD" | sed 's/^/  /'
    FAILED=1
  else
    echo "ОК: $RULE"
  fi
}

only "HTTPS-соединение создаёт только б24т_ТранспортHTTPS" \
  'HTTPСоединение|ЗащищенноеСоединение|ЗащищённоеСоединение|HTTPЗапрос' \
  '/CommonModules/б24т_ТранспортHTTPS/' "$PRODUCT"

only "безопасное хранилище читают только б24т_Настройки и б24т_Битрикс24" \
  'ПрочитатьДанныеИзБезопасногоХранилища' \
  '/CommonModules/(б24т_Настройки|б24т_Битрикс24)/' "$PRODUCT"

only "безопасное хранилище пишет и стирает только б24т_Настройки" \
  'ЗаписатьДанныеВБезопасноеХранилище|УдалитьДанныеИзБезопасногоХранилища|УстановитьДанныеВБезопасноеХранилище' \
  '/CommonModules/б24т_Настройки/' "$PRODUCT"

only "формы и команды не вызывают б24т_Битрикс24" \
  'б24т_Битрикс24\.' \
  '/CommonModules/' "$PRODUCT"

only "б24т_Настройки из форм вызывает только форма настроек" \
  'б24т_Настройки\.' \
  '/CommonModules/|/CommonForms/б24т_НастройкиИнтеграции/' "$PRODUCT"

# 4. exported functions whose name carries the webhook address: only the known two (they take or mask an address, never
# return the stored one)
BAD="$(grep -rnE --include='*.bsl' '^[[:space:]]*Функция[[:space:]]+[^ (]*АдресВебхука[^ (]*[[:space:]]*\(.*\)[[:space:]]*Экспорт' "$PRODUCT" \
  | grep -vE 'Функция[[:space:]]+(НормализованныйАдресВебхука|ПредставлениеАдресаВебхука)[[:space:]]*\(' || true)"
if [ -n "$BAD" ]; then
  echo "НАРУШЕНИЕ: экспортная функция с адресом вебхука в имени вне списка"
  echo "$BAD" | cut -d: -f1,2 | sed 's/^/  /'
  FAILED=1
else
  echo "ОК: экспортных функций с адресом вебхука в имени вне списка нет"
fi

# 5. other code that touches the safe storage: test extension and the UI-check tool
only "в тестах и tools/ui-check хранилище читают только известные модули" \
  'БезопасногоХранилища' \
  '/CommonModules/(б24тТест_Настройки|б24тТест_Доступ|б24тТест_ПроверкаУтечки)/' "$TESTS" tools/ui-check/src

if [ "$FAILED" -eq 0 ]; then
  echo "ИТОГ: ПРОЙДЕНО"
  exit 0
fi
echo "ИТОГ: НЕ ПРОЙДЕНО"
exit 1

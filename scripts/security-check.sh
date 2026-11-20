#!/bin/bash
# Static check of the webhook and OpenAI key rules (PRD «Связь с Битрикс24 и безопасность», Ф14; TASKS 11.1, 16.7)
# over the BSL sources:
#   1. the HTTPS connection is created only in the transports б24т_ТранспортHTTPS and б24т_ТранспортOpenAI (so every
#      Bitrix24 call goes through the stage 5 client and every OpenAI call through the stage 16 client); the OpenAI
#      address and the Authorization header appear only in б24т_ТранспортOpenAI;
#   2. the safe storage is read only by б24т_Настройки, б24т_Битрикс24 and б24т_OpenAI, written and deleted only by
#      б24т_Настройки;
#   3. forms never call б24т_Битрикс24 or б24т_OpenAI, and б24т_Настройки is called only by the settings form; the
#      OpenAI request (б24т_OpenAI.Вызвать) is made only by б24т_Настройки (check) and б24т_ЗаполнениеИИ (operation);
#   4. no exported function returns the full webhook address (exported names with «АдресВебхука» are a fixed list),
#      the OpenAI key (no exported name with «КлючOpenAI») or the stored secrets (the storage readers are not exported);
#   5. the test extension and tools/ui-check read the safe storage only in the known places;
#   6. the task chat is only read (Ф15): the only `im.*` method named in the product is im.dialog.messages.get, and only
#      the REST client (its allowed list), the comments reader б24т_КомментарииЗадачи and the connection check
#      (б24т_Настройки) name it; forms never call б24т_КомментарииЗадачи (it talks to Bitrix24).
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

only "HTTPS-соединение создают только б24т_ТранспортHTTPS и б24т_ТранспортOpenAI" \
  'HTTPСоединение|ЗащищенноеСоединение|ЗащищённоеСоединение|HTTPЗапрос' \
  '/CommonModules/(б24т_ТранспортHTTPS|б24т_ТранспортOpenAI)/' "$PRODUCT"

# The host as a string literal of its own: the «Проверить ИИ» text names api.openai.com inside a sentence.
only "адрес OpenAI и заголовок с ключом есть только в б24т_ТранспортOpenAI" \
  '"api\.openai\.com"|Authorization|Bearer' \
  '/CommonModules/б24т_ТранспортOpenAI/' "$PRODUCT"

only "безопасное хранилище читают только б24т_Настройки, б24т_Битрикс24 и б24т_OpenAI" \
  'ПрочитатьДанныеИзБезопасногоХранилища' \
  '/CommonModules/(б24т_Настройки|б24т_Битрикс24|б24т_OpenAI)/' "$PRODUCT"

only "безопасное хранилище пишет и стирает только б24т_Настройки" \
  'ЗаписатьДанныеВБезопасноеХранилище|УдалитьДанныеИзБезопасногоХранилища|УстановитьДанныеВБезопасноеХранилище' \
  '/CommonModules/б24т_Настройки/' "$PRODUCT"

only "формы и команды не вызывают б24т_Битрикс24" \
  'б24т_Битрикс24\.' \
  '/CommonModules/' "$PRODUCT"

only "формы и команды не вызывают б24т_КомментарииЗадачи" \
  'б24т_КомментарииЗадачи\.' \
  '/CommonModules/' "$PRODUCT"

# 6. chat methods: a string literal starting with «im.» anywhere in the product must be im.dialog.messages.get, and it
# appears only in the allowed list of the client, the comments reader and the right check of «Проверить подключение».
only "из методов чата в продукте есть только чтение im.dialog.messages.get" \
  '"im\.|,im\.' \
  '/CommonModules/(б24т_Битрикс24|б24т_КомментарииЗадачи|б24т_Настройки)/' "$PRODUCT"
BAD="$(grep -rnE --include='*.bsl' '"im\.|,im\.' "$PRODUCT" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' \
  | grep -oE '"im\.[A-Za-z._]+|,im\.[A-Za-z._]+' | grep -vE 'im\.dialog\.messages\.get$')"
if [ -n "$BAD" ]; then
  echo "НАРУШЕНИЕ: в продукте назван метод чата, кроме im.dialog.messages.get"
  echo "$BAD" | sed 's/^/  /'
  FAILED=1
else
  echo "ОК: в продукте не назван ни один метод чата, кроме im.dialog.messages.get"
fi

only "формы и команды не вызывают б24т_OpenAI" \
  'б24т_OpenAI\.' \
  '/CommonModules/' "$PRODUCT"

# The only callers of the OpenAI client: the settings check («Проверить ИИ», explicit key from the form) and the
# «Заполнить с помощью ИИ» operation (the saved key, read by the client itself).
only "запрос к OpenAI (б24т_OpenAI.Вызвать) делают только б24т_Настройки и б24т_ЗаполнениеИИ" \
  'б24т_OpenAI\.Вызвать' \
  '/CommonModules/(б24т_Настройки|б24т_ЗаполнениеИИ)/' "$PRODUCT"

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

# 4b. no exported function returns the OpenAI key: no exported name with «КлючOpenAI» (the masked presentation is
# «ПредставлениеКлючаOpenAI», genitive, and takes the key as a parameter)
BAD="$(grep -rnE --include='*.bsl' '^[[:space:]]*Функция[[:space:]]+[^ (]*КлючOpenAI[^ (]*[[:space:]]*\(.*\)[[:space:]]*Экспорт' "$PRODUCT" || true)"
if [ -n "$BAD" ]; then
  echo "НАРУШЕНИЕ: экспортная функция с ключом OpenAI в имени"
  echo "$BAD" | cut -d: -f1,2 | sed 's/^/  /'
  FAILED=1
else
  echo "ОК: экспортных функций с ключом OpenAI в имени нет"
fi

# 4c. the functions that read the safe storage stay private: КлючИзХранилища, АдресИзХранилища, АдресВебхукаКлиента
BAD="$(grep -rnE --include='*.bsl' '^[[:space:]]*Функция[[:space:]]+(КлючИзХранилища|АдресИзХранилища|АдресВебхукаКлиента)[[:space:]]*\(.*\)[[:space:]]*Экспорт' "$PRODUCT" || true)"
if [ -n "$BAD" ]; then
  echo "НАРУШЕНИЕ: функция чтения безопасного хранилища экспортная"
  echo "$BAD" | cut -d: -f1,2 | sed 's/^/  /'
  FAILED=1
else
  echo "ОК: функции чтения безопасного хранилища не экспортные"
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

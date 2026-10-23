# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Stages 0–5 are done, including the live run 5.6 of the REST client; stage 6 (the access checks, Ф2, module `б24т_Доступ`) is implemented test-first and its live check on the development webhook passed on 2026-10-21 (the development webhook is entered, test mode on, project 38; the 11 test tasks were deleted from the portal and must be recreated before acceptance, which notifies the colleagues in their roles): the extensions and YAxUnit are installed in the local base, the first rule (e-mail normalization) is implemented test-first, and the «ID Б24» column (Ф7) is in the tabular section and in `ФормаДокумента`; the settings form (Ф8) and `б24т_Настройки` exist; `б24т_Битрикс24` is the REST client, the settings form has the «Проверить подключение» button. The security audit fixes of 2026-10-22 are in (task 6.4 in `TASKS.md`). Stage 7 (the task list, search and selection by number or link, server side only: `б24т_Задачи`, `б24т_ЗадачиКлиентСервер`) is implemented test-first on 2026-10-22; 204 tests green. Stage 8 (the counterparty from the task's CRM company, Ф6, module `б24т_Контрагенты`) is implemented test-first on 2026-10-22; 237 tests green; its live check through the `1c` MCP on the development webhook passed on 2026-10-22 (the 7 test companies plus a two-company and a no-company task match table 2.2; the event log has one `crm.company.list` and one `crm.requisite.list` per run and no `/rest/`). Stage 9 (the window «Заполнить из задачи Битрикс24», Ф2–Ф4, and the entry button) is implemented test-first on 2026-10-22; 328 tests green; `scripts/ui-check.sh` passes live on the development webhook (46 checks); task 9.12 (the window under an ordinary employee) is closed without a run under that user. Stage 10 (the button and adding the row, Ф1/Ф5) is implemented test-first on 2026-10-23; 358 tests green; `scripts/ui-check.sh строка` and `окно` pass live on the development webhook; the scenario `чужой` (С8 under the test employee «[ТЕСТ] Сотрудник», roles БазовыеПраваБСП and гем_Табель) passes too; task 9.12 (the window itself under that user) is closed without that run. The plan:

- `PRD.md` is the spec (in Russian). References like «Ф3» point to its features and «С5» to its acceptance scenarios.
- `TASKS.md` is the work plan: stages and tasks derived from `PRD.md`, with the open questions the PRD leaves unanswered.

All user-facing texts (error messages, button labels, CRM-company reasons in the Ф6 table) must match `PRD.md` word for word.

## Working on a stage

Every `TASKS.md` stage or task goes through three steps. Each step is agreed with the user before the next one starts:

1. **Edge cases.** List the pitfalls of the stage as numbered edge cases, each with options and the recommended one first. The user is not a programmer: they decide only what affects the product and the user experience. Technical choices are ours; state them with the reason. Only read-only checks are allowed in this step: code, `.local/ka-config`, reads through the `1c` MCP, the `b24-dev-mcp` docs and read methods of `scripts/b24.sh`.
2. **Implementation plan.** Write a plan from the agreed edge cases and wait for the user to approve it.
3. **Implementation.** Carry out the approved plan, test-first (see «Development method: TDD»).

The user's «ок» closes the current step only; it never means "go implement". Until the plan is approved, don't install software, change data in a base or on the portal (`b24.sh --write`), load extensions, edit `src/` or run the test client.

## Stack

Product code is strictly BSL (the 1C:Enterprise language) in the extension `Б24ТабельИзЗадачи` (synonym «Б24: табель из задачи»): metadata, managed forms and modules. There is no HTML/JS, no BX24.js, no Bitrix24 app, no HTTP service published from 1C and no separate backend. Tests are BSL too. Python and PowerShell are used only by the vendored skill tooling. The hand-written tools are shell scripts in `scripts/`: the test runner `run-tests.sh`, the Bitrix24 REST caller `b24.sh`, the test-data script `b24-test-data.sh`, the response recorder `b24-record-responses.sh` and `b24-selftest.sh`, which checks the guards of `b24.sh` with stubbed `security` and `curl` (no Keychain, no network; run it after any change to `b24.sh`).

### The other Bitrix24 extension in the base

The base also has the extension `Б24ПрототипЭтап1`. It links customer orders to Bitrix24 tasks, comes from the sibling project `1c-invoice-generator` and is maintained by another programmer. It borrows `Документ.ЗаказКлиента` and keeps data in its own `Расш1_*` information registers.

- Never modify, reload or delete it. Replacing it drops its registers together with their data.
- Our extension shares no objects, settings or code with it and ships separately. This was a product decision: the two features are released and maintained independently.
- Don't rename `Б24ТабельИзЗадачи` once it is in a working base. The «ID Б24» values live in the extension, and an extension with another name won't have them.

## Architecture (planned)

The feature is a «Заполнить из задачи Б24» button in the command bar of the «Табель» table in `ФормаДокумента` of `Документ.гем_Табель`. It opens the 1C window «Заполнить из задачи Битрикс24». There the employee picks one of their Bitrix24 tasks and enters the time, and the window appends one row to the timesheet open in the form. The row isn't written automatically: the employee writes or posts the timesheet as usual.

The extension contains:

- the borrowed `гем_Табель` with a new tabular-section attribute «ID Б24», `Строка(20)`, shown and editable in `ФормаДокумента`, plus the button in that form;
- the window form (Ф3, Ф4);
- a Bitrix24 REST client that works through an incoming webhook over HTTPS;
- the form «Настройки интеграции с Битрикс24»: the webhook URL (kept in the 1C safe storage), a test-mode flag and the test project ID.

### Trust and data flow

- Identity comes from the 1C login: 1C user → its физлицо → the физлицо's e-mail (contact-info kind «Электронная почта») → the active Bitrix24 user with that e-mail.
- 1C calls Bitrix24 REST through the webhook from the settings. The webhook runs with the rights of the admin who created it. Its scopes are `task`, `crm`, `user` and `sonet_group` (the last one only for the test project name). The 1C server needs outbound HTTPS access to the portal.
- The feature only reads Bitrix24 (`user.get`, `user.admin`, `tasks.task.list`, `tasks.task.get`, `crm.company.get`, `crm.company.list`, `crm.requisite.list`, `sonet_group.get`). A webhook can't be made read-only, so this rule is enforced in code.
- The webhook URL must not reach the event log, messages or any form except the settings form.

### Matching rules (easy to get subtly wrong)

- **Employee:**
  - The timesheet's `Сотрудник` (`СправочникСсылка.ФизическиеЛица`) must equal the current 1C user's физлицо.
  - The e-mail is compared case-insensitively, with surrounding spaces trimmed. If the физлицо has several addresses, any of them may match.
- **Task:**
  - The user must be the creator, the responsible person or an accomplice. Observers don't count, and the task status doesn't matter.
  - The list shows open tasks and tasks closed no earlier than the timesheet date minus 30 days. Only status «Завершена» (5) counts as closed.
- **Counterparty:** only from a CRM **company** bound in the task's «Элементы CRM» (`UF_CRM_TASK`). Exactly one company is required.
  - Companies reached through deals or contacts don't count. A deleted company counts as absent.
  - The number is the first of `RQ_BIN`, `RQ_IIN` and `RQ_INN` that contains digits, taken from the first active requisite of the company (in card display order) that has one. Only the digits are kept (`2345 1261 2395` and `234512612395.` give `234512612395`; `-` is empty), the leading zero stays, the number is text.
  - It is compared with `СокрЛП(Справочник.Контрагенты.ИНН)` («БИН/ИИН»). Counterparties marked for deletion are excluded, and exactly one match is required.
  - The company name is never used. If no counterparty is found, the row is still added with an empty counterparty.
- **Row:**
  - The row is added to the open form's «Табель» table, which is then sorted by `ВремяНач` the way the form does before «Добавить»; the new row lands in its place. Existing rows' values are never edited, and the document is never written.
  - Default start time is the `ВремяКон` of the row with the latest `ВремяНач`; 09:00 if the table is empty; empty if that row has no end time. An overlap with another row is a warning, never a block.
  - If no counterparty was found, the new row's «Контрагент» cell becomes current and its choice opens.
  - `ТипПП` is never filled.
  - The time types offered are the `Перечисление.гем_ТипыВремени` values starting with «Клиент» or «Офис», except «Офис (командировка)» and «Офис (собрания)» (the form clears the counterparty for them). The default is «Клиент (УД)».
  - The calculated fields (Факт, Норма, К оплате, Зарплата and others) and the «Всего зарплата» total must use the same code the form runs on manual time entry. The other fields get the same defaults as a row added with «Добавить».
  - The calculation lives only in `ФормаДокумента`. Its «Редактировать в диалоге» flag is locked off, and `ФормаВвода` has no calculation code.

### KA base facts (stage 1)

- **Form `гем_Табель.ФормаДокумента`** (client procedures, not exported):
  - `Пересчет(Стр)` computes Факт, Норма, К оплате, Зарплата and the Вызов fields; for «Клиент» it calls `гем_Сервер.ПолучитьВызовКлиента`.
  - `ОбработкаФормы(Стр)` sets column availability and clears fields per time type.
  - `ОбновитьПодвал()` recomputes the «Всего к оплате» label.
  - `ТабельПередНачаломДобавления` sorts by `ВремяНач`; `ТабельПриНачалеРедактирования` sets the new row's `ВремяНач` to the last row's `ВремяКон`.
  - `ПриОткрытии` disables the table's command bar when `ПроверитьПрава()` is false (no full rights and the author's физлицо isn't the user's).
- **Adding a row from the extension:** the borrowed form's module calls the original procedures directly: sort → add and fill → `ОбработкаФормы` → `Пересчет` → `ОбновитьПодвал` → make current, set `Модифицированность`. Our command is NOT marked `ИзменяетСохраняемыеДанные` (the platform marks the form modified when the command starts, and «Отмена» would leave the «save changes?» question); read-only mode is handled in code (`б24т_ПриОткрытииПосле` disables the button when `ТолькоПросмотр`).
- **Closed periods:** БСП checks the change-prohibition date only on write; the form stays editable.
- **Form.xml** binds 7 events to procedures that don't exist (e.g. `ПослеЗаписи`). The borrowed form still loads and opens; nothing had to be removed.
- **«ID Б24» (stage 3):**
  - The tabular-section attribute is `б24т_IDБ24`, `Строка(20)`, synonym «ID Б24». The form column is `Табельб24т_IDБ24`, placed right after `ТабельСодержание`. It is the only column the extension adds; `ФормаВвода` is not borrowed.
  - The extension now changes the data structure. After an update on the office server users must restart 1C. Disabling the extension hides the numbers, deleting it erases them.
  - Borrowing `гем_Табель` pulled in `Справочник.Пользователи`, `ФизическиеЛица`, `Контрагенты` and the enums `гем_ТипыВремени`, `ГЕМ_ТипПП` as unchanged borrowed objects.
  - A row copy (F9, document copy) carries the number with the other fields. This is platform behavior; Ф7 says so.
  - The form module of the extension can call the original non-exported client procedures `ОбработкаФормы`, `Пересчет` and `ОбновитьПодвал` directly (checked with a probe that computed Факт 01:30 and updated the footer). This confirms the stage 1.4 decision for stage 10.
  - `cfe-validate -ConfigPath` reports error 14 for the new column: it checks form paths only against the main configuration and doesn't see the extension's own attributes. Run it without `-ConfigPath`. The `NegativeTextColor` warning is harmless.
- **Integration settings (stage 4):**
  - `б24т_Настройки` (server module): `Настройки()` (no URL in the structure, read in privileged mode), `НормализованныйАдресВебхука` (accepts only `https://‹имя›.bitrix24.‹зона›/rest/‹номер›/‹ключ›/`, zone of one or two labels), `ПредставлениеАдресаВебхука`, `ДанныеФормыНастроек` (also `Предупреждения` about test extensions and disabled unsafe-action protection, from `ПредупрежденияОРасширениях`), `ЗаписатьНастройки(Изменения, Пользователь)` (returns errors as `Поле`/`Текст`, writes nothing on error), `ПроверитьПраваНаНастройку`.
  - The full webhook URL exists only inside `б24т_Битрикс24` and as a private function of `б24т_Настройки` (for the connection check and the masked presentation). There is no exported function that returns it; don't add one. Both modules read the safe storage with owner `"Б24ТабельИзЗадачи"`, key `"АдресВебхука"`.
  - Test webhook addresses must be on `*.bitrix24.*` (the tests use `portal.bitrix24.kz`), or the client refuses them as «не настроено».
  - The test flag and project ID are constants of the extension; the URL is only in the safe storage. The event log gets `Б24ТабельИзЗадачи.Настройки` with the list of changed fields, never a value.
  - The form is the common form `б24т_НастройкиИнтеграции`. A common form in a subsystem's `Content` creates no menu item; the item is the common command `б24т_НастройкиИнтеграции` (group `ActionsPanelTools`) that opens the form, and the command is in the adopted subsystem `Администрирование.НастройкаИнтеграции`. `cfe-borrow` can't borrow a nested subsystem, so `Subsystems/Администрирование/Subsystems/НастройкаИнтеграции.xml` is hand-written (`ExtendedConfigurationObject` = the UUID of the original) and holds only the command in `Content`.
  - Rights: only the role `ПолныеПрава` of the main configuration has «setForNewObjects», so it alone gets rights on new objects of the extension (the form, the command and the constants); the extension's role is empty and not given to everyone. A test checks every role.
  - `ПравоДоступа(…, Роль)` works only in privileged mode (the platform raises an error otherwise).
  - Tests that write settings run in a transaction with rollback (`.ВТранзакции()`), so the developer's real webhook in the base is not touched.
  - `Новый` and `Исключение` are keywords: they can't be variable names.
- **REST client (stage 5):**
  - `б24т_Битрикс24` (server): `НовыйКлиент(Транспорт, АдресВебхука)` (address `Неопределено` = from settings, read before each request and never stored in the client), `Вызвать(Клиент, Метод, Параметры)`, `ВызватьВсеСтраницы(Клиент, Метод, Параметры, ИмяСписка)`, `ТекстОшибки(Ошибка)`, `ВидОшибки*()`. Eight methods are allowed (the Bitrix24 list above plus `user.admin`); any other, `batch` included, raises an exception before the address is read.
  - Errors are returned as data: `Ошибка.Вид` is `Недоступен` (no answer in 30 s, 5xx, 429, not JSON, rate limit), `НеНастроено` (401, 403, 3xx, access codes) or `ОшибкаМетода` (e.g. «Not found»). One retry after `ПаузаПовтора` (2 s) only for 503/5xx. Success is decided by the body (`error` / `result` keys), not by the HTTP status.
  - Parameters with keys like `::SUBFILTER-R` must be a `Соответствие`, a `Структура` can't hold them.
  - The transport is a common module with `ВыполнитьЗапрос(Запрос)` (`Выполнить` is a keyword). Product: `б24т_ТранспортHTTPS`, the only place with `HTTPСоединение`. Tests: `б24тТест_ЗаглушкаТранспорта` (queue `Клиент.Ответы`, journal `Клиент.Вызовы`; `НовыйКлиент`, `ДобавитьОтвет`, `ДобавитьСыройОтвет`, `ДобавитьИсключение`). Any other transport name than `б24т_ТранспортHTTPS` or a `б24тТест_*` module raises an exception. All `б24т_*` common modules have `ServerCall = false` (a test checks it).
  - The event-log texts of `б24т_Битрикс24` and `б24т_Доступ` pass through `б24т_Сопоставление.СкрытьАдресаЭлектроннойПочты` (`t***@example.com`); messages to the employee keep the full address.
  - Event log: `Б24ТабельИзЗадачи.Обращение` (every call, no answer content) and `Б24ТабельИзЗадачи.Ошибка`. `б24т_Настройки.СкрытьКлючВебхука` masks the webhook in any text, `НомерВладельцаВебхука` takes the creator's id from the address.
  - `б24т_Настройки.ПроверитьПодключение(Параметры, Пользователь, Клиент)` backs the settings-form button; the form calls it from a wait handler so the «Проверка подключения…» label is painted first.
  - Keywords that can't be names of variables, parameters, structure properties or functions: `Новый`, `Исключение`, `Выполнить`. A local variable named `Параметры` inside a managed form is read-only.
  - `scripts/b24-record-responses.sh` re-records every template from the portal; the portal data changed since stage 2, so a full re-run rewrites the old templates with different content. The stage 5 block runs on its own: copy the preamble and the block into a temporary script.
  - Live run 5.6: `б24тТест_ЖивойПрогон.Прогон(Данные)` through the `1c` MCP (restart its session first so it sees the new module).
  - Task answers: `accomplicesData` and `auditorsData` are objects keyed by user id, but an empty `[]` when the task has no such members; `closedDate` is present and `null` on an open task. Code must accept both shapes and must not rely on these `*Data` fields for the role check.
- **Access checks (stage 6):**
  - `б24т_Доступ` (server): `ПроверитьДоступ(Сотрудник, Пользователь, Клиент)` returns `Успех`, `Сообщение`, `Контекст` (`ИДПользователя` as a number, `РежимТестирования`, `ПроектДляТестирования`, `НазваниеПроекта`); `ДанныеПользователя1С(Пользователь)` returns `ФизическоеЛицо`, `ФИО`, `Адреса` (read in privileged mode, only for the user's own физлицо).
  - Order is the Ф2 table: webhook set → employee → физлицо → own timesheet → e-mail → the same e-mail on another физлицо not marked for deletion (all 1C, no REST call) → `user.admin` → `user.get` → in test mode `sonet_group.get`. Nothing is cached. A full success writes «Сотрудник ‹ФИО› сопоставлен с пользователем Битрикс24 ID ‹N› по e-mail ‹скрытый›» to `Б24ТабельИзЗадачи.Доступ`.
  - Another `Пользователь` than the logged-in one, or any `Клиент`, in `ПроверитьДоступ`, `ДанныеПользователя1С`, `ПроверитьПодключение`, `ЗаписатьНастройки` and `ПроверитьПраваНаНастройку` is accepted only in privileged mode (`б24т_Доступ.ПроверитьПодменуДляТестов`). Tests wrap such calls in `УстановитьПривилегированныйРежим(Истина)`; form code must always pass `Неопределено`. Don't wrap a call under the current user: in privileged mode `ЭтоПолноправныйПользователь` is true for anyone.
  - `user.get` gets all the employee's addresses in one `FILTER.EMAIL` array plus `ACTIVE: true` and `USER_TYPE: "employee"`. Bitrix24 treats `EMAIL` as a pattern (`_` and `%` match any character) and does not trim spaces, so `б24т_Сопоставление.ПодходящиеПользователи` re-checks the exact address. Two different users matched → refusal with the new Ф2 text; no user → all addresses listed in the message.
  - Refusals the employee can't understand from the text (webhook owner is not an admin, several users, the same e-mail on another физлицо, test project missing) go to the event log as `Б24ТабельИзЗадачи.Доступ`.
  - The contact-info kind `EMailФизическиеЛица` allows several values; add them one by one with `УправлениеКонтактнойИнформацией.ДобавитьКонтактнуюИнформацию(…, Замещать = Ложь)`.
  - The `1c` MCP session doesn't see a newly loaded module until the 1C client behind it is restarted; `restart_1c_session` timed out on 2026-10-21 and left two hung `1cv8c /Execute` processes, so restart the client by hand. In MCP code the catalog description of the user is «Орлов Александр Владимирович»; «Администратор (ОрловАВ)» is only the login name, so take the user from `Пользователи.АвторизованныйПользователь()`.
- **Task list (stage 7):**
  - `б24т_Задачи` (server): `СписокЗадач(Сотрудник, ДатаТабеля, Пользователь, Клиент)` returns `Успех`, `ОтказВДоступе`, `Сообщение`, `Задачи` (rows of plain values, sorted by activity), `Усечено`, `Предупреждение`, `Подпись`, `НадписьРежимаТестирования`. `ЗадачаПоНомеру(Сотрудник, Текст, Пользователь, Клиент)` returns `Итог` (`Выбрана` / `Отклонена` / `Ошибка`), `Сообщение`, `Номер`, `Задача` (`Номер`, `Название`, `МояРоль`; only when selected). Both run `б24т_Доступ.ПроверитьДоступ` first and take the employee's Bitrix24 ID from it; the ID, the client and raw answers never go into the result. Form code passes `Неопределено` for `Пользователь` and `Клиент`.
  - `б24т_ЗадачиКлиентСервер` (client and server, `ServerCall = false`): `КлючСтроки`, `ПодходитПодПоиск` (case-insensitive, «е» = «ё», search ≤ 100 characters), `ПорядокСортировки(Вид)` for `Сортировать()` of a values table and of form data, `ТекстНичегоНеНайдено`, `МаксимальнаяДлинаПоиска`/`МаксимальнаяДлинаНомера` (100/300). The search runs on the loaded list on the client, with no server call.
  - The list is two `tasks.task.list` queries merged by `id` (`::SUBFILTER-R` creator OR responsible; `ACCOMPLICE`), each with `::SUBFILTER-ST` (`!REAL_STATUS` 5 OR `>=CLOSED_DATE` = boundary minus one day, portal date format), `GROUP_ID` in test mode and `order: {ID: desc}`; then every task is re-checked in 1C (`ДопускЗадачи`, `ПопадаетВСписок`). Company names come from one `crm.company.list`; a company absent from the answer is deleted and doesn't count.
  - The boundary is the whole day `дата табеля − 30`. Bitrix24 dates are converted with `СмещениеВремени()` (`ТекущаяДатаСеанса − ТекущаяУниверсальнаяДата`, rounded to 15 minutes), not with the platform time-zone base; compare moments, not strings.
  - Task numbers: `РазобратьНомерИлиСсылку` accepts `10180`, `#10180`, `№ 10 180` and links with `/tasks/task/view/N` or `/tasks/task/edit/N` (no spaces, ≤ 300 characters); anything else gives 0. Only the number goes into `tasks.task.get` (`taskId`).
  - `ДопускЗадачи`: test-mode project first (`groupId`), then the role. A task the employee has no role in returns no title, company or counterparty.
  - Limits of `б24т_Битрикс24`: `НовыйКлиент` has `МаксимумСтраниц` 20 (1000 records), `МаксимумРазмераОтвета` 5 MB (a larger body is `Недоступен` without retry) and `СрокОкончания`; `УстановитьПределВремени(Клиент, Секунд)` sets the total time (60 s for the list): when it is over no request is sent, the request timeout is not longer than the rest, and no retry if the pause doesn't fit.
  - Tests: `ЗаписатьJSON` doesn't accept `Null`. The test module writes the marker `"__NULL__"` and replaces it with `null` in the text; `СтрПовторить` doesn't exist in this compatibility mode. `tasks.task.list` with this `select` returns all needed fields (`status`, not `subStatus`, is the real status; `subStatus` -2/-3 are «not viewed»/«almost overdue» flags).
- **Counterparty (stage 8):**
  - `б24т_Контрагенты` (server, `ServerCall = false`): `КонтрагентыЗадач(Клиент, Задачи, Названия)` returns `Успех`, `Сообщение`, `Контрагенты` (`Соответствие` task number → `Контрагент` (ref or empty), `БИН`, `Текст`: «найден в 1С по БИН ‹номер›» or the Ф6 reason). Rules are exported for tests: `НормализованныйНомер`, `НомерИзРеквизитов(Реквизиты, ИДКомпании)`, `КонтрагентыПоНомерам`, `РезультатПоНомеру`, `ТекстНетКомпании`, `ТекстНесколькоКомпаний`, `ТекстНетНомера`.
  - Decided early, not on click: `б24т_Задачи.СписокЗадач` calls it for the tasks that stayed in the list (rows get `Контрагент`, `БИН`, `ТекстКонтрагента`), `ЗадачаПоНомеру` for the selected task (`Задача.Контрагент`, `БИН`, `ТекстКонтрагента`). Never for a task the employee has no role in: no company name or number leaks. Stage 10 takes the counterparty from the window and doesn't look it up again.
  - A company counts if it is in `crm.company.list` (`б24т_Задачи.СуществующиеКомпании`, the same rule as the «Компания CRM» column). One `crm.requisite.list` per 50 companies (`ENTITY_TYPE_ID` 4, `ENTITY_ID` list, `order SORT, ID`, all pages), only for tasks with exactly one company; requisites with `ACTIVE` = «N» are skipped; `SORT` and `ID` are compared as numbers. The 1C lookup is `ВЫБРАТЬ РАЗРЕШЕННЫЕ` (the employee's rights). Texts always say «БИН», even for an ИИН or ИНН.
  - Tests: `б24тТест_Контрагенты` (26) and seven in `б24тТест_Задачи`. The set answers `crm_company_list_НаборС6` and `crm_requisite_list_НаборС6` hold the 7 test companies; the tests replace their real numbers with `99…` numbers of «[ТЕСТ]» counterparties (checked absent from the base first; the transaction rollback removes them). The «Stage 8» block of `scripts/b24-record-responses.sh` re-records only those two.
  - `Задачи` is a platform global (the Task manager): never name a local variable so (parameters are fine).
- **Window (stage 9):**
  - The window is the own form `Документ.гем_Табель.Форма.б24т_ЗаполнениеИзЗадачи` of the borrowed document (`form-add -Purpose Custom`, no default-form slot; a common form would be seen only by `ПолныеПрава`). It has no main attribute, locks the owner (`БлокироватьОкноВладельца`) and returns the row data (`б24т_ЗаполнениеИзЗадачиКлиентСервер.ДанныеСтроки`) to the opener; it writes nothing. Form.xml was first generated by `form-compile`, but its JSON is not kept: Form.xml is the source now, edit it with `form-edit` and check it with `form-validate`. The module is hand-written.
  - **Form parameters are not readable on the client** (`Параметры.Сотрудник` fails with «Поле объекта не обнаружено» in an open window, found by `ui-check`). `ПриСозданииНаСервере` copies them into the attributes `ТабельСотрудник`, `ТабельДата`, `ТабельСтроки`; client code reads only those.
  - Rules: `б24т_ЗаполнениеИзЗадачи` (server: `ТипыВремениОкна`, `ТипВремениПоУмолчанию`), `б24т_ЗаполнениеИзЗадачиКлиентСервер` (start time, overlap, time hints, `МожноДобавить`, selection transitions `ВыбратьИзСписка` / `ПрименитьРезультатНомера` / `ПрименитьПерепроверку`, `ДанныеСтроки`, `СписокВремён`). 00:00 means «not set». `б24т_Доступ.ПроверитьДоступВ1С` is the REST-free part of Ф2 (shared worker `ПроверкиВ1С`).
  - Client tests (`б24тТест_ЗаполнениеИзЗадачиФормаКлиент`) take the form with `ПолучитьФорму` (no `ПриОткрытии`, no wait handlers, no REST) and feed the exported procedures `ПрименитьПроверкуДоступа`, `ПрименитьСписок`, `ВыбратьСтрокуСписка`, `ПрименитьРезультатНомера`, `ЗавершитьДобавление` with ready structures. Event handlers called by tests must be `Экспорт`.
  - Loading, number lookup and the re-check on «Добавить в табель» run from `ПодключитьОбработчикОжидания(…, 0.1, Истина)` after the label is painted; handlers do nothing unless the form `Открыта()`.
  - The entry command `б24т_ЗаполнитьИзЗадачи` and the button (first in `ТабельКоманднаяПанель`) are in the borrowed `ФормаДокумента`; `б24т_ПараметрыОкна()` takes date, employee and rows (`НомерСтроки`, `ВремяНач`, `ВремяКон`) from the open form. The row is added by stage 10 in `б24т_ПослеЗакрытияОкна`.
- **Adding the row (stage 10):**
  - In the borrowed `ФормаДокумента`: `б24т_ПослеЗакрытияОкна` → `б24т_ДобавитьСтроку(Данные)` (exported, returns the row). It calls the original `ТабельПередНачаломДобавления` (sort by `ВремяНач`), inserts the row at `б24т_ЗаполнениеИзЗадачиКлиентСервер.ИндексНовойСтроки` (after the rows with the same start), fills the fields from `ДанныеСтроки`, then `ОбработкаФормы` → `Пересчет` → `ОбновитьПодвал`, makes the row current and sets `Модифицированность`. «Содержание» is taken from the window as it is (the shifr template substitution is not called). Nothing is written.
  - `б24т_ОкноДоступно()` (exported): not `ТолькоПросмотр` and the table's command bar is enabled; `б24т_ЗаполнитьИзЗадачи` (exported) does nothing otherwise.
  - The choice of the counterparty opens only if none was found and the time type starts with «Клиент» (`ВыбиратьКонтрагента`, client-server module: the server module `б24т_ЗаполнениеИзЗадачи` can't be called from the client form). The form sets `Элементы.Табель.ТекущийЭлемент = Элементы.ТабельКонтрагент`, raises the form attribute `б24т_ЖдётВыбораКонтрагента` and starts the wait handler `б24т_ОткрытьВыборКонтрагента` (0.1 s): `ИзменитьСтроку()` plus `ОткрытьФорму("Справочник.Контрагенты.ФормаВыбора", , Элементы.ТабельКонтрагент)`. The platform puts the chosen counterparty into the cell (checked live).
  - For «Клиент» with a counterparty the form itself adds the «Вызов» of the client (`гем_Сервер.ПолучитьВызовКлиента`, 30 minutes for a new counterparty), so Зарплата = К оплате + Вызов.
  - Tests: `б24тТест_ТабельСтрокаИзЗадачиКлиент` (24 client tests on an open form), helper `б24тТест_ТабельСтрокаСервер` (`ServerCall = true`, no tests: counterparties, a saved timesheet, `ВерсияДанных`), six server tests in `б24тТест_ЗаполнениеИзЗадачи`. `ПолучитьСообщенияПользователю` does not exist on the client: the «Новый тип времени» message can't be caught by a client test. A query alias must not be named like a tabular section (`Табель`).
  - Own test tasks for live checks: `ownDalstroy` (company «[ТЕСТ] Дальстрой») and `ownNoCompany` (no company) in project 38, the developer is creator and responsible, nobody else is notified. `scripts/b24-test-data.sh create-tasks KEY…` creates tasks of the spec in the existing project and companies of `ids.json`.
- **UI check (`scripts/ui-check.sh [scenario] [--user "name"]`):** builds `tools/ui-check` (external processor, `epf-build`) into `.local/ui-check/`, starts a test client (`1cv8c … /TESTCLIENT -TPort<free port>`) and a test manager (`/TESTMANAGER /Execute UiCheck.epf /C"out=…;port=…;scenario=…;since=…"`) on the local base, prints the report and kills only its own two processes. `--user` runs only the test client under that user; the test manager always runs as the registry user, who can read the event log. Run outside the sandbox; about 1.5 minutes. Exit 0 passed, 1 failed, 2 environment (no `ИТОГ:` line = the scenario hung, the report shows the last step). Scenarios: «окно» (open a new timesheet, press the button, check the window, С2/С12/С14, «Отмена», event log); «строка» (adds rows from the two own test tasks, passed as `tasks=` from `scripts/b24-test-data.ids.json`: row on its place, counterparty, choice of the counterparty, recalculation, repeat, row without the end, not written, post and delete; С1/С4/С5/С15); «чужой» (`--user "[ТЕСТ] Сотрудник"`: the manager creates a timesheet of the admin, the client opens it by the navigation link and checks that «Заполнить из задачи Б24» and «Добавить» are disabled, С8). Table API of the test client: `ПолучитьВыделенныеСтроки()` gives the current row as a map «column title → text» (times as `ч:мм:сс`), `ПерейтиКСледующейСтроке()` raises at the end of the table, a row in edit mode must be finished (`ЗакончитьРедактированиеСтроки`, then a pause) before reading; `ВвестиТекст` plus a focus change may fail once, so the number entry retries; `Попытка` is a keyword, not a variable name; `ТестируемаяФорма` has no `Закрыть`. A user created in the Designer has no standard authentication (login «Пользователь ИБ не идентифицирован») and no item in `Справочник.Пользователи` (БСП: «не существует в справочнике»): through `execute_code` set `АутентификацияСтандартная = Истина`, create the catalog item and link it with `ИдентификаторПользователяИБ` under `ОбменДанными.Загрузка = Истина` (a normal write clears the link). `ТестируемаяКнопкаФормы.ТекущаяДоступность()` ignores a disabled parent group: check the command bar and that `Нажать()` raises. The platform syntax help can be unpacked with `7zz x /opt/1cv8/8.3.23.2040/shcntx_ru.hbk` when the `1c` MCP is down. Facts: the report is written step by step; e-mails and everything after «/rest/» are masked on every write, and a run whose text had «/rest/» fails; `ВвестиТекст` only types, the change event fires when focus leaves, so the tool activates another field; an empty label reads back as its element name; read dynamic label text by polling (`ЖдатьТекст`); a form attribute named `Окно`/`Объект`/`Параметры` is read-only, don't use these as variable names; the test API reference is available through the `1c` MCP `get_bsl_syntax_help`. The tool covers what unit tests cannot: real open forms, wait handlers, the platform behavior.
- **E-mail:** `УправлениеКонтактнойИнформацией.КонтактнаяИнформацияОбъектов` (server only) with type `АдресЭлектроннойПочты` and kind `Справочники.ВидыКонтактнойИнформации.EMailФизическиеЛица`; the address is in `Представление`.
- **Counterparty number:** `Контрагенты.ИНН`, `Строка(12)`, indexed. `СокрЛП` works in queries here.
- **Time types in the window:** representation starts with «Клиент»/«Офис», minus `ОфисКомандировка` and `ОфисСобрания`, 13 values; default `КлиентУдаленныйДоступ`.
- **БСП:** safe storage via `ОбщегоНазначения.ЗаписатьДанныеВБезопасноеХранилище`/`ПрочитатьДанныеИзБезопасногоХранилища` in privileged mode, owner `"Б24ТабельИзЗадачи"`, key `"АдресВебхука"`; `Пользователи.ЭтоПолноправныйПользователь()`; the settings command goes into subsystem `Администрирование.НастройкаИнтеграции`.

### Bitrix24 REST facts (stage 2, checked on the portal)

- **Webhook access.** The development webhook sees tasks where its owner has no role (e.g. task 550). The role check is therefore only ours: never trust the list to contain only the employee's tasks.
- **Task list by role.** `::SUBFILTER-…` with `"::LOGIC": "OR"` works for `CREATED_BY` and `RESPONSIBLE_ID`, but `ACCOMPLICE` or `AUDITOR` inside an OR subfilter silently drops tasks that have no accomplices or auditors at all. `MEMBER` includes auditors. So the list takes two queries merged by ID:
  1. `::SUBFILTER-R`: OR of `CREATED_BY` and `RESPONSIBLE_ID` = the employee's ID;
  2. `ACCOMPLICE` = the employee's ID.
- **Open or recently closed.** `::SUBFILTER-ST`: `{"::LOGIC": "OR", "!REAL_STATUS": 5, ">=CLOSED_DATE": "ДД.ММ.ГГГГ ЧЧ:ММ:СС"}`. Inside a subfilter only the portal format is accepted; ISO dates give «Incorrect date/time» (outside subfilters ISO works). The date is read in the webhook owner's time zone (+05:00 here) and the boundary is exact to the second.
- **Project filter:** `GROUP_ID`; tasks outside a project return `groupId: "0"`.
- **Title search:** `TITLE` with a plain value is a case-insensitive substring search; `%` is taken literally.
- **Paging:** 50 per page, `start` = offset, the answer has `total` and `next` (absent on the last page).
- **Answer shape:** `result.tasks[]` with camelCase keys (`id`, `title`, `createdBy`, `responsibleId`, `accomplices`, `auditors`, `status`, `groupId`, `ufCrmTask`, `closedDate`, `deadline`, `activityDate`), all IDs as strings. `ufCrmTask` is `null` when empty, otherwise `["CO_<id>", …]` (other prefixes are deals, contacts and so on). Dates are ISO with offset, e.g. `2026-10-15T20:40:55+05:00`.
- **Status codes** (`status`/`REAL_STATUS`): 2 «Ждёт выполнения», 3 «Выполняется», 4 «Ждёт контроля», 5 «Завершена», 6 «Отложена». Only codes come back, names are ours. A task created with `TASK_CONTROL = N` goes straight to 5 on `tasks.task.complete`.
- **Task links:** `…/company/personal/user/<uid>/tasks/task/view/<id>/` and `…/workgroups/group/<gid>/tasks/task/view/<id>/`; take the number after `/task/view/`.
- **Errors:**
  - `tasks.task.get` of a missing task: HTTP 200 with `"result": []` (no error).
  - `crm.company.get` of a missing (or deleted) company: HTTP 400, `"error": ""`, `"error_description": "Not found"`.
  - Wrong webhook token: HTTP 401, `INVALID_CREDENTIALS`.
  - A company without requisites: `crm.requisite.list` → `result: []`, `total: 0`.
- **Users:** `user.get` with `FILTER.EMAIL` ignores case; add `ACTIVE: true`.
- **Requisites:** presets on this portal (KZ, `COUNTRY_ID` 6): 1 «ИП» (`RQ_IIN`), 3 «Юр. лицо» (`RQ_BIN`, `RQ_IIN`), 5 «Физ. лицо». `crm.requisite.list` takes `ENTITY_ID` as a list, so one call covers several companies; order by `SORT`, then `ID`.
- **Company names for the list:** `crm.company.list` with `filter.ID` as a list and `select: [ID, TITLE]` gives all names in one call. It is in the feature's method list (approved after stage 2).
- **Time zones differ by method:** `sonet_group.get` returns `+03:00`, tasks return `+05:00`. Compare dates as instants, not as strings.

## Tooling

### MCP servers (`.mcp.json`)

- **`1c`**, at `http://127.0.0.1:6003/mcp`, gives live access to the 1C base: queries, metadata, code execution and the event log.
  - It is served by `MCP_Toolkit_macos.epf`, a macOS build of the toolkit. The copies in the root and in `tools/` are identical.
  - That file must be open in 1C:Enterprise in «Встроенный сервер» mode with the server started. If `mcp__1c__*` calls fail, it isn't running.
- **`b24-dev-mcp`** holds the official Bitrix24 REST docs. Look up methods, placements and scopes there instead of relying on memory.

### Submodule

`tools/1c-mcp-toolkit` is the upstream toolkit (ROCTUP, v1.9.0) and is kept as reference only. Initialize it with:

```bash
git submodule update --init
```

### Skills

- `.claude/skills/` (for Claude Code) and `.agents/skills/` (for other agents) are vendored copies pinned in `skills-lock.json`. Don't hand-edit them.
- The 1C skills (`cf-*`, `cfe-*`, `db-*`, `epf-*`, `form-*`, `meta-*`, `skd-*` and others) come from `nikolay-shirokov/cc-1c-skills`. The Bitrix24 skills come from `bxmaximum/bitrix-framework-skills`.
- Use `$code-scout` for non-trivial repository discovery to delegate broad code reading to a lower-cost subagent scout and keep irrelevant file contents out of the primary agent's context.

### Running 1C skill scripts on macOS

The skill docs show `powershell.exe -NoProfile -File …/scripts/<name>.ps1`. That binary doesn't exist on this Mac. Every script has a Python twin that takes the same `-Param` arguments, for example:

```bash
python3 .claude/skills/cfe-validate/scripts/cfe-validate.py -ExtensionPath src/cfe/Б24ТабельИзЗадачи
```

`pwsh -NoProfile -File …ps1` also works.

The local platform is `/opt/1cv8/8.3.23.2040`. The base is «Комплексная автоматизация для Казахстана» 2.4.5.21 with БСП 3.1.7 in compatibility mode `Version8_3_21`. `cfe-init` defaults `CompatibilityMode` to `Version8_3_24`. Take the mode from the base configuration with `-ConfigPath`, or pass `Version8_3_21` explicitly, so the extension still loads.

The local development base is a copy of the KA demo base, the file base `~/Documents/1C/Базы/КА демо`. Designer-mode skills (`db-dump-*`, `db-load-*`) fail with a lock error while the Configurator has that base open.

Its configuration was loaded from the production KA's `.cf`, so `гем_Табель` and its forms match production as of that snapshot. The office server runs a compatible platform and already reaches Bitrix24 over HTTPS: the orders extension calls its REST from there.

### Local setup

- **`.v8-project.json`** (git-ignored, per developer) is the database registry in the `db-list` format. The `db-*` scripts read only `v8path`/`v8args` from it, so always pass `-InfoBasePath` and `-UserName` explicitly. The local base is used as «Администратор (ОрловАВ)» without a password; that user's физлицо «Орлов Александр Владимирович» carries `TEST_USER_EMAIL`.
- **`.local/`** (git-ignored) holds the full config dump `.local/ka-config` (`configSrc`, about 80 000 files, 5.5 GB, format 2.16), downloads in `.local/vendor/`, logs and test reports.
- **Sources:**
  - `src/cfe/Б24ТабельИзЗадачи` is the product extension: AddOn, prefix `б24т_`, `Version8_3_21`, safe mode off, unsafe-action protection on.
  - `src/cfe/Б24ТабельИзЗадачиТесты` is the test extension: AddOn, prefix `б24тТест_`, safe mode and protection off.
  - Run `cfe-validate` after every change. The warning about format 2.16 being below the tested range is expected.
- **Dev loop.** Load an extension with `db-load-xml.py -ConfigDir src/cfe/<Name> -Extension <Name> -UpdateDB`.
  - Always name `-Extension` explicitly and never use `-AllExtensions`, so `Б24ПрототипЭтап1` stays untouched.
  - Run every `1cv8`/`ibcmd` command outside the Claude Code sandbox; inside it the platform exits with 134 or hangs.
  - A 1C session sees extension changes only after it restarts. Test runs start their own session. The `1c` MCP session needs a restart only when you inspect new metadata through it.
  - If `/UpdateDBCfg` hits an exclusive lock, ask the user to close the 1C clients.
- **Module files** are UTF-8 with exactly one BOM. Writing a file can keep an existing BOM, so check the first bytes (`efbbbf` once) before loading. A doubled BOM breaks compilation.

### Tests

- **Framework:** YAxUnit 25.12, extension `YAXUNIT`, from `https://github.com/bia-technologies/yaxunit/releases/download/25.12/YAxUnit-25.12.cfe`, SHA-256 `805a2277c997a3c24be0b0d080696479e91e4a15ed7e27aaf3991a7346522d70`. Safe mode and protection are off.
  - The applicability check warns that `OnStart` and `ОбработкаОтображенияОшибки` handlers are missing. Tests still run.
  - `YAXUNIT` and the test extension live only in the local base and are never installed in the office or production bases.
- **Run:** `scripts/run-tests.sh` (outside the sandbox). It launches the thin client `1cv8c` with `RunUnitTests` and reads YAxUnit's result file. Exit codes: 0 green, 1 red (failed tests are printed), 2 environment not ready. Reports go to `.local/tests/` (`junit.xml`, `yaxunit.log`).
  - YAxUnit skips a test module that fails to compile and still reports success. The script therefore treats `[ERR]` in its log or zero executed tests as red.
- **Test modules:** server common modules `б24тТест_<ТестируемыйМодуль>` with `ИсполняемыеСценарии()`. A module compiled on the client can't use server-only БСП modules, so keep server tests in server-only modules; client tests go in separate client modules.
  - `meta-compile` with `"context": "server"` sets `ServerCall` to true and YAxUnit silently skips such a module (it reports fewer tests and green). Set `<ServerCall>false</ServerCall>` in the module's XML and check the test count after a run.
  - Client tests: keep the form from `ПолучитьФорму(...)` in a variable (an element of a released form is «недействительный объект»), and don't read `ПутьКДанным` of an element (unavailable on the client).
  - Changing the data structure (a new attribute) needs exclusive access: close every 1C client, Designer and the MCP processing before loading the extension.
- **Recorded Bitrix24 responses:** text common templates of the test extension, `б24тТест_Ответ_<метод>_<случай>` (dots in the method become `_`, errors not tied to a method are `Ответ_Ошибка_<случай>`), with the webhook URL, real e-mails and names removed.
  - `scripts/b24-record-responses.sh` re-records all of them from the test data (IDs in `scripts/b24-test-data.ids.json`) and builds the `_Синтетика` ones the portal can't produce on demand.
  - Templates hold only the body. HTTP statuses: «Not found» 400, `INVALID_CREDENTIALS` 401, `INTERNAL_SERVER_ERROR` 500, `QUERY_LIMIT_EXCEEDED` 503.
  - The test `б24тТест_ЗаписанныеОтветы` lists the required ones and fails if any template is not JSON or contains `/rest/`, the portal domain or an e-mail outside `example.com`. A new template must be added to its list.
- **REST client stub.** YAxUnit's Мокито can't intercept methods of an extension, so the transport is passed in as a parameter.
  - The parameter is the name of a common module with `Выполнить(Запрос)`. Production code uses the HTTPS module of the product extension; tests pass `б24тТест_ЗаглушкаТранспорта`.
  - The stub answers from the templates and appends every call to the `Вызовы` array of the client structure.
  - Resolve the module with БСП `ОбщегоНазначения.ОбщийМодуль`; it finds product-extension modules (verified).
- **Data in the base:** `ЮТест.Данные()` with `.УдалениеТестовыхДанных()`, plus `.ВТранзакции()` for server tests. Names start with «[ТЕСТ]».
- **Form logic** lives in server functions on plain structures and is tested on the server. The glue to `ФормаДокумента` is covered by client tests that open the form with `ПолучитьФорму(…)` and call its exported procedures.
- **HTTPS:** connect with `Новый ЗащищенноеСоединениеOpenSSL(Неопределено, Новый СертификатыУдостоверяющихЦентровОС)`. Without the second parameter the certificate isn't checked. The local base reaches `toofirmagem.bitrix24.kz` this way.

## Development method: TDD

All code is written test-first, in small red → green → refactor cycles:

1. **Red.** Write one test for the next behavior and run it. Check that it fails for the expected reason, not because of a typo or missing setup.
2. **Green.** Write the minimum code that makes it pass. Add no behavior that no test asks for.
3. **Refactor.** Clean up code and tests while everything stays green, then run `cfe-validate`.

How this applies here:

- Tests come from the spec. Every branch of Ф2, Ф3, Ф4, Ф5, Ф6 and Ф8 and every acceptance scenario («С…» in `PRD.md`) gets a test before its code. Expected messages are copied from `PRD.md` word for word, so the tests also catch text drift.
- Keep the matching rules in server functions that take plain structures, not HTTP connections or live REST calls. These rules are e-mail normalization, the role check, the 30-day list filter, the CRM-company count, number extraction from requisites and the counterparty lookup. Unit-test them against recorded Bitrix24 JSON responses with the webhook URL removed.
- Test the window logic with the Bitrix24 REST client stubbed. Cover the invariants:
  - a row is always added and never overwrites an existing one;
  - the document is not written;
  - no REST call writes to Bitrix24;
  - the webhook URL never reaches the event log or messages.
- Tests that touch the demo base use only «[ТЕСТ]» data and clean up after themselves.
- A bug fix starts with a test that reproduces the bug.
- A change is done only when all tests pass. Never skip or weaken a test to get green; report failures with their output.

## Test data conventions

- Development happens on the developer's copy of the KA demo base. Acceptance happens on the KA demo base on the office server, in test mode. Both use the production Bitrix24 portal.
- Test companies and tasks are prefixed «[ТЕСТ]» and live in the project «[ТЕСТ] Табель из задачи».
- Test data is created over REST through the development webhook with `scripts/b24-test-data.sh`. The webhook is reissued before production.
- The CRM 1C ↔ Bitrix24 exchange is not involved in development or acceptance.
- Local test values live in `.env` (git-ignored; `.env.example` is the template). `TEST_USER_EMAIL` is the developer's e-mail for the Bitrix24 user and the физлицо in the local demo base. Reading `.env` is allowed.
- The developer is also the Bitrix24 portal admin. They create the development webhook under their own account, put its URL into the macOS Keychain (`security add-generic-password -a "$USER" -s b24-dev-webhook -w`) and enter it into 1C themselves.
  - Webhook URLs never go into `.env`, the repo or the agent chat. Don't ask for them, don't read them back from the safe storage through the `1c` MCP server, and never run `security find-generic-password … -w` yourself.
  - Call Bitrix24 only through `scripts/b24.sh <method> ['<json>'] [--write] [--save <file>] [--bad-token]`. It reads the URL from the Keychain, masks it in all output, allows a whitelist of read methods and needs `--write` for the methods that create or delete test data. Run it outside the sandbox (Keychain access).
  - The webhook owner and the test user are the same person. A live run therefore can't catch code that lists the webhook owner's tasks instead of the employee's. Unit tests must assert that every task request passes the employee's Bitrix24 ID explicitly.

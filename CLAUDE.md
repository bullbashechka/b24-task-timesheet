# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Stage 0 is done: the empty product extension, the test extension and YAxUnit are installed in the local base, and the first rule (e-mail normalization) is implemented test-first. The plan:

- `PRD.md` is the spec (in Russian). References like «Ф3» point to its features and «С5» to its acceptance scenarios.
- `TASKS.md` is the work plan: stages and tasks derived from `PRD.md`, with the open questions the PRD leaves unanswered.

All user-facing texts (error messages, button labels, CRM-company reasons in the Ф6 table) must match `PRD.md` word for word.

## Stack

Product code is strictly BSL (the 1C:Enterprise language) in the extension `Б24ТабельИзЗадачи` (synonym «Б24: табель из задачи»): metadata, managed forms and modules. There is no HTML/JS, no BX24.js, no Bitrix24 app, no HTTP service published from 1C and no separate backend. Tests are BSL too. Python and PowerShell are used only by the vendored skill tooling; the one hand-written tool is the shell test runner `scripts/run-tests.sh`.

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
- The feature only reads Bitrix24 (`user.get`, `tasks.task.list`, `tasks.task.get`, `crm.company.get`, `crm.requisite.list`, `sonet_group.get`). A webhook can't be made read-only, so this rule is enforced in code.
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
  - The number is the first filled of `RQ_BIN`, `RQ_IIN` and `RQ_INN`, taken from the first requisite (in card display order) that has one. Spaces are stripped on both sides.
  - It is compared with `Справочник.Контрагенты.ИНН` («БИН/ИИН»). Counterparties marked for deletion are excluded, and exactly one match is required.
  - The company name is never used. If no counterparty is found, the row is still added with an empty counterparty.
- **Row:**
  - The row is appended to the end of the open form's «Табель» table. Existing rows are never edited, and the document is never written.
  - `ТипПП` is never filled.
  - The time types offered are the `Перечисление.гем_ТипыВремени` values starting with «Клиент» or «Офис». The default is «Клиент (УД)».
  - The calculated fields (Факт, Норма, К оплате, Зарплата and others) and the «Всего зарплата» total must use the same code the form runs on manual time entry. The other fields get the same defaults as a row added with «Добавить».
  - The form has a «Редактировать в диалоге» flag, so rows can also be edited in `ФормаВвода`. Check both forms for the calculation code.

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
- **Recorded Bitrix24 responses:** text common templates of the test extension, `б24тТест_Ответ_<метод>_<случай>`, with the webhook URL, real e-mails and names removed.
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
  - a row is always appended and never overwrites an existing one;
  - the document is not written;
  - no REST call writes to Bitrix24;
  - the webhook URL never reaches the event log or messages.
- Tests that touch the demo base use only «[ТЕСТ]» data and clean up after themselves.
- A bug fix starts with a test that reproduces the bug.
- A change is done only when all tests pass. Never skip or weaken a test to get green; report failures with their output.

## Test data conventions

- Development happens on the developer's copy of the KA demo base. Acceptance happens on the KA demo base on the office server, in test mode. Both use the production Bitrix24 portal.
- Test companies and tasks are prefixed «[ТЕСТ]» and live in the project «[ТЕСТ] Табель из задачи».
- Test data is created over REST through a temporary incoming webhook, which is deleted afterwards.
- The CRM 1C ↔ Bitrix24 exchange is not involved in development or acceptance.
- Local test values live in `.env` (git-ignored; `.env.example` is the template). `TEST_USER_EMAIL` is the developer's e-mail for the Bitrix24 user and the физлицо in the local demo base. Reading `.env` is allowed.
- The developer is also the Bitrix24 portal admin. They create the development webhook and the temporary test-data webhooks under their own account and enter the URLs into 1C themselves.
  - Webhook URLs never go into `.env`, the repo or the agent chat. Don't ask for them, and don't read them back from the safe storage through the `1c` MCP server.
  - The webhook owner and the test user are the same person. A live run therefore can't catch code that lists the webhook owner's tasks instead of the employee's. Unit tests must assert that every task request passes the employee's Bitrix24 ID explicitly.

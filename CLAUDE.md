# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

There is no application code yet. The project is at the planning stage:

- `PRD.md` is the spec (in Russian). References like «Ф3» point to its features and «С5» to its acceptance scenarios.
- `TASKS.md` is the work plan: stages and tasks derived from `PRD.md`, with the open questions the PRD leaves unanswered.

All user-facing texts (error messages, button labels, CRM-company reasons in the Ф6 table) must match `PRD.md` word for word.

## Stack

Product code is strictly BSL (the 1C:Enterprise language) in the extension `Б24ПрототипЭтап1`: metadata, managed forms and modules. There is no HTML/JS, no BX24.js, no Bitrix24 app, no HTTP service published from 1C and no separate backend. Tests are BSL too. Python and PowerShell are used only by the vendored skill tooling.

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
python3 .claude/skills/cfe-validate/scripts/cfe-validate.py -ExtensionPath src/cfe/Б24ПрототипЭтап1
```

`pwsh -NoProfile -File …ps1` also works.

The local platform is `/opt/1cv8/8.3.23.2040`. `cfe-init` defaults `CompatibilityMode` to `Version8_3_24`. Take the mode from the base configuration with `-ConfigPath`, or pass it explicitly, so the extension still loads.

The local development base is a copy of the KA demo base, the file base `~/Documents/1C/Базы/КА демо`. Designer-mode skills (`db-dump-*`, `db-load-*`) fail with a lock error while the Configurator has that base open.

### Not set up yet

- **`.v8-project.json`**, the database registry that the `db-*` and `cfe-*` skills read for connection details and `configSrc`. Create it with `/db-list add`.
- **Source layout.** By skill convention, extension sources go in `src/cfe/<Name>`. Run `cfe-validate` after every change to them.
- **Test framework.** It must be BSL, for example YAxUnit as a separate test extension. The runner and the fixture layout aren't chosen yet. Settle them before the first extension code is written.

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

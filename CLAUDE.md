# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

There is no application code yet. The project is at the planning stage:

- `PRD.md` is the spec (in Russian). References like «Ф3» point to its features and «С5» to its acceptance scenarios.
- `TASKS.md` is the work plan, stages 0–9. Stage 0 is a go/no-go browser feasibility check. If browsers block the Bitrix24 iframe from calling the office-LAN 1C server, the architecture below has to be revisited before the main development starts. Open questions are listed at the end of `TASKS.md`.

All user-facing texts (error messages, button labels, CRM-company reasons in the Ф6 table) must match `PRD.md` word for word.

## Architecture (planned)

The feature is a «Заполнить табель» button in a Bitrix24 cloud task. It adds one row to the employee's 1C timesheet (`Документ.гем_Табель`, tabular section «Табель»). It has two parts and no separate backend:

1. **1C extension `Б24ПрототипЭтап1`** (on the KA demo base on the office server, and on the production KA only after acceptance). It contains:
   - the borrowed `гем_Табель` with a new tabular-section attribute «ID Б24», `Строка(20)`, shown and editable in `ФормаДокумента`;
   - an HTTP service. It serves the HTML/JS window page (it runs inside the Bitrix24 slider via BX24.js) and the JSON methods: `ping` (stage 0), `init` (window opens) and `add` (append a row);
   - integration settings: the portal URL, a technical integration user, a test-mode flag and the test project ID.
2. **Bitrix24 local app.** It has only placements, with no server logic: the «Приложения» block in the new task card (placement code still TBD) and `TASK_LIST_CONTEXT_MENU`. Scopes are `task`, `crm`, `user` and `placement`. Both placements point at the page published by the 1C web server.

### Trust and data flow

- The page sends 1C only the task ID, the Bitrix24 user access token and the fields the user entered. 1C calls Bitrix24 REST itself with that token: `user.current`, `tasks.task.get`, `crm.company.get` and `crm.requisite.list`. The portal URL comes from the 1C settings, never from the page.
- The role check (creator, responsible or accomplice only) and the employee lookup run on `init` and again on `add`.
- The app must never write to CRM or to tasks. The CRM scope can't be made read-only, so this rule is enforced in code.
- Tokens must not reach the 1C event log.
- The 1C server is LAN-only and must be published over HTTPS with a certificate the browsers trust. The 1C server needs outbound HTTPS access to the portal.

### Matching rules (easy to get subtly wrong)

- **Employee:** the Bitrix24 user's e-mail is matched, case- and whitespace-insensitive, against the 1C user's or the физлицо's e-mail. The matched физлицо becomes the timesheet employee.
- **Counterparty:** only from a CRM **company** bound in the task's «Элементы CRM». Exactly one company is required; companies reached through deals or contacts don't count.
  - The БИН (or ИИН for sole proprietors) comes from the first requisite where it is filled, in card display order, with spaces stripped.
  - It is compared with the counterparty's «ИНН» field in 1C. Counterparties marked for deletion are excluded, and exactly one match is required.
  - The company name is never used. If no counterparty is found, the row is still added with an empty counterparty.
- **Timesheet:**
  - Use the employee's timesheet for the selected date that isn't marked for deletion. If there is none, create one: the date is the selected date plus the current time, the organization is the default, and the author is the employee's 1C user or the technical user.
  - Each `add` appends a new row and never edits existing rows.
  - A posted document is reposted; an unposted one is just written. Everything runs in one transaction, so any 1C error leaves no changes and its text goes back to the window.
  - Факт/Норма/К оплате must use the same calculation the form runs on manual time entry. Тип ПП is never filled.

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

### Not set up yet

- **`.v8-project.json`**, the database registry that the `db-*` and `cfe-*` skills read for connection details and `configSrc`. Create it with `/db-list add` once the demo base connection is known.
- **Source layout.** By skill convention, extension sources go in `src/cfe/<Name>`. Run `cfe-validate` after every change to them.
- **Test framework.** The 1C test runner (for example, YAxUnit as a separate test extension) and the fixture layout aren't chosen yet. Settle them before the first extension code is written.

## Development method: TDD

All code is written test-first, in small red → green → refactor cycles:

1. **Red.** Write one test for the next behavior and run it. Check that it fails for the expected reason, not because of a typo or missing setup.
2. **Green.** Write the minimum code that makes it pass. Add no behavior that no test asks for.
3. **Refactor.** Clean up code and tests while everything stays green, then run `cfe-validate`.

How this applies here:

- Tests come from the spec. Every branch of Ф2, Ф4, Ф5 and Ф6 and every acceptance scenario («С…» in `TASKS.md`) gets a test before its code. Expected messages are copied from `PRD.md` word for word, so the tests also catch text drift.
- Keep the matching rules (e-mail normalization, БИН/ИИН extraction from requisites, the CRM-company count, the counterparty lookup) in server functions that take plain structures, not HTTP requests or live REST calls. Unit-test them against recorded Bitrix24 JSON responses with tokens removed.
- Test `init` and `add` with the Bitrix24 REST client stubbed. Cover the invariants: a row is always appended and never overwrites an existing one, a posted timesheet is reposted, any error rolls everything back, no REST call writes to CRM or tasks, and no token reaches the event log.
- Tests that touch the demo base use only «[ТЕСТ]» data and clean up after themselves.
- A bug fix starts with a test that reproduces the bug.
- A change is done only when all tests pass. Never skip or weaken a test to get green; report failures with their output.

## Test data conventions

- Development and acceptance happen on the production Bitrix24 portal and on the KA demo base.
- Test companies and tasks are prefixed «[ТЕСТ]» and live in the project «[ТЕСТ] Табель из задачи».
- Test data is created over REST through a temporary incoming webhook, which is deleted afterwards.
- The CRM 1C ↔ Bitrix24 exchange is not involved in development or acceptance.

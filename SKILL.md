---
name: ASKB
description: Drive the Bloomberg ASKB (Beta) AI chat window on the Bloomberg Terminal via Windows GUI automation — paste a question, read the answer back from screenshots, and translate it into a testable Bloomberg API recipe (BQL / BDP / BDH / BDS / BLPAPI). Use whenever the user wants to ask ASKB / "Ask Bloomberg" something, pull Bloomberg data, or discover the API route + fields for a Bloomberg data request.
---

# ASKB — Bloomberg "Ask Bloomberg" automation + API discovery

Drives the **ASKB (Beta)** chat window in the Bloomberg Terminal: types a question,
submits it, and reads the response back from screenshots. ASKB is used for
**discovery and translation** — turning a natural-language data request into an
exact, testable Bloomberg API recipe. The deliverable is an API-access recipe,
not Terminal navigation.

## Run it headless (important)

When invoked interactively, the controlling terminal window keeps stealing
foreground and **obscures ASKB** on screen, and screenshots catch the terminal on
top. Avoid this by running the automation **headless** so there is no visible
console window. Use the launcher:

```
pwsh -File scripts/run-headless.ps1 -Task "Use the ASKB skill: new chat, ask ASKB for the latest price of AAPL US Equity, read + scroll the answer, then report the price, BDP formula, and BLPAPI field."
```

`run-headless.ps1` feeds the task to `claude -p --dangerously-skip-permissions`
via **stdin from a temp file**. Do NOT pass a long/multi-line prompt as an inline
`claude -p "<text>"` argument — the shell truncates it (an early version saw the
prompt cut down to just `"Use"`). The launcher prints the headless agent's stdout
and enforces a timeout; run it in the background if you don't want to block.

The helper script also minimizes console windows as a fallback for interactive
runs (pass `-NoMinimizeTerminals` to disable). Either way, the script re-focuses
ASKB immediately before every screenshot — so screenshots are clean even
in-session.

## Prerequisites & readiness (auto-handled)

The user only needs the **Bloomberg Terminal running and logged in**. ASKB itself
does **not** need to be open — the skill launches it. Always start with
`-Action ensure`, which:

1. Checks the Terminal is running. If not → returns a friendly message asking the
   user to open and log into Bloomberg (it does **not** fail hard).
2. Checks for the login screen. If present → asks the user to log in.
3. Checks for the ASKB chat window. If missing → **launches it by physically
   clicking the Bloomberg command line and typing `ASKB<GO>`** (with a `HELP`→`ASKB`
   refresh fallback, since ASKB only spawns its separate window on a fresh
   navigation), then waits. A physical click is required because
   `SetForegroundWindow`+`SendKeys` does not reliably focus Bloomberg's command line.
4. If everything is ready (or once ASKB launches) → returns `{ok:true, ...}`.

Only proceed to send a prompt when `ensure` returns `ok:true`. Otherwise relay its
`message` to the user.

## Helper script — `scripts/askb.ps1`

Composable primitives. **Never hardcode PIDs or coordinates** — the script detects
the window every call and clicks at window-relative fractions. Run with `pwsh`
(PowerShell 7). `-Out` defaults to `%TEMP%\askb_shot.png`; after each call, **Read
the PNG** to see the result.

| Action | What it does |
|---|---|
| `bbstatus` | JSON readiness check: `{bloomberg_running, terminal_panels, login_required, askb_open, window}`. No side effects. |
| `ensure` | Make ASKB ready: friendly message if Bloomberg/login missing; **auto-launch ASKB** if the chat is closed. Returns `{ok, ...}` or `{ok:false, need, message}`. |
| `find` | Print detected window (id, title, rect) as JSON. Diagnostic / availability check. |
| `send -Prompt "..." [-NewChat] [-WaitSeconds N] -Out p.png` | Calls `ensure` first, then paste a prompt, submit (Enter), wait, screenshot. `-NewChat` starts a fresh chat. |
| `shot -Out p.png` | Screenshot the ASKB window now. |
| `scroll -Amount -1200 -Out p.png` | Scroll chat (negative = down), then screenshot. The window only shows ~one screen; long answers need several scrolls. |
| `click -RelX 0.17 -RelY 0.25 -Out p.png` | Click at a window-relative fraction, then screenshot. Use to expand `> Data Query` toggles or `Expand Table to Artifact Pane`. |
| `newchat -Out p.png` | Click the compose / new-chat icon. |

### How the window is detected
The live chat is the `bplus64` process whose `MainWindowTitle` is **`ASKB (Beta)`**.
The doubled-prefix `ASKB ASKB (Beta) by Bloomberg AI` window is the embedded panel —
the script explicitly skips it.

### Hard-won automation lessons (baked into the script)
- **Paste, don't type.** Set the clipboard and send `Ctrl+V`; simulated keystrokes
  drop characters and multi-line text submits prematurely. Enter submits.
- **A fresh chat's input box is centered** (~`RelY 0.53`); once a conversation
  exists, the follow-up box is **near the bottom** (~`RelY 0.94`). `send -NewChat`
  handles this automatically.
- **Read responses from screenshots**, not the DOM. ASKB is a Chromium-based
  (`blpwtk2`) surface; capture and visually read.
- **Scroll all the way through long answers.** After reaching what looks like the
  end, scroll once more to confirm — the message ends at the **Suggested Follow-Ups**
  block above the input bar. Don't stop early.
- **Data is collapsed.** Actual values hide behind `> Data Query` toggles and the
  `Expand Table to Artifact Pane` control (opens a panel on the right). Use `click`
  at the toggle's fraction, or use the **Excel-export icon** next to a query.

### How the Terminal is detected (for auto-launch)
The Bloomberg Terminal is the `wintrv` process; its command panels are windows of
class `BLPFrameWClass`/`BLPFrame{1..5}WClass` titled `1-BLOOMBERG`…`6-BLOOMBERG`.
"Bloomberg is open" = `wintrv` running with these panels. A visible
`BLOOMBERG: Login` window = not logged in. To launch ASKB, the script finds the
main Bloomberg tab (a `bplus64` window whose title isn't the `ASKB (Beta)`
standalone), physically clicks its command line (~90px,93px from the tab's
top-left), and types `ASKB<GO>`.

## Workflow

1. **Ensure ASKB is ready** — `-Action ensure`. If it returns `ok:false`, relay its
   `message` (open Bloomberg / log in / open ASKB) and stop. Otherwise continue.
2. **Ask with the API-first prompt** below (`send -NewChat`). Default `-WaitSeconds 30`;
   bump to 45–60 for heavier data queries.
3. **Read + fully scroll** the answer (`scroll`, repeat) and expand any data tables.
4. **Extract** the route, securities, fields, overrides, dates, entitlements, and the
   minimal reproducible test (schema below).
5. If ASKB returns only Terminal screen guidance, send the **mandatory API follow-up**.
6. **Validate** through the strongest available route before claiming high confidence.
7. If validation fails, send the **error follow-up** with the exact error.
8. Save reusable validated recipes and concise session notes (Storage below).

## Required ASKB prompt (API-first)

```text
I want to access Bloomberg data programmatically, not just through Terminal screens.

Question: [USER QUESTION]

Please give:
1. The best BQL query if available.
2. BDP formulas for point-in-time fields.
3. BDH formulas for historical fields.
4. BDS formulas for bulk/reference datasets, if applicable.
5. BLPAPI field mnemonics, security syntax, services, request type, and overrides.
6. Any required date handling, periodicity, currency, source, or account
   entitlement considerations.
7. A minimal reproducible test example that can be validated through Bloomberg
   API, Bloomberg Excel, BQuant, or a local Bloomberg broker.

Do not give only Terminal navigation. If a Terminal function is relevant, include
it only as supporting context.
```

## Mandatory API-access follow-up (if ASKB answers with screen navigation)

```text
The answer above gives Terminal screens/functions. I need the API-accessible version.

Please translate this into exact Bloomberg API access instructions:
- BQL query, if supported
- BDP/BDH/BDS Excel formulas, if supported
- BLPAPI service/request type, securities, fields, overrides, and dates
- Any field mnemonics, bulk fields, or dataset identifiers
- A minimal validation example

If there is no API-accessible route, say so explicitly and explain the limitation.
```

## Error follow-up (if validation fails)

```text
This Bloomberg API validation failed:

[ERROR]

Original request:
[USER QUESTION]

Attempted API route:
[FIELDS / SECURITIES / BQL / FORMULA / REQUEST]

What is the correct API-accessible version? Please provide exact fields,
securities, overrides, date handling, and a minimal validation example.
```

## Extraction schema

After ASKB answers, extract: `original_question`, `askb_prompt`,
`askb_answer_summary`, `terminal_functions`, `api_routes`, `securities`, `fields`,
`overrides`, `date_handling`, `entitlements_or_limitations`, `minimal_tests`,
`validation_status`, `validation_evidence`, `confidence`, `askb_session_note`.

## Validation guidance

Prefer the strongest available validation:
1. Local broker endpoint using the repo's Bloomberg service.
2. Direct BLPAPI request (a local BLPAPI test script, or the official `blpapi` examples).
3. BQL execution.
4. Bloomberg Excel formula.
5. BQuant notebook/script.

Confidence:
- `high`: API route validated with live data / a clear Bloomberg API response.
- `medium`: route is specific and plausible, but validation could not be run.
- `low`: ASKB gave incomplete, screen-only, or conflicting guidance.

## Safety

- Use ASKB for **discovery only**.
- **Never** use computer control for order entry, EMSX, FXGO, BUY/SELL screens,
  trade tickets, unattended sensitive workflows, or bulk GUI scraping.
- Do not treat ASKB conclusions as investment recommendations.
- Do not accept ASKB output as final until validated through an API, Bloomberg
  Excel, BQuant, or the local broker. ASKB shows a beta-accuracy warning — verify.

## Storage

- Validated reusable recipes → `bloomberg_knowledge/field_dictionary.json`
  (also used as the MCP server's recipe cache, keyed by question hash)
- Concise session notes → `bloomberg_knowledge/askb_sessions/`
  (date, user question, ASKB prompt, answer summary, validation attempt, result,
  follow-ups).

## Programmatic access — MCP server / importable core

`scripts/askb_mcp_server.py` exposes ASKB discovery as **structured JSON** so other
programs (or agents) can call it. The "read the screen" step is delegated to a
headless `claude -p` run, so no extra API key is needed. Install deps once:
`python -m pip install -r scripts/requirements.txt`.

**Tools (stdio MCP):**
- `askb_status()` → `{available, window|error}` (cheap; no LLM call).
- `askb_ensure()` → confirm Bloomberg is up/logged in and **auto-launch ASKB** if
  closed; `{ok:true,...}` or `{ok:false, need, message}`. `askb_discover` calls it first.
- `askb_discover(question, validate=False, use_cache=True, wait_seconds=35)` →
  recipe dict: `security, api_route, field_mnemonic, bdp_formula, bdh_formula,
  bql_query, overrides, date_handling, entitlements_or_limitations, minimal_test,
  validation_status, confidence, notes`.
- `askb_clear_cache()` → clears `field_dictionary.json`.

**Register with an MCP client (stdio):**
```json
{ "mcpServers": { "askb": {
  "command": "python",
  "args": ["C:\\Users\\<you>\\.claude\\skills\\ASKB\\scripts\\askb_mcp_server.py"]
} } }
```
or Claude Code: `claude mcp add askb -- python <abs path>\scripts\askb_mcp_server.py`

**Or call the core directly from any Python program (no MCP):**
```python
from askb_mcp_server import discover_recipe, askb_window_status
recipe = discover_recipe("daily total return for AAPL US Equity")
```

`discover_recipe` caches by question (instant repeat calls, no GUI). Recommended
pattern: use it for **discovery** (figure out the field/query once), cache the
recipe, then have your program fetch the actual **data** directly via BLPAPI/BQL.
Do not route bulk/real-time data through ASKB — it is GUI-bound, serial, beta-
accuracy, and ~30–60 s per query.

## Provenance

Combines the project-local Codex skill `bloomberg-askb-api-discovery`
(API-first discovery workflow, prompts, validation, safety) with the GUI-automation
primitives developed for Claude Code on Windows.

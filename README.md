# askb-mcp

Drive **Bloomberg ASKB (Beta)** — Bloomberg's "Ask Bloomberg" AI assistant — from
Claude Code or any program, and turn natural-language data requests into **testable
Bloomberg API recipes** (BQL / BDP / BDH / BDS / BLPAPI).

It ships as both:
- a **Claude Code skill** (`SKILL.md`) — type `/ASKB` and ask, or
- an **MCP server** (`scripts/askb_mcp_server.py`) — call `askb_discover` from any
  MCP client (Claude Desktop/Code/Codex) or import `discover_recipe()` directly in Python.

ASKB is a Windows GUI app, so this automates it: it detects the ASKB window, pastes
a prompt, reads the answer back from screenshots, and extracts a structured recipe.

> ⚠️ **Windows only.** Requires a logged-in Bloomberg Terminal on the same machine.
> ASKB is in beta and shows an accuracy warning — treat results as **discovery**,
> validate via a real API/Excel/BQL run before relying on them, and never use it for
> order entry or any trade action.

## How it works

```
your prompt ─► askb.ps1 (focus ASKB window, paste, screenshot)
            ─► a headless `claude -p` reads the screenshot
            ─► structured JSON recipe ─► (cache) ─► your program / agent
```

Then fetch the actual **data** directly via BLPAPI/BQL using the discovered fields —
don't route bulk/real-time data through ASKB (it's GUI-bound, serial, ~30–60 s/query).

## Requirements

- Windows with the **Bloomberg Terminal running and logged in** (ASKB itself does
  *not* need to be open — the skill launches it by typing `ASKB<GO>`).
- **PowerShell 7** (`pwsh`).
- **Claude Code CLI** (`claude`) on PATH and authenticated — used headless to read
  the ASKB screen (no extra API key needed).
- **Python 3.10+** (only for the MCP server / `discover_recipe`).

## Install

```powershell
# 1. Clone into your Claude Code skills folder so /ASKB is available
git clone https://github.com/arjundivecha/askb-mcp.git "$env:USERPROFILE\.claude\skills\ASKB"

# 2. (MCP server only) install the Python dep
python -m pip install -r "$env:USERPROFILE\.claude\skills\ASKB\scripts\requirements.txt"
```

Restart Claude Code so it picks up the new skill.

## Use it as a Claude Code skill

Just ask, e.g. *"use ASKB to get the latest price for AAPL US Equity"* or run `/ASKB`.
The skill confirms Bloomberg is up (and launches ASKB if needed), sends an API-first
prompt, reads + scrolls the full answer, and extracts the recipe.

## Use it as an MCP server

Register it with your MCP client (stdio):

```json
{ "mcpServers": { "askb": {
  "command": "python",
  "args": ["C:\\Users\\<you>\\.claude\\skills\\ASKB\\scripts\\askb_mcp_server.py"]
} } }
```

or with Claude Code:

```powershell
claude mcp add askb -- python "$env:USERPROFILE\.claude\skills\ASKB\scripts\askb_mcp_server.py"
```

**Tools**
| Tool | Purpose |
|---|---|
| `askb_status` | Is the ASKB chat window open? (cheap, no LLM) |
| `askb_ensure` | Confirm Bloomberg is up/logged in; **auto-launch ASKB** if closed. Returns a friendly message if the user must act. |
| `askb_discover(question, validate=False)` | Return a structured API recipe. Calls `ensure` first; caches results. |
| `askb_clear_cache` | Clear the recipe cache. |

## Use it from plain Python (no MCP)

```python
import sys; sys.path.insert(0, r"C:\Users\<you>\.claude\skills\ASKB\scripts")
from askb_mcp_server import discover_recipe, askb_window_status

recipe = discover_recipe("daily total return for AAPL US Equity")
print(recipe["field_mnemonic"], recipe["bdp_formula"])
```

Recipes are cached (by question) in `bloomberg_knowledge/field_dictionary.json`, so
repeat calls return instantly without re-driving the GUI.

## HTTP transport (advanced)

To call the server from a *different* machine/VM (e.g. a host driving a Windows VM),
run `scripts/run-http.cmd` in the logged-on desktop session and point your MCP client
at `http://<this-machine-ip>:8765/mcp`.

## Direct PowerShell primitives

`scripts/askb.ps1` exposes composable actions: `bbstatus`, `ensure`, `find`, `send`,
`shot`, `scroll`, `click`, `newchat`. See the script header for usage.

## Safety

Discovery only. No order entry, EMSX, FXGO, trade tickets, or bulk GUI scraping.
ASKB output is **not** investment advice and **not** authoritative until validated
through a real Bloomberg API/Excel/BQL run.

## License

MIT — see [LICENSE](LICENSE).

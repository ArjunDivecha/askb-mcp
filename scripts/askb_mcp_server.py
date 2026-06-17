#!/usr/bin/env python
"""
ASKB MCP server (stdio) + importable core.

Exposes the Bloomberg ASKB discovery flow as MCP tools that return STRUCTURED JSON.
The "read the ASKB screen" step is delegated to a headless `claude -p` run (reusing
the validated automation in scripts/askb.ps1), so no second API key is needed.

Two ways to use it:

  1. As an MCP server (stdio) for an agent/client:
         python askb_mcp_server.py
     Register it with your MCP client (see SKILL.md "MCP server" section).

  2. Directly from any Python program (no MCP needed):
         from askb_mcp_server import discover_recipe, askb_window_status
         recipe = discover_recipe("daily total return for AAPL US Equity")

Tools / functions:
  - askb_window_status()                -> {available, window|error}
  - discover_recipe(question, ...)      -> structured recipe dict
  - clear_recipe_cache()                -> {cleared: n}
"""
from __future__ import annotations
import json
import re
import subprocess
import shutil
import hashlib
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
SCRIPTS = SKILL_DIR / "scripts"
ASKB_PS1 = SCRIPTS / "askb.ps1"
CACHE_FILE = SKILL_DIR / "bloomberg_knowledge" / "field_dictionary.json"

RECIPE_KEYS = [
    "security", "api_route", "field_mnemonic", "bdp_formula", "bdh_formula",
    "bql_query", "overrides", "date_handling", "entitlements_or_limitations",
    "minimal_test", "validation_status", "confidence", "notes",
]


def _pwsh() -> str:
    return shutil.which("pwsh") or shutil.which("powershell") or "pwsh"


def _claude() -> str:
    return shutil.which("claude") or "claude"


def _extract_json(text: str):
    """Pull the first balanced JSON object out of model output (tolerates fences/prose)."""
    if not text:
        return None
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    if fenced:
        try:
            return json.loads(fenced.group(1))
        except Exception:
            pass
    start = text.find("{")
    while start != -1:
        depth = 0
        for i in range(start, len(text)):
            c = text[i]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    frag = text[start:i + 1]
                    try:
                        return json.loads(frag)
                    except Exception:
                        break
        start = text.find("{", start + 1)
    return None


def _cache_load() -> dict:
    if CACHE_FILE.exists():
        try:
            return json.loads(CACHE_FILE.read_text(encoding="utf-8"))
        except Exception:
            return {}
    return {}


def _cache_save(data: dict) -> None:
    CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    CACHE_FILE.write_text(json.dumps(data, indent=2), encoding="utf-8")


def _key(question: str) -> str:
    return hashlib.sha1(question.strip().lower().encode("utf-8")).hexdigest()[:16]


def askb_window_status() -> dict:
    """Check whether the ASKB chat window is open. Cheap; no LLM call."""
    try:
        out = subprocess.run(
            [_pwsh(), "-NoProfile", "-File", str(ASKB_PS1), "-Action", "find"],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=40,
        )
        line = (out.stdout or "").strip().splitlines()[-1] if out.stdout.strip() else ""
        if out.returncode == 0 and line.startswith("{"):
            return {"available": True, "window": json.loads(line)}
        return {"available": False, "error": ((out.stderr or out.stdout) or "unknown").strip()[:500]}
    except Exception as e:  # noqa: BLE001
        return {"available": False, "error": str(e)}


def ensure_askb(launch_wait: int = 30) -> dict:
    """
    Make ASKB ready: confirm the Bloomberg Terminal is running (and logged in), and
    LAUNCH ASKB by typing ASKB<GO> into a command panel if the chat window is closed.
    Returns the ensure JSON: {ok, ...} on success, or {ok:false, need, message} when
    the user must act (open Bloomberg / log in / open ASKB manually).
    """
    try:
        out = subprocess.run(
            [_pwsh(), "-NoProfile", "-File", str(ASKB_PS1), "-Action", "ensure",
             "-LaunchWaitSeconds", str(launch_wait)],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=launch_wait + 60,
        )
        line = (out.stdout or "").strip().splitlines()[-1] if out.stdout.strip() else ""
        if line.startswith("{"):
            return json.loads(line)
        return {"ok": False, "need": "error",
                "message": ((out.stderr or out.stdout) or "ensure failed").strip()[:500]}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "need": "error", "message": str(e)}


def discover_recipe(
    question: str,
    validate: bool = False,
    use_cache: bool = True,
    wait_seconds: int = 35,
    timeout: int = 320,
) -> dict:
    """
    Ask ASKB how to get a Bloomberg data series and return a structured API recipe.

    question      Plain-English data request, e.g. "daily total return for AAPL US Equity".
    validate      If True, also validate the recipe via BLPAPI before returning.
    use_cache     Reuse a previously discovered recipe for the same question.
    wait_seconds  How long ASKB is given to answer before the screenshot.
    timeout       Hard cap (s) on the headless run.
    """
    q = (question or "").strip()
    if not q:
        return {"error": "empty question"}

    cache = _cache_load() if use_cache else {}
    k = _key(q)
    if use_cache and not validate and k in cache:
        rec = dict(cache[k])
        rec["_cached"] = True
        return rec

    ens = ensure_askb()
    if not ens.get("ok"):
        # Friendly, actionable result instead of a hard failure.
        return {
            "error": ens.get("message", "ASKB is not ready."),
            "action_required": ens.get("need"),
        }

    val_clause = ""
    if validate:
        val_clause = (
            " After extracting the recipe, validate it via BLPAPI / BQL / Bloomberg Excel "
            "if a local Bloomberg API connection is available, and set validation_status "
            "and confidence to reflect the result."
        )

    task = (
        "Use the ASKB skill at ~/.claude/skills/ASKB (run scripts/askb.ps1 with pwsh). "
        "Start a NEW ASKB chat and ask, using the skill's API-first prompt, this question:\n"
        f"{q}\n"
        f"Wait ~{wait_seconds}s, screenshot, Read it, and scroll through the ENTIRE answer "
        "(expand Data Query / data tables if needed)." + val_clause + "\n"
        "Then output ONLY a single JSON object (no prose, no code fences) with these keys: "
        + ", ".join(RECIPE_KEYS) + ". Use null for any field that does not apply."
    )

    try:
        proc = subprocess.run(
            [_claude(), "-p", "--dangerously-skip-permissions"],
            input=task, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return {"error": f"headless ASKB run timed out after {timeout}s"}

    if proc.returncode != 0:
        return {"error": "headless claude failed", "detail": ((proc.stderr or proc.stdout) or "")[:800]}

    rec = _extract_json(proc.stdout)
    if rec is None:
        return {"error": "could not parse recipe JSON from ASKB run", "raw": (proc.stdout or "")[:1500]}

    rec["original_question"] = q
    if use_cache and rec.get("confidence") in ("high", "medium"):
        cache[k] = rec
        _cache_save(cache)
    return rec


def clear_recipe_cache() -> dict:
    data = _cache_load()
    n = len(data)
    _cache_save({})
    return {"cleared": n}


# ---- MCP server wrapper (stdio) ------------------------------------------------
def _build_server():
    from mcp.server.fastmcp import FastMCP

    mcp = FastMCP("ASKB")

    @mcp.tool()
    def askb_status() -> dict:
        """Check whether the Bloomberg ASKB chat window is open and ready."""
        return askb_window_status()

    @mcp.tool()
    def askb_ensure() -> dict:
        """
        Make ASKB ready: confirm the Bloomberg Terminal is running and logged in, and
        auto-launch ASKB (by typing ASKB<GO> into a command panel) if it is closed.
        Returns {ok:true,...} when ready, or {ok:false, need, message} when the user
        must act (open Bloomberg / log in / open ASKB). askb_discover calls this first.
        """
        return ensure_askb()

    @mcp.tool()
    def askb_discover(
        question: str,
        validate: bool = False,
        use_cache: bool = True,
        wait_seconds: int = 35,
    ) -> dict:
        """
        Ask Bloomberg ASKB how to retrieve a data series and return a structured API recipe
        (security, api_route, field_mnemonic, bdp_formula, bdh_formula, bql_query, overrides,
        date_handling, entitlements_or_limitations, minimal_test, validation_status, confidence).
        Set validate=True to additionally validate via BLPAPI before returning.
        """
        return discover_recipe(
            question, validate=validate, use_cache=use_cache, wait_seconds=wait_seconds
        )

    @mcp.tool()
    def askb_clear_cache() -> dict:
        """Clear the cached recipe store (field_dictionary.json)."""
        return clear_recipe_cache()

    return mcp


def main() -> None:
    """
    Run the ASKB MCP server.

    Transport selection (so the SAME server can be used two ways):
      - stdio (default): a local MCP client spawns this process and talks over stdio.
      - HTTP  : long-running server in the guest's INTERACTIVE Windows session (so the
                ASKB GUI is reachable), exposed on a TCP port. A remote MCP client
                (e.g. Claude Code on the macOS host) connects over the Parallels network.

    Choose HTTP with `--http` (streamable-http) or `--sse`, or env ASKB_TRANSPORT.
    Bind via env ASKB_HOST (default 0.0.0.0) and ASKB_PORT (default 8765).
    """
    import os
    import sys

    transport = os.environ.get("ASKB_TRANSPORT", "stdio").lower()
    if "--http" in sys.argv:
        transport = "http"
    if "--sse" in sys.argv:
        transport = "sse"

    mcp = _build_server()
    if transport in ("http", "streamable-http", "sse"):
        mcp.settings.host = os.environ.get("ASKB_HOST", "0.0.0.0")
        mcp.settings.port = int(os.environ.get("ASKB_PORT", "8765"))
        # Trusted private Parallels link (macOS host <-> Windows guest). MCP's
        # DNS-rebinding guard 421s any non-localhost Host, so the macOS host
        # reaching the guest by IP would be rejected; disable it here. Stateless
        # so simple HTTP clients need no Mcp-Session-Id bookkeeping.
        mcp.settings.stateless_http = True
        try:
            from mcp.server.transport_security import TransportSecuritySettings
            mcp.settings.transport_security = TransportSecuritySettings(
                enable_dns_rebinding_protection=False
            )
        except Exception:
            pass
        mcp.run(transport=("sse" if transport == "sse" else "streamable-http"))
    else:
        mcp.run()  # stdio transport (default)


if __name__ == "__main__":
    main()

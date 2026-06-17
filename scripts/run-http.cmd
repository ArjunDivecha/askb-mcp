@echo off
REM ===================================================================
REM run-http.cmd - launch the ASKB MCP server as an HTTP (streamable)
REM   service in the INTERACTIVE Windows session so it can drive the
REM   live Bloomberg ASKB GUI window.
REM
REM   Use this when an MCP client on ANOTHER machine/VM needs to reach
REM   the server (e.g. a host connecting to a Windows VM over the LAN):
REM   the client connects to http://<this-machine-ip>:8765/mcp
REM
REM   Run it in the logged-on desktop session (session 1) -- e.g. via a
REM   scheduled task created with /it (interactive token) -- NOT session 0,
REM   or ASKB's GUI window will not be reachable.
REM
REM   OUTPUT: %TEMP%\askb_http.log  (server stdout/stderr)
REM   Set PY to your python.exe if "python" is not on PATH.
REM ===================================================================
set ASKB_PORT=8765
set ASKB_HOST=0.0.0.0
if "%PY%"=="" set PY=python
"%PY%" "%~dp0askb_mcp_server.py" --http > "%TEMP%\askb_http.log" 2>&1

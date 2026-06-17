<#
  run-headless.ps1 — launch a headless Claude Code run that drives ASKB.

  Headless (`claude -p`) means there is NO visible console window, so nothing
  steals foreground or obscures the ASKB window while the agent screenshots it.

  The task prompt is fed via STDIN from a temp file (Start-Process
  -RedirectStandardInput), NOT as an inline argument. Passing a long/multi-line
  prompt as an argument gets truncated by the shell (an early version of this
  skill saw the prompt cut down to just "Use"); stdin-from-file avoids that.

  USAGE
    pwsh -File run-headless.ps1 -Task "Use the ASKB skill: new chat, ask ASKB for
      the latest price of AAPL US Equity, read + scroll the answer, report the
      price, BDP formula, and BLPAPI field."

  PARAMS
    -Task            The instruction for the headless agent (required).
    -OutLog          Where stdout is written (default %TEMP%\askb_headless.log).
    -TimeoutSeconds  Kill the run if it exceeds this (default 300).

  Prints the agent's stdout when done. Run this itself in the background from the
  caller if you don't want to block.
#>
param(
  [Parameter(Mandatory=$true)][string]$Task,
  [string]$OutLog = "$env:TEMP\askb_headless.log",
  [int]$TimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'

$promptFile = "$env:TEMP\askb_headless_prompt.txt"
$errFile    = "$env:TEMP\askb_headless.err"
Set-Content -Path $promptFile -Value $Task -Encoding UTF8
foreach ($f in @($OutLog, $errFile)) { if (Test-Path $f) { Remove-Item $f -Force } }

$claude = (Get-Command claude -ErrorAction Stop).Source
$p = Start-Process -FilePath $claude `
       -ArgumentList @('-p', '--dangerously-skip-permissions') `
       -RedirectStandardInput $promptFile `
       -RedirectStandardOutput $OutLog `
       -RedirectStandardError $errFile `
       -NoNewWindow -PassThru

try {
  $p | Wait-Process -Timeout $TimeoutSeconds -ErrorAction Stop
} catch {
  Write-Warning "Headless run exceeded $TimeoutSeconds s; terminating."
  try { $p | Stop-Process -Force } catch {}
}

$code = try { $p.ExitCode } catch { 'unknown' }
Write-Output "--- headless exit code: $code ---"
if ((Test-Path $OutLog) -and (Get-Item $OutLog).Length -gt 0) {
  Write-Output "--- STDOUT ---"
  Get-Content $OutLog -Raw
} else {
  Write-Output "(no stdout captured)"
}
if ((Test-Path $errFile) -and (Get-Item $errFile).Length -gt 0) {
  Write-Output "--- STDERR (tail) ---"
  Get-Content $errFile -Tail 12
}

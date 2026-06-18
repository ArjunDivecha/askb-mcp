<#
  askb.ps1 — drive the Bloomberg ASKB (Beta) chat window via Windows GUI automation.

  Composable primitives for the ASKB skill. Detects the live ASKB chat window by
  process + title (PIDs change every session, so they are NEVER hardcoded).

  ACTIONS
    bbstatus Print Bloomberg/ASKB readiness as JSON: is the Terminal running, is it
             at the login screen, is ASKB open, how many command panels exist.
    ensure   Make ASKB ready: if Bloomberg isn't running -> friendly "open it" JSON;
             if at login -> "log in" JSON; if ASKB is closed -> LAUNCH it by typing
             ASKB<GO> into a Terminal panel and wait for the window. Returns JSON.
    find     Print the detected ASKB window as JSON (handle, rect). Diagnostic.
    send     Ensure ASKB is ready, then paste a prompt and submit it. -NewChat starts
             a fresh chat. Waits -WaitSeconds, then screenshots to -Out.
    shot     Screenshot the current ASKB window to -Out.
    scroll   Scroll the chat by -Amount wheel delta (negative = down), then screenshot.
    click    Click at window-relative fraction (-RelX -RelY), then screenshot.
    newchat  Click the new-chat (compose) icon, then screenshot.

  EXAMPLES
    pwsh -File askb.ps1 -Action bbstatus
    pwsh -File askb.ps1 -Action ensure
    pwsh -File askb.ps1 -Action send -NewChat -Prompt "latest price for AAPL US Equity" -Out C:\tmp\a.png

  Run headless (claude -p ... --dangerously-skip-permissions) so no visible terminal
  steals foreground and obscures ASKB. In interactive mode this script minimizes
  console windows first as a fallback (disable with -NoMinimizeTerminals).
#>
param(
  [Parameter(Mandatory=$true)][ValidateSet('bbstatus','ensure','find','send','shot','scroll','click','newchat')]
  [string]$Action,
  [string]$Prompt,
  [switch]$NewChat,
  [int]$WaitSeconds = 30,
  [string]$Out = "$env:TEMP\askb_shot.png",
  [int]$Amount = -1000,            # total wheel delta; negative scrolls DOWN
  [double]$RelX = 0.5,             # click X as fraction of window width
  [double]$RelY = 0.94,            # click Y as fraction of window height (bottom input bar)
  [int]$LaunchWaitSeconds = 30,    # how long to wait for ASKB to appear after typing ASKB<GO>
  [switch]$NoMinimizeTerminals
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class U {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, int e);
  [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  public struct RECT { public int L, T, R, B; }
  public static List<string> Rows = new List<string>();
  public static void Collect(IntPtr h) {
    var t = new StringBuilder(256); GetWindowText(h, t, 256);
    var c = new StringBuilder(128); GetClassName(h, c, 128);
    Rows.Add(((long)h) + "\t" + (IsWindowVisible(h) ? 1 : 0) + "\t" + (IsIconic(h) ? 1 : 0) + "\t" + c + "\t" + t);
  }
}
"@

function Get-AllWindows {
  [U]::Rows.Clear()
  [U]::EnumWindows([U+EnumProc] { param($h, $l) [U]::Collect($h); $true }, [IntPtr]::Zero) | Out-Null
  foreach ($r in [U]::Rows) {
    $p = $r -split "`t", 5
    [pscustomobject]@{ Handle = [long]$p[0]; Vis = [int]$p[1]; Min = [int]$p[2]; Class = $p[3]; Title = $p[4] }
  }
}

function Get-AskbWindow {
  # Live standalone chat = bplus64 whose title starts with "ASKB" but is NOT the
  # embedded "ASKB ASKB ..." panel. Prefer the exact "ASKB (Beta)" window.
  # Accept ONLY the standalone chat ("ASKB (Beta)"). The embedded launcher panel
  # ("ASKB ASKB (Beta) by Bloomberg AI") is a notice, not the drivable chat — never
  # fall back to it, or we'd think ASKB is open when the real chat is closed.
  $win = Get-Process -Name bplus64 -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowTitle -like 'ASKB*' -and $_.MainWindowTitle -notlike 'ASKB ASKB*' -and $_.MainWindowHandle -ne 0 } |
         Select-Object -First 1
  if (-not $win) { throw "No ASKB window found." }
  $h = $win.MainWindowHandle
  if ([U]::IsIconic($h)) { [U]::ShowWindow($h, 9) | Out-Null }
  [U]::ShowWindow($h, 9) | Out-Null
  [U]::SetForegroundWindow($h) | Out-Null
  Start-Sleep -Milliseconds 500
  $r = New-Object U+RECT
  [U]::GetWindowRect($h, [ref]$r) | Out-Null
  [pscustomobject]@{ Id=$win.Id; Title=$win.MainWindowTitle; Handle=$h
                     L=$r.L; T=$r.T; W=($r.R-$r.L); H=($r.B-$r.T) }
}

function Get-BloombergStatus {
  $wintrv = @(Get-Process -Name wintrv -ErrorAction SilentlyContinue)
  $wins = @(Get-AllWindows)
  $panels = @($wins | Where-Object { $_.Class -like 'BLPFrame*WClass' })
  $loginVisible = [bool](@($wins | Where-Object { $_.Title -eq 'BLOOMBERG: Login' -and $_.Vis -eq 1 }).Count)
  $askb = $null; try { $askb = Get-AskbWindow } catch { $askb = $null }
  [pscustomobject]@{
    bloomberg_running = [bool]$wintrv.Count
    terminal_panels   = $panels.Count
    login_required    = $loginVisible
    askb_open         = [bool]$askb
    panels            = $panels
    askb              = $askb
  }
}

function Hide-Terminals {
  if ($NoMinimizeTerminals) { return }
  Get-Process | Where-Object {
    $_.ProcessName -match 'WindowsTerminal|conhost|OpenConsole|pwsh|powershell' -and $_.MainWindowHandle -ne 0
  } | ForEach-Object { [U]::ShowWindow($_.MainWindowHandle, 6) | Out-Null }   # SW_MINIMIZE
}

function Get-MainBloombergTab {
  # The main Bloomberg terminal tab hosts the command line. It is a bplus64 window
  # whose title is NOT the ASKB standalone ("ASKB (Beta)"); prefer one mentioning
  # "Bloomberg". Returns {Handle, L, T, W, H, Title} or $null.
  $cands = Get-Process -Name bplus64 -ErrorAction SilentlyContinue | Where-Object {
    $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -and $_.MainWindowTitle -ne 'ASKB (Beta)'
  }
  $pick = $cands | Where-Object { $_.MainWindowTitle -like '*loomberg*' } | Select-Object -First 1
  if (-not $pick) { $pick = $cands | Select-Object -First 1 }
  if (-not $pick) { return $null }
  $r = New-Object U+RECT; [U]::GetWindowRect($pick.MainWindowHandle, [ref]$r) | Out-Null
  [pscustomobject]@{ Handle=$pick.MainWindowHandle; L=$r.L; T=$r.T; W=($r.R-$r.L); H=($r.B-$r.T); Title=$pick.MainWindowTitle }
}

function Invoke-EnsureAskb {
  $s = Get-BloombergStatus
  if (-not $s.bloomberg_running) {
    return [pscustomobject]@{ ok=$false; bloomberg=$false; need='open_bloomberg'
      message='Bloomberg Terminal is not running. Please launch and log into the Bloomberg Terminal, then try again.' }
  }
  if ($s.login_required) {
    return [pscustomobject]@{ ok=$false; bloomberg=$true; login_required=$true; need='login'
      message='Bloomberg is open but at the login screen. Please log in to the Terminal, then try again.' }
  }
  if ($s.askb_open) {
    return [pscustomobject]@{ ok=$true; bloomberg=$true; askb='already_open'; window=$s.askb }
  }
  $tab = Get-MainBloombergTab
  if (-not $tab) {
    return [pscustomobject]@{ ok=$false; bloomberg=$true; need='manual'
      message='Bloomberg is running but the main command window was not found. Open a Bloomberg panel (or run ASKB <GO>) manually, then retry.' }
  }
  # Launch ASKB by PHYSICALLY CLICKING the Bloomberg command line, then typing ASKB<GO>.
  # SetForegroundWindow + SendKeys does NOT reliably focus Bloomberg's command-line
  # control (Bloomberg uses a dual wintrv/bplus64 window model); a real mouse click
  # does. ASKB only spawns its separate chat window on a FRESH navigation, so the
  # fallback navigates away (HELP) and back. Command line sits ~90px,93px from the
  # tab's top-left (below the title bar + green function-button row).
  $clickX = $tab.L + 90
  $clickY = $tab.T + 93
  $click = {
    [U]::ShowWindow($tab.Handle, 5) | Out-Null
    [U]::ShowWindow($tab.Handle, 9) | Out-Null
    [U]::SetForegroundWindow($tab.Handle) | Out-Null
    Start-Sleep -Milliseconds 400
    [void][U]::SetCursorPos($clickX, $clickY); Start-Sleep -Milliseconds 250
    [U]::mouse_event(0x02,0,0,0,0); [U]::mouse_event(0x04,0,0,0,0); Start-Sleep -Milliseconds 450
  }
  $cmd  = { param($c)
    [System.Windows.Forms.SendKeys]::SendWait("{ESC}"); Start-Sleep -Milliseconds 250
    [System.Windows.Forms.SendKeys]::SendWait($c);      Start-Sleep -Milliseconds 400
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
  }
  $poll = { param($secs) $dl=(Get-Date).AddSeconds($secs); while((Get-Date) -lt $dl){ Start-Sleep -Milliseconds 1200; try { $w = Get-AskbWindow; if ($w) { return $w } } catch {} }; return $null }

  & $click; & $cmd "ASKB"
  $w = & $poll 10
  if (-not $w) {
    & $click; & $cmd "HELP"; Start-Sleep -Seconds 3     # force a fresh navigation
    & $click; & $cmd "ASKB"
    $w = & $poll $LaunchWaitSeconds
  }
  if ($w) { return [pscustomobject]@{ ok=$true; bloomberg=$true; askb='launched'; window=$w } }
  return [pscustomobject]@{ ok=$false; bloomberg=$true; need='manual'
    message='Tried to launch ASKB by typing ASKB <GO> into the Bloomberg command line, but the chat window did not appear. Please open ASKB manually and retry.' }
}

function Click-Rel($win, $fx, $fy) {
  $x = $win.L + [int]($win.W * $fx)
  $y = $win.T + [int]($win.H * $fy)
  [void][U]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 150
  [U]::mouse_event(0x02,0,0,0,0); [U]::mouse_event(0x04,0,0,0,0)
  Start-Sleep -Milliseconds 300
}

function Scroll-Chat($win, $total) {
  $notch = 120
  $count = [int]([math]::Abs($total) / $notch); if ($count -lt 1) { $count = 1 }
  [void][U]::SetCursorPos(($win.L + [int]($win.W*0.5)), ($win.T + [int]($win.H*0.4)))
  Start-Sleep -Milliseconds 150
  for ($i=0; $i -lt $count; $i++) {
    $d = if ($total -lt 0) { [uint32](4294967296 - $notch) } else { [uint32]$notch }
    [U]::mouse_event(0x0800, 0, 0, $d, 0)
    Start-Sleep -Milliseconds 110
  }
}

function Shot($win, $path) {
  [U]::SetForegroundWindow($win.Handle) | Out-Null
  Start-Sleep -Milliseconds 400
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $bmp = New-Object System.Drawing.Bitmap($win.W, $win.H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($win.L, $win.T, 0, 0, (New-Object System.Drawing.Size($win.W, $win.H)))
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}

Hide-Terminals

switch ($Action) {
  'bbstatus' {
    $s = Get-BloombergStatus
    [pscustomobject]@{
      bloomberg_running = $s.bloomberg_running; terminal_panels = $s.terminal_panels
      login_required = $s.login_required; askb_open = $s.askb_open; window = $s.askb
    } | ConvertTo-Json -Compress -Depth 6
    break
  }

  'ensure' { Invoke-EnsureAskb | ConvertTo-Json -Compress -Depth 6; break }

  'find' {
    try { (Get-AskbWindow) | ConvertTo-Json -Compress -Depth 6 }
    catch { [pscustomobject]@{ error='No ASKB window found.'; need='ensure' } | ConvertTo-Json -Compress }
    break
  }

  'send' {
    if (-not $Prompt) { throw "-Prompt is required for 'send'." }
    $ens = Invoke-EnsureAskb
    if (-not $ens.ok) { $ens | ConvertTo-Json -Compress -Depth 6; break }
    $win = Get-AskbWindow
    if ($NewChat) {
      Click-Rel $win 0.03 0.085         # new chat
      Start-Sleep -Milliseconds 900
      Click-Rel $win 0.5 0.53           # fresh-chat input box is centered
    } else {
      Click-Rel $win $RelX $RelY        # follow-up input bar (default near bottom)
    }
    Set-Clipboard -Value $Prompt
    Start-Sleep -Milliseconds 250
    [System.Windows.Forms.SendKeys]::SendWait("^v")   # paste (typing is unreliable)
    Start-Sleep -Milliseconds 600
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    Write-Output "submitted; waiting $WaitSeconds s ..."
    Start-Sleep -Seconds $WaitSeconds
    Shot $win $Out
    Write-Output "captured -> $Out"; break
  }

  'newchat' {
    $win = Get-AskbWindow
    Click-Rel $win 0.03 0.085
    Start-Sleep -Milliseconds 800
    Shot $win $Out
    Write-Output "new chat opened -> $Out"; break
  }

  'shot'   { Shot (Get-AskbWindow) $Out; Write-Output "captured -> $Out"; break }
  'scroll' { $w = Get-AskbWindow; Scroll-Chat $w $Amount; Start-Sleep -Milliseconds 500; Shot $w $Out; Write-Output "scrolled $Amount -> $Out"; break }
  'click'  { $w = Get-AskbWindow; Click-Rel $w $RelX $RelY; Start-Sleep -Milliseconds 700; Shot $w $Out; Write-Output "clicked ($RelX,$RelY) -> $Out"; break }
}

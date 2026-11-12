@echo off
title VPN-Proof Website Blocker v2.2
setlocal DisableDelayedExpansion

:: ============================================================================
:: 1. AUTO-ELEVATE TO ADMINISTRATOR
:: Automatically requests Administrator privileges on double-click
:: ============================================================================
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: ============================================================================
:: 2. STARTUP CHECK
:: Converts expired locks to UNLOCKED and resumes any 30-min pending unblocks
:: ============================================================================
call :CHECK_EXPIRY
set "STARTUP_STATE=%errorLevel%"

if "%STARTUP_STATE%"=="2" (
    cls
    echo.
    echo  ====================================================================
    echo                 RESUMING PENDING UNBLOCK COUNTDOWN
    echo  ====================================================================
    echo   A 30-minute Deliberate Friction timer is still active.
    call :WAIT_PENDING
    echo.
    pause
)
if "%STARTUP_STATE%"=="3" (
    echo.
    pause
)

:: ============================================================================
:: 3. MAIN MENU (Option 5 / EXODUS is hidden)
:: ============================================================================
:MENU
call :CHECK_EXPIRY
if %errorLevel% equ 2 call :WAIT_PENDING

cls
echo.
echo  ====================================================================
echo                     VPN-PROOF LOCAL WEBSITE BLOCKER
echo  ====================================================================
powershell -NoProfile -Command ^
    "$r = @(Get-NetFirewallRule -Group 'CustomSiteBlocker' -EA SilentlyContinue); " ^
    "$l = @($r | Where-Object { ([string]$_.Description).StartsWith('LOCKED') }).Count; " ^
    "$u = $r.Count - $l; " ^
    "Write-Host ('   Active Blocks: ' + $r.Count + ' total  (') -NoNewline -FG Gray; " ^
    "Write-Host ($l.ToString() + ' LOCKED') -NoNewline -FG Red; " ^
    "Write-Host ', ' -NoNewline -FG Gray; " ^
    "Write-Host ($u.ToString() + ' UNLOCKED') -NoNewline -FG Green; " ^
    "Write-Host ')' -FG Gray"
echo  --------------------------------------------------------------------
echo    [1] Block Website(s)          (Add LOCKED or UNLOCKED domains)
echo    [2] View / Export Blocklist   (Status table ^& comma-separated list)
echo    [3] Unblock Website(s)        (Single, batch, or ALL unlocked)
echo    [4] Exit
echo  ====================================================================
echo.
set "choice="
set /p "choice=  Select an option (1-4): "

if "%choice%"=="1" goto BLOCK
if "%choice%"=="2" goto VIEW
if "%choice%"=="3" goto UNBLOCK
if "%choice%"=="4" exit /b 0
if "%choice%"=="5" goto EXODUS
if /i "%choice%"=="EXODUS" goto EXODUS
goto MENU

:: ============================================================================
:: SUBROUTINE: :BLOCK
:: Prompts for comma-separated domains and optional duration (Nh / Nd).
:: Normalizes, validates, checks duplicates, resolves IPs, and blocks via Firewall.
:: ============================================================================
:BLOCK
cls
call :CHECK_EXPIRY
if %errorLevel% equ 2 call :WAIT_PENDING

echo.
echo  ====================================================================
echo                            BLOCK WEBSITE(S)
echo  ====================================================================
echo   Enter one or more domains separated by commas.
echo   Example: youtube.com, reddit.com, x.com
echo  --------------------------------------------------------------------
set "INPUT_DOMAINS="
set /p "INPUT_DOMAINS=  Domains (or Enter to cancel): "
if not defined INPUT_DOMAINS goto MENU

echo.
echo   Optional Lock Duration:
echo    * Type Nh (hours) or Nd (days), e.g., 6h or 1d  --^> LOCKED
echo    * Press Enter (leave blank)                     --^> UNLOCKED
echo  --------------------------------------------------------------------
set "INPUT_DURATION="
set /p "INPUT_DURATION=  Duration (Nh / Nd, or Enter): "
echo.

powershell -NoProfile -Command ^
    "$rawDom = [string]$env:INPUT_DOMAINS; " ^
    "$rawDur = ([string]$env:INPUT_DURATION).Trim().ToLower(); " ^
    "$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); " ^
    "$type = 'UNLOCKED'; $exp = 0; $n = 0; " ^
    "if ($rawDur.Length -gt 0) { " ^
    "  $unit = $rawDur.Substring($rawDur.Length - 1); " ^
    "  $numStr = $rawDur.Substring(0, $rawDur.Length - 1); " ^
    "  if (($unit -eq 'h' -or $unit -eq 'd') -and [long]::TryParse($numStr, [ref]$n) -and $n -gt 0) { " ^
    "    $mult = if ($unit -eq 'h') { 3600 } else { 86400 }; " ^
    "    $exp = $now + ($n * $mult); " ^
    "    $type = 'LOCKED'; " ^
    "  } else { " ^
    "    Write-Host '  [ERROR] Invalid duration. Use Nh (e.g., 6h), Nd (e.g., 1d), or leave blank.' -FG Red; " ^
    "    exit 1 " ^
    "  } " ^
    "}; " ^
    "$existing = @{}; " ^
    "Get-NetFirewallRule -Group 'CustomSiteBlocker' -EA SilentlyContinue | ForEach-Object { " ^
    "  $dn = $_.DisplayName.ToLower(); " ^
    "  if ($dn.StartsWith('siteblock-')) { $dn = $dn.Substring(10) }; " ^
    "  $existing[$dn] = $true " ^
    "}; " ^
    "$seen = @{}; $added = 0; " ^
    "foreach ($item in $rawDom.Split(',')) { " ^
    "  if ([string]::IsNullOrWhiteSpace($item)) { continue }; " ^
    "  $d = $item.Trim().ToLower(); " ^
    "  if ($d.StartsWith('https://')) { $d = $d.Substring(8) }; " ^
    "  if ($d.StartsWith('http://'))  { $d = $d.Substring(7) }; " ^
    "  if ($d.StartsWith('www.'))     { $d = $d.Substring(4) }; " ^
    "  $d = ($d.Split('/')[0]).Trim(); " ^
    "  if ([string]::IsNullOrWhiteSpace($d) -or [Uri]::CheckHostName($d) -ne 'Dns' -or (-not $d.Contains('.')) -or $d.StartsWith('.') -or $d.EndsWith('.')) { " ^
    "    Write-Host ('  [REJECTED]  Invalid domain format: ' + $item.Trim()) -FG Red; continue " ^
    "  }; " ^
    "  if ($existing.ContainsKey($d) -or $seen.ContainsKey($d)) { " ^
    "    Write-Host ('  [SKIPPED]   Already in blocklist:  ' + $d) -FG Yellow; continue " ^
    "  }; " ^
    "  $seen[$d] = $true; " ^
    "  Write-Host ('  [...]       Resolving IPs for ' + $d + '...') -FG DarkGray; " ^
    "  $ips = @((Resolve-DnsName $d -EA SilentlyContinue).IPAddress) + @((Resolve-DnsName ('www.' + $d) -EA SilentlyContinue).IPAddress); " ^
    "  $ips = @($ips | Where-Object { $_ } | Select-Object -Unique); " ^
    "  if ($ips.Count -eq 0) { " ^
    "    Write-Host ('  [FAILED]    Could not resolve IPs: ' + $d) -FG Red; continue " ^
    "  }; " ^
    "  try { " ^
    "    $desc = $type + ':' + $exp + ':0'; " ^
    "    New-NetFirewallRule -Name ('SiteBlock-' + $d) -DisplayName ('SiteBlock-' + $d) -Group 'CustomSiteBlocker' -Direction Outbound -Action Block -RemoteAddress $ips -Description $desc -EA Stop | Out-Null; " ^
    "    $tag = if ($type -eq 'LOCKED') { 'LOCKED (' + $rawDur + ')' } else { 'UNLOCKED (Indefinite)' }; " ^
    "    Write-Host ('  [BLOCKED]   ' + $d.PadRight(26) + ' [' + $tag + ' - ' + $ips.Count + ' IPs]') -FG Green; " ^
    "    $added++ " ^
    "  } catch { " ^
    "    Write-Host ('  [ERROR]     Firewall write failed for ' + $d + ': ' + $_.Exception.Message) -FG Red " ^
    "  } " ^
    "}; " ^
    "if ($added -gt 0) { ipconfig /flushdns | Out-Null; Write-Host ' '; Write-Host '  [OK] Firewall rules active and DNS cache flushed.' -FG Cyan }"

echo.
pause
goto MENU

:: ============================================================================
:: SUBROUTINE: :VIEW
:: Displays the blocklist table and outputs a comma-separated export string
:: with an option to copy it directly to the Windows Clipboard.
:: ============================================================================
:VIEW
cls
call :CHECK_EXPIRY
if %errorLevel% equ 2 call :WAIT_PENDING

echo.
echo  ====================================================================
echo                        CURRENTLY BLOCKED DOMAINS
echo  ====================================================================
powershell -NoProfile -Command ^
    "$rules = @(Get-NetFirewallRule -Group 'CustomSiteBlocker' -EA SilentlyContinue | Sort-Object DisplayName); " ^
    "if ($rules.Count -eq 0) { " ^
    "  Write-Host ' '; Write-Host '   No websites are currently blocked.' -FG Yellow; exit 99 " ^
    "}; " ^
    "$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); " ^
    "$csvList = @(); " ^
    "Write-Host ('   ' + 'DOMAIN'.PadRight(30) + 'STATUS'.PadRight(14) + 'REMAINING TIME') -FG Cyan; " ^
    "Write-Host '  --------------------------------------------------------------------'; " ^
    "foreach ($r in $rules) { " ^
    "  $dom = $r.DisplayName.ToLower(); " ^
    "  if ($dom.StartsWith('siteblock-')) { $dom = $dom.Substring(10) }; " ^
    "  $csvList += $dom; " ^
    "  $p = ([string]$r.Description).Split(':'); " ^
    "  $st = if ($p[0] -eq 'LOCKED') { 'LOCKED' } else { 'UNLOCKED' }; " ^
    "  $exp = 0; if ($p.Count -ge 2) { [void][long]::TryParse($p[1], [ref]$exp) }; " ^
    "  $pend = 0; if ($p.Count -ge 3) { [void][long]::TryParse($p[2], [ref]$pend) }; " ^
    "  if ($pend -gt $now) { " ^
    "    $ts = [TimeSpan]::FromSeconds($pend - $now); " ^
    "    $rem = 'Unblocking in ' + ([int]$ts.TotalMinutes).ToString('00') + 'm ' + $ts.Seconds.ToString('00') + 's'; " ^
    "    Write-Host ('   ' + $dom.PadRight(30) + 'LOCKED'.PadRight(14) + $rem) -FG Magenta " ^
    "  } elseif ($st -eq 'LOCKED' -and $exp -gt $now) { " ^
    "    $ts = [TimeSpan]::FromSeconds($exp - $now); " ^
    "    $rem = if ($ts.Days -gt 0) { $ts.Days.ToString() + 'd ' + $ts.Hours.ToString('00') + 'h ' + $ts.Minutes.ToString('00') + 'm' } " ^
    "           else { $ts.Hours.ToString('00') + 'h ' + $ts.Minutes.ToString('00') + 'm ' + $ts.Seconds.ToString('00') + 's' }; " ^
    "    Write-Host ('   ' + $dom.PadRight(30) + 'LOCKED'.PadRight(14) + $rem) -FG Red " ^
    "  } else { " ^
    "    Write-Host ('   ' + $dom.PadRight(30) + 'UNLOCKED'.PadRight(14) + 'Indefinite') -FG Green " ^
    "  } " ^
    "}; " ^
    "Write-Host '  ===================================================================='; " ^
    "Write-Host '   COMMA-SEPARATED EXPORT:' -FG Cyan; " ^
    "Write-Host ('   ' + ($csvList -join ', ')) -FG White"

if %errorLevel% equ 99 (
    echo  ====================================================================
    echo.
    pause
    goto MENU
)

echo  ====================================================================
echo   [C] Copy comma-separated list to Clipboard   [Enter] Return to Menu
echo.
set "viewChoice="
set /p "viewChoice=  Select option: "
if /i "%viewChoice%"=="C" (
    powershell -NoProfile -Command ^
        "$rules = @(Get-NetFirewallRule -Group 'CustomSiteBlocker' -EA SilentlyContinue | Sort-Object DisplayName); " ^
        "$csv = @(); " ^
        "foreach ($r in $rules) { " ^
        "  $d = $r.DisplayName.ToLower(); " ^
        "  if ($d.StartsWith('siteblock-')) { $d = $d.Substring(10) }; " ^
        "  $csv += $d " ^
        "}; " ^
        "Set-Clipboard -Value ($csv -join ', '); " ^
        "Write-Host ' '; Write-Host '  [OK] Comma-separated blocklist copied to Windows Clipboard.' -FG Green"
    echo.
    pause
)
goto MENU

:: ============================================================================
:: SUBROUTINE: :UNBLOCK
:: Supports:
::  - Typing ALL or UNBLOCK ALL to immediately remove all UNLOCKED domains.
::  - Entering comma-separated domains (instant UNLOCKED / Friction for LOCKED).
:: ============================================================================
:UNBLOCK
cls
call :CHECK_EXPIRY
if %errorLevel% equ 2 call :WAIT_PENDING

echo.
echo  ====================================================================
echo                           UNBLOCK WEBSITE(S)
echo  ====================================================================
powershell -NoProfile -Command ^
    "$rules = @(Get-NetFirewallRule -Group 'CustomSiteBlocker' -EA SilentlyContinue | Sort-Object DisplayName); " ^
    "if ($rules.Count -eq 0) { Write-Host '   No websites are currently blocked.' -FG Yellow; exit 99 }; " ^
    "foreach ($r in $rules) { " ^
    "  $d = $r.DisplayName.ToLower(); " ^
    "  if ($d.StartsWith('siteblock-')) { $d = $d.Substring(10) }; " ^
    "  $isLocked = ([string]$r.Description).StartsWith('LOCKED'); " ^
    "  $tag = if ($isLocked) { '[LOCKED - 30m Friction]' } else { '[UNLOCKED - Instant]' }; " ^
    "  $col = if ($isLocked) { 'Red' } else { 'Green' }; " ^
    "  Write-Host ('   * ' + $d.PadRight(28) + ' ' + $tag) -FG $col " ^
    "}"
if %errorLevel% equ 99 (
    echo.
    pause
    goto MENU
)
echo  --------------------------------------------------------------------
echo   * Enter comma-separated domains (e.g., reddit.com, x.com)
echo   * Or type ALL to immediately unblock all UNLOCKED domains
echo  --------------------------------------------------------------------
set "UNBLOCK_INPUT="
set /p "UNBLOCK_INPUT=  Domains or ALL (or Enter to cancel): "
if not defined UNBLOCK_INPUT goto MENU
echo.

powershell -NoProfile -Command ^
    "$raw = ([string]$env:UNBLOCK_INPUT).Trim(); " ^
    "$rules = @{}; " ^
    "Get-NetFirewallRule -Group 'CustomSiteBlocker' -EA SilentlyContinue | ForEach-Object { " ^
    "  $dn = $_.DisplayName.ToLower(); " ^
    "  if ($dn.StartsWith('siteblock-')) { $dn = $dn.Substring(10) }; " ^
    "  $rules[$dn] = $_ " ^
    "}; " ^
    "if ($raw.ToLower() -eq 'all' -or $raw.ToLower() -eq 'unblock all') { " ^
    "  $removed = 0; $skippedLocked = 0; " ^
    "  foreach ($d in ($rules.Keys | Sort-Object)) { " ^
    "    $r = $rules[$d]; " ^
    "    if (([string]$r.Description).StartsWith('LOCKED')) { " ^
    "      $skippedLocked++ " ^
    "    } else { " ^
    "      Remove-NetFirewallRule -InputObject $r -EA Stop; " ^
    "      Write-Host ('  [UNBLOCKED] ' + $d + ' removed immediately.') -FG Green; " ^
    "      $removed++ " ^
    "    } " ^
    "  }; " ^
    "  if ($removed -gt 0) { " ^
    "    ipconfig /flushdns | Out-Null; " ^
    "    Write-Host ' '; Write-Host ('  [OK] Unblocked ' + $removed + ' UNLOCKED domain(s) and flushed DNS.') -FG Cyan " ^
    "  } else { " ^
    "    Write-Host '  [INFO] No UNLOCKED domains were found to unblock.' -FG Yellow " ^
    "  }; " ^
    "  if ($skippedLocked -gt 0) { " ^
    "    Write-Host ('  [INFO] ' + $skippedLocked + ' LOCKED domain(s) remained blocked.') -FG Magenta " ^
    "  }; " ^
    "  exit 0 " ^
    "}; " ^
    "$seen = @{}; $removed = 0; $lockedCount = 0; " ^
    "foreach ($item in $raw.Split(',')) { " ^
    "  if ([string]::IsNullOrWhiteSpace($item)) { continue }; " ^
    "  $d = $item.Trim().ToLower(); " ^
    "  if ($d.StartsWith('https://')) { $d = $d.Substring(8) }; " ^
    "  if ($d.StartsWith('http://'))  { $d = $d.Substring(7) }; " ^
    "  if ($d.StartsWith('www.'))     { $d = $d.Substring(4) }; " ^
    "  $d = ($d.Split('/')[0]).Trim(); " ^
    "  if ($seen.ContainsKey($d)) { continue }; $seen[$d] = $true; " ^
    "  if (-not $rules.ContainsKey($d)) { " ^
    "    Write-Host ('  [REJECTED]  Not in blocklist: ' + $d) -FG Red; continue " ^
    "  }; " ^
    "  $r = $rules[$d]; " ^
    "  if (([string]$r.Description).StartsWith('LOCKED')) { " ^
    "    Write-Host ('  [LOCKED]    ' + $d + ' requires Deliberate Friction.') -FG Yellow; " ^
    "    $lockedCount++ " ^
    "  } else { " ^
    "    Remove-NetFirewallRule -InputObject $r -EA Stop; " ^
    "    Write-Host ('  [UNBLOCKED] ' + $d + ' removed immediately.') -FG Green; " ^
    "    $removed++ " ^
    "  } " ^
    "}; " ^
    "if ($removed -gt 0) { ipconfig /flushdns | Out-Null; Write-Host '  [OK] DNS cache flushed.' -FG Cyan }; " ^
    "if ($lockedCount -gt 0) { exit 10 } else { exit 0 }"

if %errorLevel% equ 10 call :FRICTION

echo.
pause
goto MENU

:: ============================================================================
:: SUBROUTINE: :EXODUS (HIDDEN OPTION 5)
:: Master reset button: wipes all blocked sites (LOCKED & UNLOCKED), cancels
:: any active cooldowns, restores default hosts if backup exists, flushes DNS.
:: ============================================================================
:EXODUS
cls
echo.
echo  ====================================================================
echo               EXODUS PROTOCOL - MASTER FACTORY RESET
echo  ====================================================================
echo   WARNING: This will immediately wipe out the ENTIRE blocklist
echo   (both LOCKED and UNLOCKED domains), clear all active timers, and
echo   restore all modified network/firewall settings to Windows default.
echo  --------------------------------------------------------------------
set "exoConfirm="
set /p "exoConfirm=  Type EXODUS to confirm full reset (or Enter to cancel): "
if /i not "%exoConfirm%"=="EXODUS" (
    echo.
    echo   [CANCELLED] EXODUS aborted. No settings were changed.
    echo.
    pause
    goto MENU
)

echo.
powershell -NoProfile -Command ^
    "$rules = @(Get-NetFirewallRule -Group 'CustomSiteBlocker' -EA SilentlyContinue); " ^
    "if ($rules.Count -gt 0) { " ^
    "  Remove-NetFirewallRule -Group 'CustomSiteBlocker' -EA SilentlyContinue; " ^
    "  Write-Host ('  [EXODUS] Removed all ' + $rules.Count + ' firewall block rule(s) (LOCKED and UNLOCKED).') -FG Green " ^
    "} else { " ^
    "  Write-Host '  [EXODUS] Firewall blocklist is already clean.' -FG Yellow " ^
    "}; " ^
    "$hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'; " ^
    "$hostsBak  = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts.blocker.bak'; " ^
    "if (Test-Path -LiteralPath $hostsBak) { " ^
    "  Copy-Item -LiteralPath $hostsBak -Destination $hostsFile -Force -EA SilentlyContinue; " ^
    "  Remove-Item -LiteralPath $hostsBak -Force -EA SilentlyContinue; " ^
    "  Write-Host '  [EXODUS] Restored Windows hosts file from backup to default.' -FG Green " ^
    "}; " ^
    "ipconfig /flushdns | Out-Null; " ^
    "Write-Host '  [EXODUS] Flushed Windows DNS cache. All settings restored to Windows default.' -FG Cyan"

echo.
pause
goto MENU

:: ============================================================================
:: SUBROUTINE: :FRICTION
:: Requires 3 exact 'YES' confirmations, then saves a 30-min pending timestamp
:: inside the firewall rule description and starts the countdown.
:: ============================================================================
:FRICTION
echo.
echo  ====================================================================
echo                   DELIBERATE FRICTION (LOCKED SITES)
echo  ====================================================================
echo   You must confirm 3 separate times by typing YES (in ALL CAPS).
echo   Any other input cancels and resets. After confirmation, a mandatory
echo   30-minute cooldown timer will begin and cannot be cancelled.
echo  --------------------------------------------------------------------

set "confirm="
set /p "confirm=  Confirm 1 of 3: type YES to proceed: "
if not "%confirm%"=="YES" goto FRICTION_CANCEL

set "confirm="
set /p "confirm=  Confirm 2 of 3: type YES to proceed: "
if not "%confirm%"=="YES" goto FRICTION_CANCEL

set "confirm="
set /p "confirm=  Confirm 3 of 3: type YES to proceed: "
if not "%confirm%"=="YES" goto FRICTION_CANCEL

echo.
powershell -NoProfile -Command ^
    "$pendUntil = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1800; " ^
    "$rules = @{}; " ^
    "Get-NetFirewallRule -Group 'CustomSiteBlocker' -EA SilentlyContinue | ForEach-Object { " ^
    "  $dn = $_.DisplayName.ToLower(); " ^
    "  if ($dn.StartsWith('siteblock-')) { $dn = $dn.Substring(10) }; " ^
    "  $rules[$dn] = $_ " ^
    "}; " ^
    "foreach ($item in ([string]$env:UNBLOCK_INPUT).Split(',')) { " ^
    "  $d = $item.Trim().ToLower(); " ^
    "  if ($d.StartsWith('https://')) { $d = $d.Substring(8) }; " ^
    "  if ($d.StartsWith('http://'))  { $d = $d.Substring(7) }; " ^
    "  if ($d.StartsWith('www.'))     { $d = $d.Substring(4) }; " ^
    "  $d = ($d.Split('/')[0]).Trim(); " ^
    "  if ($rules.ContainsKey($d) -and ([string]$rules[$d].Description).StartsWith('LOCKED')) { " ^
    "    $p = ([string]$rules[$d].Description).Split(':'); " ^
    "    $exp = if ($p.Count -ge 2) { $p[1] } else { '0' }; " ^
    "    $desc = 'LOCKED:' + $exp + ':' + $pendUntil; " ^
    "    Set-NetFirewallRule -InputObject $rules[$d] -Description $desc -EA Stop " ^
    "  } " ^
    "}; " ^
    "Write-Host '  [OK] 3/3 confirmations accepted. 30-minute timer locked in.' -FG Yellow"

call :WAIT_PENDING
exit /b 0

:FRICTION_CANCEL
echo.
echo   [CANCELLED] Input did not match YES. Process reset; sites remain LOCKED.
exit /b 0

:: ============================================================================
:: SUBROUTINE: :WAIT_PENDING
:: Non-cancellable 30-minute live countdown loop.
:: ============================================================================
:WAIT_PENDING
echo.
echo  --------------------------------------------------------------------
echo   30-MINUTE COOLDOWN ACTIVE (Closing this window will NOT bypass it)
echo  --------------------------------------------------------------------
:WAIT_LOOP
powershell -NoProfile -Command ^
    "while ($true) { " ^
    "  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); " ^
    "  $rules = @(Get-NetFirewallRule -Group 'CustomSiteBlocker' -EA SilentlyContinue); " ^
    "  $minRem = $null; $ready = $false; $sites = @(); " ^
    "  foreach ($r in $rules) { " ^
    "    $p = ([string]$r.Description).Split(':'); " ^
    "    if ($p.Count -ge 3) { " ^
    "      $pend = 0; [void][long]::TryParse($p[2], [ref]$pend); " ^
    "      if ($pend -gt 0) { " ^
    "        $rem = $pend - $now; " ^
    "        if ($rem -le 0) { $ready = $true; break }; " ^
    "        $dn = $r.DisplayName.ToLower(); " ^
    "        if ($dn.StartsWith('siteblock-')) { $dn = $dn.Substring(10) }; " ^
    "        $sites += $dn; " ^
    "        if ($null -eq $minRem -or $rem -lt $minRem) { $minRem = $rem } " ^
    "      } " ^
    "    } " ^
    "  }; " ^
    "  if ($ready -or $null -eq $minRem) { break }; " ^
    "  $ts = [TimeSpan]::FromSeconds($minRem); " ^
    "  $pct = [math]::Max(0, [math]::Min(20, [int]((1800 - $minRem) / 90))); " ^
    "  $bar = ('#' * $pct).PadRight(20, '-'); " ^
    "  $tStr = ([int]$ts.TotalMinutes).ToString('00') + 'm ' + $ts.Seconds.ToString('00') + 's'; " ^
    "  $msg = '  [' + $bar + '] ' + $tStr + ' left - ' + ($sites -join ', ') + '   '; " ^
    "  Write-Host -NoNewline ([char]13 + $msg) -FG Yellow; " ^
    "  Start-Sleep -Seconds 1 " ^
    "}; " ^
    "Write-Host ' '"

call :CHECK_EXPIRY
if %errorLevel% equ 2 goto WAIT_LOOP
exit /b 0

:: ============================================================================
:: SUBROUTINE: :CHECK_EXPIRY
:: 1. Silently converts expired LOCKED firewall rules to UNLOCKED.
:: 2. Removes rules whose 30-min pending-unblock timer has finished.
:: 3. Exit codes: 0 = Normal, 2 = Pending timer still active, 3 = Unblocked.
:: ============================================================================
:CHECK_EXPIRY
powershell -NoProfile -Command ^
    "$rules = @(Get-NetFirewallRule -Group 'CustomSiteBlocker' -EA SilentlyContinue); " ^
    "if ($rules.Count -eq 0) { exit 0 }; " ^
    "$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); " ^
    "$unblocked = @(); $activePending = $false; " ^
    "foreach ($r in $rules) { " ^
    "  $dom = $r.DisplayName.ToLower(); " ^
    "  if ($dom.StartsWith('siteblock-')) { $dom = $dom.Substring(10) }; " ^
    "  $p = ([string]$r.Description).Split(':'); " ^
    "  $st = if ($p[0] -eq 'LOCKED') { 'LOCKED' } else { 'UNLOCKED' }; " ^
    "  $exp = 0; if ($p.Count -ge 2) { [void][long]::TryParse($p[1], [ref]$exp) }; " ^
    "  $pend = 0; if ($p.Count -ge 3) { [void][long]::TryParse($p[2], [ref]$pend) }; " ^
    "  if ($pend -gt 0) { " ^
    "    if ($now -ge $pend) { " ^
    "      Remove-NetFirewallRule -InputObject $r -EA SilentlyContinue; " ^
    "      $unblocked += $dom " ^
    "    } else { $activePending = $true } " ^
    "  } elseif ($st -eq 'LOCKED' -and $exp -gt 0 -and $now -ge $exp) { " ^
    "    Set-NetFirewallRule -InputObject $r -Description 'UNLOCKED:0:0' -EA SilentlyContinue " ^
    "  } elseif ([string]::IsNullOrWhiteSpace($r.Description)) { " ^
    "    Set-NetFirewallRule -InputObject $r -Description 'UNLOCKED:0:0' -EA SilentlyContinue " ^
    "  } " ^
    "}; " ^
    "if ($unblocked.Count -gt 0) { " ^
    "  ipconfig /flushdns | Out-Null; " ^
    "  Write-Host ' '; " ^
    "  Write-Host ('  [OK] 30-minute cooldown complete. Unblocked: ' + ($unblocked -join ', ')) -FG Green; " ^
    "  Write-Host '  [OK] Firewall rules removed and DNS cache flushed.' -FG Cyan; " ^
    "  if (-not $activePending) { exit 3 } " ^
    "}; " ^
    "if ($activePending) { exit 2 }; exit 0"
exit /b %errorLevel%
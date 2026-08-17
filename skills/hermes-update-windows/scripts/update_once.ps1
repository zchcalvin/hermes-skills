# One-shot Hermes upgrade (Windows, proxy-aware)
# Kills desktop app + serve -> `hermes update --yes` -> restarts app -> logs checks.
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File update_once.ps1
#     [-AgentDir D:\path\to\hermes-agent]   # auto-detected from hermes CLI if omitted
#     [-ProxyUrl http://127.0.0.1:21882]    # local proxy; empty = use git global proxy
#     [-WithGateway]                        # also stop/start `hermes gateway`
#     [-DryRun]                             # print plan, make no changes
param(
    [string]$AgentDir = '',
    [string]$ProxyUrl = '',
    [switch]$WithGateway,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

# --- locate hermes CLI + install dir ---
if (-not $AgentDir) {
    $cli = Get-Command hermes -ErrorAction SilentlyContinue
    if ($cli) {
        # hermes.exe lives in <root>/venv/Scripts/hermes.exe -> walk up 3 levels
        $AgentDir = Split-Path (Split-Path (Split-Path $cli.Source -Parent) -Parent) -Parent
    } else {
        Write-Error "hermes CLI not found on PATH. Pass -AgentDir explicitly."
        exit 1
    }
}
$HERMES_CLI = Join-Path $AgentDir 'venv\Scripts\hermes.exe'
$VENV_PY   = Join-Path $AgentDir 'venv\Scripts\python.exe'
if (-not (Test-Path $HERMES_CLI)) {
    Write-Error "hermes CLI not found at $HERMES_CLI - check -AgentDir."
    exit 1
}

# --- optional desktop app (Electron) ---
$HERMES_EXE = Join-Path $AgentDir 'apps\desktop\release\win-unpacked\Hermes.exe'
$hasApp = Test-Path $HERMES_EXE

$LOG = Join-Path $env:TEMP 'hermes_update_once.log'
function Log($m) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"
    Write-Host $line
    Add-Content -Path $LOG -Value $line -Encoding utf8
}

Log "===== one-shot update start (AgentDir=$AgentDir, app=$hasApp, gateway=$WithGateway) ====="
if ($DryRun) {
    Log "[dryrun] plan: kill app+serve -> update -> restart. exiting without changes."
    exit 0
}

# --- 1. proxy resolution (VPN-agnostic, priority chain) ---
#    -ProxyUrl param > existing HTTPS_PROXY/HTTP_PROXY env > git global proxy > direct
$resolvedProxy = ''
if ($ProxyUrl) {
    $uri = $null
    try { $uri = [uri]$ProxyUrl } catch { $uri = $null }
    if ($uri -and $uri.IsAbsoluteUri -and $uri.Scheme -match '^https?$|^socks') {
        $resolvedProxy = $ProxyUrl
        Log "proxy from -ProxyUrl: $ProxyUrl"
    } else {
        Log "WARN: invalid -ProxyUrl '$ProxyUrl' ignored - falling through to env/git/direct"
    }
} elseif ($env:HTTPS_PROXY -or $env:HTTP_PROXY) {
    $resolvedProxy = if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } else { $env:HTTP_PROXY }
    Log "proxy from environment: $resolvedProxy"
} else {
    # git proxies can be global (http.proxy) or URL-scoped (http.https://github.com.proxy) - check both
    $gitProxy = git config --global http.proxy 2>$null
    if (-not $gitProxy) { $gitProxy = git config --global 'http.https://github.com.proxy' 2>$null }
    if (-not $gitProxy) {
        $gitProxy = git config --global --get-regexp '^http\..*\.proxy' 2>$null |
            Select-Object -First 1 | ForEach-Object { ($_ -split ' ')[1] }
    }
    if ($gitProxy) {
        $resolvedProxy = $gitProxy
        Log "proxy from git global: $gitProxy"
    } else {
        Log "no proxy configured - assuming direct GitHub access (works if no GFW-type restriction)"
    }
}
if ($resolvedProxy) {
    $env:HTTPS_PROXY = $resolvedProxy
    $env:HTTP_PROXY = $resolvedProxy
    if ($resolvedProxy -match '^socks') {
        Log "NOTE: socks5 proxy detected - git will use it for the pull, but pip may need pysocks or an http bridge (e.g. privoxy). If dependency install fails, set a local http proxy and pass -ProxyUrl http://127.0.0.1:PORT"
    }
}

# --- 1.5 disk space sanity (big upgrades + pip deps need room; a full disk
#        interrupts the upgrade mid-way and can corrupt the venv) ---
$drive = Get-PSDrive -PSProvider FileSystem | Where-Object { $AgentDir -like "$($_.Root)*" } | Select-Object -First 1
if ($drive) {
    $freeGB = [math]::Round($drive.Free / 1GB, 1)
    Log "disk free on $($drive.Root): ${freeGB} GB"
    if ($freeGB -lt 1) { Log "WARN: less than 1GB free - upgrade may fail mid-way. Free space first." }
}

# --- 2. kill desktop app + serve (they lock venv .pyd files during update) ---
if ($hasApp) {
    Get-Process Hermes -ErrorAction SilentlyContinue | Stop-Process -Force
    # belt & braces: also kill by exact binary path (covers renamed/dev builds)
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $HERMES_EXE } | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    Log "desktop app processes killed"
    Start-Sleep 5
}
# Match any python process that is hermes-related and runs serve (entry point
# may change across versions - don't hard-code 'hermes_cli.main serve')
Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
    Where-Object { $_.CommandLine -match 'hermes' -and $_.CommandLine -match 'serve' } | ForEach-Object {
        Log "killing serve pid $($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
Start-Sleep 2
if ($WithGateway) {
    Log 'stopping gateway...'
    & $HERMES_CLI gateway stop 2>&1 | Out-String | ForEach-Object { Log "gateway stop: $_" }
    Start-Sleep 3
}

# --- 3. run update ---
Log 'running hermes update --yes (may take several minutes)...'
Push-Location $AgentDir
$up = & $HERMES_CLI update --yes 2>&1 | Out-String
$updateExit = $LASTEXITCODE
Pop-Location
$upTail = (($up.Trim() -split "`n") | Select-Object -Last 12) -join ' | '
Log "update result (exit=$updateExit): $upTail"

# determine success: exit 0 AND no real error markers in output.
# Lookbehind excludes benign "no errors" / "0 errors" text from false FAILs.
# `errors?` covers singular AND plural forms ("Errors occurred" must FAIL).
$updateOk = ($updateExit -eq 0) -and ($up -notmatch '(?i)fatal|traceback|exception|Other Hermes processes are running|(?<!no |0 )\berrors?\b')

# --- 4. post-update checks (reported to user / log) ---
$ver = & $HERMES_CLI --version 2>&1 | Out-String
Log "version after: $(($ver.Trim() -replace "`r`n", ' | '))"
$doc = & $HERMES_CLI doctor 2>&1 | Out-String
$docLine = (($doc.Trim() -split "`n") | Where-Object { $_ -match 'unknown|issue|broken|provider|error' } | Select-Object -First 6) -join ' | '
Log "doctor scan: $docLine"
if (Test-Path $VENV_PY) {
    $pip = & $VENV_PY -m pip check 2>&1 | Out-String
    Log "pip check: $(($pip.Trim() -replace "`r`n", ' | '))"
}

# --- 5. restart desktop app + gateway ---
if ($hasApp) {
    if (Test-Path $HERMES_EXE) {
        Start-Process $HERMES_EXE
        Log "desktop app restarted"
    } else {
        Log 'WARN: desktop app binary missing - open it manually'
    }
}
if ($WithGateway) {
    Log 'restarting gateway...'
    & $HERMES_CLI gateway start 2>&1 | Out-String | ForEach-Object { Log "gateway start: $_" }
    Start-Sleep 5
}
Log "===== done. full log: $LOG ====="

# --- 6. outcome notification: result file (for agents) + desktop popup (for humans) ---
$RESULT_FILE = Join-Path $env:TEMP 'hermes_update_once_result.txt'
$newVer = if ($ver) { (($ver.Trim() -split "`n") | Select-Object -First 1) } else { 'unknown' }
$summary = if ($updateOk) { "SUCCESS - $newVer" } else { "FAIL - $newVer" }
"$summary`nupdate output tail: $upTail`nlog: $LOG" | Out-File $RESULT_FILE -Encoding utf8
Log "outcome: $summary"

try {
    Add-Type -AssemblyName System.Windows.Forms
    if ($updateOk) {
        [System.Windows.Forms.MessageBox]::Show("Hermes update succeeded.`n$newVer`n`nLog: $LOG", 'Hermes Update',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } else {
        [System.Windows.Forms.MessageBox]::Show("Hermes update FAILED.`n$upTail`n`nFull log: $LOG`nAsk your Hermes agent to check the log.", 'Hermes Update',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
} catch {
    Log "popup skipped: $($_.Exception.Message)"
}
Log "outcome file: $RESULT_FILE"

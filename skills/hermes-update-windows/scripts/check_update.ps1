# Check Hermes for updates (Windows, proxy-aware)
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File check_update.ps1 [-ProxyUrl http://127.0.0.1:21882]
param(
    [string]$ProxyUrl = ''
)
$ErrorActionPreference = 'Continue'

function Get-HermesCli {
    $c = Get-Command hermes -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    # fallback: common install locations
    $candidates = @(
        "$env:USERPROFILE\hermes\config\hermes-agent\venv\Scripts\hermes.exe",
        "$env:USERPROFILE\.hermes\venv\Scripts\hermes.exe"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return $null
}

$cli = Get-HermesCli
if (-not $cli) {
    Write-Host "FAIL: hermes CLI not found. Install Hermes first or pass the path." -ForegroundColor Red
    exit 1
}
Write-Host "hermes CLI: $cli"

# 1. Proxy resolution (VPN-agnostic, priority chain)
#    -ProxyUrl param > existing HTTPS_PROXY/HTTP_PROXY env > git global proxy > direct
$resolvedProxy = ''
if ($ProxyUrl) {
    $uri = $null
    try { $uri = [uri]$ProxyUrl } catch { $uri = $null }
    if ($uri -and $uri.IsAbsoluteUri -and $uri.Scheme -match '^https?$|^socks') {
        $resolvedProxy = $ProxyUrl
        Write-Host "proxy from -ProxyUrl: $ProxyUrl"
    } else {
        Write-Host "WARN: invalid -ProxyUrl '$ProxyUrl' ignored - falling through to env/git/direct" -ForegroundColor Yellow
    }
} elseif ($env:HTTPS_PROXY -or $env:HTTP_PROXY) {
    $resolvedProxy = if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } else { $env:HTTP_PROXY }
    Write-Host "proxy from environment: $resolvedProxy"
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
        Write-Host "proxy from git global: $gitProxy"
    }
}
if ($resolvedProxy) {
    $env:HTTPS_PROXY = $resolvedProxy
    $env:HTTP_PROXY = $resolvedProxy
    if ($resolvedProxy -match '^socks') {
        Write-Host "NOTE: socks5 proxy - git supports it; pip may need pysocks or an http bridge. If install fails, use -ProxyUrl http://..." -ForegroundColor Yellow
    }
    $port = ([uri]$resolvedProxy).Port
    $listening = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($listening) {
        Write-Host "OK: proxy listening on port $port" -ForegroundColor Green
    } else {
        Write-Host "WARN: proxy port $port NOT listening (VPN/proxy off?)" -ForegroundColor Yellow
    }
} else {
    Write-Host "No proxy configured - will try direct GitHub access." -ForegroundColor Cyan
}

# 2. GitHub reachability (git is the real test; curl direct is a cross-check)
#    Use a public repo - does not depend on the user's own origin remote existing.
Write-Host "Testing GitHub reachability..."
$gitDir = Split-Path (Split-Path (Split-Path $cli -Parent) -Parent) -Parent
git ls-remote https://github.com/git/git.git HEAD 2>$null | Select-Object -First 1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "OK: GitHub reachable" -ForegroundColor Green
} else {
    $directCode = curl.exe -s -o NUL -w "%{http_code}" --noproxy "*" --connect-timeout 8 https://github.com 2>$null
    if ($directCode -match '^[23]') {
        Write-Host "FAIL via git, but direct HTTPS works (HTTP $directCode)." -ForegroundColor Yellow
        Write-Host "Likely cause: git proxy is configured but the proxy/VPN is off, or the proxy node is dead." -ForegroundColor Yellow
        Write-Host "Fix: turn your proxy on, or test direct with: git -c http.proxy= -c http.https://github.com.proxy= ls-remote https://github.com/git/git.git HEAD" -ForegroundColor Yellow
    } else {
        Write-Host "FAIL: GitHub not reachable (git and direct both failed). Turn on your VPN/proxy and retry." -ForegroundColor Red
    }
}

# 3. Version check
Write-Host "`nCurrent version:"
& $cli --version
Write-Host "`nUpdate check:"
Push-Location $gitDir
& $cli update --check
Pop-Location

---
name: hermes-update-windows
description: Check and apply Hermes upgrades on Windows (proxy-aware, auto-restarts the desktop app). Use when updating Hermes or checking for new versions.
version: 1.4.2
author: Hermes Agent Community
license: MIT
platforms: [windows]
metadata:
  hermes:
    tags: [hermes, update, upgrade, maintenance, proxy, windows, devops]
    category: devops
---

# Hermes Update Maintenance (Windows)

Safe, repeatable workflow for upgrading a **git-installed Hermes** on Windows,
including environments where GitHub needs a proxy/VPN. Handles the two classic
gotchas: the desktop app locking the venv (`.pyd` files) and the GitHub proxy.

## Installation

Three ways to get this skill onto a Hermes install:

**A. Zip (manual)** — extract so that the folder structure lands in your
skills directory (any category subfolder works):
```
hermes-update-windows/           <- extracted folder goes here
├── SKILL.md                     D:\hermes\config\skills\devops\hermes-update-windows\
└── scripts\*.ps1                (relative paths in Quick Start assume this layout)
```
Verify with `hermes skills list`.

**B. URL** — host the `SKILL.md` anywhere public (GitHub/Gitee raw) and run:
```bash
hermes skills install https://your-host/path/to/SKILL.md
```
Note: install the scripts too — keep the `scripts/` folder next to `SKILL.md`
when you host it.

**C. Registry** — `hermes skills publish <skill-dir> --to github --repo <you>/<repo>`,
then anyone can `hermes skills search hermes-update-windows` and install.

## When to Use

- User asks: "check for updates" / "upgrade Hermes"
- `hermes update` fails with "Other Hermes processes are running... serve"
- Post-upgrade breakage: unknown provider, cryptography errors, missing .env keys

## Prerequisites

- Hermes installed **from git** (the CLI lives in `<root>/venv/Scripts/hermes.exe`).
- **Proxy/VPN for GitHub** only if your network needs one. See the compatibility
  section below — the skill works with ANY proxy product.

## Proxy Compatibility (any VPN works)

This skill has **no dependency on any specific VPN product** (WestWorldVPN,
Clash, v2rayN, Shadowsocks, corporate proxies, etc. all work). A VPN is just a
local proxy endpoint; the scripts resolve it with this priority chain:

1. `-ProxyUrl http://127.0.0.1:PORT` — explicit, most reliable
2. Your existing `HTTPS_PROXY` / `HTTP_PROXY` environment variables
3. Your git global proxy: `git config --global http.proxy`
4. **No proxy** — direct GitHub access (for users without network restrictions)

Supported proxy types:

| Type | git pull | pip install | Notes |
|---|---|---|---|
| HTTP/HTTPS (e.g. Clash http port, privoxy, corporate) | ✅ | ✅ | Best supported — pass `-ProxyUrl http://127.0.0.1:PORT` |
| SOCKS5 (e.g. v2rayN/shadowsocks default) | ✅ native | ⚠️ needs pysocks or an http bridge | Set `git config --global http.https://github.com.proxy socks5://127.0.0.1:PORT`; scripts detect socks and print a hint |
| None (direct) | ✅ | ✅ | Just omit proxy args; scripts auto-detect and go direct |

Example for a Clash user (http proxy on 7890):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\update_once.ps1 -ProxyUrl http://127.0.0.1:7890
```
Example for a v2rayN user (socks5 on 10808):
```bash
git config --global http.https://github.com.proxy socks5://127.0.0.1:10808
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\update_once.ps1   # picks up git proxy automatically
```

## New User: 60-Second Self-Check

Not sure which scenario you're in? Run these 3 commands (PowerShell):

**1. Can git reach GitHub? (the real test — `hermes update` is a git operation)**
```powershell
git ls-remote https://github.com/git/git.git HEAD
```
A commit hash prints = git works directly → run everything with **no proxy args**.
Hangs or fails = you need a working proxy → continue.

> ⚠️ Gotcha: `curl.exe https://github.com` returning `200` does **NOT** mean
> git works. If your git proxy config points at a dead/VPN-off port, git fails
> even when your network can reach GitHub directly. The git test above is the
> truth. If you know your network is fine but git fails, your git proxy may be
> dead — disable it temporarily:
> `git config --global --unset http.https://github.com.proxy`

**2. What proxy ports are listening on your machine?**
```powershell
Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -in 7890,7891,10808,10809,1080,8118,21882 } | Select-Object LocalPort,OwningProcess
```
Cross-check the port against your VPN client's settings — note whether it
says **HTTP** or **SOCKS** for that port.

**3. Is git already configured with a proxy?**
```powershell
git config --global --get-regexp "^http\."
```
Any output = your git proxy is set → scripts pick it up automatically.

Then map your result:

| You found... | Do this |
|---|---|
| Step 1 works (direct) | Just run the scripts, no args |
| An HTTP proxy port (e.g. 7890) | Pass `-ProxyUrl http://127.0.0.1:7890` |
| Only a SOCKS5 port (e.g. 10808) | Set the git proxy once: `git config --global http.https://github.com.proxy socks5://127.0.0.1:10808`, then run scripts with no args |
| Git proxy already set (step 3) | Just run the scripts, no args |

## Quick Start (one-shot, unattended)

```powershell
# 1. Check first (proxy-aware)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check_update.ps1 -ProxyUrl http://127.0.0.1:PORT

# 2. Upgrade: kills desktop app + serve -> `hermes update --yes` -> restarts app
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\update_once.ps1 -ProxyUrl http://127.0.0.1:PORT

# add -WithGateway if you also run `hermes gateway` (stops/restarts it around the update)
```

The one-shot script auto-detects the install dir from the `hermes` CLI on PATH
(or pass `-AgentDir`), logs everything to `%TEMP%\hermes_update_once.log`,
and runs post-update checks (`--version`, `doctor`, `pip check`) into the log.

**Outcome feedback (never silent):** when the update finishes, the script
- writes a machine-readable result to `%TEMP%\hermes_update_once_result.txt`
  (`SUCCESS - Hermes Agent vX.Y.Z` / `FAIL - ...` + output tail + log path), and
- pops a desktop MessageBox: green info box on success, red error box with the
  error tail on failure. So the user always sees whether the upgrade worked.

> NOTE: running it will close your desktop app mid-session. The current
> conversation is interrupted (data is persisted) and the app restarts when
> the update finishes. Tell the user before you run it.

## Manual Procedure

1. **Verify GitHub reachability** — check your proxy is up, then:
   `git ls-remote` in the install dir, or just run `hermes update --check`.
2. **Quit the desktop app completely** (including tray icon). Its backend
   (`python -m hermes_cli.main serve`) locks venv `.pyd` files; while it runs,
   `hermes update` refuses. Do NOT use `--force-venv` — it corrupts the venv
   halfway through.
3. `hermes update --yes` (git global proxy is used automatically).
4. Reopen the desktop app.

## Automatic Updates (optional scheduled task)

Template (run as the normal user; DAILY + repeat works without admin, unlike
ONLOGON):

```bash
schtasks /Create /TN "HermesAutoUpdate" /TR "powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File D:\path\to\scripts\update_once.ps1 -ProxyUrl http://127.0.0.1:PORT" /SC DAILY /ST 08:30 /RI 30 /DU 09:00 /F
```

Add an idle gate (e.g. `GetLastInputInfo` >= 10 min) if you don't want the
upgrade to interrupt active work. Mark last-success in a state file and gate
on a cycle interval (e.g. 15 days) to avoid hammering GitHub daily.

## Post-Upgrade Checklist

```bash
hermes --version                              # new version, no repair warnings
hermes doctor 2>&1 | grep -iE "unknown|issue" # provider sanity
venv/Scripts/python -m pip check              # dependency integrity
Get-Content "$env:TEMP\hermes_update_once_result.txt"  # script's own verdict
```

## Pitfalls

- **Update refused while app runs**: `✗ Other Hermes processes are running...
  serve` → close the desktop app (tray included). Never use `--force-venv`.
- **cryptography corrupted** (interrupted upgrade): `hermes --version` prints
  `repairing before launch: cryptography`; `pip show` reports
  `invalid metadata entry 'name'`; `import cryptography` lacks `__version__`.
  Fix (app closed):
  ```bash
  cd <install-dir>
  rm -rf venv/Lib/site-packages/cryptography-*.dist-info
  venv/Scripts/python -m pip install --force-reinstall --no-cache-dir cryptography==<pin from pyproject.toml>
  ```
- **Provider renamed across versions**: local Ollama provider changed from
  `ollama` to `custom` (v0.20.0+). If `hermes doctor` reports an unknown
  provider: `hermes config set model.provider custom` (base_url unchanged).
- **`.env` keys may reset on upgrade**: API keys (GLM, DashScope, OpenAI, ...)
  can vanish when `.env` is regenerated — verify after upgrading.
- **Full disk**: a big upgrade (hundreds of commits + pip deps) needs several
  hundred MB. The script logs free space before upgrading and warns below 1GB.
- **`curl.exe`**: used only for the direct-HTTP cross-check; built into Windows
  10 1803+ (Windows Server 2019+). Older systems: skip it, git alone is enough.
- **Dead proxy nodes**: if GitHub is unreachable despite VPN "on", switch
  nodes in the VPN client; the socks/privoxy ports will be listening but the
  upstream node may be down.

## Verification

- `hermes --version` shows the new version with no repair warnings.
- `hermes doctor` reports no unknown provider.
- Desktop app reopens; a gateway (if used) reconnects.

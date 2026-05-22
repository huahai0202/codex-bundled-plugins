# Codex Bundled Plugins

![Platform](https://img.shields.io/badge/platform-Windows-0078D4?logo=windows)
![Codex](https://img.shields.io/badge/Codex-skill-111827)
![PowerShell](https://img.shields.io/badge/PowerShell-5%2B-5391FE?logo=powershell)

Recover Codex Desktop's bundled OpenAI plugin marketplace and repair the Windows helper binaries used by Browser Use and Chrome.

This skill exists for Windows users who run into plugin marketplace failures, missing bundled plugins, or browser-tool startup problems after installing or updating Codex Desktop.

## What This Fixes

| Symptom | Recovery path |
| --- | --- |
| Bundled plugins are missing | Sync the local bundled marketplace |
| Remote marketplace returns `403` | Register the local bundled marketplace |
| `Browser Use` or `Chrome` fails to start | Repair helper binaries |
| `%LOCALAPPDATA%\OpenAI\Codex\bin` is missing or stale | Refresh the hashed helper binary cache |
| Codex Desktop was updated | Resync marketplace, then repair helpers if needed |

## How It Works

The skill provides two focused recovery flows:

- **Marketplace sync** copies the newest bundled marketplace from the installed Codex Desktop WindowsApps package into `%USERPROFILE%\.codex\.tmp\bundled-marketplaces\openai-bundled`, then registers it in `%USERPROFILE%\.codex\config.toml` and removes `[windows] sandbox = "elevated"` if present.
- **Helper repair** copies only the required browser helper binaries into Codex's hashed helper subdirectories under `%LOCALAPPDATA%\OpenAI\Codex\bin`, recalculating the hash directory names from the current packaged files each time. It also removes stale 16-character hash directories that are no longer required by the current package, and removes `[windows] sandbox = "elevated"` from `config.toml` after non-dry-run repairs.

It does **not** modify Chrome profiles, cookies, passwords, browser session stores, or native host manifests.

## Install

Clone this repository into your Codex skills directory:

```powershell
git clone https://github.com/huahai0202/codex-bundled-plugins.git "$env:USERPROFILE\.codex\skills\codex-bundled-plugins"
```

Restart Codex Desktop after installing the skill so it can be discovered.

## Recommended Usage

Use the skill from inside Codex and describe what is broken:

```text
Use $codex-bundled-plugins to check, enable, and repair my Codex Desktop bundled plugins.
```

For marketplace issues:

```text
Use $codex-bundled-plugins to sync the bundled plugin marketplace and register it in my Codex config.
```

For Browser Use or Chrome startup failures:

```text
Use $codex-bundled-plugins to inspect and repair the Browser Use / Chrome helper binaries on Windows.
```

After a Codex Desktop update:

```text
Use $codex-bundled-plugins to resync the bundled plugin marketplace from the newest Codex Desktop package, then refresh the Browser Use / Chrome helper binaries if needed.
```

Codex will choose the appropriate recovery path, run the relevant PowerShell script, and report what changed.

## Manual Script Usage

Advanced users can run the scripts directly.

### Sync bundled marketplace

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-bundled-plugins\scripts\sync-openai-bundled.ps1"
```

To also mark every bundled plugin as enabled:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-bundled-plugins\scripts\sync-openai-bundled.ps1" -EnableBundledPlugins
```

The script backs up `config.toml`, replaces the local bundled marketplace under `.codex\.tmp\bundled-marketplaces` with a fresh copy, preserves existing config entries, and removes `[windows] sandbox = "elevated"` if present.

### Repair Browser Use / Chrome helpers

Run a dry run first:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-bundled-plugins\scripts\repair-codex-windows-browser-use.ps1" -DryRun
```

If files are missing or stale, run the repair:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-bundled-plugins\scripts\repair-codex-windows-browser-use.ps1"
```

If Codex was updated and you need to refresh the local cache:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-bundled-plugins\scripts\repair-codex-windows-browser-use.ps1" -Force
```

## Files

```text
.
|-- SKILL.md
|-- agents/
|   `-- openai.yaml
`-- scripts/
    |-- repair-codex-windows-browser-use.ps1
    `-- sync-openai-bundled.ps1
```

## Safety Notes

- The marketplace sync prefers `Get-AppxPackage -Name OpenAI.Codex`, then falls back to scanning `OpenAI.Codex_*` package directories under `C:\Program Files\WindowsApps`.
- The scripts validate resources before using a package, so they do not depend on a fixed architecture or package family suffix.
- The helper repair copies only the required helper binary groups into hashed helper subdirectories: `node.exe`; `codex.exe`, `codex-windows-sandbox-setup.exe`, and `codex-command-runner.exe`; `node_repl.exe`; and `rg.exe`.
- The helper repair does not hard-code hash directory names. It calculates each directory as the first 16 hex characters of `sha256(file_name + NUL + sha256(file_bytes).hex_lower + NUL)` for each file in the group, matching Codex's relocation behavior after app updates.
- The helper repair removes stale 16-character hexadecimal hash directories after the current helper directories are populated. `-DryRun` reports those entries as `would-remove` without deleting them, and non-hash files or directories are left untouched.
- The scripts avoid copying the entire Codex `app\resources` directory into the helper cache.
- After running a repair, quit Codex, Chrome, and `extension-host.exe`; delete `C:\Users\MMZ\.codex\plugins\cache\openai-bundled`; then reinstall the bundled plugins inside the Codex app. The current thread's available tool list may not refresh until a new thread is opened.

## Why This Exists

Codex Desktop is excellent in many ways, but Windows plugin recovery can still be awkward when local caches drift or bundled resources are not registered cleanly. This skill packages the repair steps into a small, repeatable workflow so the fix is easier to run and easier to audit.

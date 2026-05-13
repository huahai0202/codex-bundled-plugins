# Codex Bundled Plugins

Restore Codex Desktop's bundled OpenAI plugins and repair Windows browser helper binaries.

This skill is intended for Windows users of Codex Desktop who run into plugin marketplace or browser-tool startup problems after installation, update, or local cache drift.

## What It Fixes

- Missing or broken bundled plugin marketplace
- Remote marketplace errors such as `403`
- `Browser Use` or `Chrome` tool startup failures
- Missing or stale helper binaries under `%LOCALAPPDATA%\OpenAI\Codex\bin`
- Codex Desktop updates that leave the local browser helper cache out of date

## What It Does

The skill provides two recovery paths:

- **Marketplace sync**: copies Codex Desktop's bundled `openai-bundled` marketplace from the WindowsApps package into `%USERPROFILE%\.codex\plugins\openai-bundled`, then registers it in `%USERPROFILE%\.codex\config.toml`.
- **Helper repair**: copies only the required helper binaries from the installed Codex Desktop package resources into `%LOCALAPPDATA%\OpenAI\Codex\bin`.

It does not modify Chrome profiles, cookies, passwords, session stores, or native host manifests.

## Files

```text
SKILL.md
agents/openai.yaml
scripts/sync-openai-bundled.ps1
scripts/repair-codex-windows-browser-use.ps1
```

## Usage

Sync the bundled plugin marketplace:

```powershell
powershell -ExecutionPolicy Bypass -File %USERPROFILE%\.codex\skills\codex-bundled-plugins\scripts\sync-openai-bundled.ps1
```

Sync the marketplace and enable bundled plugins immediately:

```powershell
powershell -ExecutionPolicy Bypass -File %USERPROFILE%\.codex\skills\codex-bundled-plugins\scripts\sync-openai-bundled.ps1 -EnableBundledPlugins
```

Check browser helper repair status first:

```powershell
powershell -ExecutionPolicy Bypass -File %USERPROFILE%\.codex\skills\codex-bundled-plugins\scripts\repair-codex-windows-browser-use.ps1 -DryRun
```

Repair browser helper binaries:

```powershell
powershell -ExecutionPolicy Bypass -File %USERPROFILE%\.codex\skills\codex-bundled-plugins\scripts\repair-codex-windows-browser-use.ps1
```

Refresh helper binaries after a Codex Desktop update:

```powershell
powershell -ExecutionPolicy Bypass -File %USERPROFILE%\.codex\skills\codex-bundled-plugins\scripts\repair-codex-windows-browser-use.ps1 -Force
```

## Notes

After running a repair, fully quit and restart Codex Desktop. The current thread's available tools may not refresh until a new thread is opened.


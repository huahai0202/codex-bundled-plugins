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

Use this skill from inside Codex. Tell Codex what is broken, then ask it to run the repair according to the skill.

Example prompt:

```text
Use $codex-bundled-plugins to check my Codex Desktop bundled plugins and repair the issue.
```

If the plugin marketplace is missing or returns `403`, ask:

```text
Use $codex-bundled-plugins to sync the bundled plugin marketplace and register it in my Codex config.
```

If `Browser Use` or `Chrome` fails to start, ask:

```text
Use $codex-bundled-plugins to inspect and repair the Browser Use / Chrome helper binaries on Windows.
```

If Codex Desktop was updated and browser tools stopped working, ask:

```text
Use $codex-bundled-plugins to refresh the local browser helper binary cache from the newest Codex Desktop package.
```

Codex will choose the correct recovery path from this skill, run the relevant PowerShell script, and report what changed.

Advanced users can still run the scripts directly from the `scripts/` folder if they want manual control.

## Notes

After running a repair, fully quit and restart Codex Desktop. The current thread's available tools may not refresh until a new thread is opened.

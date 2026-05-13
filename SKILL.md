---
name: codex-bundled-plugins
description: Manual-only recovery skill for syncing and registering Codex desktop's bundled OpenAI plugins and repairing Windows helper binaries for Browser Use or Chrome. Invoke only when the user explicitly mentions $codex-bundled-plugins, codex-bundled-plugins, or this skill path.
---

# Codex Bundled Plugins

Use this skill only after it is explicitly requested. It recovers Codex desktop's locally bundled plugin stack on Windows, covering both plugin marketplace registration and the helper binary cache required by Browser Use and Chrome.

## Workflow

1. Pick the recovery path:
   - Missing plugin marketplace or remote marketplace 403: run the bundled marketplace sync.
   - Browser Use or Chrome startup failure after the plugin exists: run the helper binary repair.
   - Both symptoms: run the marketplace sync, then the helper repair.
2. Locate the newest installed Codex desktop package under:

   ```text
   C:\Program Files\WindowsApps\OpenAI.Codex_*_x64__2p2nqsd0c76g0
   ```

3. For marketplace sync, confirm this source exists:

   ```text
   app\resources\plugins\openai-bundled
   ```

4. Copy the bundled marketplace to the stable user path:

   ```text
   C:\Users\<user>\.codex\plugins\openai-bundled
   ```

   On Windows, prefer `xcopy.exe /G /Q` because WindowsApps plugin files may be encrypted/protected and `Copy-Item` or `robocopy` can fail with `ERROR 6000: The specified file could not be encrypted`.

5. Update `%USERPROFILE%\.codex\config.toml`:

   ```toml
   [features]
   plugins = true

   [marketplaces.openai-bundled]
   source_type = "local"
   source = '\\?\C:\Users\<user>\.codex\plugins\openai-bundled'
   ```

6. For helper repair, populate `%LOCALAPPDATA%\OpenAI\Codex\bin` from the installed package resources. Copy only this fixed helper binary set:

   - `codex.exe`
   - `node.exe`
   - `node_repl.exe`
   - `codex-command-runner.exe`
   - `codex-windows-sandbox-setup.exe`
   - `rg.exe`

   Never copy the entire `app\resources` directory into `%LOCALAPPDATA%\OpenAI\Codex\bin`; it contains application resources and plugin trees that do not belong in the helper binary cache.
   Do not modify Chrome profiles, cookies, passwords, session stores, or native host manifests.

7. Ask the user to fully quit and restart Codex desktop. The current thread's available tool list may not refresh until a new thread starts.

## Marketplace Script

Run the bundled script for the common case:

```powershell
powershell -ExecutionPolicy Bypass -File %USERPROFILE%\.codex\skills\codex-bundled-plugins\scripts\sync-openai-bundled.ps1
```

The script backs up `config.toml` before editing, copies the newest bundled marketplace, and preserves existing config entries.

Use `-EnableBundledPlugins` only when the user wants `chrome`, `browser-use`, and `latex-tectonic` marked enabled immediately:

```powershell
powershell -ExecutionPolicy Bypass -File %USERPROFILE%\.codex\skills\codex-bundled-plugins\scripts\sync-openai-bundled.ps1 -EnableBundledPlugins
```

## Helper Repair Script

Run the repair script in dry-run mode first:

```powershell
powershell -ExecutionPolicy Bypass -File %USERPROFILE%\.codex\skills\codex-bundled-plugins\scripts\repair-codex-windows-browser-use.ps1 -DryRun
```

If the source package is found and the destination is missing or stale, run the repair:

```powershell
powershell -ExecutionPolicy Bypass -File %USERPROFILE%\.codex\skills\codex-bundled-plugins\scripts\repair-codex-windows-browser-use.ps1
```

If package discovery fails, pass the package resources directory explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File %USERPROFILE%\.codex\skills\codex-bundled-plugins\scripts\repair-codex-windows-browser-use.ps1 -PackageResourcesPath "C:\Program Files\WindowsApps\OpenAI.Codex_26.506.3741.0_x64__2p2nqsd0c76g0\app\resources"
```

If Codex was updated, rerun the repair with `-Force` to refresh the local cache from the newest package:

```powershell
powershell -ExecutionPolicy Bypass -File %USERPROFILE%\.codex\skills\codex-bundled-plugins\scripts\repair-codex-windows-browser-use.ps1 -Force
```

Prefer this script over `Copy-Item`. Microsoft Store package files under `WindowsApps` can be application-protected/encrypted, and `Copy-Item` may fail with "Cannot encrypt the specified file" even when the file is readable. The script uses stream copying so it can read the packaged helper and write a normal user-local copy.

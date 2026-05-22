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
   - Codex desktop was updated: run the marketplace sync first because bundled plugins may have changed, then run the helper repair if Browser Use or Chrome helpers are missing, stale, or browser tools are involved.
2. Locate the newest installed Codex desktop package. Prefer `Get-AppxPackage -Name OpenAI.Codex`; if that is unavailable, scan package directories under:

   ```text
   C:\Program Files\WindowsApps\OpenAI.Codex_*
   ```

   Do not assume the architecture or package family suffix is permanent. Validate the package by checking that the required marketplace or helper resources exist.

3. For marketplace sync, confirm this source exists:

   ```text
   app\resources\plugins\openai-bundled
   ```

4. Replace the bundled marketplace at the temporary bundled-marketplaces path with a fresh copy from the newest package:

   ```text
   C:\Users\<user>\.codex\.tmp\bundled-marketplaces\openai-bundled
   ```

   On Windows, prefer staging the copy into a temporary directory with `xcopy.exe /G /Q`, validating that `.agents\plugins\marketplace.json` exists, then replacing the destination directory. This avoids stale plugin files after Codex updates. WindowsApps plugin files may be encrypted/protected and `Copy-Item` or `robocopy` can fail with `ERROR 6000: The specified file could not be encrypted`.

5. Update `%USERPROFILE%\.codex\config.toml`:

   ```toml
   [features]
   plugins = true

   [marketplaces.openai-bundled]
   source_type = "local"
   source = '\\?\C:\Users\<user>\.codex\.tmp\bundled-marketplaces\openai-bundled'
   ```

6. For helper repair, populate `%LOCALAPPDATA%\OpenAI\Codex\bin` from the installed package resources using Codex's hashed helper subdirectory layout. Copy only these helper binary groups:

   - `node.exe`
   - `codex.exe`, `codex-windows-sandbox-setup.exe`, and `codex-command-runner.exe` in one shared group
   - `node_repl.exe`
   - `rg.exe`

   Do not hard-code the hash directory names. For each group, calculate the destination folder from the current package files using Codex's relocation algorithm:

   ```text
   file_digest = sha256(file_bytes).hex_lower
   group_hash = sha256(file_name + NUL + file_digest + NUL for each file in group order).hex_lower
   destination_directory = first 16 hex characters of group_hash
   ```

   Use group order exactly as Codex does: `codex.exe`, `codex-windows-sandbox-setup.exe`, then `codex-command-runner.exe`. Single-file groups contain only that file. Recalculate this folder name every time files are refreshed so Codex updates automatically move helpers into the new hash directory.

   After ensuring the current hash directories are populated, remove stale 16-character hexadecimal hash directories under `%LOCALAPPDATA%\OpenAI\Codex\bin` that are not required by the current package. In dry-run mode, report them as `would-remove` without deleting them. Leave non-hash files and directories untouched.

   Never copy the entire `app\resources` directory into `%LOCALAPPDATA%\OpenAI\Codex\bin`; it contains application resources and plugin trees that do not belong in the helper binary cache.
   Do not modify Chrome profiles, cookies, passwords, session stores, or native host manifests.

7. After the recovery commands finish, remove the temporary elevated Windows sandbox setting from `%USERPROFILE%\.codex\config.toml` if present:

   ```toml
   [windows]
   sandbox = "elevated"
   ```

   Remove only that `sandbox = "elevated"` entry. Leave other `[windows]` settings intact, and remove the `[windows]` section only if it becomes empty.
8. Remind the user to fully quit Codex, Chrome, and `extension-host.exe`; delete `C:\Users\MMZ\.codex\plugins\cache\openai-bundled`; then reinstall the bundled plugins inside the Codex app. The current thread's available tool list may not refresh until a new thread starts.

## Marketplace Script

Run the bundled script for the common case:

```powershell
powershell -ExecutionPolicy Bypass -File %USERPROFILE%\.codex\skills\codex-bundled-plugins\scripts\sync-openai-bundled.ps1
```

The script backs up `config.toml` before editing, replaces the local bundled marketplace under `.codex\.tmp\bundled-marketplaces` with the newest bundled marketplace, preserves existing config entries, and removes `[windows] sandbox = "elevated"` if present.

Use `-EnableBundledPlugins` only when the user wants every plugin listed in the bundled marketplace marked enabled immediately:

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
powershell -ExecutionPolicy Bypass -File %USERPROFILE%\.codex\skills\codex-bundled-plugins\scripts\repair-codex-windows-browser-use.ps1 -PackageResourcesPath "C:\Program Files\WindowsApps\OpenAI.Codex_<version>_<arch>__<publisher>\app\resources"
```

Replace the placeholder package directory with the actual newest `OpenAI.Codex_*` directory on the machine.

If Codex was updated, run the marketplace sync first so the bundled plugin marketplace is refreshed from the newest package. Then rerun the helper repair with `-Force` when Browser Use or Chrome helpers also need to be refreshed:

```powershell
powershell -ExecutionPolicy Bypass -File %USERPROFILE%\.codex\skills\codex-bundled-plugins\scripts\repair-codex-windows-browser-use.ps1 -Force
```

Prefer this script over `Copy-Item`. Microsoft Store package files under `WindowsApps` can be application-protected/encrypted, and `Copy-Item` may fail with "Cannot encrypt the specified file" even when the file is readable. The script uses stream copying so it can read the packaged helper and write a normal user-local copy.

After a non-dry-run repair, the script also removes `[windows] sandbox = "elevated"` from `%USERPROFILE%\.codex\config.toml` when present. In `-DryRun` mode, it reports this as `would-remove` without editing the config.

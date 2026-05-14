param(
  [switch]$EnableBundledPlugins
)

$ErrorActionPreference = "Stop"

function Ensure-Section {
  param(
    [string]$Content,
    [string]$Section,
    [hashtable]$Entries
  )

  $escapedSection = [regex]::Escape($Section)
  $sectionPattern = "(?ms)^\[$escapedSection\]\s*.*?(?=^\[|\z)"

  if ($Content -match $sectionPattern) {
    $block = $Matches[0]
    foreach ($key in $Entries.Keys) {
      $value = $Entries[$key]
      $keyPattern = "(?m)^$([regex]::Escape($key))\s*=.*$"
      if ($block -match $keyPattern) {
        $block = [regex]::Replace($block, $keyPattern, "$key = $value")
      } else {
        $block = $block.TrimEnd() + "`r`n$key = $value`r`n"
      }
    }
    return [regex]::Replace($Content, $sectionPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block })
  }

  $newBlock = "`r`n[$Section]`r`n"
  foreach ($key in $Entries.Keys) {
    $newBlock += "$key = $($Entries[$key])`r`n"
  }
  return $Content.TrimEnd() + "`r`n" + $newBlock
}

$codexHome = Join-Path $env:USERPROFILE ".codex"
$configPath = Join-Path $codexHome "config.toml"
$dest = Join-Path $codexHome "plugins\openai-bundled"
$pluginsRoot = Split-Path -Parent $dest
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

function Test-BundledMarketplace {
  param([Parameter(Mandatory = $true)][string]$InstallLocation)

  $marketplaceJson = Join-Path $InstallLocation "app\resources\plugins\openai-bundled\.agents\plugins\marketplace.json"
  return (Test-Path -LiteralPath $marketplaceJson)
}

function Get-CodexInstallLocation {
  $candidates = New-Object System.Collections.Generic.List[string]

  try {
    $packages = @(Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue |
      Sort-Object Version -Descending)
    foreach ($package in $packages) {
      if ($package.InstallLocation) {
        $candidates.Add($package.InstallLocation)
      }
    }
  } catch {
    # Keep searching by filesystem path below.
  }

  $windowsApps = Join-Path $env:ProgramFiles "WindowsApps"
  if (Test-Path -LiteralPath $windowsApps) {
    $packageDirs = @(Get-ChildItem -Directory -LiteralPath $windowsApps -Filter "OpenAI.Codex_*" -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending)
    foreach ($dir in $packageDirs) {
      $candidates.Add($dir.FullName)
    }
  }

  $unique = $candidates | Where-Object { $_ } | Select-Object -Unique
  foreach ($candidate in $unique) {
    if ((Test-Path -LiteralPath $candidate) -and (Test-BundledMarketplace -InstallLocation $candidate)) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  throw "Could not find an OpenAI.Codex WindowsApps package containing the bundled marketplace."
}

$installLocation = Get-CodexInstallLocation
$sourceRoot = Join-Path $installLocation "app\resources\plugins\openai-bundled"
$marketplaceJson = Join-Path $sourceRoot ".agents\plugins\marketplace.json"
if (-not (Test-Path -LiteralPath $marketplaceJson)) {
  throw "Bundled marketplace not found at: $marketplaceJson"
}

New-Item -ItemType Directory -Force -Path $pluginsRoot | Out-Null

$tempDest = Join-Path $pluginsRoot "openai-bundled.tmp-$timestamp"
$oldDest = Join-Path $pluginsRoot "openai-bundled.old-$timestamp"
$sourceGlob = Join-Path $sourceRoot "*"

if (Test-Path -LiteralPath $tempDest) {
  Remove-Item -LiteralPath $tempDest -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $tempDest | Out-Null

try {
  xcopy.exe $sourceGlob ($tempDest + "\") /E /I /H /Y /G /Q | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "xcopy failed with exit code $LASTEXITCODE"
  }

  $tempMarketplaceJson = Join-Path $tempDest ".agents\plugins\marketplace.json"
  if (-not (Test-Path -LiteralPath $tempMarketplaceJson)) {
    throw "Copied marketplace is missing marketplace.json: $tempMarketplaceJson"
  }

  $movedOld = $false
  if (Test-Path -LiteralPath $dest) {
    Move-Item -LiteralPath $dest -Destination $oldDest -Force
    $movedOld = $true
  }

  try {
    Move-Item -LiteralPath $tempDest -Destination $dest -Force
    if ($movedOld -and (Test-Path -LiteralPath $oldDest)) {
      Remove-Item -LiteralPath $oldDest -Recurse -Force
    }
  } catch {
    if ((-not (Test-Path -LiteralPath $dest)) -and (Test-Path -LiteralPath $oldDest)) {
      Move-Item -LiteralPath $oldDest -Destination $dest -Force
    }
    throw
  }
} catch {
  if (Test-Path -LiteralPath $tempDest) {
    Remove-Item -LiteralPath $tempDest -Recurse -Force
  }
  throw
}

if (-not (Test-Path -LiteralPath $configPath)) {
  New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
  Set-Content -LiteralPath $configPath -Value "" -Encoding UTF8
}

$backupPath = "$configPath.bak-openai-bundled-$timestamp"
Copy-Item -LiteralPath $configPath -Destination $backupPath -Force

$content = Get-Content -LiteralPath $configPath -Raw
if ($null -eq $content) {
  $content = ""
}

$content = Ensure-Section -Content $content -Section "features" -Entries @{
  "plugins" = "true"
}

$stableSource = "\\?\$dest"
$stableSource = $stableSource -replace "'", "''"
$content = Ensure-Section -Content $content -Section "marketplaces.openai-bundled" -Entries @{
  "source_type" = '"local"'
  "source" = "'$stableSource'"
}

$marketplace = Get-Content -LiteralPath (Join-Path $dest ".agents\plugins\marketplace.json") -Raw | ConvertFrom-Json
$pluginNames = @(
  $marketplace.plugins |
    ForEach-Object { $_.name } |
    Where-Object { $_ } |
    Select-Object -Unique
)

if ($EnableBundledPlugins) {
  foreach ($plugin in $pluginNames) {
    $content = Ensure-Section -Content $content -Section "plugins.`"$plugin@openai-bundled`"" -Entries @{
      "enabled" = "true"
    }
  }
}

Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8

Write-Host ""
Write-Host "Synced bundled marketplace from:"
Write-Host "  $sourceRoot"
Write-Host "to:"
Write-Host "  $dest"
Write-Host "Registered marketplace in:"
Write-Host "  $configPath"
Write-Host "Backup:"
Write-Host "  $backupPath"
Write-Host "Plugins in marketplace:"
Write-Host "  $($pluginNames -join ', ')"
if ($EnableBundledPlugins) {
  Write-Host "Enabled bundled plugins:"
  Write-Host "  $($pluginNames -join ', ')"
} else {
  Write-Host "Bundled plugins were synced but not enabled."
  Write-Host "Re-run with -EnableBundledPlugins to enable every plugin in the bundled marketplace."
}
Write-Host ""
Write-Host "Restart Codex desktop to reload plugin marketplaces."

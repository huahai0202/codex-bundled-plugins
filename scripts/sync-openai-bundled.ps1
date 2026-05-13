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

$pkg = Get-AppxPackage OpenAI.Codex -ErrorAction SilentlyContinue |
  Sort-Object Version -Descending |
  Select-Object -First 1

if (-not $pkg) {
  $pkg = Get-ChildItem "C:\Program Files\WindowsApps" -Directory -ErrorAction Stop |
    Where-Object { $_.Name -like "OpenAI.Codex_*_x64__2p2nqsd0c76g0" } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
}

if (-not $pkg) {
  throw "No OpenAI.Codex WindowsApps package was found."
}

$installLocation = if ($pkg.InstallLocation) { $pkg.InstallLocation } else { $pkg.FullName }
$sourceRoot = Join-Path $installLocation "app\resources\plugins\openai-bundled"
$marketplaceJson = Join-Path $sourceRoot ".agents\plugins\marketplace.json"
if (-not (Test-Path -LiteralPath $marketplaceJson)) {
  throw "Bundled marketplace not found at: $marketplaceJson"
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null

$sourceGlob = Join-Path $sourceRoot "*"
xcopy.exe $sourceGlob ($dest + "\") /E /I /H /Y /G /Q | Out-Host
if ($LASTEXITCODE -ne 0) {
  throw "xcopy failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $configPath)) {
  New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
  Set-Content -LiteralPath $configPath -Value "" -Encoding UTF8
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
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

if ($EnableBundledPlugins) {
  foreach ($plugin in @("browser-use", "chrome", "latex-tectonic")) {
    $content = Ensure-Section -Content $content -Section "plugins.`"$plugin@openai-bundled`"" -Entries @{
      "enabled" = "true"
    }
  }
}

Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8

$marketplace = Get-Content -LiteralPath (Join-Path $dest ".agents\plugins\marketplace.json") -Raw | ConvertFrom-Json
$pluginNames = ($marketplace.plugins | Select-Object -ExpandProperty name) -join ", "

Write-Host ""
Write-Host "Synced bundled marketplace from:"
Write-Host "  $sourceRoot"
Write-Host "to:"
Write-Host "  $dest"
Write-Host "Registered marketplace in:"
Write-Host "  $configPath"
Write-Host "Backup:"
Write-Host "  $backupPath"
Write-Host "Plugins:"
Write-Host "  $pluginNames"
Write-Host ""
Write-Host "Restart Codex desktop to reload plugin marketplaces."

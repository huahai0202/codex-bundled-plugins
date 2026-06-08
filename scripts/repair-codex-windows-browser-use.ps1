[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [string]$PackageResourcesPath,
    [string]$DestinationDir = (Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin")
)

$ErrorActionPreference = "Stop"

function New-Utf8NoBomEncoding {
    param([bool]$ThrowOnInvalidBytes = $false)

    return [System.Text.UTF8Encoding]::new($false, $ThrowOnInvalidBytes)
}

function Read-TextFileUtf8 {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
    if ($bytes.Length -eq 0) {
        return ""
    }

    try {
        $text = (New-Utf8NoBomEncoding -ThrowOnInvalidBytes $true).GetString($bytes)
    } catch [System.Text.DecoderFallbackException] {
        throw "File is not valid UTF-8 and was not edited: $LiteralPath. $($_.Exception.Message)"
    }

    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) {
        return $text.Substring(1)
    }

    return $text
}

function Write-TextFileUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [AllowNull()][string]$Content
    )

    if ($null -eq $Content) {
        $Content = ""
    }

    [System.IO.File]::WriteAllText($LiteralPath, $Content, (New-Utf8NoBomEncoding))
}

$HelperGroups = @(
    [pscustomobject]@{
        Primary = "node.exe"
        Files = @("node.exe")
    },
    [pscustomobject]@{
        Primary = "codex.exe"
        Files = @(
            "codex.exe",
            "codex-windows-sandbox-setup.exe",
            "codex-command-runner.exe"
        )
    },
    [pscustomobject]@{
        Primary = "node_repl.exe"
        Files = @("node_repl.exe")
    },
    [pscustomobject]@{
        Primary = "rg.exe"
        Files = @("rg.exe")
    }
)

$RequiredFiles = @(
    $HelperGroups |
        ForEach-Object { $_.Files } |
        Select-Object -Unique
)

function Convert-BytesToHex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    return (($Bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-FileSha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return (Convert-BytesToHex -Bytes ($sha.ComputeHash($stream)))
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Get-CodexHelperDirectoryName {
    param([Parameter(Mandatory = $true)][object[]]$Files)

    $payloadBuilder = New-Object System.Text.StringBuilder
    foreach ($file in $Files) {
        [void]$payloadBuilder.Append($file.Name)
        [void]$payloadBuilder.Append("`0")
        [void]$payloadBuilder.Append($file.Digest)
        [void]$payloadBuilder.Append("`0")
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payloadBuilder.ToString())
        return (Convert-BytesToHex -Bytes ($sha.ComputeHash($payloadBytes))).Substring(0, 16)
    } finally {
        $sha.Dispose()
    }
}

function Get-HelperFileMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $sourcePath = Join-Path $SourceDir $Name
    $sourceItem = Get-Item -LiteralPath $sourcePath -ErrorAction Stop
    if (-not $sourceItem.PSIsContainer -and $sourceItem.Length -ge 0) {
        return [pscustomobject]@{
            Name = $Name
            SourcePath = $sourcePath
            Digest = Get-FileSha256Hex -Path $sourcePath
            Size = $sourceItem.Length
        }
    }

    throw "Required helper source is not a file: $sourcePath"
}

function Resolve-HelperBinaries {
    param([Parameter(Mandatory = $true)][string]$SourceDir)

    $helpers = New-Object System.Collections.Generic.List[object]
    foreach ($group in $HelperGroups) {
        $fileMetadata = @(
            $group.Files | ForEach-Object {
                Get-HelperFileMetadata -SourceDir $SourceDir -Name $_
            }
        )
        $destinationDirectory = Get-CodexHelperDirectoryName -Files $fileMetadata

        foreach ($file in $fileMetadata) {
            $helpers.Add([pscustomobject]@{
                Source = $file.Name
                SourceDigest = $file.Digest
                SourceSize = $file.Size
                DestinationDirectory = $destinationDirectory
                DestinationFile = $file.Name
                GroupPrimary = $group.Primary
            })
        }
    }

    return $helpers
}

function Test-RequiredFiles {
    param([Parameter(Mandatory = $true)][string]$Directory)

    foreach ($file in $RequiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Directory $file))) {
            return $false
        }
    }

    return $true
}

function Get-CodexPackageResourcesPath {
    if ($PackageResourcesPath) {
        $explicit = (Resolve-Path -LiteralPath $PackageResourcesPath -ErrorAction Stop).Path
        if (-not (Test-RequiredFiles -Directory $explicit)) {
            throw "PackageResourcesPath does not contain all required helper binaries: $explicit"
        }
        return $explicit
    }

    $candidates = New-Object System.Collections.Generic.List[string]

    try {
        $packages = @(Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending)
        foreach ($package in $packages) {
            if ($package.InstallLocation) {
                $candidates.Add((Join-Path $package.InstallLocation "app\resources"))
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
            $candidates.Add((Join-Path $dir.FullName "app\resources"))
        }
    }

    $unique = $candidates | Where-Object { $_ } | Select-Object -Unique
    foreach ($candidate in $unique) {
        if ((Test-Path -LiteralPath $candidate) -and (Test-RequiredFiles -Directory $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Could not find a Codex package resources directory containing all required helper binaries. Pass -PackageResourcesPath explicitly."
}

function Copy-FileStream {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null

    $legacyTmp = "$Destination.tmp"
    if (Test-Path -LiteralPath $legacyTmp) {
        Remove-Item -LiteralPath $legacyTmp -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $Destination) {
        try {
            $replaceProbe = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $replaceProbe.Dispose()
        } catch {
            throw "Cannot replace helper while it is in use: $Destination. Quit Codex, Chrome, and extension-host.exe, then rerun this script. $($_.Exception.Message)"
        }
    }

    $tmp = "$Destination.tmp.$([System.Guid]::NewGuid().ToString("N"))"

    try {
        $inputStream = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $outputStream = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $inputStream.CopyTo($outputStream, 1048576)
            } finally {
                $outputStream.Dispose()
            }
        } finally {
            $inputStream.Dispose()
        }

        if (Test-Path -LiteralPath $Destination) {
            [System.IO.File]::Delete($Destination)
        }
        [System.IO.File]::Move($tmp, $Destination)
    } catch {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Get-FileReplacementReadiness {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            replaceable = $true
            error = $null
        }
    }

    try {
        $replaceProbe = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $replaceProbe.Dispose()
        return [pscustomobject]@{
            replaceable = $true
            error = $null
        }
    } catch {
        return [pscustomobject]@{
            replaceable = $false
            error = $_.Exception.Message
        }
    }
}

function Get-PendingReplacementPath {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$SourceHash
    )

    return "$Destination.pending.$($SourceHash.Substring(0, 16))"
}

function Remove-HelperTransientFiles {
    param([Parameter(Mandatory = $true)][string]$Destination)

    $cleanup = New-Object System.Collections.Generic.List[object]
    $parent = Split-Path -Parent $Destination
    $leaf = Split-Path -Leaf $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        return $cleanup
    }

    foreach ($pattern in @("$leaf.tmp", "$leaf.tmp.*", "$leaf.bak.*")) {
        foreach ($file in @(Get-ChildItem -LiteralPath $parent -Filter $pattern -File -ErrorAction SilentlyContinue)) {
            $entry = [ordered]@{
                file = $file.FullName
                reason = "helper-transient-file"
            }

            try {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                $entry.action = "removed"
            } catch {
                $entry.action = "failed-remove"
                $entry.error = $_.Exception.Message
            }

            $cleanup.Add([pscustomobject]$entry)
        }
    }

    return $cleanup
}

function Get-HelperDestinationRelativePath {
    param([Parameter(Mandatory = $true)]$Helper)

    return (Join-Path $Helper.DestinationDirectory $Helper.DestinationFile)
}

function Get-HelperDestinationPath {
    param(
        [Parameter(Mandatory = $true)]$Helper,
        [Parameter(Mandatory = $true)][string]$Root
    )

    return (Join-Path $Root (Get-HelperDestinationRelativePath -Helper $Helper))
}

function Get-FileState {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $sourceItem = Get-Item -LiteralPath $Source -ErrorAction Stop
    $sourceHash = Get-FileSha256Hex -Path $Source
    $destExists = Test-Path -LiteralPath $Destination
    $destLength = $null
    $destHash = $null
    $sameHash = $false

    if ($destExists) {
        $destItem = Get-Item -LiteralPath $Destination -ErrorAction Stop
        $destLength = $destItem.Length
        if ($sourceItem.Length -eq $destItem.Length) {
            $destHash = Get-FileSha256Hex -Path $Destination
            $sameHash = ($sourceHash -eq $destHash)
        }
    }

    [pscustomobject]@{
        sourceLength = $sourceItem.Length
        sourceHash = $sourceHash
        destExists = $destExists
        destLength = $destLength
        destHash = $destHash
        sameHash = $sameHash
    }
}

function Get-NormalizedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $trimChars = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )

    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd($trimChars)
}

function Test-PathIsUnderDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    $normalizedPath = Get-NormalizedFullPath -Path $Path
    $normalizedDirectory = Get-NormalizedFullPath -Path $Directory
    $prefix = $normalizedDirectory + [System.IO.Path]::DirectorySeparatorChar

    return $normalizedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-StaleHashDirectories {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][hashtable]$CurrentHashDirectories,
        [Parameter(Mandatory = $true)][bool]$DryRun
    )

    $cleanup = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Root)) {
        return $cleanup
    }

    $rootPath = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
    $staleDirectories = @(
        Get-ChildItem -Directory -LiteralPath $rootPath -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.Name -match "^[0-9a-fA-F]{16}$") -and
                (-not $CurrentHashDirectories.ContainsKey($_.Name.ToLowerInvariant()))
            }
    )

    foreach ($directory in $staleDirectories) {
        $entry = [ordered]@{
            directory = $directory.Name
            reason = "stale-hash-directory"
        }

        if (-not (Test-PathIsUnderDirectory -Path $directory.FullName -Directory $rootPath)) {
            $entry.action = "skipped-outside-destination"
        } elseif (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $entry.action = "skipped-reparse-point"
        } elseif ($DryRun) {
            $entry.action = "would-remove"
        } else {
            try {
                Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
                $entry.action = "removed"
            } catch {
                $entry.action = "failed-remove"
                $entry.error = $_.Exception.Message
            }
        }

        $cleanup.Add([pscustomobject]$entry)
    }

    return $cleanup
}

function Remove-WindowsElevatedSandboxSetting {
    param([string]$Content)

    if ($null -eq $Content) {
        return ""
    }

    $sectionPattern = "(?ms)^\[windows\]\s*.*?(?=^\[|\z)"
    if ($Content -notmatch $sectionPattern) {
        return $Content
    }

    $block = $Matches[0]
    $settingPattern = "(?m)^[^\S\r\n]*sandbox[^\S\r\n]*=[^\S\r\n]*(?:`"elevated`"|'elevated'|elevated)[^\S\r\n]*(?:#.*)?\r?\n?"
    $updatedBlock = [regex]::Replace($block, $settingPattern, "")

    if ($updatedBlock -eq $block) {
        return $Content
    }

    if ($updatedBlock -match "^\[windows\]\s*\z") {
        return [regex]::Replace($Content, $sectionPattern, "")
    }

    $updatedBlock = $updatedBlock.TrimEnd() + "`r`n"
    return [regex]::Replace($Content, $sectionPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $updatedBlock })
}

function Remove-WindowsElevatedSandboxSettingFromConfig {
    param([Parameter(Mandatory = $true)][bool]$DryRun)

    $codexHome = Join-Path $env:USERPROFILE ".codex"
    $configPath = Join-Path $codexHome "config.toml"
    $result = [ordered]@{
        path = $configPath
        action = "skipped-missing-config"
        backup = $null
    }

    if (-not (Test-Path -LiteralPath $configPath)) {
        return [pscustomobject]$result
    }

    $content = Read-TextFileUtf8 -LiteralPath $configPath
    if ($null -eq $content) {
        $content = ""
    }

    $updatedContent = Remove-WindowsElevatedSandboxSetting -Content $content
    if ($updatedContent -eq $content) {
        $result.action = "skipped-not-present"
        return [pscustomobject]$result
    }

    if ($DryRun) {
        $result.action = "would-remove"
        return [pscustomobject]$result
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = "$configPath.bak-windows-sandbox-$timestamp"
    Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    Write-TextFileUtf8NoBom -LiteralPath $configPath -Content $updatedContent

    $result.action = "removed"
    $result.backup = $backupPath
    return [pscustomobject]$result
}

$sourceDir = Get-CodexPackageResourcesPath
$HelperBinaries = Resolve-HelperBinaries -SourceDir $sourceDir
New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null

$results = New-Object System.Collections.Generic.List[object]
$transientCleanup = New-Object System.Collections.Generic.List[object]
$pendingReplacements = New-Object System.Collections.Generic.List[object]
$destinationBySource = @{}
$currentHashDirectories = @{}

foreach ($helper in $HelperBinaries) {
    $source = Join-Path $sourceDir $helper.Source
    $destination = Get-HelperDestinationPath -Helper $helper -Root $DestinationDir
    $relativeDestination = Get-HelperDestinationRelativePath -Helper $helper
    $destinationBySource[$helper.Source] = $destination
    $currentHashDirectories[$helper.DestinationDirectory.ToLowerInvariant()] = $true

    if (-not $DryRun) {
        foreach ($cleanupEntry in @(Remove-HelperTransientFiles -Destination $destination)) {
            $transientCleanup.Add($cleanupEntry)
        }
    }

    $state = Get-FileState -Source $source -Destination $destination
    $needsCopy = (-not $state.destExists) -or (-not $state.sameHash)
    $action = if ($needsCopy) { if ($DryRun) { "would-copy" } else { "copied" } } else { "skipped" }

    if ($needsCopy -and -not $DryRun) {
        $readiness = Get-FileReplacementReadiness -Path $destination
        if ($readiness.replaceable) {
            Copy-FileStream -Source $source -Destination $destination
            $state = Get-FileState -Source $source -Destination $destination
        } else {
            $pendingPath = Get-PendingReplacementPath -Destination $destination -SourceHash $state.sourceHash
            Copy-FileStream -Source $source -Destination $pendingPath
            $pendingState = Get-FileState -Source $source -Destination $pendingPath
            $action = "staged-pending-replacement"
            $pendingReplacements.Add([pscustomobject]@{
                file = $helper.Source
                reason = "destination-in-use"
                destination = $destination
                pending = $pendingPath
                pendingLength = $pendingState.destLength
                pendingHash = $pendingState.destHash
                pendingMatchesSource = $pendingState.sameHash
                error = $readiness.error
                replaceAfterQuit = @(
                    "删除 $destination",
                    "将 $pendingPath 重命名为 $destination"
                )
            })
        }
    }

    $results.Add([pscustomobject]@{
        file = $helper.Source
        destination = $relativeDestination
        hashDirectory = $helper.DestinationDirectory
        action = $action
        sourceLength = $state.sourceLength
        sourceHash = $state.sourceHash
        destExists = $state.destExists
        destLength = $state.destLength
        destHash = $state.destHash
        sameHash = $state.sameHash
    })
}

$cleanup = @(Remove-StaleHashDirectories -Root $DestinationDir -CurrentHashDirectories $currentHashDirectories -DryRun ([bool]$DryRun))
$configCleanup = Remove-WindowsElevatedSandboxSettingFromConfig -DryRun ([bool]$DryRun)
$validation = [ordered]@{}

if (-not $DryRun) {
    $nodePath = $destinationBySource["node.exe"]
    $codexPath = $destinationBySource["codex.exe"]
    $nodeReplPath = $destinationBySource["node_repl.exe"]
    $rgPath = $destinationBySource["rg.exe"]

    $validation.nodeVersion = (& $nodePath --version) -join "`n"
    $validation.codexVersion = (& $codexPath --version) -join "`n"
    $validation.nodeReplHelp = ((& $nodeReplPath --help) | Select-Object -First 1) -join "`n"
    $validation.rgVersion = ((& $rgPath --version) | Select-Object -First 1) -join "`n"
}

$failedTransientFiles = @(
    $transientCleanup |
        Where-Object { $_.action -eq "failed-remove" } |
        ForEach-Object { $_.file }
)
$failedStaleDirectories = @(
    $cleanup |
        Where-Object { $_.action -eq "failed-remove" } |
        ForEach-Object { Join-Path $DestinationDir $_.directory }
)
$manualCleanupPaths = @($failedTransientFiles) + @($failedStaleDirectories)
$manualReplacements = @(
    $pendingReplacements |
        Where-Object { $_.pendingMatchesSource } |
        ForEach-Object {
            [pscustomobject]@{
                destination = $_.destination
                pending = $_.pending
            }
        }
)
$cachePath = Join-Path $env:USERPROFILE ".codex\plugins\cache\openai-bundled"
$nextStepLines = @(
    "重要后续步骤：",
    "1. 完全退出 Codex、Chrome 和 extension-host.exe。",
    "2. 删除 $cachePath。",
    "3. 在 Codex 应用中重新安装 bundled 插件。",
    "4. 重新启动 Codex，并打开新线程后再重试 Browser Use 或 @chrome。"
)

if ($manualCleanupPaths.Count -gt 0) {
    $nextStepLines += ""
    $nextStepLines += "需要手动清理：退出 Codex、Chrome 和 extension-host.exe 后执行："
    foreach ($path in $manualCleanupPaths) {
        $nextStepLines += "- 删除 $path"
    }
}

if ($manualReplacements.Count -gt 0) {
    $nextStepLines += ""
    $nextStepLines += "需要手动替换：退出 Codex、Chrome 和 extension-host.exe 后执行："
    foreach ($replacement in $manualReplacements) {
        $nextStepLines += "- 删除 $($replacement.destination)"
        $nextStepLines += "- 将 $($replacement.pending) 重命名为 $($replacement.destination)"
    }
}

[pscustomobject]@{
    sourceDir = $sourceDir
    destinationDir = $DestinationDir
    dryRun = [bool]$DryRun
    force = [bool]$Force
    files = $results
    transientCleanup = $transientCleanup
    pendingReplacements = $pendingReplacements
    cleanup = $cleanup
    configCleanup = $configCleanup
    validation = $validation
    nextStep = ($nextStepLines -join "`n")
} | ConvertTo-Json -Depth 5

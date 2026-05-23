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

    $tmp = "$Destination.tmp"
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Force
    }

    $inputStream = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $outputStream = [System.IO.File]::Open($tmp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $inputStream.CopyTo($outputStream, 1048576)
        } finally {
            $outputStream.Dispose()
        }
    } finally {
        $inputStream.Dispose()
    }

    Move-Item -LiteralPath $tmp -Destination $Destination -Force
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
$destinationBySource = @{}
$currentHashDirectories = @{}

foreach ($helper in $HelperBinaries) {
    $source = Join-Path $sourceDir $helper.Source
    $destination = Get-HelperDestinationPath -Helper $helper -Root $DestinationDir
    $relativeDestination = Get-HelperDestinationRelativePath -Helper $helper
    $destinationBySource[$helper.Source] = $destination
    $currentHashDirectories[$helper.DestinationDirectory.ToLowerInvariant()] = $true

    $state = Get-FileState -Source $source -Destination $destination
    $needsCopy = $Force -or (-not $state.destExists) -or (-not $state.sameHash)
    $action = if ($needsCopy) { if ($DryRun) { "would-copy" } else { "copied" } } else { "skipped" }

    if ($needsCopy -and -not $DryRun) {
        Copy-FileStream -Source $source -Destination $destination
        $state = Get-FileState -Source $source -Destination $destination
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

[pscustomobject]@{
    sourceDir = $sourceDir
    destinationDir = $DestinationDir
    dryRun = [bool]$DryRun
    force = [bool]$Force
    files = $results
    cleanup = $cleanup
    configCleanup = $configCleanup
    validation = $validation
    nextStep = "Quit Codex, Chrome, and extension-host.exe; delete C:\Users\MMZ\.codex\plugins\cache\openai-bundled; reinstall the bundled plugins in the app; then retry Browser Use or @chrome in a new thread."
} | ConvertTo-Json -Depth 5

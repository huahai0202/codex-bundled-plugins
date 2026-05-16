[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [string]$PackageResourcesPath,
    [string]$DestinationDir = (Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin")
)

$ErrorActionPreference = "Stop"

$HelperBinaries = @(
    [pscustomobject]@{
        Source = "node.exe"
        DestinationDirectory = "5b9024f90663758b"
        DestinationFile = "node.exe"
    },
    [pscustomobject]@{
        Source = "codex.exe"
        DestinationDirectory = "76ac88818493fc45"
        DestinationFile = "codex.exe"
    },
    [pscustomobject]@{
        Source = "codex-command-runner.exe"
        DestinationDirectory = "76ac88818493fc45"
        DestinationFile = "codex-command-runner.exe"
    },
    [pscustomobject]@{
        Source = "codex-windows-sandbox-setup.exe"
        DestinationDirectory = "76ac88818493fc45"
        DestinationFile = "codex-windows-sandbox-setup.exe"
    },
    [pscustomobject]@{
        Source = "node_repl.exe"
        DestinationDirectory = "46831e373630ff93"
        DestinationFile = "node_repl.exe"
    },
    [pscustomobject]@{
        Source = "rg.exe"
        DestinationDirectory = "ada252862d154cdd"
        DestinationFile = "rg.exe"
    }
)

$RequiredFiles = @(
    $HelperBinaries |
        ForEach-Object { $_.Source } |
        Select-Object -Unique
)

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
    $destExists = Test-Path -LiteralPath $Destination
    $destLength = $null
    $sameHash = $false

    if ($destExists) {
        $destItem = Get-Item -LiteralPath $Destination -ErrorAction Stop
        $destLength = $destItem.Length
        if ($sourceItem.Length -eq $destItem.Length) {
            $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Source).Hash
            $destHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash
            $sameHash = ($sourceHash -eq $destHash)
        }
    }

    [pscustomobject]@{
        sourceLength = $sourceItem.Length
        destExists = $destExists
        destLength = $destLength
        sameHash = $sameHash
    }
}

$sourceDir = Get-CodexPackageResourcesPath
New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null

$results = New-Object System.Collections.Generic.List[object]
$destinationBySource = @{}

foreach ($helper in $HelperBinaries) {
    $source = Join-Path $sourceDir $helper.Source
    $destination = Get-HelperDestinationPath -Helper $helper -Root $DestinationDir
    $relativeDestination = Get-HelperDestinationRelativePath -Helper $helper
    $destinationBySource[$helper.Source] = $destination

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
        action = $action
        sourceLength = $state.sourceLength
        destExists = $state.destExists
        destLength = $state.destLength
        sameHash = $state.sameHash
    })
}

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
    validation = $validation
    nextStep = "Fully restart Codex, then retry Browser Use or @chrome in a new thread."
} | ConvertTo-Json -Depth 5

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Command = "build",

    [switch]$l,
    [switch]$la,
    [string]$v,
    [string]$n,
    [switch]$h
)

# =========================
# HELP
# =========================
function Show-Help {
@"
kml MTR mod ResourcePack Build CLI

USAGE:
    pwsh build.ps1 [command] [options]

COMMANDS:
    build       Build resourcepack (default)
    help        Show help

OPTIONS:
    -l          Enable low-poly optimization
    -la         Build both normal + optimized
    -v <ver>    Version tag (e.g. 1.0, 1.1-Pre)
    -n <name>   Custom pack name (Unicode supported)
    -h          Show help

NOTES:
    - Cross-platform (Windows / Linux / macOS)
    - Requires PowerShell 7+
    - All scripts are written by AI, so some of the content might not be accurate

"@ | Write-Host
}

# =========================
# HELP TRIGGER
# =========================
if ($h -or $Command -eq "help") {
    Show-Help
    exit 0
}

# =========================
# UNKNOWN PARAM GUARD
# =========================
$valid = @("l","la","v","n","h")

foreach ($a in $args) {
    if ($a -match "^-([a-zA-Z]+)") {
        if ($matches[1] -notin $valid) {
            Write-Host "ERROR: Unknown parameter '$a'"
            Show-Help
            exit 1
        }
    }
}

# =========================
# PATH NORMALIZATION (跨平台关键)
# =========================
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$removeScript = Join-Path $scriptDir "Remove-BBModelTexture.ps1"
$lowPolyScript = Join-Path $scriptDir "CreateLowPolyPack.ps1"

$packDir = Join-Path $scriptDir "resourcepack"

# =========================
# ZIP (跨平台替代 Compress-Archive)
# =========================
function New-Zip($sourceDir, $zipPath) {

    if (Test-Path $zipPath) {
        Remove-Item $zipPath -Force
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $sourceDir,
        $zipPath
    )
}

# =========================
# NAME SYSTEM
# =========================
function Get-BaseName {

    if ($n -and $v) { return "${n}_v${v}" }
    if ($n) { return $n }
    if ($v) { return $v }

    return Get-Date -Format "yyyyMMdd-HHmmss"
}

function Zip-Pack($name) {

    $zipPath = Join-Path $scriptDir ($name + ".zip")

    New-Zip -sourceDir $packDir -zipPath $zipPath

    Write-Host "Created: $zipPath"
}

# =========================
# BUILD PIPELINE
# =========================
function Run-Build {

    Write-Host "Starting build..."

    & $removeScript -InputPath "kml.bbmodel" -TextureName "texturekml.png" -OutputPath (Join-Path $packDir "assets/mtr/kmlr.bbmodel")
    & $removeScript -InputPath "kmllcdst.bbmodel" -TextureName "texkmllcdst.png" -OutputPath (Join-Path $packDir "assets/mtr/kmllcdstr.bbmodel")

    $name = Get-BaseName

    if ($la) {

        Zip-Pack $name

        & $lowPolyScript `
            -InputPath (Join-Path $packDir "assets/mtr/kmlr.bbmodel") `
            -OutputPath (Join-Path $packDir "assets/mtr/kmlr.bbmodel")

        Zip-Pack ($name + "-Optimized")
    }
    elseif ($l) {

        & $lowPolyScript `
            -InputPath (Join-Path $packDir "assets/mtr/kmlr.bbmodel") `
            -OutputPath (Join-Path $packDir "assets/mtr/kmlr.bbmodel")

        Zip-Pack ($name + "-Optimized")
    }
    else {
        Zip-Pack $name
    }

    Write-Host "Done."
}

# =========================
# ROUTER
# =========================
switch ($Command.ToLower()) {
    "build" { Run-Build }
    "help"  { Show-Help }
    default {
        Write-Host "ERROR: Unknown command '$Command'"
        Show-Help
        exit 1
    }
}
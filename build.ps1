<#
.SYNOPSIS
    kml MTR mod ResourcePack Build CLI
.DESCRIPTION
    Builds resource pack with optional low-poly optimization and sound integration.
.PARAMETER Command
    Command to run (build or help). Default is build.
.PARAMETER l
    Enable low-poly optimization (creates only optimized pack).
.PARAMETER la
    Build both normal and optimized versions.
.PARAMETER v
    Version tag (e.g. 1.0, 1.1-Pre). Will be prefixed with "v" if no -n given.
.PARAMETER n
    Custom pack name (supports Unicode). If specified, overrides version prefix.
.PARAMETER r
    Release mode - do not add "(预览版)" prefix.
.PARAMETER h
    Show help.
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Command = "build",

    [switch]$l,
    [switch]$la,
    [string]$v,
    [string]$n,
    [switch]$h,
    [switch]$r
)

# =========================
# USER CUSTOMIZABLE（改这里）
# =========================
$packDescriptionBase = "仅支持mtr4+ 作者：Copilot_Q29waW（Bilibili)"      # 基础描述，可改
$extraMetadata = @{
    address = "https://github.com/git1145vi7/kml"                  # 自定义额外字段，可改
}
# =========================

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
    -r          Release mode (no "预览版" prefix)
    -h          Show help

NOTES:
    - Requires PowerShell 5+
    - Cross-platform (Windows / Linux / macOS)
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
$valid = @("l","la","v","n","h","r")
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
# PATH NORMALIZATION
# =========================
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$removeScript = Join-Path $scriptDir "Remove-BBModelTexture.ps1"
$lowPolyScript = Join-Path $scriptDir "CreateLowPolyPack.ps1"
$addSoundsScript = Join-Path $scriptDir "AddSounds.ps1"

$packDir = Join-Path $scriptDir "resourcepack"

# =========================
# ZIP 打包（使用 Compress-Archive）
# =========================
function New-Zip($sourceDir, $zipPath) {
    if (Test-Path $zipPath) {
        Remove-Item $zipPath -Force
    }
    Compress-Archive -Path $sourceDir\* -DestinationPath $zipPath -CompressionLevel Optimal -Force
    Write-Host "Created: $zipPath"
}

# =========================
# 名称生成（修正：只有 -v 时加 v 前缀）
# =========================
function Get-BaseName {
    if ($n -and $v) { return "${n}_v${v}" }
    if ($n) { return $n }
    if ($v) { return "v$v" }          # ← 这里改了
    return Get-Date -Format "yyyyMMdd-HHmmss"
}

# =========================
# 打包封装
# =========================
function ZipPack($name) {
    $zipPath = Join-Path $scriptDir ($name + ".zip")
    New-Zip -sourceDir $packDir -zipPath $zipPath
}

# =========================
# 更新 pack.mcmeta（格式化 JSON，去掉控制台描述）
# =========================
function Update-PackMcmeta($isOptimized) {
    $metaPath = Join-Path $packDir "pack.mcmeta"
    $defaultFormat = 15

    if (Test-Path $metaPath) {
        try {
            $existing = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $packFormat = $existing.pack.pack_format
        } catch {
            Write-Warning "无法解析现有 pack.mcmeta，使用默认 pack_format"
            $packFormat = $defaultFormat
        }
    } else {
        $packFormat = $defaultFormat
    }

    $prefix = ""
    if (-not $r) {
        $prefix += "（预览版）"
    }
    if ($isOptimized) {
        $prefix += "（优化版）"
    }
    $finalDesc = if ($prefix) { "$prefix$packDescriptionBase" } else { $packDescriptionBase }

    $buildInfo = $extraMetadata.Clone()
    $buildInfo['build_time'] = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if ($v) {
        $buildInfo['version'] = $v
    }
    $commit = $env:GITHUB_SHA
    if ($commit -and $commit.Length -ge 7) {
        $buildInfo['commit'] = $commit.Substring(0, 7)
    }

    $newMeta = @{
        pack = @{
            pack_format = $packFormat
            description = $finalDesc
        }
        build_info = $buildInfo
    }

    # 生成格式化 JSON（不带 -Compress）
    $json = $newMeta | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($metaPath, $json, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Updated pack.mcmeta"
}

# =========================
# 主构建流程
# =========================
function Run-Build {
    Write-Host "Starting build..."

    Write-Host "Removing embedded textures..."
    & $removeScript -InputPath "kml.bbmodel" -TextureName "texturekml.png" -OutputPath (Join-Path $packDir "assets/mtr/kmlr.bbmodel")
    & $removeScript -InputPath "kmllcdst.bbmodel" -TextureName "texkmllcdst.png" -OutputPath (Join-Path $packDir "assets/mtr/kmllcdstr.bbmodel")

    if (Test-Path $addSoundsScript) {
        Write-Host "Running AddSounds.ps1..."
        & $addSoundsScript
    } else {
        Write-Host "AddSounds.ps1 not found, skipping."
    }

    $name = Get-BaseName

    if ($la) {
        Write-Host "Building normal version..."
        Update-PackMcmeta -isOptimized $false
        ZipPack $name

        Write-Host "Applying low-poly optimization..."
        & $lowPolyScript `
            -InputPath (Join-Path $packDir "assets/mtr/kmlr.bbmodel") `
            -OutputPath (Join-Path $packDir "assets/mtr/kmlr.bbmodel")

        Write-Host "Building optimized version..."
        Update-PackMcmeta -isOptimized $true
        ZipPack ($name + "-Optimized")
    }
    elseif ($l) {
        Write-Host "Applying low-poly optimization..."
        & $lowPolyScript `
            -InputPath (Join-Path $packDir "assets/mtr/kmlr.bbmodel") `
            -OutputPath (Join-Path $packDir "assets/mtr/kmlr.bbmodel")

        Write-Host "Building optimized version..."
        Update-PackMcmeta -isOptimized $true
        ZipPack ($name + "-Optimized")
    }
    else {
        Write-Host "Building normal version..."
        Update-PackMcmeta -isOptimized $false
        ZipPack $name
    }

    Write-Host "Done."
}

# =========================
# 命令路由
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
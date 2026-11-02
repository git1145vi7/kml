<#
.SYNOPSIS
    从 .msep 项目文件导出 MTR 声音包 (*-MTR.zip)。

.DESCRIPTION
    复刻 Motor Sound Editor 的 MTR 导出流程：
      1. 解析 .msep（ZIP）中的 project.json / tracks.json / 音频资源
      2. 筛选 enabled 且未静音且已分配音频的轨道
      3. 生成 sounds.json、sound.cfg、四个 CSV 曲线表
      4. 使用 ffmpeg 将音频转码为单声道 OGG Vorbis
      5. 打包为 <项目名>-MTR.zip

.PARAMETER MsepPath
    .msep 项目文件路径。输出文件默认为同目录下的 <名字>-MTR.zip。

.PARAMETER SampleRate
    输出音频采样率，默认 44100。可选 22050 / 32000 / 44100 / 48000 / 96000。

.PARAMETER AttenuationDistance
    声音衰减距离，默认 32。可选 16 / 32 / 64。

.PARAMETER FfmpegPath
    ffmpeg 可执行文件路径或命令名，默认从 PATH 中查找 "ffmpeg"。

.PARAMETER OutputPath
    输出 zip 路径，默认 <msep目录>/<msep名>-MTR.zip。

.EXAMPLE
    .\Export-MsepToMtr.ps1 .\123.msep

.EXAMPLE
    .\Export-MsepToMtr.ps1 .\123.msep -SampleRate 48000 -AttenuationDistance 64
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$MsepPath,

    [ValidateSet(22050, 32000, 44100, 48000, 96000)]
    [int]$SampleRate = 44100,

    [ValidateSet(16, 32, 64)]
    [int]$AttenuationDistance = 32,

    [string]$FfmpegPath = "ffmpeg",

    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

# ============================================================
# 工具函数
# ============================================================

# 对应 Rust 的 safe_zip_segment
function Safe-ZipSegment {
    param([string]$Value)
    if ($null -eq $Value) { $Value = "" }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '<' -or $ch -eq '>' -or $ch -eq ':' -or $ch -eq '"' -or
            $ch -eq '/' -or $ch -eq '\' -or $ch -eq '|' -or $ch -eq '?' -or
            $ch -eq '*' -or [char]::IsControl($ch)) {
            [void]$sb.Append('_')
        } else {
            [void]$sb.Append($ch)
        }
    }
    $sanitized = $sb.ToString()
    $parts = $sanitized -split '\s+' | Where-Object { $_ -ne '' }
    $trimmed = $parts -join ' '
    if ([string]::IsNullOrEmpty($trimmed)) {
        return "Motor Sound Export"
    }
    return $trimmed
}

# 对应 Rust 的 safe_slug_segment
function Safe-SlugSegment {
    param([string]$Value)
    $sanitized = (Safe-ZipSegment -Value $Value).ToLowerInvariant()
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $sanitized.ToCharArray()) {
        if ([char]::IsWhiteSpace($ch)) {
            [void]$sb.Append('_')
            continue
        }
        $code = [int]$ch
        $isLower = ($code -ge 97 -and $code -le 122)
        $isDigit = ($code -ge 48 -and $code -le 57)
        if ($isLower -or $isDigit -or $code -eq 95 -or $code -eq 45) {
            [void]$sb.Append($ch)
        } else {
            [void]$sb.Append('_')
        }
    }
    $slug = $sb.ToString()
    $parts = $slug -split '_' | Where-Object { $_ -ne '' }
    $collapsed = $parts -join '_'
    if ([string]::IsNullOrEmpty($collapsed)) {
        return "motor_sound_export"
    }
    return $collapsed
}

# 对应 Rust 的 format_number
function Format-Number {
    param([double]$Value)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) {
        return "0"
    }
    $text = $Value.ToString("0.000000", [System.Globalization.CultureInfo]::InvariantCulture)
    if ($text.Contains('.')) {
        $text = $text.TrimEnd('0')
        $text = $text.TrimEnd('.')
    }
    if ($text -eq '-0') { return "0" }
    return $text
}

# 对应 Rust 的 normalize_curve_value
function Normalize-CurveValue {
    param([string]$Kind, [double]$Value)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) {
        if ($Kind -eq 'pitch') { return 0.01 }
        return 0.0
    }
    if ($Kind -eq 'pitch') {
        if ($Value -le 0.0) { return 0.01 }
        return [Math]::Max($Value, 0.01)
    }
    return [Math]::Max($Value, 0.0)
}

# 对应 Rust 的 sample_curve
function Sample-Curve {
    param(
        [object[]]$Keyframes,
        [string]$Kind,
        [double]$Speed
    )
    if ($null -eq $Keyframes -or $Keyframes.Count -eq 0) {
        if ($Kind -eq 'pitch') { return 1.0 }
        return 0.0
    }
    $kf = @($Keyframes)
    $firstSpeed = [double]$kf[0].speed
    if ($Speed -le $firstSpeed) {
        return (Normalize-CurveValue -Kind $Kind -Value ([double]$kf[0].value))
    }
    $low = 1
    $high = $kf.Count - 1
    $nextIndex = $kf.Count
    while ($low -le $high) {
        $mid = [int](($low + $high) / 2)
        if ($Speed -le [double]$kf[$mid].speed) {
            $nextIndex = $mid
            if ($mid -eq 0) { break }
            $high = $mid - 1
        } else {
            $low = $mid + 1
        }
    }
    $value = 0.0
    if ($nextIndex -eq $kf.Count) {
        $value = [double]$kf[$kf.Count - 1].value
    } else {
        $prev = $kf[$nextIndex - 1]
        $next = $kf[$nextIndex]
        $span = [double]$next.speed - [double]$prev.speed
        $ratio = if ($span -eq 0.0) { 0.0 } else { ($Speed - [double]$prev.speed) / $span }
        $value = [double]$prev.value + ([double]$next.value - [double]$prev.value) * $ratio
    }
    return (Normalize-CurveValue -Kind $Kind -Value $value)
}

# 取轨道曲线
function Get-Curve {
    param(
        [object]$Track,
        [string]$CurveSet,
        [string]$Kind
    )
    $set = $Track.curveSets.$CurveSet
    if ($null -eq $set) { return $null }
    return $set.$Kind
}

# ZIP 写入辅助
function Add-ZipBytes {
    param(
        [System.IO.Compression.ZipArchive]$Zip,
        [string]$EntryName,
        [byte[]]$Bytes
    )
    $entry = $Zip.CreateEntry($EntryName, [System.IO.Compression.CompressionLevel]::Optimal)
    $stream = $entry.Open()
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
    } finally {
        $stream.Dispose()
    }
}

function Add-ZipText {
    param(
        [System.IO.Compression.ZipArchive]$Zip,
        [string]$EntryName,
        [string]$Text
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    Add-ZipBytes -Zip $Zip -EntryName $EntryName -Bytes $bytes
}

function Read-ZipText {
    param(
        [System.IO.Compression.ZipArchive]$Zip,
        [string]$Name
    )
    $entry = $Zip.GetEntry($Name)
    if (-not $entry) {
        throw "ZIP 缺少条目：$Name"
    }
    $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
}

# ============================================================
# 主流程
# ============================================================

# --- 解析路径 ---
if (-not (Test-Path -LiteralPath $MsepPath -PathType Leaf)) {
    throw "找不到 .msep 文件：$MsepPath"
}
$msepFullPath = (Resolve-Path -LiteralPath $MsepPath).Path
$msepDir = Split-Path -Parent $msepFullPath
$msepBaseName = [System.IO.Path]::GetFileNameWithoutExtension($msepFullPath)

if (-not $OutputPath) {
    $OutputPath = Join-Path $msepDir "$msepBaseName-MTR.zip"
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

# --- 查找 ffmpeg ---
$ffmpegCmd = Get-Command -Name $FfmpegPath -ErrorAction SilentlyContinue
if (-not $ffmpegCmd) {
    throw "找不到 ffmpeg：$FfmpegPath。请安装 ffmpeg 或使用 -FfmpegPath 指定完整路径。"
}
$ffmpegExe = $ffmpegCmd.Source

Write-Host "读取 .msep：$msepFullPath" -ForegroundColor Cyan

# --- 打开 msep ---
$msepStream = [System.IO.File]::OpenRead($msepFullPath)
$msepZip = New-Object System.IO.Compression.ZipArchive($msepStream, [System.IO.Compression.ZipArchiveMode]::Read)

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("msep-mtr-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    # --- 读 JSON ---
    $projectJson = Read-ZipText -Zip $msepZip -Name "project.json"
    $tracksJson  = Read-ZipText -Zip $msepZip -Name "tracks.json"

    $project   = $projectJson | ConvertFrom-Json
    $tracksDoc = $tracksJson  | ConvertFrom-Json

    $projectName = $project.meta.name
    if ([string]::IsNullOrWhiteSpace($projectName)) {
        $projectName = "Untitled Project"
    }

    $rootName    = Safe-ZipSegment  -Value $projectName
    $projectSlug = Safe-SlugSegment -Value $projectName

    Write-Host "项目名称：$projectName" -ForegroundColor Cyan
    Write-Host "  根目录 ：$rootName" -ForegroundColor DarkGray
    Write-Host "  slug   ：$projectSlug" -ForegroundColor DarkGray

    # --- 构建 asset 索引 ---
    $assetById = @{}
    foreach ($asset in @($tracksDoc.assets)) {
        if ($asset -and $asset.id) {
            $assetById[$asset.id] = $asset
        }
    }

    # --- 筛选可导出轨道 ---
    $exportable = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($track in @($tracksDoc.tracks)) {
        if (-not $track) { continue }
        if (-not $track.enabled) { continue }
        if ($track.mute) { continue }
        if (-not $track.assetId) { continue }

        $asset = $assetById[$track.assetId]
        if (-not $asset) {
            Write-Warning "轨道 '$($track.name)' 引用了不存在的音频资产：$($track.assetId)"
            continue
        }
        if (-not $asset.packagedPath) {
            Write-Warning "音频资产 $($asset.id) 缺少 packagedPath"
            continue
        }

        $entry = $msepZip.GetEntry($asset.packagedPath)
        if (-not $entry) {
            Write-Warning "ZIP 中找不到音频：$($asset.packagedPath)"
            continue
        }

        $ms = New-Object System.IO.MemoryStream
        try {
            $s = $entry.Open()
            try { $s.CopyTo($ms) } finally { $s.Dispose() }
            $bytes = $ms.ToArray()
        } finally {
            $ms.Dispose()
        }

        $exportable.Add([PSCustomObject]@{
            Index = $index
            Track = $track
            Asset = $asset
            Bytes = $bytes
        })
        $index++
    }

    if ($exportable.Count -eq 0) {
        throw "没有可导出的轨道（需要 enabled 且未静音且已分配音频）。"
    }

    Write-Host "可导出轨道数：$($exportable.Count)" -ForegroundColor Cyan

    # --- 生成 sounds.json（复刻 serde_json::to_string_pretty 的格式）---
    function New-SoundsJson {
        param(
            [object[]]$Items,
            [string]$Slug,
            [int]$Attenuation
        )

        # 构造条目并按 key 字符串排序（等价于 serde_json 的 BTreeMap）
        $entries = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Items) {
            $audioSlug = "motor$($item.Index)"
            $entries.Add([PSCustomObject]@{
                Key       = "${Slug}_${audioSlug}"
                AudioSlug = $audioSlug
            })
        }
        $sorted = @($entries | Sort-Object -Property Key)

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("{`n")
        for ($i = 0; $i -lt $sorted.Count; $i++) {
            $e = $sorted[$i]
            [void]$sb.Append("  `"$($e.Key)`": {`n")
            [void]$sb.Append("    `"sounds`": [`n")
            [void]$sb.Append("      {`n")
            [void]$sb.Append("        `"attenuation_distance`": $Attenuation,`n")
            [void]$sb.Append("        `"name`": `"mtr:$Slug/$($e.AudioSlug)`"`n")
            [void]$sb.Append("      }`n")
            [void]$sb.Append("    ]`n")
            [void]$sb.Append("  }")
            if ($i -lt $sorted.Count - 1) {
                [void]$sb.Append(",")
            }
            [void]$sb.Append("`n")
        }
        [void]$sb.Append("}")
        return $sb.ToString()
    }

    $soundsJsonText = New-SoundsJson `
        -Items $exportable `
        -Slug $projectSlug `
        -Attenuation $AttenuationDistance

    # --- 生成 sound.cfg ---
    $cfgLines = New-Object System.Collections.Generic.List[string]
    $cfgLines.Add("Version 1.0")
    $cfgLines.Add("")
    $cfgLines.Add("[MTR]")
    $cfgLines.Add("MotorNoiseDataType = 5")
    $cfgLines.Add("MotorVolumeMultiply = 1")
    $cfgLines.Add("DoorCloseSoundLength = 1")
    $cfgLines.Add("")
    $cfgLines.Add("[Run]")
    $cfgLines.Add("")
    $cfgLines.Add("[Motor]")
    foreach ($item in $exportable) {
        # 与 Rust 源码保持一致：这里写的是 .wav（实际文件是 .ogg）
        $cfgLines.Add("$($item.Index) = motor$($item.Index).wav")
    }
    $cfgLines.Add("")
    $cfgText = $cfgLines -join "`r`n"

    # --- 生成 CSV ---
    function New-MotorNoiseCsv {
        param(
            $Items,
            [string]$CurveSet,
            [string]$Kind
        )
        $speeds = New-Object System.Collections.Generic.List[double]
        foreach ($item in $Items) {
            $curve = Get-Curve -Track $item.Track -CurveSet $CurveSet -Kind $Kind
            if (-not $curve) { continue }
            foreach ($kf in @($curve.keyframes)) {
                $s = [double]$kf.speed
                if ([double]::IsNaN($s) -or [double]::IsInfinity($s)) { continue }
                $rounded = [Math]::Round($s * 1000000.0, [MidpointRounding]::AwayFromZero) / 1000000.0
                $speeds.Add($rounded)
            }
        }
        if ($speeds.Count -eq 0) { $speeds.Add(0.0) }
        $sortedSpeeds = @($speeds | Sort-Object -Unique)

        $rows = New-Object System.Collections.Generic.List[string]
        $rows.Add("bvets motor noise table 0.01")
        foreach ($speed in $sortedSpeeds) {
            $values = New-Object System.Collections.Generic.List[string]
            $values.Add((Format-Number -Value $speed))
            foreach ($item in $Items) {
                $curve = Get-Curve -Track $item.Track -CurveSet $CurveSet -Kind $Kind
                $keyframes = if ($curve) { @($curve.keyframes) } else { @() }
                $v = Sample-Curve -Keyframes $keyframes -Kind $Kind -Speed $speed
                $values.Add((Format-Number -Value $v))
            }
            $rows.Add(($values -join ","))
        }
        return ($rows -join "`r`n")
    }

    $csvDefs = @(
        @{ Name = "powerfreq.csv"; CurveSet = "traction"; Kind = "pitch"  },
        @{ Name = "powervol.csv";  CurveSet = "traction"; Kind = "volume" },
        @{ Name = "brakefreq.csv"; CurveSet = "brake";    Kind = "pitch"  },
        @{ Name = "brakevol.csv";  CurveSet = "brake";    Kind = "volume" }
    )
    $csvContents = @{}
    foreach ($def in $csvDefs) {
        $csvContents[$def.Name] = New-MotorNoiseCsv `
            -Items $exportable -CurveSet $def.CurveSet -Kind $def.Kind
    }

    # --- 音频转码 ---
    Write-Host "开始转码音频（$SampleRate Hz，单声道 OGG）..." -ForegroundColor Cyan
    $oggFiles = @{}
    foreach ($item in $exportable) {
        $ext = if ($item.Asset.format) { "$($item.Asset.format)".ToLowerInvariant() } else { "bin" }
        $inPath  = Join-Path $tempRoot "track_$($item.Index).$ext"
        $outPath = Join-Path $tempRoot "motor$($item.Index).ogg"
        [System.IO.File]::WriteAllBytes($inPath, $item.Bytes)

        $ffArgs = @(
            "-hide_banner", "-loglevel", "error", "-y",
            "-i", $inPath,
            "-ar", "$SampleRate",
            "-ac", "1",
            "-c:a", "libvorbis",
            $outPath
        )
        & $ffmpegExe @ffArgs
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outPath)) {
            # 回退到内置 vorbis 编码器
            $ffArgsFallback = @(
                "-hide_banner", "-loglevel", "error", "-y",
                "-i", $inPath,
                "-ar", "$SampleRate",
                "-ac", "1",
                "-c:a", "vorbis", "-strict", "-2",
                $outPath
            )
            & $ffmpegExe @ffArgsFallback
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outPath)) {
                throw "ffmpeg 转码失败：track $($item.Index)"
            }
        }
        $oggFiles[$item.Index] = $outPath
        Write-Host ("  motor{0}.ogg ✓" -f $item.Index) -ForegroundColor DarkGray
    }

    # --- 写出 ZIP ---
    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }

    $soundRoot = "$rootName/sounds/$projectSlug"
    Write-Host "写入 ZIP：$OutputPath" -ForegroundColor Cyan

    $outStream = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::Create)
    try {
        $outZip = New-Object System.IO.Compression.ZipArchive(
            $outStream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            Add-ZipText -Zip $outZip -EntryName "$rootName/sounds.json" -Text $soundsJsonText
            Add-ZipText -Zip $outZip -EntryName "$soundRoot/sound.cfg" -Text $cfgText
            foreach ($name in $csvContents.Keys) {
                Add-ZipText -Zip $outZip -EntryName "$soundRoot/$name" -Text $csvContents[$name]
            }
            foreach ($item in $exportable) {
                $oggPath = $oggFiles[$item.Index]
                $bytes = [System.IO.File]::ReadAllBytes($oggPath)
                Add-ZipBytes -Zip $outZip `
                    -EntryName "$soundRoot/motor$($item.Index).ogg" `
                    -Bytes $bytes
            }
        } finally {
            $outZip.Dispose()
        }
    } finally {
        $outStream.Dispose()
    }

    Write-Host ""
    Write-Host "导出完成：$OutputPath" -ForegroundColor Green
}
finally {
    $msepZip.Dispose()
    $msepStream.Dispose()
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
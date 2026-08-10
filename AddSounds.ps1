# Set root directory to script location
$root = $PSScriptRoot
if (-not $root) { $root = Get-Location }

# 1. Check if motor_sounds\kml-MTR.zip exists
$zipPath = Join-Path $root "motor_sounds\kml-MTR.zip"
if (-not (Test-Path $zipPath)) {
    Write-Host "ERROR: motor_sounds\kml-MTR.zip not found. Exiting." -ForegroundColor Red
    exit 1
}

# Define resource pack paths
$assetsMtr = Join-Path $root "resourcepack\assets\mtr"
$soundsFolder = Join-Path $assetsMtr "sounds"
$kmlSoundsFolder = Join-Path $soundsFolder "kml"   # target for ogg files and sound.cfg

# 2. Delete old sounds folder if exists
if (Test-Path $soundsFolder) {
    Write-Host "Deleting existing sounds folder..."
    Remove-Item -Path $soundsFolder -Recurse -Force -ErrorAction SilentlyContinue
}

# 3. Extract kml-MTR.zip (kml folder contents) into assets\mtr
Write-Host "Extracting $zipPath ..."
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
try {
    Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force
    $sourceKml = Join-Path $tempDir "kml"
    if (Test-Path $sourceKml) {
        # Copy everything inside kml (sounds folder and sounds.json) to assets\mtr
        Copy-Item -Path "$sourceKml\*" -Destination $assetsMtr -Recurse -Force
        Write-Host "Extraction and copy completed."
    } else {
        Write-Host "WARNING: No 'kml' directory found inside the zip. Check archive structure." -ForegroundColor Yellow
    }
} finally {
    if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force }
}

# 4. Ensure the target kml subfolder exists (for ogg files and sound.cfg)
if (-not (Test-Path $kmlSoundsFolder)) {
    New-Item -Path $kmlSoundsFolder -ItemType Directory -Force | Out-Null
    Write-Host "Created $kmlSoundsFolder"
}

# 5. Copy three .ogg files from motor_sounds to resourcepack\assets\mtr\sounds\kml
$oggSourceDir = Join-Path $root "motor_sounds"
$oggFiles = @("loop.ogg", "opdr.ogg", "clsdr.ogg")
$missingOgg = $false
foreach ($file in $oggFiles) {
    $src = Join-Path $oggSourceDir $file
    if (-not (Test-Path $src)) {
        Write-Host "WARNING: $file not found, skipping copy." -ForegroundColor Yellow
        $missingOgg = $true
        continue
    }
    $dest = Join-Path $kmlSoundsFolder $file
    Copy-Item -Path $src -Destination $dest -Force
    Write-Host "Copied $file to $kmlSoundsFolder"
}
if ($missingOgg) {
    Write-Host "Some .ogg files are missing, but continuing." -ForegroundColor Yellow
}

# 6. Modify sounds.json (located in assets\mtr) ¨C add three new entries
$jsonPath = Join-Path $assetsMtr "sounds.json"
if (Test-Path $jsonPath) {
    Write-Host "Updating sounds.json ..."
    try {
        $jsonContent = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json

        $newEntries = @{
            "kml_loop" = @{
                sounds = @(
                    @{
                        attenuation_distance = 32
                        name = "mtr:kml/loop"
                    }
                )
            }
            "kml_opdr" = @{
                sounds = @(
                    @{
                        attenuation_distance = 32
                        name = "mtr:kml/opdr"
                    }
                )
            }
            "kml_clsdr" = @{
                sounds = @(
                    @{
                        attenuation_distance = 32
                        name = "mtr:kml/clsdr"
                    }
                )
            }
        }

        foreach ($key in $newEntries.Keys) {
            $jsonContent | Add-Member -MemberType NoteProperty -Name $key -Value $newEntries[$key] -Force
        }

        $jsonContent | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Force
        Write-Host "sounds.json updated."
    } catch {
        Write-Host "ERROR updating sounds.json: $_" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "ERROR: sounds.json not found. Extraction may have failed." -ForegroundColor Red
    exit 1
}

# 7. Append content to sound.cfg inside resourcepack\assets\mtr\sounds\kml\
$cfgPath = Join-Path $kmlSoundsFolder "sound.cfg"
$cfgAppend = @"

[Others]
# Constantly played in background.
Noise = loop.wav

# Plays when the doors open and close.
[Door]
Open = opdr.wav
Close = clsdr.wav
"@

if (-not (Test-Path $cfgPath)) {
    New-Item -Path $cfgPath -ItemType File -Force | Out-Null
}
Add-Content -Path $cfgPath -Value $cfgAppend -Force
Write-Host "sound.cfg updated at $cfgPath"

Write-Host "All operations completed successfully!" -ForegroundColor Green
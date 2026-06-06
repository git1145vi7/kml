param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [Parameter(Mandatory = $true)]
    [string]$TextureName,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$content = [System.IO.File]::ReadAllText($InputPath)

# 找 textures 数组
$texturesPos = $content.IndexOf('"textures":[')

if ($texturesPos -lt 0)
{
    throw "textures array not found"
}

$arrayStart = $texturesPos + 11  # 指向 [

# 找 textures 数组结束 ]
$arrayEnd = $content.IndexOf(']', $arrayStart)

if ($arrayEnd -lt 0)
{
    throw "textures array end not found"
}

# 只在 textures 范围内搜索
$namePattern = '"name":"' + $TextureName + '"'

$namePos = $content.IndexOf(
    $namePattern,
    $arrayStart,
    $arrayEnd - $arrayStart
)

if ($namePos -lt 0)
{
    Write-Host "Texture not found."
    [System.IO.File]::WriteAllText($OutputPath, $content)
    exit
}

# 向前找对象起始 {
$objStart = $content.LastIndexOf('{', $namePos)

if ($objStart -lt 0)
{
    throw "object start not found"
}

# 向后找对象结束 }
$objEnd = $content.IndexOf('}', $namePos)

if ($objEnd -lt 0)
{
    throw "object end not found"
}

$removeStart = $objStart
$removeEnd = $objEnd

# 处理中间元素：
# {...},{目标},{...}
if (
    $removeEnd + 1 -lt $content.Length -and
    $content[$removeEnd + 1] -eq ','
)
{
    $removeEnd++
}
# 处理末尾元素：
# {...},{目标}
elseif (
    $removeStart -gt 0 -and
    $content[$removeStart - 1] -eq ','
)
{
    $removeStart--
}

$newContent =
    $content.Remove(
        $removeStart,
        $removeEnd - $removeStart + 1
    )

[System.IO.File]::WriteAllText(
    $OutputPath,
    $newContent
)

Write-Host "Done."
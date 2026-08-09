param(
    [Parameter(Mandatory=$true)] [string]$InputPath,
    [Parameter(Mandatory=$true)] [string]$OutputPath
)

# 读取 bbmodel JSON
$model = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json

# 建立 name->uuid 和 uuid->name 映射
$nameToUuid = @{}; $uuidToName = @{}
foreach ($g in $model.groups) {
    $nameToUuid[$g.name] = $g.uuid
    $uuidToName[$g.uuid] = $g.name
}

# 建立 uuid->节点 对象映射
$uuidToNode = @{}
function Register-Nodes {
    param($node)
    if ($node.uuid) { $script:uuidToNode[$node.uuid] = $node }
    if ($node.children) {
        foreach ($c in $node.children) {
            if ($c -isnot [string]) { Register-Nodes $c }
        }
    }
}
foreach ($root in $model.outliner) { Register-Nodes $root }

# 收集所有元素的 UUID（model.elements 中）
$elementSet = @{}
if ($model.elements) {
    foreach ($e in $model.elements) {
        $elementSet[$e.uuid] = $true
    }
}

# 递归收集节点及其后代的所有 UUID
function Collect-All {
    param($node)
    $set = @()
    if ($node.children) {
        foreach ($c in $node.children) {
            if ($c -is [string]) {
                $set += $c
            } else {
                $set += $c.uuid
                $set += Collect-All $c
            }
        }
    }
    return $set
}

# 删除 _handrail* 节点
$cleanGroups = @(
    "body_inter","head_inter","end_inter",
    "end_inter_seat","end_inter_accessible","end_inter_accessible_box"
)
foreach ($groupName in $cleanGroups) {
    if (-not $nameToUuid.ContainsKey($groupName)) { continue }
    $node = $uuidToNode[$nameToUuid[$groupName]]
    if (-not $node) { continue }
    $newChildren = @()
    foreach ($c in $node.children) {
        if ($c -is [string]) {
            $newChildren += $c
            continue
        }
        $childName = $uuidToName[$c.uuid]
        if ($childName -match '^_handrail') {
            # 收集并删除此节点和其后代中的所有元素 UUID
            $all = Collect-All $c
            foreach ($id in $all) {
                if ($elementSet.ContainsKey($id)) { $elementSet.Remove($id) }
            }
            # 不将此节点加入 newChildren，即删除该组节点
            continue
        }
        $newChildren += $c
    }
    $node.children = $newChildren
}

# 将 _low_handr 下的指定子组移动到对应的 _inter 组
$moveMap = @{
    "_body" = "body_inter";      "_head" = "head_inter";
    "_end"  = "end_inter";       "_end_seat" = "end_inter_seat";
    "_end_acc"  = "end_inter_accessible"; 
    "_end_accb" = "end_inter_accessible_box"
}
$low = $uuidToNode[$nameToUuid["_low_handr"]]
foreach ($pair in $moveMap.GetEnumerator()) {
    $srcName = $pair.Key; $dstGroup = $pair.Value
    if (-not $nameToUuid.ContainsKey($srcName) -or -not $nameToUuid.ContainsKey($dstGroup)) {
        continue
    }
    $srcUuid = $nameToUuid[$srcName]
    $dstNode = $uuidToNode[$nameToUuid[$dstGroup]]
    # 在 _low_handr 子节点中找到匹配的组节点
    $srcNode = $null
    foreach ($c in $low.children) {
        if ($c -isnot [string] -and $c.uuid -eq $srcUuid) {
            $srcNode = $c; break
        }
    }
    if ($null -eq $srcNode) { continue }
    # 剪切：从 _low_handr 移除，并添加到目标组
    $low.children = @($low.children | Where-Object { ($_ -is [string]) -or ($_.uuid -ne $srcUuid) })
    $dstNode.children += $srcNode
}

# 将剩余的元素集合写回 model.elements
$model.elements = $model.elements | Where-Object { $elementSet.ContainsKey($_.uuid) }

# 序列化并保存输出 JSON
$model | ConvertTo-Json -Depth 100 -Compress | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Successfully created the low-poly model."

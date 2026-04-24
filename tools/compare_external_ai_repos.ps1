param(
    [string]$OutputDir = '',
    [int]$MaxFilesPerCategory = 12,
    [switch]$IncludeOvermind
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
}

function New-AiTarget {
    param(
        [string]$Name,
        [string]$Path
    )
    return [pscustomobject]@{
        Name = $Name
        Path = $Path
    }
}

function Get-RelativePathSafe {
    param(
        [string]$Root,
        [string]$Path
    )
    try {
        return [System.IO.Path]::GetRelativePath($Root, $Path)
    } catch {
        return $Path
    }
}

function Get-KeywordCounts {
    param(
        [string]$Text,
        [string[]]$Patterns
    )

    $counts = [ordered]@{}
    foreach ($pattern in $Patterns) {
        $matches = [regex]::Matches($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $counts[$pattern] = $matches.Count
    }
    return $counts
}

function Get-CategoryScore {
    param(
        [hashtable]$Counts,
        [string[]]$Patterns
    )

    $score = 0
    foreach ($pattern in $Patterns) {
        if ($Counts.ContainsKey($pattern)) {
            $score += [int]$Counts[$pattern]
        }
    }
    return $score
}

function Format-MarkdownTable {
    param(
        [string[]]$Headers,
        [object[]]$Rows
    )

    $lines = @()
    $lines += ('| ' + ($Headers -join ' | ') + ' |')
    $lines += ('| ' + (($Headers | ForEach-Object { '---' }) -join ' | ') + ' |')
    foreach ($row in $Rows) {
        $values = foreach ($header in $Headers) {
            $value = if ($row.PSObject.Properties.Name -contains $header) { $row.$header } else { '' }
            ([string]$value).Replace('|', '\|')
        }
        $lines += ('| ' + ($values -join ' | ') + ' |')
    }
    return $lines
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot 'autotune\external-ai-research'
}
Ensure-Directory -Path $OutputDir

$gameRoot = Split-Path -Parent (Split-Path -Parent $repoRoot)
$documentsMods = Join-Path $env:USERPROFILE 'Documents\My Games\Gas Powered Games\Supreme Commander Forged Alliance\Mods'

$targets = @()
$targets += (New-AiTarget -Name 'M28' -Path (Join-Path $gameRoot 'mods\M28AI'))
$targets += (New-AiTarget -Name 'M27' -Path (Join-Path $gameRoot 'mods\M27AI'))
$targets += (New-AiTarget -Name 'RNGAI' -Path (Join-Path $documentsMods 'RNGAI'))
$targets += (New-AiTarget -Name 'SorianEdit' -Path (Join-Path $documentsMods 'Sorian Edit'))
if ($IncludeOvermind) {
    $targets += New-AiTarget -Name 'Overmind' -Path $repoRoot
}

$allPatterns = @(
    'reclaim', 'mass', 'mex', 'extractor', 'economy', 'factory', 'engineer', 'assist', 'idle',
    'zone', 'map', 'marker', 'threat', 'intel', 'scout', 'path', 'nav', 'label', 'island',
    'platoon', 'attack', 'retreat', 'repair', 'shield', 'acu', 'commander', 'raid', 'defense',
    'naval', 'air', 'transport', 'bomber', 'fighter'
)

$categories = [ordered]@{
    Economy = @('reclaim', 'mass', 'mex', 'extractor', 'economy', 'factory', 'engineer', 'assist', 'idle')
    WorldModel = @('zone', 'map', 'marker', 'threat', 'intel', 'scout', 'path', 'nav', 'label', 'island')
    Combat = @('platoon', 'attack', 'retreat', 'repair', 'shield', 'acu', 'commander', 'raid', 'defense')
    Domains = @('naval', 'air', 'transport', 'bomber', 'fighter')
}

$fileRows = @()
$summaryRows = @()

foreach ($target in $targets) {
    if (-not (Test-Path -LiteralPath $target.Path)) {
        Write-Warning ("Skipping missing AI target {0}: {1}" -f $target.Name, $target.Path)
        continue
    }

    $luaFiles = @(Get-ChildItem -LiteralPath $target.Path -Recurse -File -Filter '*.lua' -ErrorAction SilentlyContinue)
    $targetCounts = [ordered]@{}
    foreach ($pattern in $allPatterns) {
        $targetCounts[$pattern] = 0
    }

    foreach ($file in $luaFiles) {
        $text = ''
        try {
            $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
        } catch {
            continue
        }
        if ($null -eq $text) {
            $text = ''
        }

        $counts = Get-KeywordCounts -Text $text -Patterns $allPatterns
        foreach ($pattern in $allPatterns) {
            $targetCounts[$pattern] += [int]$counts[$pattern]
        }

        $categoryScores = [ordered]@{}
        foreach ($categoryName in $categories.Keys) {
            $categoryScores[$categoryName] = Get-CategoryScore -Counts $counts -Patterns $categories[$categoryName]
        }

        $lineCount = ([regex]::Matches($text, "`n")).Count + 1
        $fileRows += [pscustomobject]@{
            AI = $target.Name
            Path = Get-RelativePathSafe -Root $target.Path -Path $file.FullName
            Lines = $lineCount
            Economy = $categoryScores['Economy']
            WorldModel = $categoryScores['WorldModel']
            Combat = $categoryScores['Combat']
            Domains = $categoryScores['Domains']
            Total = ($categoryScores.Values | Measure-Object -Sum).Sum
        }
    }

    $summaryRows += [pscustomobject]@{
        AI = $target.Name
        Path = $target.Path
        LuaFiles = $luaFiles.Count
        Reclaim = $targetCounts['reclaim']
        Mex = $targetCounts['mex'] + $targetCounts['extractor']
        Factory = $targetCounts['factory']
        Engineer = $targetCounts['engineer']
        ZoneMap = $targetCounts['zone'] + $targetCounts['map'] + $targetCounts['marker'] + $targetCounts['label']
        ThreatIntel = $targetCounts['threat'] + $targetCounts['intel'] + $targetCounts['scout']
        PathNav = $targetCounts['path'] + $targetCounts['nav']
        RepairShield = $targetCounts['repair'] + $targetCounts['shield']
        Platoon = $targetCounts['platoon']
    }
}

$csvPath = Join-Path $OutputDir 'external-ai-file-scores.csv'
$jsonPath = Join-Path $OutputDir 'external-ai-summary.json'
$mdPath = Join-Path $OutputDir 'external-ai-research.md'

$fileRows | Sort-Object AI, @{ Expression = 'Total'; Descending = $true } | Export-Csv -LiteralPath $csvPath -NoTypeInformation
$summaryRows | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$lines = @()
$lines += '# External AI Economy Research'
$lines += ''
$lines += "- Generated: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
$lines += "- Output CSV: $csvPath"
$lines += "- Output JSON: $jsonPath"
$lines += ''
$lines += '## Coverage Summary'
$lines += ''
$lines += Format-MarkdownTable -Headers @('AI', 'LuaFiles', 'Reclaim', 'Mex', 'Factory', 'Engineer', 'ZoneMap', 'ThreatIntel', 'PathNav', 'RepairShield', 'Platoon') -Rows $summaryRows
$lines += ''

foreach ($categoryName in $categories.Keys) {
    $lines += "## Top $categoryName Files"
    $lines += ''
    $topRows = @(
        $fileRows |
            Sort-Object @{ Expression = $categoryName; Descending = $true }, AI |
            Select-Object -First $MaxFilesPerCategory |
            ForEach-Object {
                [pscustomobject]@{
                    AI = $_.AI
                    Score = $_.$categoryName
                    Lines = $_.Lines
                    Path = $_.Path
                }
            }
    )
    $lines += Format-MarkdownTable -Headers @('AI', 'Score', 'Lines', 'Path') -Rows $topRows
    $lines += ''
}

$lines += '## Immediate Lessons For Overmind'
$lines += ''
$lines += '- Treat reclaim, mex capture, factory production, and engineer tasking as one coupled economy problem. The reference AIs concentrate many of those decisions in economy/engineer/factory overseers instead of letting independent builders compete blindly.'
$lines += '- Keep map labels/zones/paths visible to economy. RNG and M28 both have substantial map/nav/zone surfaces, which is the missing bridge between "stable economy" and "must expand/contest/reclaim now".'
$lines += '- Prefer explicit anti-idle guarantees. The strongest pattern across the references is not a perfect budget formula, it is persistent pressure against idle factories and idle engineers.'
$lines += '- Upgrade decisions need live spend accounting. RNG in particular tracks extractor spend and upgrade concurrency directly, which is the right shape for avoiding both starvation and passive no-upgrade states.'
$lines += '- Economy learning should tune policy weights, but the code still needs hard capabilities: emergency ACU support, forward reclaim escorts, safe expansion routing, and base-priority structure placement.'

Set-Content -LiteralPath $mdPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
Write-Host "External AI research report written: $mdPath"

param(
    [string]$Prompt = '',
    [string]$PromptFile = '',
    [string[]]$ContextFiles = @(),
    [string]$Label = 'manual',
    [string]$Model = 'gpt-5.4',
    [string]$WorkRoot = '',
    [string]$OutputRoot = '',
    [switch]$ApplyToCurrentBranch,
    [switch]$KeepWorktree,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    $WorkRoot = Join-Path $repoRoot 'autotune\codex-worktrees'
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot 'autotune\codex-patches'
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
}

function Get-Slug {
    param([string]$Value)
    $slug = (($Value -replace '[^A-Za-z0-9]+', '-') -replace '(^-+|-+$)', '').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return 'patch'
    }
    return $slug
}

if ([string]::IsNullOrWhiteSpace($Prompt) -and [string]::IsNullOrWhiteSpace($PromptFile)) {
    throw 'Provide -Prompt or -PromptFile.'
}

$promptText = $Prompt
if (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
    if (-not (Test-Path -LiteralPath $PromptFile)) {
        throw "PromptFile not found: $PromptFile"
    }
    $promptText = Get-Content -LiteralPath $PromptFile -Raw
}

Ensure-Directory -Path $WorkRoot
Ensure-Directory -Path $OutputRoot

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$slug = Get-Slug -Value $Label
$sessionName = "$timestamp-$slug"
$branchName = "codex/$slug-$timestamp"
$worktreePath = Join-Path $WorkRoot $sessionName
$outputDir = Join-Path $OutputRoot $sessionName
Ensure-Directory -Path $outputDir

$contextLines = @()
foreach ($path in $ContextFiles) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        continue
    }
    $resolved = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $repoRoot $path }
    if (Test-Path -LiteralPath $resolved) {
        $contextLines += "- $resolved"
    }
}

$fullPrompt = @"
You are an offline patch worker for OvermindAI in an isolated git worktree.

Goal:
$promptText

Repository rules:
- Work only in this worktree.
- Do not sync live mirrors.
- Do not update mod_info.lua or Bootstrap.lua unless explicitly required by the task.
- Prefer responsibility modules over inflating already-large files.
- After editing, run: powershell -ExecutionPolicy Bypass -File .\tools\release_checks.ps1 -SkipSync
- Finish by summarizing the files changed and the reasoning.

Suggested context files:
$($contextLines -join [Environment]::NewLine)
"@

$promptPath = Join-Path $outputDir 'prompt.txt'
$messagePath = Join-Path $outputDir 'codex-last-message.txt'
$diffPath = Join-Path $outputDir 'candidate.patch'
$statusPath = Join-Path $outputDir 'git-status.txt'
$diffStatPath = Join-Path $outputDir 'git-diff-stat.txt'
$stdoutPath = Join-Path $outputDir 'codex-stdout.log'
$stderrPath = Join-Path $outputDir 'codex-stderr.log'
$syntaxPath = Join-Path $outputDir 'syntax-check.log'
Set-Content -LiteralPath $promptPath -Value $fullPrompt -Encoding UTF8

if ($DryRun) {
    Write-Host "[DRYRUN] git worktree add -b $branchName $worktreePath HEAD"
    Write-Host "[DRYRUN] codex exec --cd $worktreePath -m $Model --dangerously-bypass-approvals-and-sandbox -o $messagePath -"
    return
}

& git -C $repoRoot worktree add -b $branchName $worktreePath HEAD | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to create git worktree.'
}

try {
    $promptBytes = [System.Text.Encoding]::UTF8.GetBytes($fullPrompt)
    $promptStream = New-Object System.IO.MemoryStream(,$promptBytes)
    $reader = New-Object System.IO.StreamReader($promptStream, [System.Text.Encoding]::UTF8)
    try {
        $reader.BaseStream.Position = 0
        $reader.DiscardBufferedData()
        $reader | & codex exec --cd $worktreePath -m $Model --dangerously-bypass-approvals-and-sandbox -o $messagePath - 1> $stdoutPath 2> $stderrPath
        if ($LASTEXITCODE -ne 0) {
            throw "codex exec failed. See $stderrPath"
        }
    } finally {
        $reader.Dispose()
        $promptStream.Dispose()
    }

    & git -C $worktreePath status --short | Set-Content -LiteralPath $statusPath -Encoding ASCII
    & git -C $worktreePath diff --stat HEAD | Set-Content -LiteralPath $diffStatPath -Encoding ASCII
    & git -C $worktreePath diff --binary HEAD | Set-Content -LiteralPath $diffPath -Encoding ASCII

    & powershell -ExecutionPolicy Bypass -File (Join-Path $worktreePath 'tools\release_checks.ps1') -SkipSync *> $syntaxPath
    if ($LASTEXITCODE -ne 0) {
        throw "Syntax check failed. See $syntaxPath"
    }

    if ($ApplyToCurrentBranch) {
        if ((Get-Item -LiteralPath $diffPath).Length -gt 0) {
            & git -C $repoRoot apply --3way --whitespace=nowarn $diffPath
            if ($LASTEXITCODE -ne 0) {
                throw 'Failed to apply generated patch back to current branch.'
            }
        }
    }
}
finally {
    if (-not $KeepWorktree) {
        & git -C $repoRoot worktree remove --force $worktreePath | Out-Null
    }
}

Write-Host "Codex patch session complete: $outputDir"

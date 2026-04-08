param(
    [switch]$SkipSyntax,
    [switch]$SkipSync
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$docsMirror = 'C:\Users\Sepgi\Documents\My Games\Gas Powered Games\Supreme Commander Forged Alliance\Mods\OvermindAI'
$fafMirror = 'C:\ProgramData\FAForever\user\My Games\Gas Powered Games\Supreme Commander Forged Alliance\mods\OvermindAI'

function Invoke-LuaSyntaxPass {
    $luac = Get-Command luac -ErrorAction SilentlyContinue
    if (-not $luac) {
        throw 'luac not found in PATH'
    }

    $luaFiles = Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter *.lua |
        Where-Object { $_.FullName -notmatch '\\\.git\\' }

    if (-not $luaFiles) {
        throw 'No Lua files found'
    }

    $failed = @()
    foreach ($file in $luaFiles) {
        & $luac.Source -p $file.FullName
        if ($LASTEXITCODE -ne 0) {
            $failed += $file.FullName
        }
    }

    if ($failed.Count -gt 0) {
        Write-Host 'SYNTAX_FAIL'
        $failed | ForEach-Object { Write-Host $_ }
        throw "Lua syntax check failed for $($failed.Count) file(s)"
    }

    Write-Host "SYNTAX_OK files=$($luaFiles.Count)"
}

function Invoke-RobocopyMirror {
    param(
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    $robocopyArgs = @(
        $repoRoot,
        $Destination,
        '/MIR',
        '/XD', '.git'
    )

    & robocopy @robocopyArgs | Out-Null
    $code = $LASTEXITCODE

    if ($code -gt 7) {
        throw "robocopy failed for $Destination with exit code $code"
    }

    Write-Host "SYNC_OK $Destination code=$code"
}

Push-Location $repoRoot
try {
    if (-not $SkipSyntax) {
        Invoke-LuaSyntaxPass
    }

    if (-not $SkipSync) {
        Invoke-RobocopyMirror -Destination $docsMirror
        Invoke-RobocopyMirror -Destination $fafMirror
    }
}
finally {
    Pop-Location
}

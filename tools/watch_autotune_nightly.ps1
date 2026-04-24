param(
    [string]$LaunchLog = '',
    [string]$OutputDir = '',
    [int]$RefreshSeconds = 300,
    [int]$TailLines = 80,
    [int]$WindowSeconds = 120,
    [int]$MinActionSamples = 10,
    [int]$MaxIterations = 0,
    [switch]$Once,
    [string]$ComposeFile = '',
    [string]$EnvFile = '',
    [string]$ProjectName = 'overmind-autotune'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\AutotuneDb.ps1')

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
}

function Query-AsCsvRows {
    param(
        $Settings,
        [string]$Query
    )

    try {
        if (Test-AutotuneDockerReady) {
            $lines = Invoke-AutotuneSqlQuery -Settings $Settings -Query ("copy ({0}) to stdout with csv header" -f $Query) -Quiet
        } else {
            $lines = Invoke-DirectPsqlCopy -Settings $Settings -Query $Query
        }
        if ($lines.Count -le 0) {
            return @()
        }
        return @($lines | ConvertFrom-Csv)
    } catch {
        Write-Warning ("DB query failed: {0}" -f $_.Exception.Message)
        return @()
    }
}

function Test-DirectPsqlReady {
    param($Settings)

    if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
        return $false
    }

    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect('127.0.0.1', [int]$Settings.Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(1000, $false)) {
            return $false
        }
        $client.EndConnect($async)
        return $client.Connected
    } catch {
        return $false
    } finally {
        if ($client) {
            $client.Close()
        }
    }
}

function Invoke-DirectPsqlCopy {
    param(
        $Settings,
        [string]$Query
    )

    $psql = Get-Command psql -ErrorAction Stop
    $oldPassword = $env:PGPASSWORD
    $env:PGPASSWORD = $Settings.Password
    try {
        $copyQuery = "copy ({0}) to stdout with csv header" -f $Query
        $args = @(
            '-h', '127.0.0.1',
            '-p', [string]$Settings.Port,
            '-U', $Settings.User,
            '-d', $Settings.Database,
            '-X',
            '-v', 'ON_ERROR_STOP=1',
            '-q',
            '-c', $copyQuery
        )
        $output = & $psql.Source @args
        if ($LASTEXITCODE -ne 0) {
            throw 'direct psql query failed.'
        }
        return @($output)
    } finally {
        $env:PGPASSWORD = $oldPassword
    }
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

function Get-LatestLaunchLog {
    param([string]$RepoRoot)

    $launchDir = Join-Path $RepoRoot 'autotune\launches'
    if (-not (Test-Path -LiteralPath $launchDir)) {
        return ''
    }
    $latest = Get-ChildItem -LiteralPath $launchDir -Filter 'overnight-autotune-*.out.log' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($latest) {
        return $latest.FullName
    }
    return ''
}

function Get-LogTail {
    param(
        [string]$Path,
        [int]$Lines
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @('No launch log found.')
    }
    try {
        return @(Get-Content -LiteralPath $Path -Tail $Lines)
    } catch {
        return @("Could not read launch log: $($_.Exception.Message)")
    }
}

function Write-WatchReport {
    param(
        $Settings,
        [string]$RepoRoot,
        [string]$LaunchLogPath,
        [string]$ReportDir,
        [int]$Tail,
        [int]$ActionWindow,
        [int]$ActionMinSamples
    )

    $generated = Get-Date
    $processRows = @()
    $launcher = Get-Process -Id 14864 -ErrorAction SilentlyContinue
    if ($launcher) {
        $processRows += [pscustomobject]@{
            Name = 'overnight-wrapper'
            Count = 1
            Detail = ("pid={0} cpu={1:N1}" -f $launcher.Id, $launcher.CPU)
        }
    }
    $fafCount = @(Get-Process -Name 'ForgedAlliance' -ErrorAction SilentlyContinue).Count
    $processRows += [pscustomobject]@{
        Name = 'ForgedAlliance'
        Count = $fafCount
        Detail = 'live game clients'
    }

    $dbReady = ((Test-AutotuneDockerReady) -or (Test-DirectPsqlReady -Settings $Settings))

    if ($dbReady) {
        $recentSessions = Query-AsCsvRows -Settings $Settings -Query @"
select session_id, coalesce(overnight_session_id, '') as overnight, promoted, best_candidate,
       round(best_score::numeric, 2) as best_score,
       round(best_avg_mass_ratio::numeric, 4) as mass_ratio,
       round(best_avg_game_time::numeric, 1) as avg_time,
       coalesce(best_primary_failure_class, '') as failure,
       to_char(created_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS') as created_utc
from autotune.session_runs
where session_kind = 'economy'
order by created_at desc
limit 12
"@

        $aggregateRows = Query-AsCsvRows -Settings $Settings -Query @"
select count(*) as sessions,
       coalesce(sum(case when promoted then 1 else 0 end), 0) as promotions,
       round(avg(best_avg_mass_ratio)::numeric, 4) as avg_mass_ratio,
       round(max(best_avg_mass_ratio)::numeric, 4) as best_mass_ratio,
       round(avg(best_avg_game_time)::numeric, 1) as avg_time,
       round(max(best_avg_game_time)::numeric, 1) as best_time
from autotune.session_runs
where session_kind = 'economy'
  and created_at >= now() - interval '12 hours'
"@

        $failureRows = Query-AsCsvRows -Settings $Settings -Query @"
select map_name, opponent_key, primary_failure_class, candidates,
       avg_mass_ratio, avg_game_time, avg_score
from autotune.v_failure_hotspots
order by candidates desc, avg_score asc
limit 10
"@

        $bestActions = Query-AsCsvRows -Settings $Settings -Query @"
select subsystem, action_type, action_value, samples, avg_reward,
       avg_delta_mex_ready as d_mex, avg_delta_factory_total as d_fac,
       avg_delta_reclaim_mass as d_reclaim, avg_delta_map_control as d_map,
       survival_rate, avg_final_mass_ratio as final_mass
from autotune.v_action_value_by_choice
where window_seconds = $(ConvertTo-AutotuneSqlLiteral $ActionWindow)
  and samples >= $(ConvertTo-AutotuneSqlLiteral $ActionMinSamples)
order by avg_reward desc, samples desc
limit 8
"@

        $worstActions = Query-AsCsvRows -Settings $Settings -Query @"
select subsystem, action_type, action_value, samples, avg_reward,
       avg_delta_mex_ready as d_mex, avg_delta_factory_total as d_fac,
       avg_delta_reclaim_mass as d_reclaim, avg_delta_map_control as d_map,
       survival_rate, avg_final_mass_ratio as final_mass
from autotune.v_action_value_by_choice
where window_seconds = $(ConvertTo-AutotuneSqlLiteral $ActionWindow)
  and samples >= $(ConvertTo-AutotuneSqlLiteral $ActionMinSamples)
order by avg_reward asc, samples desc
limit 8
"@

        $paramRows = Query-AsCsvRows -Settings $Settings -Query @"
select param_name, samples, avg_value, avg_score, avg_mass_ratio,
       score_corr, mass_ratio_corr, game_time_corr
from autotune.v_param_effects
where samples >= 8
order by abs(coalesce(mass_ratio_corr, 0)) desc, samples desc
limit 12
"@
    } else {
        $recentSessions = @([pscustomobject]@{
            session_id = 'db-unavailable'
            overnight = ''
            promoted = ''
            best_candidate = ''
            best_score = ''
            mass_ratio = ''
            avg_time = ''
            failure = 'Docker daemon unavailable; launch-log monitoring still active.'
            created_utc = ''
        })
        $aggregateRows = @([pscustomobject]@{
            sessions = 'db-unavailable'
            promotions = ''
            avg_mass_ratio = ''
            best_mass_ratio = ''
            avg_time = ''
            best_time = ''
        })
        $failureRows = @()
        $bestActions = @()
        $worstActions = @()
        $paramRows = @()
    }

    $tailLines = Get-LogTail -Path $LaunchLogPath -Lines $Tail

    $lines = @()
    $lines += '# Overnight Autotune Watch'
    $lines += ''
    $lines += "- Generated: $($generated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    $lines += "- Launch log: $LaunchLogPath"
    $lines += "- Action window: ${ActionWindow}s"
    $lines += ''
    $lines += '## Process Status'
    $lines += ''
    $lines += Format-MarkdownTable -Headers @('Name', 'Count', 'Detail') -Rows $processRows
    $lines += ''
    $lines += '## Last 12 Hours'
    $lines += ''
    $lines += Format-MarkdownTable -Headers @('sessions', 'promotions', 'avg_mass_ratio', 'best_mass_ratio', 'avg_time', 'best_time') -Rows $aggregateRows
    $lines += ''
    $lines += '## Recent Sessions'
    $lines += ''
    $lines += Format-MarkdownTable -Headers @('session_id', 'overnight', 'promoted', 'best_candidate', 'best_score', 'mass_ratio', 'avg_time', 'failure', 'created_utc') -Rows $recentSessions
    $lines += ''
    $lines += '## Failure Hotspots'
    $lines += ''
    $lines += Format-MarkdownTable -Headers @('map_name', 'opponent_key', 'primary_failure_class', 'candidates', 'avg_mass_ratio', 'avg_game_time', 'avg_score') -Rows $failureRows
    $lines += ''
    $lines += '## Best Actions'
    $lines += ''
    $lines += Format-MarkdownTable -Headers @('subsystem', 'action_type', 'action_value', 'samples', 'avg_reward', 'd_mex', 'd_fac', 'd_reclaim', 'd_map', 'survival_rate', 'final_mass') -Rows $bestActions
    $lines += ''
    $lines += '## Worst Actions'
    $lines += ''
    $lines += Format-MarkdownTable -Headers @('subsystem', 'action_type', 'action_value', 'samples', 'avg_reward', 'd_mex', 'd_fac', 'd_reclaim', 'd_map', 'survival_rate', 'final_mass') -Rows $worstActions
    $lines += ''
    $lines += '## Parameter Signals'
    $lines += ''
    $lines += Format-MarkdownTable -Headers @('param_name', 'samples', 'avg_value', 'avg_score', 'avg_mass_ratio', 'score_corr', 'mass_ratio_corr', 'game_time_corr') -Rows $paramRows
    $lines += ''
    $lines += '## Launch Log Tail'
    $lines += ''
    $lines += '```text'
    $lines += $tailLines
    $lines += '```'

    $latestPath = Join-Path $ReportDir 'latest.md'
    $stampPath = Join-Path $ReportDir ("watch-{0}.md" -f $generated.ToString('yyyyMMdd-HHmmss'))
    Set-Content -LiteralPath $latestPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
    Set-Content -LiteralPath $stampPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
    Write-Host "Watch report written: $latestPath"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot 'autotune\nightly-watch'
}
Ensure-Directory -Path $OutputDir

if ([string]::IsNullOrWhiteSpace($LaunchLog)) {
    $LaunchLog = Get-LatestLaunchLog -RepoRoot $repoRoot
}

$settings = Get-AutotuneDbSettings -RepoRoot $repoRoot -ComposeFile $ComposeFile -EnvFile $EnvFile -ProjectName $ProjectName

$iteration = 0
while ($true) {
    $iteration += 1
    Write-WatchReport -Settings $settings -RepoRoot $repoRoot -LaunchLogPath $LaunchLog -ReportDir $OutputDir -Tail $TailLines -ActionWindow $WindowSeconds -ActionMinSamples $MinActionSamples

    if ($Once -or ($MaxIterations -gt 0 -and $iteration -ge $MaxIterations)) {
        break
    }
    Start-Sleep -Seconds $RefreshSeconds
}

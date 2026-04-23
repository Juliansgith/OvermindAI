Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AutotuneDbRepoRoot {
    return Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

function Read-AutotuneEnvFile {
    param([string]$Path)

    $values = @{}
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $values
    }

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('#')) {
            continue
        }
        $parts = $trimmed -split '=', 2
        if ($parts.Count -ne 2) {
            continue
        }
        $values[$parts[0].Trim()] = $parts[1].Trim()
    }

    return $values
}

function Get-AutotuneDbSettings {
    param(
        [string]$RepoRoot = '',
        [string]$ComposeFile = '',
        [string]$EnvFile = '',
        [string]$ProjectName = 'overmind-autotune'
    )

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-AutotuneDbRepoRoot
    }
    if ([string]::IsNullOrWhiteSpace($ComposeFile)) {
        $ComposeFile = Join-Path $RepoRoot 'docker-compose.autotune-db.yml'
    }
    if ([string]::IsNullOrWhiteSpace($EnvFile)) {
        $EnvFile = Join-Path $RepoRoot '.env.autotune-db'
    }

    $envMap = Read-AutotuneEnvFile -Path $EnvFile
    return [pscustomobject]@{
        RepoRoot = $RepoRoot
        ComposeFile = $ComposeFile
        EnvFile = $EnvFile
        ProjectName = $ProjectName
        ServiceName = 'postgres'
        AdminerServiceName = 'adminer'
        Database = if ($envMap.ContainsKey('AUTOTUNE_DB_NAME')) { $envMap['AUTOTUNE_DB_NAME'] } else { 'overmind_autotune' }
        User = if ($envMap.ContainsKey('AUTOTUNE_DB_USER')) { $envMap['AUTOTUNE_DB_USER'] } else { 'overmind' }
        Password = if ($envMap.ContainsKey('AUTOTUNE_DB_PASSWORD')) { $envMap['AUTOTUNE_DB_PASSWORD'] } else { 'overmind_dev' }
        Port = if ($envMap.ContainsKey('AUTOTUNE_DB_PORT')) { [int]$envMap['AUTOTUNE_DB_PORT'] } else { 54329 }
        AdminerPort = if ($envMap.ContainsKey('AUTOTUNE_ADMINER_PORT')) { [int]$envMap['AUTOTUNE_ADMINER_PORT'] } else { 18081 }
    }
}

function Get-AutotuneComposeBaseArgs {
    param($Settings)

    $args = @('compose', '-p', $Settings.ProjectName, '-f', $Settings.ComposeFile)
    if (Test-Path -LiteralPath $Settings.EnvFile) {
        $args += @('--env-file', $Settings.EnvFile)
    }
    return $args
}

function Test-AutotuneDockerReady {
    try {
        $output = & docker version --format '{{.Server.Version}}' 2>$null
        return (($LASTEXITCODE -eq 0) -and -not [string]::IsNullOrWhiteSpace(($output | Out-String)))
    } catch {
        return $false
    }
}

function Ensure-AutotuneDockerReady {
    param([int]$TimeoutSeconds = 45)

    if (Test-AutotuneDockerReady) {
        return
    }

    $service = Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Running') {
        try {
            Start-Service -Name 'com.docker.service' -ErrorAction Stop
        } catch {
        }
    }

    if (-not (Test-AutotuneDockerReady)) {
        $desktopPath = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
        if (Test-Path -LiteralPath $desktopPath) {
            try {
                Start-Process -FilePath $desktopPath | Out-Null
            } catch {
            }
        }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-AutotuneDockerReady) {
            return
        }
        Start-Sleep -Seconds 2
    }

    throw 'Docker daemon is not reachable. Start Docker Desktop and retry.'
}

function Invoke-AutotuneCompose {
    param(
        $Settings,
        [string[]]$Arguments
    )

    Ensure-AutotuneDockerReady
    $args = @(Get-AutotuneComposeBaseArgs -Settings $Settings) + @($Arguments)
    $output = & docker @args
    if ($output) {
        $output | ForEach-Object { Write-Host $_ }
    }
    return $LASTEXITCODE
}

function Start-AutotuneDb {
    param(
        $Settings,
        [switch]$IncludeAdminer,
        [int]$ReadyTimeoutSeconds = 60
    )

    $services = @($Settings.ServiceName)
    if ($IncludeAdminer) {
        $services += $Settings.AdminerServiceName
    }

    $code = Invoke-AutotuneCompose -Settings $Settings -Arguments (@('up', '-d') + $services)
    if ($code -ne 0) {
        throw 'Failed to start autotune database services.'
    }

    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $readyCode = Invoke-AutotuneCompose -Settings $Settings -Arguments @('exec', '-T', $Settings.ServiceName, 'pg_isready', '-U', $Settings.User, '-d', $Settings.Database)
        if ($readyCode -eq 0) {
            return
        }
        Start-Sleep -Seconds 2
    }

    throw 'Autotune database did not become ready in time.'
}

function Stop-AutotuneDb {
    param(
        $Settings,
        [switch]$DestroyData
    )

    $args = @('down')
    if ($DestroyData) {
        $args += '-v'
    }
    $code = Invoke-AutotuneCompose -Settings $Settings -Arguments $args
    if ($code -ne 0) {
        throw 'Failed to stop autotune database services.'
    }
}

function Copy-AutotuneFileToContainer {
    param(
        $Settings,
        [string]$SourcePath,
        [string]$DestinationPath
    )

    Ensure-AutotuneDockerReady
    $args = @(Get-AutotuneComposeBaseArgs -Settings $Settings) + @('cp', $SourcePath, ('{0}:{1}' -f $Settings.ServiceName, $DestinationPath))
    & docker @args
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to copy '$SourcePath' into container path '$DestinationPath'."
    }
}

function Invoke-AutotunePsqlFile {
    param(
        $Settings,
        [string]$Path
    )

    $fileName = Split-Path -Leaf $Path
    $containerPath = "/tmp/$fileName"
    Copy-AutotuneFileToContainer -Settings $Settings -SourcePath $Path -DestinationPath $containerPath
    $code = Invoke-AutotuneCompose -Settings $Settings -Arguments @('exec', '-T', $Settings.ServiceName, 'psql', '-v', 'ON_ERROR_STOP=1', '-U', $Settings.User, '-d', $Settings.Database, '-f', $containerPath)
    if ($code -ne 0) {
        throw "psql failed for file '$Path'."
    }
}

function Invoke-AutotuneSqlQuery {
    param(
        $Settings,
        [string]$Query,
        [switch]$Quiet
    )

    $args = @('exec', '-T', $Settings.ServiceName, 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', $Settings.User, '-d', $Settings.Database, '-P', 'footer=off', '-A', '-F', '|', '-c', $Query)
    Ensure-AutotuneDockerReady
    $composeArgs = @(Get-AutotuneComposeBaseArgs -Settings $Settings) + $args
    $output = & docker @composeArgs
    if ($LASTEXITCODE -ne 0) {
        throw 'psql query failed.'
    }
    if (-not $Quiet) {
        $output | ForEach-Object { Write-Host $_ }
    }
    return @($output)
}

function Get-OvermindBuildMetadata {
    param([string]$RepoRoot = '')

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-AutotuneDbRepoRoot
    }

    $version = $null
    $fingerprint = $null
    $modInfoPath = Join-Path $RepoRoot 'mod_info.lua'
    $bootstrapPath = Join-Path $RepoRoot 'lua\AI\Overmind\Bootstrap.lua'

    if (Test-Path -LiteralPath $modInfoPath) {
        $modInfo = Get-Content -LiteralPath $modInfoPath -Raw
        if ($modInfo -match 'version\s*=\s*([0-9]+)') {
            $version = [int]$Matches[1]
        }
    }
    if (Test-Path -LiteralPath $bootstrapPath) {
        $bootstrap = Get-Content -LiteralPath $bootstrapPath -Raw
        if ($bootstrap -match "BuildFingerprint\s*=\s*'([^']+)'") {
            $fingerprint = [string]$Matches[1]
        }
    }

    $gitCommit = $null
    try {
        $gitCommit = (& git -C $RepoRoot rev-parse HEAD 2>$null)
        if ($LASTEXITCODE -ne 0) {
            $gitCommit = $null
        }
    } catch {
        $gitCommit = $null
    }

    return [pscustomobject]@{
        Version = $version
        Fingerprint = $fingerprint
        GitCommit = $gitCommit
    }
}

function ConvertTo-AutotuneSqlLiteral {
    param($Value)

    if ($null -eq $Value) {
        return 'NULL'
    }
    if ($Value -is [bool]) {
        return ($(if ($Value) { 'TRUE' } else { 'FALSE' }))
    }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return ([string]$Value).Replace(',', '.')
    }
    if ($Value -is [datetime]) {
        return "'" + ($Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) + "'"
    }
    $text = [string]$Value
    return "'" + ($text.Replace("'", "''")) + "'"
}

function ConvertTo-AutotuneSqlJson {
    param($Value)
    if ($null -eq $Value) {
        return 'NULL'
    }
    $json = $Value | ConvertTo-Json -Depth 32 -Compress
    return ("'{0}'::jsonb" -f ($json.Replace("'", "''")))
}

function ConvertTo-AutotuneSqlTextArray {
    param($Values)
    if ($null -eq $Values) {
        return 'NULL'
    }
    $items = @($Values)
    if ($items.Count -eq 0) {
        return 'ARRAY[]::text[]'
    }
    $encoded = @()
    foreach ($item in $items) {
        $encoded += (ConvertTo-AutotuneSqlLiteral -Value ([string]$item))
    }
    return ('ARRAY[{0}]::text[]' -f ($encoded -join ', '))
}

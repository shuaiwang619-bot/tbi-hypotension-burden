param(
    [string]$PsqlPath = "psql",
    [string]$HostName = "127.0.0.1",
    [int]$Port = 5432,
    [string]$UserName = "postgres",
    [string]$RunId = (Get-Date -Format "yyyyMMdd_HHmmss")
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$outputRoot = Join-Path $projectRoot "03_outputs\cohort_flow"
$logRoot = Join-Path $projectRoot "03_outputs\logs"
$runDir = Join-Path $outputRoot $RunId

New-Item -ItemType Directory -Path $runDir -Force | Out-Null
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

if (-not (Get-Command $PsqlPath -ErrorAction SilentlyContinue)) {
    throw "psql executable not found or not on PATH: $PsqlPath"
}

if (-not $env:PGPASSWORD) {
    throw "PGPASSWORD is not set. Set it in the current PowerShell session before running this script."
}

function Invoke-CohortSql {
    param(
        [string]$Database,
        [string]$SqlFile,
        [string]$OutputFile,
        [string]$LogFile
    )

    if (-not (Test-Path -LiteralPath $SqlFile)) {
        throw "SQL file not found: $SqlFile"
    }

    $args = @(
        "-h", $HostName,
        "-p", $Port,
        "-U", $UserName,
        "-d", $Database,
        "--csv",
        "-q",
        "-X",
        "-f", $SqlFile
    )

    & $PsqlPath @args 1> $OutputFile 2> $LogFile
    if ($LASTEXITCODE -ne 0) {
        throw "psql failed for $Database. See log: $LogFile"
    }
}

$eicuSql = Join-Path $projectRoot "02_code\sql\eicu\01_eicu_cohort_flow.sql"
$mimicSql = Join-Path $projectRoot "02_code\sql\mimic\01_mimic_cohort_flow.sql"

$eicuOut = Join-Path $runDir "eicu_cohort_flow.csv"
$mimicOut = Join-Path $runDir "mimic_cohort_flow.csv"
$eicuLog = Join-Path $logRoot "${RunId}_eicu_cohort_flow.log"
$mimicLog = Join-Path $logRoot "${RunId}_mimic_cohort_flow.log"

Invoke-CohortSql -Database "eicu" -SqlFile $eicuSql -OutputFile $eicuOut -LogFile $eicuLog
Invoke-CohortSql -Database "mimic" -SqlFile $mimicSql -OutputFile $mimicOut -LogFile $mimicLog

$manifest = Join-Path $runDir "manifest.txt"
@(
    "run_id=$RunId",
    "run_time=$(Get-Date -Format s)",
    "project_root=$projectRoot",
    "psql_path=$PsqlPath",
    "host=$HostName",
    "port=$Port",
    "user=$UserName",
    "eicu_sql=$eicuSql",
    "mimic_sql=$mimicSql",
    "eicu_output=$eicuOut",
    "mimic_output=$mimicOut",
    "eicu_log=$eicuLog",
    "mimic_log=$mimicLog",
    "note=Aggregate cohort counts only; no patient-level data exported."
) | Set-Content -LiteralPath $manifest -Encoding UTF8

Write-Host "Cohort extraction completed."
Write-Host "Run directory: $runDir"
Write-Host "eICU output: $eicuOut"
Write-Host "MIMIC output: $mimicOut"



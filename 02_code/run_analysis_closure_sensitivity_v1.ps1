param(
    [string]$PythonPath = "python",
    [string]$PsqlPath = "psql",
    [string]$HostName = "127.0.0.1",
    [int]$Port = 5432,
    [string]$UserName = "postgres"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$analysisScript = Join-Path $projectRoot "02_code\python\analysis_closure_sensitivity_v1.py"

if (-not (Get-Command $PythonPath -ErrorAction SilentlyContinue)) {
    throw "Python executable not found or not on PATH: $PythonPath"
}

if (-not (Get-Command $PsqlPath -ErrorAction SilentlyContinue)) {
    throw "psql executable not found or not on PATH: $PsqlPath"
}

if (-not (Test-Path -LiteralPath $analysisScript)) {
    throw "Analysis script not found: $analysisScript"
}

if (-not $env:PGPASSWORD) {
    throw "PGPASSWORD is not set. Set it in the current PowerShell session before running this script."
}

& $PythonPath $analysisScript --psql-path $PsqlPath --host $HostName --port $Port --user $UserName
if ($LASTEXITCODE -ne 0) {
    throw "Analysis closure sensitivity v1 failed."
}



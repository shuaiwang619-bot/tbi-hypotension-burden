param(
    [string]$PythonPath = "python"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$modelScript = Join-Path $projectRoot "02_code\python\adjusted_model_v3_hypotension_rcs.py"

if (-not (Get-Command $PythonPath -ErrorAction SilentlyContinue)) {
    throw "Python executable not found or not on PATH: $PythonPath"
}

if (-not (Test-Path -LiteralPath $modelScript)) {
    throw "Model script not found: $modelScript"
}

& $PythonPath $modelScript
if ($LASTEXITCODE -ne 0) {
    throw "Adjusted model v3 hypotension RCS failed."
}



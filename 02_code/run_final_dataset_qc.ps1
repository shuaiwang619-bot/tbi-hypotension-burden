param(
    [string]$PythonPath = "python"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$qcScript = Join-Path $projectRoot "02_code\python\final_dataset_qc.py"

if (-not (Get-Command $PythonPath -ErrorAction SilentlyContinue)) {
    throw "Python executable not found or not on PATH: $PythonPath"
}

if (-not (Test-Path -LiteralPath $qcScript)) {
    throw "QC script not found: $qcScript"
}

& $PythonPath $qcScript
if ($LASTEXITCODE -ne 0) {
    throw "Final dataset QC failed."
}



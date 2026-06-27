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
$outputRoot = Join-Path $projectRoot "03_outputs\tables\burden"
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

function Invoke-BurdenSql {
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

function Get-Number {
    param([object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    return [double]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [double]$P
    )
    $clean = @($Values | Where-Object { -not [double]::IsNaN($_) } | Sort-Object)
    if ($clean.Count -eq 0) { return $null }
    if ($clean.Count -eq 1) { return [math]::Round($clean[0], 6) }

    $pos = ($clean.Count - 1) * $P
    $lower = [math]::Floor($pos)
    $upper = [math]::Ceiling($pos)
    if ($lower -eq $upper) { return [math]::Round($clean[$lower], 6) }

    $weight = $pos - $lower
    return [math]::Round(($clean[$lower] * (1 - $weight)) + ($clean[$upper] * $weight), 6)
}

function Add-MetricRow {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [string]$Database,
        [string]$Section,
        [string]$Metric,
        [object]$Value,
        [string]$Notes = ""
    )
    $Rows.Add([pscustomobject]@{
        database_name = $Database
        section       = $Section
        metric        = $Metric
        value         = if ($null -eq $Value) { "" } else { [string]$Value }
        notes         = $Notes
    })
}

function Summarize-BurdenCsv {
    param(
        [string]$Database,
        [string]$CsvPath
    )

    $data = @(Import-Csv -LiteralPath $CsvPath)
    $rows = [System.Collections.Generic.List[object]]::new()
    $totalN = $data.Count
    $eligible = @($data | Where-Object { $_.eligible_24h_12h_coverage -eq "1" })
    $eligibleObserved = @($data | Where-Object { $_.eligible_observed_window_50pct -eq "1" })
    $remained24 = @($data | Where-Object { $_.survived_or_remained_icu_24h -eq "1" })

    Add-MetricRow $rows $Database "cohort" "primary_cohort_n" $totalN "strict intracranial TBI, GCS <= 8"
    Add-MetricRow $rows $Database "cohort" "icu_deaths_overall_n" (($data | Where-Object { $_.death_icu -eq "1" }).Count) ""
    Add-MetricRow $rows $Database "cohort" "hospital_deaths_overall_n" (($data | Where-Object { $_.death_hospital -eq "1" }).Count) ""
    Add-MetricRow $rows $Database "coverage" "eligible_24h_12h_coverage_n" $eligible.Count "MAP and SpO2 effective observation each >= 12h"
    Add-MetricRow $rows $Database "coverage" "eligible_24h_12h_coverage_pct" ([math]::Round(100 * $eligible.Count / [math]::Max($totalN, 1), 2)) ""
    Add-MetricRow $rows $Database "coverage" "eligible_observed_window_50pct_n" $eligibleObserved.Count "MAP and SpO2 effective observation each >= 50% of ICU-observed window"
    Add-MetricRow $rows $Database "coverage" "remained_or_survived_icu_24h_n" $remained24.Count "window end reached full 24h"
    Add-MetricRow $rows $Database "coverage" "icu_deaths_eligible_24h_n" (($eligible | Where-Object { $_.death_icu -eq "1" }).Count) ""
    Add-MetricRow $rows $Database "coverage" "hospital_deaths_eligible_24h_n" (($eligible | Where-Object { $_.death_hospital -eq "1" }).Count) ""

    foreach ($subsetSpec in @(
        @{ Name = "overall"; Data = $data },
        @{ Name = "eligible_24h"; Data = $eligible }
    )) {
        $subsetName = $subsetSpec.Name
        $subsetData = @($subsetSpec.Data)
        foreach ($var in @(
            "map_effective_hours",
            "spo2_effective_hours",
            "hypotension_twa",
            "hypoxemia_twa",
            "hypotension_minutes",
            "hypoxemia_minutes",
            "combined_burden_z"
        )) {
            $values = @($subsetData | ForEach-Object { Get-Number $_.$var } | Where-Object { $null -ne $_ })
            Add-MetricRow $rows $Database "distribution_$subsetName" "${var}_p25" (Get-Percentile -Values $values -P 0.25) ""
            Add-MetricRow $rows $Database "distribution_$subsetName" "${var}_median" (Get-Percentile -Values $values -P 0.50) ""
            Add-MetricRow $rows $Database "distribution_$subsetName" "${var}_p75" (Get-Percentile -Values $values -P 0.75) ""
        }
    }

    foreach ($q in 1..4) {
        $qData = @($eligible | Where-Object { $_.combined_burden_quartile -eq [string]$q })
        Add-MetricRow $rows $Database "quartile" "q${q}_n" $qData.Count "eligible 24h cohort only"
        Add-MetricRow $rows $Database "quartile" "q${q}_icu_deaths_n" (($qData | Where-Object { $_.death_icu -eq "1" }).Count) ""
        if ($qData.Count -gt 0) {
            $deathPct = [math]::Round(100 * (($qData | Where-Object { $_.death_icu -eq "1" }).Count) / $qData.Count, 2)
            Add-MetricRow $rows $Database "quartile" "q${q}_icu_death_pct" $deathPct ""
        } else {
            Add-MetricRow $rows $Database "quartile" "q${q}_icu_death_pct" "" ""
        }
    }

    return $rows
}

$eicuSql = Join-Path $projectRoot "02_code\sql\burden\01_eicu_burden_24h.sql"
$mimicSql = Join-Path $projectRoot "02_code\sql\burden\01_mimic_burden_24h.sql"

$eicuOut = Join-Path $runDir "eicu_burden_24h.csv"
$mimicOut = Join-Path $runDir "mimic_burden_24h.csv"
$summaryOut = Join-Path $runDir "burden_24h_summary.csv"
$eicuLog = Join-Path $logRoot "${RunId}_eicu_burden_24h.log"
$mimicLog = Join-Path $logRoot "${RunId}_mimic_burden_24h.log"

Invoke-BurdenSql -Database "eicu" -SqlFile $eicuSql -OutputFile $eicuOut -LogFile $eicuLog
Invoke-BurdenSql -Database "mimic" -SqlFile $mimicSql -OutputFile $mimicOut -LogFile $mimicLog

$summaryRows = [System.Collections.Generic.List[object]]::new()
foreach ($row in (Summarize-BurdenCsv -Database "eICU" -CsvPath $eicuOut)) { $summaryRows.Add($row) }
foreach ($row in (Summarize-BurdenCsv -Database "MIMIC-IV" -CsvPath $mimicOut)) { $summaryRows.Add($row) }
$summaryRows | Export-Csv -LiteralPath $summaryOut -NoTypeInformation -Encoding UTF8

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
    "summary_output=$summaryOut",
    "eicu_log=$eicuLog",
    "mimic_log=$mimicLog",
    "definition=24h time-weighted average burden: MAP<65 and SpO2<90 deficit area divided by effective observed time.",
    "eligibility=main flag requires MAP and SpO2 effective observation each >= 720 minutes.",
    "note=Patient-level deidentified stay IDs retained locally for analysis; public outputs should use aggregate summaries only."
) | Set-Content -LiteralPath $manifest -Encoding UTF8

Write-Host "Burden extraction completed."
Write-Host "Run directory: $runDir"
Write-Host "eICU table: $eicuOut"
Write-Host "MIMIC table: $mimicOut"
Write-Host "Summary: $summaryOut"



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
    $clean = @($Values | Where-Object { $null -ne $_ -and -not [double]::IsNaN($_) } | Sort-Object)
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

function Get-GcsValue {
    param([object]$Row)
    if ($Row.PSObject.Properties.Name -contains "apache_gcs") {
        return Get-Number $Row.apache_gcs
    }
    return Get-Number $Row.gcs_min
}

function Add-Interaction {
    param([object[]]$Rows)
    foreach ($row in $Rows) {
        $hypotension = Get-Number $row.hypotension_twa
        $hypoxemia = Get-Number $row.hypoxemia_twa
        $interaction = ""
        if ($null -ne $hypotension -and $null -ne $hypoxemia) {
            $interaction = [math]::Round($hypotension * $hypoxemia, 8)
        }
        $row | Add-Member -NotePropertyName "hypotension_hypoxemia_interaction" -NotePropertyValue $interaction -Force
    }
}

function New-ComparisonRows {
    param(
        [string]$Database,
        [string]$Section,
        [string]$GroupName,
        [object[]]$Rows
    )

    $n = $Rows.Count
    $icuDeaths = (@($Rows | Where-Object { $_.death_icu -eq "1" })).Count
    $hospitalDeaths = (@($Rows | Where-Object { $_.death_hospital -eq "1" })).Count
    $gcsValues = @($Rows | ForEach-Object { Get-GcsValue $_ } | Where-Object { $null -ne $_ })
    $windowHours = @($Rows | ForEach-Object {
        $v = Get-Number $_.window_end_min
        if ($null -ne $v) { $v / 60.0 }
    } | Where-Object { $null -ne $_ })
    $hypotensionValues = @($Rows | ForEach-Object { Get-Number $_.hypotension_twa } | Where-Object { $null -ne $_ })
    $hypoxemiaValues = @($Rows | ForEach-Object { Get-Number $_.hypoxemia_twa } | Where-Object { $null -ne $_ })

    return [pscustomobject]@{
        database_name          = $Database
        section                = $Section
        group                  = $GroupName
        n                      = $n
        icu_deaths_n           = $icuDeaths
        icu_death_pct          = if ($n -gt 0) { [math]::Round(100 * $icuDeaths / $n, 2) } else { "" }
        hospital_deaths_n      = $hospitalDeaths
        hospital_death_pct     = if ($n -gt 0) { [math]::Round(100 * $hospitalDeaths / $n, 2) } else { "" }
        gcs_p25                = Get-Percentile -Values $gcsValues -P 0.25
        gcs_median             = Get-Percentile -Values $gcsValues -P 0.50
        gcs_p75                = Get-Percentile -Values $gcsValues -P 0.75
        window_hours_median    = Get-Percentile -Values $windowHours -P 0.50
        hypotension_twa_median = Get-Percentile -Values $hypotensionValues -P 0.50
        hypoxemia_twa_median   = Get-Percentile -Values $hypoxemiaValues -P 0.50
    }
}

function New-QuartileSummary {
    param(
        [string]$Database,
        [string]$Variable,
        [object[]]$Rows
    )

    $valid = @($Rows | Where-Object {
        $v = Get-Number $_.$Variable
        $null -ne $v
    } | Sort-Object { Get-Number $_.$Variable })

    $out = [System.Collections.Generic.List[object]]::new()
    $n = $valid.Count
    if ($n -lt 8) { return $out }

    $qSize = [math]::Floor($n / 4)
    $q1 = @($valid[0..($qSize - 1)])
    $q4 = @($valid[($n - $qSize)..($n - 1)])

    foreach ($qSpec in @(
        @{ Quartile = 1; Data = $q1 },
        @{ Quartile = 4; Data = $q4 }
    )) {
        $qRows = @($qSpec.Data)
        $deaths = (@($qRows | Where-Object { $_.death_icu -eq "1" })).Count
        $values = @($qRows | ForEach-Object { Get-Number $_.$Variable } | Where-Object { $null -ne $_ })
        $out.Add([pscustomobject]@{
            database_name = $Database
            variable      = $Variable
            quartile      = "Q$($qSpec.Quartile)"
            n             = $qRows.Count
            icu_deaths_n  = $deaths
            icu_death_pct = if ($qRows.Count -gt 0) { [math]::Round(100 * $deaths / $qRows.Count, 2) } else { "" }
            value_min     = Get-Percentile -Values $values -P 0.00
            value_median  = Get-Percentile -Values $values -P 0.50
            value_max     = Get-Percentile -Values $values -P 1.00
        })
    }

    $a = (@($q4 | Where-Object { $_.death_icu -eq "1" })).Count
    $b = $q4.Count - $a
    $c = (@($q1 | Where-Object { $_.death_icu -eq "1" })).Count
    $d = $q1.Count - $c
    $or = ""
    $ci = ""
    if (($a * $b * $c * $d) -gt 0) {
        $orVal = ($a * $d) / ($b * $c)
        $se = [math]::Sqrt((1 / $a) + (1 / $b) + (1 / $c) + (1 / $d))
        $lo = [math]::Exp([math]::Log($orVal) - 1.96 * $se)
        $hi = [math]::Exp([math]::Log($orVal) + 1.96 * $se)
        $or = [math]::Round($orVal, 3)
        $ci = "$([math]::Round($lo, 3))-$([math]::Round($hi, 3))"
    }

    $out.Add([pscustomobject]@{
        database_name = $Database
        variable      = $Variable
        quartile      = "Q4_vs_Q1"
        n             = "$($q4.Count) vs $($q1.Count)"
        icu_deaths_n  = "$a vs $c"
        icu_death_pct = $or
        value_min     = "crude_or"
        value_median  = $ci
        value_max     = "95pct_ci"
    })

    return $out
}

function Export-V2Products {
    param(
        [string]$Database,
        [string]$RawCsv,
        [string]$Prefix,
        [string]$RunDir,
        [System.Collections.Generic.List[object]]$SummaryRows,
        [System.Collections.Generic.List[object]]$ComparisonRows,
        [System.Collections.Generic.List[object]]$QuartileRows
    )

    $data = @(Import-Csv -LiteralPath $RawCsv)
    Add-Interaction -Rows $data

    $coverageEligible = @($data | Where-Object { $_.eligible_24h_12h_coverage -eq "1" })
    $coverageExcluded = @($data | Where-Object { $_.eligible_24h_12h_coverage -ne "1" })
    $landmark = @($data | Where-Object { $_.survived_or_remained_icu_24h -eq "1" })
    $landmarkMain = @($landmark | Where-Object { $_.eligible_24h_12h_coverage -eq "1" })
    $earlyExitOrDeath = @($data | Where-Object { $_.survived_or_remained_icu_24h -ne "1" })
    $landmarkCoverageExcluded = @($landmark | Where-Object { $_.eligible_24h_12h_coverage -ne "1" })

    $mainOut = Join-Path $RunDir "${Prefix}_burden_24h_landmark_main.csv"
    $truncatedOut = Join-Path $RunDir "${Prefix}_burden_24h_truncated_sensitivity.csv"
    $sourceOut = Join-Path $RunDir "${Prefix}_burden_24h_all_source.csv"

    $data | Export-Csv -LiteralPath $sourceOut -NoTypeInformation -Encoding UTF8
    $landmarkMain | Export-Csv -LiteralPath $mainOut -NoTypeInformation -Encoding UTF8
    $coverageEligible | Export-Csv -LiteralPath $truncatedOut -NoTypeInformation -Encoding UTF8

    Add-MetricRow $SummaryRows $Database "cohort" "primary_cohort_n" $data.Count "strict intracranial TBI, GCS <= 8"
    Add-MetricRow $SummaryRows $Database "cohort" "icu_deaths_overall_n" (@($data | Where-Object { $_.death_icu -eq "1" })).Count ""
    Add-MetricRow $SummaryRows $Database "coverage" "coverage_eligible_n" $coverageEligible.Count "MAP and SpO2 effective observation each >= 12h"
    Add-MetricRow $SummaryRows $Database "coverage" "coverage_excluded_n" $coverageExcluded.Count ""
    Add-MetricRow $SummaryRows $Database "landmark" "survived_or_remained_icu_24h_n" $landmark.Count "eligible for 24h landmark before coverage gate"
    Add-MetricRow $SummaryRows $Database "landmark" "landmark_main_n" $landmarkMain.Count "24h landmark plus 12h MAP/SpO2 coverage"
    Add-MetricRow $SummaryRows $Database "landmark" "landmark_main_icu_deaths_n" (@($landmarkMain | Where-Object { $_.death_icu -eq "1" })).Count ""
    Add-MetricRow $SummaryRows $Database "landmark" "early_exit_or_death_before_24h_n" $earlyExitOrDeath.Count "excluded from main landmark analysis"
    Add-MetricRow $SummaryRows $Database "landmark" "early_exit_or_death_before_24h_icu_deaths_n" (@($earlyExitOrDeath | Where-Object { $_.death_icu -eq "1" })).Count ""
    Add-MetricRow $SummaryRows $Database "landmark" "landmark_coverage_excluded_n" $landmarkCoverageExcluded.Count "survived/remained 24h but failed 12h coverage gate"

    foreach ($row in @(
        (New-ComparisonRows -Database $Database -Section "coverage_gate" -GroupName "coverage_eligible" -Rows $coverageEligible),
        (New-ComparisonRows -Database $Database -Section "coverage_gate" -GroupName "coverage_excluded" -Rows $coverageExcluded),
        (New-ComparisonRows -Database $Database -Section "landmark_gate" -GroupName "landmark_main" -Rows $landmarkMain),
        (New-ComparisonRows -Database $Database -Section "landmark_gate" -GroupName "early_exit_or_death_before_24h" -Rows $earlyExitOrDeath),
        (New-ComparisonRows -Database $Database -Section "landmark_gate" -GroupName "landmark_coverage_excluded" -Rows $landmarkCoverageExcluded)
    )) {
        $ComparisonRows.Add($row)
    }

    foreach ($variable in @("hypotension_twa", "hypoxemia_twa", "hypotension_hypoxemia_interaction", "combined_burden_z")) {
        foreach ($row in (New-QuartileSummary -Database $Database -Variable $variable -Rows $landmarkMain)) {
            $QuartileRows.Add($row)
        }
    }

    return [pscustomobject]@{
        source_out      = $sourceOut
        main_out        = $mainOut
        sensitivity_out = $truncatedOut
    }
}

$eicuSql = Join-Path $projectRoot "02_code\sql\burden\01_eicu_burden_24h.sql"
$mimicSql = Join-Path $projectRoot "02_code\sql\burden\01_mimic_burden_24h.sql"

$eicuRaw = Join-Path $runDir "eicu_burden_24h_raw_from_sql.csv"
$mimicRaw = Join-Path $runDir "mimic_burden_24h_raw_from_sql.csv"
$summaryOut = Join-Path $runDir "burden_v2_summary.csv"
$comparisonOut = Join-Path $runDir "burden_v2_exclusion_comparison.csv"
$quartileOut = Join-Path $runDir "burden_v2_landmark_quartile_signal.csv"
$methodsOut = Join-Path $runDir "burden_v2_methods_note.md"
$eicuLog = Join-Path $logRoot "${RunId}_eicu_burden_v2.log"
$mimicLog = Join-Path $logRoot "${RunId}_mimic_burden_v2.log"

Invoke-BurdenSql -Database "eicu" -SqlFile $eicuSql -OutputFile $eicuRaw -LogFile $eicuLog
Invoke-BurdenSql -Database "mimic" -SqlFile $mimicSql -OutputFile $mimicRaw -LogFile $mimicLog

$summaryRows = [System.Collections.Generic.List[object]]::new()
$comparisonRows = [System.Collections.Generic.List[object]]::new()
$quartileRows = [System.Collections.Generic.List[object]]::new()

$eicuProducts = Export-V2Products -Database "eICU" -RawCsv $eicuRaw -Prefix "eicu" -RunDir $runDir -SummaryRows $summaryRows -ComparisonRows $comparisonRows -QuartileRows $quartileRows
$mimicProducts = Export-V2Products -Database "MIMIC-IV" -RawCsv $mimicRaw -Prefix "mimic" -RunDir $runDir -SummaryRows $summaryRows -ComparisonRows $comparisonRows -QuartileRows $quartileRows

$summaryRows | Export-Csv -LiteralPath $summaryOut -NoTypeInformation -Encoding UTF8
$comparisonRows | Export-Csv -LiteralPath $comparisonOut -NoTypeInformation -Encoding UTF8
$quartileRows | Export-Csv -LiteralPath $quartileOut -NoTypeInformation -Encoding UTF8

@(
    "# Burden V2 Methods Note",
    "",
    "Run ID: $RunId",
    "",
    "Primary analysis set:",
    "",
    "- 24h landmark analysis.",
    "- Include only stays alive and still in ICU or observed through the first 24h.",
    "- Require MAP and SpO2 effective observation time each >= 12h.",
    "",
    "Primary exposure variables:",
    "",
    "- hypotension_twa: time-weighted average MAP deficit below 65 mmHg.",
    "- hypoxemia_twa: time-weighted average SpO2 deficit below 90%.",
    "- hypotension_hypoxemia_interaction: product of the two raw TWA burdens; planned as interaction term, not a standalone burden score.",
    "",
    "Sensitivity analyses:",
    "",
    "- Truncated 0-24h window including early ICU death or early ICU exit.",
    "- combined_burden_z retained only as a secondary/sensitivity summary index.",
    "",
    "Output files:",
    "",
    "- eICU main: $($eicuProducts.main_out)",
    "- MIMIC-IV main: $($mimicProducts.main_out)",
    "- eICU truncated sensitivity: $($eicuProducts.sensitivity_out)",
    "- MIMIC-IV truncated sensitivity: $($mimicProducts.sensitivity_out)",
    "- Exclusion comparison: $comparisonOut",
    "- Landmark crude quartile signal: $quartileOut"
) | Set-Content -LiteralPath $methodsOut -Encoding UTF8

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
    "eicu_raw_sql_output=$eicuRaw",
    "mimic_raw_sql_output=$mimicRaw",
    "eicu_landmark_main=$($eicuProducts.main_out)",
    "mimic_landmark_main=$($mimicProducts.main_out)",
    "eicu_truncated_sensitivity=$($eicuProducts.sensitivity_out)",
    "mimic_truncated_sensitivity=$($mimicProducts.sensitivity_out)",
    "summary_output=$summaryOut",
    "comparison_output=$comparisonOut",
    "quartile_output=$quartileOut",
    "methods_note=$methodsOut",
    "eicu_log=$eicuLog",
    "mimic_log=$mimicLog",
    "definition_v2=Primary analysis uses 24h landmark; primary exposures are raw hypotension_twa and hypoxemia_twa plus interaction.",
    "sensitivity=Truncated-window all coverage-eligible table and combined_burden_z retained only for sensitivity."
) | Set-Content -LiteralPath $manifest -Encoding UTF8

Write-Host "Burden V2 completed."
Write-Host "Run directory: $runDir"
Write-Host "Summary: $summaryOut"
Write-Host "Exclusion comparison: $comparisonOut"
Write-Host "Quartile signal: $quartileOut"



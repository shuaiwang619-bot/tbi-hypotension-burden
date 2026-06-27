param(
    [string]$PsqlPath = "psql",
    [string]$HostName = "127.0.0.1",
    [int]$Port = 5432,
    [string]$UserName = "postgres",
    [string]$BurdenRunId = "20260620_burden24h_v2",
    [string]$RunId = (Get-Date -Format "yyyyMMdd_HHmmss")
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$outputRoot = Join-Path $projectRoot "03_outputs\tables\covariates"
$logRoot = Join-Path $projectRoot "03_outputs\logs"
$runDir = Join-Path $outputRoot $RunId
$burdenDir = Join-Path $projectRoot "03_outputs\tables\burden\$BurdenRunId"

New-Item -ItemType Directory -Path $runDir -Force | Out-Null
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

if (-not (Get-Command $PsqlPath -ErrorAction SilentlyContinue)) {
    throw "psql executable not found or not on PATH: $PsqlPath"
}

if (-not $env:PGPASSWORD) {
    throw "PGPASSWORD is not set. Set it in the current PowerShell session before running this script."
}

function Invoke-CovariateSql {
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

function Merge-Covariates {
    param(
        [string]$Database,
        [string]$KeyColumn,
        [string]$BurdenCsv,
        [string]$CovariateCsv,
        [string]$OutputCsv
    )

    $burden = @(Import-Csv -LiteralPath $BurdenCsv)
    $covars = @(Import-Csv -LiteralPath $CovariateCsv)
    $covarMap = @{}
    foreach ($row in $covars) {
        $covarMap[[string]$row.$KeyColumn] = $row
    }

    $covarColumns = @()
    if ($covars.Count -gt 0) {
        $covarColumns = @($covars[0].PSObject.Properties.Name | Where-Object {
            $_ -notin @("database_name", "patientunitstayid", "patienthealthsystemstayid", "subject_id", "hadm_id", "stay_id", "death_icu", "death_hospital")
        })
    }

    foreach ($row in $burden) {
        $key = [string]$row.$KeyColumn
        $covar = $covarMap[$key]
        foreach ($col in $covarColumns) {
            $value = ""
            if ($null -ne $covar) {
                $value = $covar.$col
            }
            $row | Add-Member -NotePropertyName $col -NotePropertyValue $value -Force
        }
        $row | Add-Member -NotePropertyName "covariate_row_found" -NotePropertyValue $(if ($null -ne $covar) { "1" } else { "0" }) -Force
    }

    $burden | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
}

function Add-MissingnessRows {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [string]$Database,
        [string]$CsvPath
    )

    $data = @(Import-Csv -LiteralPath $CsvPath)
    $n = $data.Count
    if ($n -eq 0) { return }

    $exclude = @(
        "database_name", "stay_key", "patientunitstayid", "patienthealthsystemstayid",
        "subject_id", "hadm_id", "stay_id"
    )

    foreach ($col in $data[0].PSObject.Properties.Name) {
        if ($exclude -contains $col) { continue }
        $missing = (@($data | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.$col) })).Count
        $Rows.Add([pscustomobject]@{
            database_name = $Database
            variable      = $col
            n             = $n
            missing_n     = $missing
            missing_pct   = [math]::Round(100 * $missing / [math]::Max($n, 1), 2)
            nonmissing_n  = $n - $missing
        })
    }
}

$eicuSql = Join-Path $projectRoot "02_code\sql\covariates\01_eicu_covariates_v1.sql"
$mimicSql = Join-Path $projectRoot "02_code\sql\covariates\01_mimic_covariates_v1.sql"

$eicuCovariatesRaw = Join-Path $runDir "eicu_covariates_v1_all_strict_severe.csv"
$mimicCovariatesRaw = Join-Path $runDir "mimic_covariates_v1_all_strict_severe.csv"
$eicuAnalysis = Join-Path $runDir "eicu_analysis_covariates_v1_landmark_main.csv"
$mimicAnalysis = Join-Path $runDir "mimic_analysis_covariates_v1_landmark_main.csv"
$missingnessOut = Join-Path $runDir "covariates_v1_missingness_landmark_main.csv"
$variableMapOut = Join-Path $runDir "covariates_v1_variable_map.md"
$binarySummaryOut = Join-Path $runDir "covariates_v2_baseline_binary_summary.csv"
$eicuLog = Join-Path $logRoot "${RunId}_eicu_covariates_v1.log"
$mimicLog = Join-Path $logRoot "${RunId}_mimic_covariates_v1.log"

$eicuBurdenMain = Join-Path $burdenDir "eicu_burden_24h_landmark_main.csv"
$mimicBurdenMain = Join-Path $burdenDir "mimic_burden_24h_landmark_main.csv"
if (-not (Test-Path -LiteralPath $eicuBurdenMain)) { throw "Missing eICU burden main table: $eicuBurdenMain" }
if (-not (Test-Path -LiteralPath $mimicBurdenMain)) { throw "Missing MIMIC burden main table: $mimicBurdenMain" }

Invoke-CovariateSql -Database "eicu" -SqlFile $eicuSql -OutputFile $eicuCovariatesRaw -LogFile $eicuLog
Invoke-CovariateSql -Database "mimic" -SqlFile $mimicSql -OutputFile $mimicCovariatesRaw -LogFile $mimicLog

Merge-Covariates -Database "eICU" -KeyColumn "patientunitstayid" -BurdenCsv $eicuBurdenMain -CovariateCsv $eicuCovariatesRaw -OutputCsv $eicuAnalysis
Merge-Covariates -Database "MIMIC-IV" -KeyColumn "stay_id" -BurdenCsv $mimicBurdenMain -CovariateCsv $mimicCovariatesRaw -OutputCsv $mimicAnalysis

$missingRows = [System.Collections.Generic.List[object]]::new()
Add-MissingnessRows -Rows $missingRows -Database "eICU" -CsvPath $eicuAnalysis
Add-MissingnessRows -Rows $missingRows -Database "MIMIC-IV" -CsvPath $mimicAnalysis
$missingRows | Sort-Object database_name, missing_pct, variable -Descending:$false | Export-Csv -LiteralPath $missingnessOut -NoTypeInformation -Encoding UTF8

$binaryVariables = @(
    "sex_male",
    "tbi_subdural",
    "tbi_subarachnoid",
    "tbi_epidural",
    "tbi_intracerebral_hemorrhage",
    "tbi_contusion_or_laceration",
    "tbi_diffuse_axonal_injury",
    "tbi_herniation",
    "tbi_edema",
    "mechanical_vent_baseline_proxy",
    "mechanical_vent_entry_1h_proxy",
    "respiratorycare_vent_at_entry",
    "respiratorycare_vent_entry_1h_window",
    "mechanical_vent_at_icu_entry",
    "mechanical_vent_entry_1h_window",
    "mechanical_vent_24h",
    "vasopressor_prior_or_at_entry_6h",
    "vasopressor_at_icu_entry",
    "vasopressor_entry_1h_window",
    "vasopressor_24h",
    "hx_congestive_heart_failure",
    "hx_diabetes",
    "hx_chronic_pulmonary_disease",
    "hx_renal_disease",
    "hx_liver_disease",
    "hx_malignancy",
    "hx_cerebrovascular_disease"
)

$binaryRows = [System.Collections.Generic.List[object]]::new()
foreach ($dataset in @(
        @{ Name = "eICU"; Path = $eicuAnalysis },
        @{ Name = "MIMIC-IV"; Path = $mimicAnalysis }
    )) {
    $data = @(Import-Csv -LiteralPath $dataset.Path)
    $n = $data.Count
    if ($n -eq 0) { continue }

    foreach ($variable in $binaryVariables) {
        if ($data[0].PSObject.Properties.Name -notcontains $variable) { continue }
        $yes = (@($data | Where-Object { [string]$_.$variable -eq "1" })).Count
        $missing = (@($data | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.$variable) })).Count
        $binaryRows.Add([pscustomobject]@{
            database_name = $dataset.Name
            variable      = $variable
            n             = $n
            yes_n         = $yes
            yes_pct       = [math]::Round(100 * $yes / [math]::Max($n, 1), 1)
            missing_n     = $missing
            missing_pct   = [math]::Round(100 * $missing / [math]::Max($n, 1), 1)
        })
    }
}
$binaryRows | Sort-Object database_name, variable | Export-Csv -LiteralPath $binarySummaryOut -NoTypeInformation -Encoding UTF8

@(
    "# Covariates V2 Baseline Variable Map",
    "",
    "Run ID: $RunId",
    "",
    "Analysis source:",
    "",
    "- Burden V2 landmark main set: $BurdenRunId.",
    "- eICU main N and MIMIC-IV main N are inherited from burden V2 landmark tables.",
    "",
    "Main-model cross-database covariate candidates:",
    "",
    "- Age and sex.",
    "- GCS total score. Component scores are extracted for description/QC, not as a parallel main-model severity block unless prespecified.",
    "- TBI phenotype flags: subdural, subarachnoid, epidural, intracerebral hemorrhage, contusion/laceration, diffuse axonal injury, edema. eICU also has a herniation string flag; MIMIC-IV herniation is currently set to 0 because this v1 ICD map does not extract it cleanly.",
    "- Comorbidity flags: heart failure, diabetes, chronic pulmonary disease, renal disease, liver disease, malignancy, cerebrovascular disease.",
    "- Baseline/ICU-entry treatment proxies can be considered only after review: eICU respiratorycare ventilation at entry or +/-1h; MIMIC-IV mechanical ventilation at ICU entry or +/-1h; vasopressor at entry or +/-1h. Sparse baseline vasopressor should likely be descriptive/sensitivity-only if unstable.",
    "",
    "Variables extracted but not for the primary adjustment model:",
    "",
    "- Mechanical ventilation in the first 24h and vasopressor/inotrope exposure in the first 24h are extracted for sensitivity/descriptive analyses only because they overlap the 0-24h burden exposure window and may be treatment/mediator variables.",
    "- First-day labs: lactate max, hemoglobin min, WBC max, creatinine max, sodium min/max, glucose max, platelet min, INR max, PT max, PTT max. High-missing/selectively ordered variables, especially lactate and coagulation, are not main-model covariates unless a later sensitivity plan justifies imputation/subset use.",
    "",
    "Database-specific descriptive severity variables:",
    "",
    "- eICU: acute physiology score, APACHE score, predicted ICU/hospital mortality.",
    "- MIMIC-IV: APS III, first-day SOFA, SAPS II.",
    "",
    "Important caution:",
    "",
    "- First-day ventilation and vasopressors overlap the 0-24h burden window and must not enter the primary adjustment model.",
    "- Baseline/entry treatment status definitions differ by database. eICU APACHE intubated/vent flags may be first-day style rather than pure ICU-entry fields, so stricter respiratorycare entry fields are reported separately.",
    "- MIMIC-IV strict ICU-entry vasopressor is extremely sparse in this landmark cohort; avoid forcing it into a multivariable model if it is unstable.",
    "- eICU comorbidity flags come from pasthistory strings; absence of a string is coded as 0 in this extraction but should be reviewed before final modeling.",
    "- Lab variables with >20% missingness require a second rescue/review pass before final model use."
) | Set-Content -LiteralPath $variableMapOut -Encoding UTF8

$manifest = Join-Path $runDir "manifest.txt"
@(
    "run_id=$RunId",
    "run_time=$(Get-Date -Format s)",
    "project_root=$projectRoot",
    "burden_run_id=$BurdenRunId",
    "eicu_sql=$eicuSql",
    "mimic_sql=$mimicSql",
    "eicu_covariates_raw=$eicuCovariatesRaw",
    "mimic_covariates_raw=$mimicCovariatesRaw",
    "eicu_analysis_table=$eicuAnalysis",
    "mimic_analysis_table=$mimicAnalysis",
    "missingness_output=$missingnessOut",
    "binary_summary_output=$binarySummaryOut",
    "variable_map=$variableMapOut",
    "eicu_log=$eicuLog",
    "mimic_log=$mimicLog"
) | Set-Content -LiteralPath $manifest -Encoding UTF8

Write-Host "Covariates V1 completed."
Write-Host "Run directory: $runDir"
Write-Host "eICU analysis table: $eicuAnalysis"
Write-Host "MIMIC analysis table: $mimicAnalysis"
Write-Host "Missingness: $missingnessOut"
Write-Host "Binary summary: $binarySummaryOut"



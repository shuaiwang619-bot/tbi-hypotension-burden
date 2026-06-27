# Reproduction Guide

This repository supports two levels of reuse.

## Level 1: Inspect Published Aggregate Results

No database access is needed. Open:

```text
results/tables/
results/figures/
docs/FINAL_DECISION_NOTE.md
docs/FINAL_ARTIFACT_QA_SUMMARY.md
```

## Level 2: Rerun The Analysis Locally

Full reproduction requires:

- Python 3.10 or newer
- PostgreSQL client tools with `psql` on PATH
- Local PostgreSQL databases containing eICU and MIMIC-IV
- Database access credentials set outside the repository

Install Python dependencies:

```powershell
python -m pip install -r requirements.txt
```

Set the database password in the current PowerShell session:

```powershell
$env:PGPASSWORD = "your_local_database_password"
```

Run the frozen analysis sequence:

```powershell
powershell -ExecutionPolicy Bypass -File 02_code/run_cohort_extraction.ps1 -RunId 20260620_icuoutcome_fix
powershell -ExecutionPolicy Bypass -File 02_code/run_exposure_qc.ps1 -RunId 20260620_exposure_qc_v1
powershell -ExecutionPolicy Bypass -File 02_code/run_burden_v2.ps1 -RunId 20260620_burden24h_v2
powershell -ExecutionPolicy Bypass -File 02_code/run_covariates_v1.ps1 -BurdenRunId 20260620_burden24h_v2 -RunId 20260620_covariates_v2_baseline
powershell -ExecutionPolicy Bypass -File 02_code/run_final_dataset_qc.ps1
powershell -ExecutionPolicy Bypass -File 02_code/run_adjusted_model_v1.ps1
powershell -ExecutionPolicy Bypass -File 02_code/run_adjusted_model_v2_interaction.ps1
powershell -ExecutionPolicy Bypass -File 02_code/run_adjusted_model_v3b_hypotension_rcs_limited.ps1
powershell -ExecutionPolicy Bypass -File 02_code/run_analysis_closure_sensitivity_v1.ps1
python 02_code/python/final_manuscript_artifacts_v1.py
```

By default, the runners use:

```text
HostName = 127.0.0.1
Port = 5432
UserName = postgres
PsqlPath = psql
PythonPath = python
```

Override these parameters as needed for your local environment.

## Output Convention

Recreated intermediate outputs are written to `03_outputs/`. That directory is intentionally ignored by Git because it can contain row-level derived data and local rendering cache files. Curate only aggregate tables and figures before public release.

## Known Design Constraints

- The primary design is a 24-hour landmark logistic model, not a time-to-event Cox model.
- MIMIC-IV is used for locked-coefficient external validation; the full model is not refit in MIMIC-IV because the validation event count is small.
- Hypoxemia analyses are prespecified secondary/sensitivity analyses because hypoxemia burden is heavily zero-inflated.
- Spline-derived values should be treated as exploratory shape information, not clinical cutoffs.


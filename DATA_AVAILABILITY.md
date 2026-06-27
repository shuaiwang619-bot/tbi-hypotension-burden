# Data Availability

This repository does not include patient-level data from eICU or MIMIC-IV.

Both source databases require credentialed access and separate data-use agreements. Users who want to reproduce the cohort extraction and primary analyses must obtain authorized access to the relevant databases and load them into a local PostgreSQL environment.

## Included

- Aggregate manuscript tables in `results/tables/`
- Publication-ready figures in `results/figures/`
- SQL scripts used to define cohorts, exposures, burden measures, and covariates
- Python scripts used for modeling, QC, sensitivity analyses, and figure/table generation

## Not Included

- Raw eICU or MIMIC-IV tables
- Patient-level or stay-level analytic CSV files
- Database credentials
- Local database dumps
- Temporary rendering profiles or QA cache directories

## Expected Local Inputs For Full Reproduction

The analysis scripts expect derived analytic CSV files under:

```text
03_outputs/tables/covariates/20260620_covariates_v2_baseline/
```

These files are generated locally from credentialed databases by the SQL and PowerShell runners. They are not redistributed because they contain row-level data.


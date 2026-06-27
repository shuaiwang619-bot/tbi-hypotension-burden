# Codebook

## Core Identifiers

Patient-level identifiers are not included in the public results. The local extraction scripts use database-specific ICU stay identifiers only during private reproduction.

## Cohort Variables

| Variable | Meaning |
|---|---|
| `database_name` | Source database, eICU or MIMIC-IV |
| `age` | Age at ICU admission |
| `sex_male` | Male sex indicator |
| `gcs_total` | Total Glasgow Coma Scale score used for severe TBI definition |
| `death_icu` | ICU mortality after the 24-hour landmark |
| `death_hospital` | Hospital mortality |

## Exposure Variables

| Variable | Meaning |
|---|---|
| `hypotension_twa` | Time-weighted average MAP deficit below 65 mmHg during ICU hours 0-24 |
| `hypoxemia_twa` | Time-weighted average SpO2 deficit below 90 percent during ICU hours 0-24 |
| `map_effective_minutes` | Effective MAP observation time within the first 24 hours |
| `spo2_effective_minutes` | Effective SpO2 observation time within the first 24 hours |

## Model Variables

| Variable | Meaning |
|---|---|
| `hypotension_twa_per_sd` | `hypotension_twa` standardized by the eICU derivation-set SD |
| `hypoxemia_twa_per_sd` | `hypoxemia_twa` standardized by the eICU derivation-set SD |
| `age_per_10y` | Age centered and scaled per 10 years |
| `gcs_per_point` | GCS centered per 1-point increase |

## Main Model

```text
death_icu ~ hypotension_twa_per_sd + hypoxemia_twa_per_sd + age_per_10y + sex_male + gcs_per_point
```

The model is fitted in eICU. Locked eICU coefficients are then applied to MIMIC-IV for external validation.


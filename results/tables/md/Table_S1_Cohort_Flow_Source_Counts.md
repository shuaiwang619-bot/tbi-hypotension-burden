# Table S1 Cohort Flow Source Counts

| Database | Step | N | ICU deaths | ICU mortality, % | Notes |
| --- | --- | --- | --- | --- | --- |
| eICU | adult first ICU unit stays | 165,795 | 9,094 | 5.5 | adult, first ICU unit stay by largest hospitaladmitoffset; death = ICU unit discharge death |
| eICU | strict intracranial TBI diagnosis | 4,202 | 327 | 7.8 | diagnosisstring contains intracranial injury or traumatic subdural hematoma |
| eICU | strict TBI + APACHE GCS available | 4,060 | 321 | 7.9 | valid eyes, motor, and verbal components |
| eICU | strict TBI + GCS <= 8 | 989 | 263 | 26.6 | primary severe TBI definition |
| eICU | strict TBI + GCS <= 12 | 1,464 | 288 | 19.7 | prespecified sensitivity definition |
| MIMIC-IV | adult first ICU stays | 85,242 | 6,226 | 7.3 | adult, first ICU stay within hospitalization; death = ICU mortality |
| MIMIC-IV | strict TBI diagnosis | 3,202 | 262 | 8.2 | ICD-9 850-854 or ICD-10 S06% |
| MIMIC-IV | strict TBI + first-day GCS available | 3,193 | 257 | 8.0 | mimiciv_derived.first_day_gcs |
| MIMIC-IV | strict TBI + GCS <= 8 | 223 | 39 | 17.5 | primary severe TBI definition |
| MIMIC-IV | strict TBI + GCS <= 12 | 672 | 56 | 8.3 | prespecified sensitivity definition |

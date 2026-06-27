-- MIMIC-IV cohort flow for severe intracranial TBI.
-- Output level: aggregate counts only, no patient-level export.
-- Index time: mimiciv_icu.icustays.intime.
-- Primary population: adult first ICU stay within hospitalization, strict intracranial TBI, first-day GCS <= 8.
-- Primary outcome for harmonization with eICU: ICU mortality.
-- Hospital mortality is retained as an audit row for comparison with the previous extraction.

WITH icu_base AS MATERIALIZED (
    SELECT
        i.subject_id,
        i.hadm_id,
        i.stay_id,
        i.intime,
        i.outtime,
        a.deathtime,
        a.hospital_expire_flag,
        (p.anchor_age + EXTRACT(YEAR FROM i.intime)::int - p.anchor_year) AS age_num,
        ROW_NUMBER() OVER (
            PARTITION BY i.hadm_id
            ORDER BY i.intime
        ) AS rn_icu_hadm
    FROM mimiciv_icu.icustays i
    JOIN mimiciv_hosp.admissions a
      ON a.hadm_id = i.hadm_id
    JOIN mimiciv_hosp.patients p
      ON p.subject_id = i.subject_id
),
adult AS MATERIALIZED (
    SELECT *
    FROM icu_base
    WHERE age_num >= 18
      AND rn_icu_hadm = 1
),
dx_flags AS MATERIALIZED (
    SELECT
        d.hadm_id,
        MAX(
            CASE
                WHEN (d.icd_version = 9 AND (
                        d.icd_code LIKE '850%' OR
                        d.icd_code LIKE '851%' OR
                        d.icd_code LIKE '852%' OR
                        d.icd_code LIKE '853%' OR
                        d.icd_code LIKE '854%'
                    ))
                  OR (d.icd_version = 10 AND d.icd_code LIKE 'S06%')
                THEN 1 ELSE 0
            END
        ) AS strict_tbi_dx,
        MAX(
            CASE
                WHEN (d.icd_version = 9 AND (
                        d.icd_code LIKE '800%' OR
                        d.icd_code LIKE '801%' OR
                        d.icd_code LIKE '802%' OR
                        d.icd_code LIKE '803%' OR
                        d.icd_code LIKE '804%' OR
                        d.icd_code LIKE '850%' OR
                        d.icd_code LIKE '851%' OR
                        d.icd_code LIKE '852%' OR
                        d.icd_code LIKE '853%' OR
                        d.icd_code LIKE '854%' OR
                        d.icd_code = '95901'
                    ))
                  OR (d.icd_version = 10 AND (
                        d.icd_code LIKE 'S06%' OR
                        d.icd_code LIKE 'S020%' OR
                        d.icd_code LIKE 'S021%' OR
                        d.icd_code LIKE 'S027%' OR
                        d.icd_code LIKE 'S029%' OR
                        d.icd_code LIKE 'S099%'
                    ))
                THEN 1 ELSE 0
            END
        ) AS broad_tbi_dx,
        MAX(
            CASE
                WHEN (d.icd_version = 9 AND (
                        d.icd_code LIKE '800%' OR
                        d.icd_code LIKE '801%' OR
                        d.icd_code LIKE '802%' OR
                        d.icd_code LIKE '803%' OR
                        d.icd_code LIKE '804%'
                    ))
                  OR (d.icd_version = 10 AND (
                        d.icd_code LIKE 'S020%' OR
                        d.icd_code LIKE 'S021%' OR
                        d.icd_code LIKE 'S027%' OR
                        d.icd_code LIKE 'S029%'
                    ))
                THEN 1 ELSE 0
            END
        ) AS skull_fracture_dx
    FROM mimiciv_hosp.diagnoses_icd d
    GROUP BY d.hadm_id
),
cohort AS MATERIALIZED (
    SELECT
        a.subject_id,
        a.hadm_id,
        a.stay_id,
        a.intime,
        a.outtime,
        CASE
            WHEN a.deathtime IS NOT NULL
             AND a.deathtime >= a.intime
             AND a.deathtime <= a.outtime
            THEN 1 ELSE 0
        END AS death,
        a.hospital_expire_flag AS hospital_death,
        g.gcs_min,
        COALESCE(dx.strict_tbi_dx, 0) AS strict_tbi_dx,
        COALESCE(dx.broad_tbi_dx, 0) AS broad_tbi_dx,
        COALESCE(dx.skull_fracture_dx, 0) AS skull_fracture_dx
    FROM adult a
    LEFT JOIN dx_flags dx
      ON dx.hadm_id = a.hadm_id
    LEFT JOIN mimiciv_derived.first_day_gcs g
      ON g.stay_id = a.stay_id
),
strict_severe AS MATERIALIZED (
    SELECT *
    FROM cohort
    WHERE strict_tbi_dx = 1
      AND gcs_min <= 8
),
vital_counts AS MATERIALIZED (
    SELECT
        ss.stay_id,
        ss.death,
        COUNT(*) FILTER (
            WHERE v.charttime >= ss.intime
              AND v.charttime < ss.intime + INTERVAL '24 hours'
              AND v.mbp BETWEEN 20 AND 200
        ) AS art_map_n_24h,
        COUNT(*) FILTER (
            WHERE v.charttime >= ss.intime
              AND v.charttime < ss.intime + INTERVAL '24 hours'
              AND v.sbp BETWEEN 30 AND 300
        ) AS art_sbp_n_24h,
        COUNT(*) FILTER (
            WHERE v.charttime >= ss.intime
              AND v.charttime < ss.intime + INTERVAL '24 hours'
              AND v.mbp_ni BETWEEN 20 AND 200
        ) AS ni_map_n_24h,
        COUNT(*) FILTER (
            WHERE v.charttime >= ss.intime
              AND v.charttime < ss.intime + INTERVAL '24 hours'
              AND v.sbp_ni BETWEEN 30 AND 300
        ) AS ni_sbp_n_24h,
        COUNT(*) FILTER (
            WHERE v.charttime >= ss.intime
              AND v.charttime < ss.intime + INTERVAL '24 hours'
              AND v.spo2 BETWEEN 50 AND 100
        ) AS spo2_n_24h,
        COUNT(*) FILTER (
            WHERE v.charttime >= ss.intime
              AND v.charttime < ss.intime + INTERVAL '72 hours'
              AND v.mbp BETWEEN 20 AND 200
        ) AS art_map_n_72h,
        COUNT(*) FILTER (
            WHERE v.charttime >= ss.intime
              AND v.charttime < ss.intime + INTERVAL '72 hours'
              AND v.sbp BETWEEN 30 AND 300
        ) AS art_sbp_n_72h,
        COUNT(*) FILTER (
            WHERE v.charttime >= ss.intime
              AND v.charttime < ss.intime + INTERVAL '72 hours'
              AND v.mbp_ni BETWEEN 20 AND 200
        ) AS ni_map_n_72h,
        COUNT(*) FILTER (
            WHERE v.charttime >= ss.intime
              AND v.charttime < ss.intime + INTERVAL '72 hours'
              AND v.sbp_ni BETWEEN 30 AND 300
        ) AS ni_sbp_n_72h,
        COUNT(*) FILTER (
            WHERE v.charttime >= ss.intime
              AND v.charttime < ss.intime + INTERVAL '72 hours'
              AND v.spo2 BETWEEN 50 AND 100
        ) AS spo2_n_72h
    FROM strict_severe ss
    LEFT JOIN mimiciv_derived.vitalsign v
      ON v.stay_id = ss.stay_id
    GROUP BY ss.stay_id, ss.death
),
coverage AS MATERIALIZED (
    SELECT
        ss.stay_id,
        ss.death,
        COALESCE(vc.art_map_n_24h, 0) AS art_map_n_24h,
        COALESCE(vc.art_sbp_n_24h, 0) AS art_sbp_n_24h,
        COALESCE(vc.ni_map_n_24h, 0) AS ni_map_n_24h,
        COALESCE(vc.ni_sbp_n_24h, 0) AS ni_sbp_n_24h,
        COALESCE(vc.spo2_n_24h, 0) AS spo2_n_24h,
        COALESCE(vc.art_map_n_72h, 0) AS art_map_n_72h,
        COALESCE(vc.art_sbp_n_72h, 0) AS art_sbp_n_72h,
        COALESCE(vc.ni_map_n_72h, 0) AS ni_map_n_72h,
        COALESCE(vc.ni_sbp_n_72h, 0) AS ni_sbp_n_72h,
        COALESCE(vc.spo2_n_72h, 0) AS spo2_n_72h
    FROM strict_severe ss
    LEFT JOIN vital_counts vc
      ON vc.stay_id = ss.stay_id
),
flow_rows AS (
    SELECT *
    FROM (
        VALUES
            ('MIMIC-IV', 'cohort_flow', 1, 'adult first ICU stays',
                (SELECT COUNT(*) FROM cohort),
                (SELECT SUM(death) FROM cohort),
                NULL::numeric,
                'adult, first ICU stay within hospitalization; death = ICU mortality'),
            ('MIMIC-IV', 'cohort_flow', 2, 'strict TBI diagnosis',
                (SELECT COUNT(*) FROM cohort WHERE strict_tbi_dx = 1),
                (SELECT SUM(death) FROM cohort WHERE strict_tbi_dx = 1),
                NULL::numeric,
                'ICD-9 850-854 or ICD-10 S06%'),
            ('MIMIC-IV', 'cohort_flow', 3, 'strict TBI + first-day GCS available',
                (SELECT COUNT(*) FROM cohort WHERE strict_tbi_dx = 1 AND gcs_min IS NOT NULL),
                (SELECT SUM(death) FROM cohort WHERE strict_tbi_dx = 1 AND gcs_min IS NOT NULL),
                NULL::numeric,
                'mimiciv_derived.first_day_gcs'),
            ('MIMIC-IV', 'cohort_flow', 4, 'strict TBI + GCS <= 8',
                (SELECT COUNT(*) FROM cohort WHERE strict_tbi_dx = 1 AND gcs_min <= 8),
                (SELECT SUM(death) FROM cohort WHERE strict_tbi_dx = 1 AND gcs_min <= 8),
                NULL::numeric,
                'primary severe TBI definition'),
            ('MIMIC-IV', 'cohort_flow', 5, 'strict TBI + GCS <= 12',
                (SELECT COUNT(*) FROM cohort WHERE strict_tbi_dx = 1 AND gcs_min <= 12),
                (SELECT SUM(death) FROM cohort WHERE strict_tbi_dx = 1 AND gcs_min <= 12),
                NULL::numeric,
                'prespecified sensitivity definition'),
            ('MIMIC-IV', 'diagnosis_audit', 10, 'broad TBI + GCS <= 8',
                (SELECT COUNT(*) FROM cohort WHERE broad_tbi_dx = 1 AND gcs_min <= 8),
                (SELECT SUM(death) FROM cohort WHERE broad_tbi_dx = 1 AND gcs_min <= 8),
                NULL::numeric,
                'strict TBI plus skull fracture/head injury ICD codes'),
            ('MIMIC-IV', 'diagnosis_audit', 11, 'broad TBI + GCS <= 12',
                (SELECT COUNT(*) FROM cohort WHERE broad_tbi_dx = 1 AND gcs_min <= 12),
                (SELECT SUM(death) FROM cohort WHERE broad_tbi_dx = 1 AND gcs_min <= 12),
                NULL::numeric,
                'broad sensitivity option'),
            ('MIMIC-IV', 'diagnosis_audit', 12, 'skull fracture code without strict TBI + GCS <= 8',
                (SELECT COUNT(*) FROM cohort WHERE skull_fracture_dx = 1 AND strict_tbi_dx = 0 AND gcs_min <= 8),
                (SELECT SUM(death) FROM cohort WHERE skull_fracture_dx = 1 AND strict_tbi_dx = 0 AND gcs_min <= 8),
                NULL::numeric,
                'excluded from primary strict intracranial TBI cohort'),
            ('MIMIC-IV', 'outcome_audit', 15, 'primary cohort hospital deaths under old outcome definition',
                (SELECT COUNT(*) FROM strict_severe),
                (SELECT SUM(hospital_death) FROM strict_severe),
                NULL::numeric,
                'comparison with previous hospital_expire_flag-based death definition'),
            ('MIMIC-IV', 'coverage', 20, 'primary cohort + any MAP and SpO2 in 24h',
                (SELECT COUNT(*) FROM coverage WHERE (art_map_n_24h + ni_map_n_24h) > 0 AND spo2_n_24h > 0),
                (SELECT SUM(death) FROM coverage WHERE (art_map_n_24h + ni_map_n_24h) > 0 AND spo2_n_24h > 0),
                NULL::numeric,
                'MAP from invasive or noninvasive sources; SpO2 from derived vitalsign'),
            ('MIMIC-IV', 'coverage', 21, 'primary cohort + >=4 MAP and >=4 SpO2 records in 24h',
                (SELECT COUNT(*) FROM coverage WHERE (art_map_n_24h + ni_map_n_24h) >= 4 AND spo2_n_24h >= 4),
                (SELECT SUM(death) FROM coverage WHERE (art_map_n_24h + ni_map_n_24h) >= 4 AND spo2_n_24h >= 4),
                NULL::numeric,
                'minimum density screen for 24h burden feasibility'),
            ('MIMIC-IV', 'coverage', 22, 'primary cohort + any MAP and SpO2 in 72h',
                (SELECT COUNT(*) FROM coverage WHERE (art_map_n_72h + ni_map_n_72h) > 0 AND spo2_n_72h > 0),
                (SELECT SUM(death) FROM coverage WHERE (art_map_n_72h + ni_map_n_72h) > 0 AND spo2_n_72h > 0),
                NULL::numeric,
                '72h dynamic window feasibility'),
            ('MIMIC-IV', 'coverage', 23, 'primary cohort + >=8 MAP and >=8 SpO2 records in 72h',
                (SELECT COUNT(*) FROM coverage WHERE (art_map_n_72h + ni_map_n_72h) >= 8 AND spo2_n_72h >= 8),
                (SELECT SUM(death) FROM coverage WHERE (art_map_n_72h + ni_map_n_72h) >= 8 AND spo2_n_72h >= 8),
                NULL::numeric,
                'minimum density screen for 72h burden feasibility'),
            ('MIMIC-IV', 'source_coverage', 30, 'any invasive MAP in 24h',
                (SELECT COUNT(*) FROM coverage WHERE art_map_n_24h > 0),
                (SELECT SUM(death) FROM coverage WHERE art_map_n_24h > 0),
                (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY art_map_n_24h) FROM coverage WHERE art_map_n_24h > 0),
                'median_records reports nonzero stays only'),
            ('MIMIC-IV', 'source_coverage', 31, 'any noninvasive MAP in 24h',
                (SELECT COUNT(*) FROM coverage WHERE ni_map_n_24h > 0),
                (SELECT SUM(death) FROM coverage WHERE ni_map_n_24h > 0),
                (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY ni_map_n_24h) FROM coverage WHERE ni_map_n_24h > 0),
                'median_records reports nonzero stays only'),
            ('MIMIC-IV', 'source_coverage', 32, 'any SpO2 in 24h',
                (SELECT COUNT(*) FROM coverage WHERE spo2_n_24h > 0),
                (SELECT SUM(death) FROM coverage WHERE spo2_n_24h > 0),
                (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY spo2_n_24h) FROM coverage WHERE spo2_n_24h > 0),
                'median_records reports nonzero stays only'),
            ('MIMIC-IV', 'source_coverage', 33, 'any invasive MAP in 72h',
                (SELECT COUNT(*) FROM coverage WHERE art_map_n_72h > 0),
                (SELECT SUM(death) FROM coverage WHERE art_map_n_72h > 0),
                (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY art_map_n_72h) FROM coverage WHERE art_map_n_72h > 0),
                'median_records reports nonzero stays only'),
            ('MIMIC-IV', 'source_coverage', 34, 'any noninvasive MAP in 72h',
                (SELECT COUNT(*) FROM coverage WHERE ni_map_n_72h > 0),
                (SELECT SUM(death) FROM coverage WHERE ni_map_n_72h > 0),
                (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY ni_map_n_72h) FROM coverage WHERE ni_map_n_72h > 0),
                'median_records reports nonzero stays only'),
            ('MIMIC-IV', 'source_coverage', 35, 'any SpO2 in 72h',
                (SELECT COUNT(*) FROM coverage WHERE spo2_n_72h > 0),
                (SELECT SUM(death) FROM coverage WHERE spo2_n_72h > 0),
                (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY spo2_n_72h) FROM coverage WHERE spo2_n_72h > 0),
                'median_records reports nonzero stays only')
    ) AS v(database_name, section, row_order, metric, n, deaths, median_records, notes)
)
SELECT
    database_name,
    section,
    row_order,
    metric,
    n,
    deaths,
    ROUND(100.0 * deaths / NULLIF(n, 0), 1) AS mortality_pct,
    median_records,
    notes
FROM flow_rows
ORDER BY section, row_order;

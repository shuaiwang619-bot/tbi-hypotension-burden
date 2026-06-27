-- eICU cohort flow for severe intracranial TBI.
-- Output level: aggregate counts only, no patient-level export.
-- Index time: eICU unit admission offset 0 minutes.
-- Primary population: adult first ICU unit stay, strict intracranial TBI, APACHE GCS <= 8.
-- Primary outcome for harmonization with MIMIC-IV: ICU unit discharge death.
-- Hospital discharge death and missing outcome status are retained as audit rows.

WITH adult_first AS MATERIALIZED (
    SELECT
        p.patientunitstayid,
        p.patienthealthsystemstayid,
        p.unitvisitnumber,
        p.hospitaladmitoffset,
        p.unitdischargeoffset,
        p.unitdischargestatus,
        p.hospitaldischargestatus,
        CASE
            WHEN p.age = '> 89' THEN 90
            WHEN p.age ~ '^[0-9]+$' THEN p.age::int
            ELSE NULL
        END AS age_num,
        ROW_NUMBER() OVER (
            PARTITION BY p.patienthealthsystemstayid
            ORDER BY p.unitvisitnumber NULLS LAST, p.patientunitstayid
        ) AS rn_old_unit_hospstay,
        ROW_NUMBER() OVER (
            PARTITION BY p.patienthealthsystemstayid
            ORDER BY p.hospitaladmitoffset DESC NULLS LAST,
                     p.unitvisitnumber NULLS LAST,
                     p.patientunitstayid
        ) AS rn_time_unit_hospstay
    FROM eicu_crd.patient p
),
adult AS MATERIALIZED (
    SELECT *
    FROM adult_first
    WHERE age_num >= 18
      AND rn_time_unit_hospstay = 1
),
first_unit_audit AS MATERIALIZED (
    SELECT
        old_first.patienthealthsystemstayid,
        old_first.patientunitstayid AS old_first_patientunitstayid,
        time_first.patientunitstayid AS time_first_patientunitstayid
    FROM adult_first old_first
    JOIN adult_first time_first
      ON time_first.patienthealthsystemstayid = old_first.patienthealthsystemstayid
    WHERE old_first.age_num >= 18
      AND time_first.age_num >= 18
      AND old_first.rn_old_unit_hospstay = 1
      AND time_first.rn_time_unit_hospstay = 1
),
dx_flags AS MATERIALIZED (
    SELECT
        d.patientunitstayid,
        MAX(
            CASE
                WHEN lower(COALESCE(d.diagnosisstring, '')) LIKE '%trauma - cns|intracranial injury%'
                  OR lower(COALESCE(d.diagnosisstring, '')) LIKE '%cerebral subdural hematoma|secondary to trauma%'
                THEN 1 ELSE 0
            END
        ) AS intracranial_tbi_dx,
        MAX(
            CASE
                WHEN lower(COALESCE(d.diagnosisstring, '')) LIKE '%trauma - cns|fracture of skull%'
                THEN 1 ELSE 0
            END
        ) AS skull_fracture_dx,
        MAX(
            CASE
                WHEN lower(COALESCE(d.diagnosisstring, '')) LIKE '%trauma - cns%'
                THEN 1 ELSE 0
            END
        ) AS any_trauma_cns_dx
    FROM eicu_crd.diagnosis d
    GROUP BY d.patientunitstayid
),
head_admission_dx AS MATERIALIZED (
    SELECT DISTINCT patientunitstayid
    FROM (
        SELECT p.patientunitstayid
        FROM eicu_crd.patient p
        WHERE lower(COALESCE(p.apacheadmissiondx, '')) LIKE '%head%trauma%'

        UNION ALL

        SELECT ad.patientunitstayid
        FROM eicu_crd.admissiondx ad
        WHERE lower(
            COALESCE(ad.admitdxpath, '') || ' ' ||
            COALESCE(ad.admitdxname, '') || ' ' ||
            COALESCE(ad.admitdxtext, '')
        ) LIKE '%diagnosis|trauma|head%'
    ) z
),
gcs AS MATERIALIZED (
    SELECT
        a.patientunitstayid,
        CASE
            WHEN a.eyes BETWEEN 1 AND 4
             AND a.motor BETWEEN 1 AND 6
             AND a.verbal BETWEEN 1 AND 5
            THEN a.eyes + a.motor + a.verbal
            ELSE NULL
        END AS apache_gcs
    FROM eicu_crd.apacheapsvar a
),
cohort AS MATERIALIZED (
    SELECT
        a.patientunitstayid,
        a.patienthealthsystemstayid,
        a.unitvisitnumber,
        a.hospitaladmitoffset,
        a.unitdischargeoffset,
        a.unitdischargestatus,
        a.hospitaldischargestatus,
        CASE
            WHEN a.unitdischargestatus = 'Expired' THEN 1
            WHEN a.unitdischargestatus IS NULL OR btrim(a.unitdischargestatus) = '' THEN NULL
            ELSE 0
        END AS death,
        CASE
            WHEN a.hospitaldischargestatus = 'Expired' THEN 1
            WHEN a.hospitaldischargestatus IS NULL OR btrim(a.hospitaldischargestatus) = '' THEN NULL
            ELSE 0
        END AS hospital_death,
        gcs.apache_gcs,
        COALESCE(dx.intracranial_tbi_dx, 0) AS intracranial_tbi_dx,
        COALESCE(dx.skull_fracture_dx, 0) AS skull_fracture_dx,
        COALESCE(dx.any_trauma_cns_dx, 0) AS any_trauma_cns_dx,
        CASE WHEN hadx.patientunitstayid IS NOT NULL THEN 1 ELSE 0 END AS head_admission_dx
    FROM adult a
    LEFT JOIN dx_flags dx
      ON dx.patientunitstayid = a.patientunitstayid
    LEFT JOIN head_admission_dx hadx
      ON hadx.patientunitstayid = a.patientunitstayid
    LEFT JOIN gcs
      ON gcs.patientunitstayid = a.patientunitstayid
),
strict_severe AS MATERIALIZED (
    SELECT *
    FROM cohort
    WHERE intracranial_tbi_dx = 1
      AND apache_gcs <= 8
),
vp_counts AS MATERIALIZED (
    SELECT
        v.patientunitstayid,
        COUNT(*) FILTER (
            WHERE v.observationoffset >= 0
              AND v.observationoffset < 1440
              AND v.systemicmean BETWEEN 20 AND 200
        ) AS art_map_n_24h,
        COUNT(*) FILTER (
            WHERE v.observationoffset >= 0
              AND v.observationoffset < 1440
              AND v.systemicsystolic BETWEEN 30 AND 300
        ) AS art_sbp_n_24h,
        COUNT(*) FILTER (
            WHERE v.observationoffset >= 0
              AND v.observationoffset < 1440
              AND v.sao2 BETWEEN 50 AND 100
        ) AS spo2_n_24h,
        COUNT(*) FILTER (
            WHERE v.observationoffset >= 0
              AND v.observationoffset < 4320
              AND v.systemicmean BETWEEN 20 AND 200
        ) AS art_map_n_72h,
        COUNT(*) FILTER (
            WHERE v.observationoffset >= 0
              AND v.observationoffset < 4320
              AND v.systemicsystolic BETWEEN 30 AND 300
        ) AS art_sbp_n_72h,
        COUNT(*) FILTER (
            WHERE v.observationoffset >= 0
              AND v.observationoffset < 4320
              AND v.sao2 BETWEEN 50 AND 100
        ) AS spo2_n_72h
    FROM eicu_crd.vitalperiodic v
    JOIN strict_severe ss
      ON ss.patientunitstayid = v.patientunitstayid
    GROUP BY v.patientunitstayid
),
va_counts AS MATERIALIZED (
    SELECT
        v.patientunitstayid,
        COUNT(*) FILTER (
            WHERE v.observationoffset >= 0
              AND v.observationoffset < 1440
              AND v.noninvasivemean BETWEEN 20 AND 200
        ) AS ni_map_n_24h,
        COUNT(*) FILTER (
            WHERE v.observationoffset >= 0
              AND v.observationoffset < 1440
              AND v.noninvasivesystolic BETWEEN 30 AND 300
        ) AS ni_sbp_n_24h,
        COUNT(*) FILTER (
            WHERE v.observationoffset >= 0
              AND v.observationoffset < 4320
              AND v.noninvasivemean BETWEEN 20 AND 200
        ) AS ni_map_n_72h,
        COUNT(*) FILTER (
            WHERE v.observationoffset >= 0
              AND v.observationoffset < 4320
              AND v.noninvasivesystolic BETWEEN 30 AND 300
        ) AS ni_sbp_n_72h
    FROM eicu_crd.vitalaperiodic v
    JOIN strict_severe ss
      ON ss.patientunitstayid = v.patientunitstayid
    GROUP BY v.patientunitstayid
),
coverage AS MATERIALIZED (
    SELECT
        ss.patientunitstayid,
        ss.death,
        COALESCE(vp.art_map_n_24h, 0) AS art_map_n_24h,
        COALESCE(vp.art_sbp_n_24h, 0) AS art_sbp_n_24h,
        COALESCE(va.ni_map_n_24h, 0) AS ni_map_n_24h,
        COALESCE(va.ni_sbp_n_24h, 0) AS ni_sbp_n_24h,
        COALESCE(vp.spo2_n_24h, 0) AS spo2_n_24h,
        COALESCE(vp.art_map_n_72h, 0) AS art_map_n_72h,
        COALESCE(vp.art_sbp_n_72h, 0) AS art_sbp_n_72h,
        COALESCE(va.ni_map_n_72h, 0) AS ni_map_n_72h,
        COALESCE(va.ni_sbp_n_72h, 0) AS ni_sbp_n_72h,
        COALESCE(vp.spo2_n_72h, 0) AS spo2_n_72h
    FROM strict_severe ss
    LEFT JOIN vp_counts vp
      ON vp.patientunitstayid = ss.patientunitstayid
    LEFT JOIN va_counts va
      ON va.patientunitstayid = ss.patientunitstayid
),
flow_rows AS (
    SELECT *
    FROM (
        VALUES
            ('eICU', 'cohort_flow', 1, 'adult first ICU unit stays',
                (SELECT COUNT(*) FROM cohort),
                (SELECT COALESCE(SUM(death), 0) FROM cohort),
                NULL::numeric,
                'adult, first ICU unit stay by largest hospitaladmitoffset; death = ICU unit discharge death'),
            ('eICU', 'cohort_flow', 2, 'strict intracranial TBI diagnosis',
                (SELECT COUNT(*) FROM cohort WHERE intracranial_tbi_dx = 1),
                (SELECT COALESCE(SUM(death), 0) FROM cohort WHERE intracranial_tbi_dx = 1),
                NULL::numeric,
                'diagnosisstring contains intracranial injury or traumatic subdural hematoma'),
            ('eICU', 'cohort_flow', 3, 'strict TBI + APACHE GCS available',
                (SELECT COUNT(*) FROM cohort WHERE intracranial_tbi_dx = 1 AND apache_gcs IS NOT NULL),
                (SELECT COALESCE(SUM(death), 0) FROM cohort WHERE intracranial_tbi_dx = 1 AND apache_gcs IS NOT NULL),
                NULL::numeric,
                'valid eyes, motor, and verbal components'),
            ('eICU', 'cohort_flow', 4, 'strict TBI + GCS <= 8',
                (SELECT COUNT(*) FROM cohort WHERE intracranial_tbi_dx = 1 AND apache_gcs <= 8),
                (SELECT COALESCE(SUM(death), 0) FROM cohort WHERE intracranial_tbi_dx = 1 AND apache_gcs <= 8),
                NULL::numeric,
                'primary severe TBI definition'),
            ('eICU', 'cohort_flow', 5, 'strict TBI + GCS <= 12',
                (SELECT COUNT(*) FROM cohort WHERE intracranial_tbi_dx = 1 AND apache_gcs <= 12),
                (SELECT COALESCE(SUM(death), 0) FROM cohort WHERE intracranial_tbi_dx = 1 AND apache_gcs <= 12),
                NULL::numeric,
                'prespecified sensitivity definition'),
            ('eICU', 'diagnosis_audit', 10, 'old strict including skull fracture + GCS <= 8',
                (SELECT COUNT(*) FROM cohort WHERE (intracranial_tbi_dx = 1 OR skull_fracture_dx = 1) AND apache_gcs <= 8),
                (SELECT COALESCE(SUM(death), 0) FROM cohort WHERE (intracranial_tbi_dx = 1 OR skull_fracture_dx = 1) AND apache_gcs <= 8),
                NULL::numeric,
                'prior broader strict definition before excluding isolated skull fracture'),
            ('eICU', 'diagnosis_audit', 11, 'isolated skull fracture + GCS <= 8, excluded',
                (SELECT COUNT(*) FROM cohort WHERE skull_fracture_dx = 1 AND intracranial_tbi_dx = 0 AND apache_gcs <= 8),
                (SELECT COALESCE(SUM(death), 0) FROM cohort WHERE skull_fracture_dx = 1 AND intracranial_tbi_dx = 0 AND apache_gcs <= 8),
                NULL::numeric,
                'excluded from primary strict intracranial TBI cohort'),
            ('eICU', 'diagnosis_audit', 12, 'head admission dx without intracranial diagnosis + GCS <= 8',
                (SELECT COUNT(*) FROM cohort WHERE head_admission_dx = 1 AND intracranial_tbi_dx = 0 AND apache_gcs <= 8),
                (SELECT COALESCE(SUM(death), 0) FROM cohort WHERE head_admission_dx = 1 AND intracranial_tbi_dx = 0 AND apache_gcs <= 8),
                NULL::numeric,
                'possible missed TBI if using diagnosis table only'),
            ('eICU', 'diagnosis_audit', 13, 'intracranial dx UNION head admission dx + GCS <= 8',
                (SELECT COUNT(*) FROM cohort WHERE (intracranial_tbi_dx = 1 OR head_admission_dx = 1) AND apache_gcs <= 8),
                (SELECT COALESCE(SUM(death), 0) FROM cohort WHERE (intracranial_tbi_dx = 1 OR head_admission_dx = 1) AND apache_gcs <= 8),
                NULL::numeric,
                'broad sensitivity option'),
            ('eICU', 'selection_audit', 14, 'adult health-system stays with changed first ICU unit after time ordering',
                (SELECT COUNT(*) FROM first_unit_audit WHERE old_first_patientunitstayid <> time_first_patientunitstayid),
                NULL::bigint,
                NULL::numeric,
                'new ordering uses hospitaladmitoffset DESC; old ordering used unitvisitnumber then patientunitstayid'),
            ('eICU', 'outcome_audit', 15, 'primary cohort with missing unit discharge status',
                (SELECT COUNT(*) FROM strict_severe WHERE unitdischargestatus IS NULL OR btrim(unitdischargestatus) = ''),
                NULL::bigint,
                NULL::numeric,
                'primary ICU death outcome missingness check'),
            ('eICU', 'outcome_audit', 16, 'primary cohort with missing hospital discharge status',
                (SELECT COUNT(*) FROM strict_severe WHERE hospitaldischargestatus IS NULL OR btrim(hospitaldischargestatus) = ''),
                NULL::bigint,
                NULL::numeric,
                'old hospital death outcome missingness check'),
            ('eICU', 'outcome_audit', 17, 'primary cohort hospital deaths under old outcome definition',
                (SELECT COUNT(*) FROM strict_severe),
                (SELECT COALESCE(SUM(hospital_death), 0) FROM strict_severe),
                NULL::numeric,
                'comparison with previous hospitaldischargestatus-based death definition'),
            ('eICU', 'coverage', 20, 'primary cohort + any MAP and SpO2 in 24h',
                (SELECT COUNT(*) FROM coverage WHERE (art_map_n_24h + ni_map_n_24h) > 0 AND spo2_n_24h > 0),
                (SELECT COALESCE(SUM(death), 0) FROM coverage WHERE (art_map_n_24h + ni_map_n_24h) > 0 AND spo2_n_24h > 0),
                NULL::numeric,
                'MAP from invasive or noninvasive sources; SpO2 from vitalperiodic'),
            ('eICU', 'coverage', 21, 'primary cohort + >=4 MAP and >=4 SpO2 records in 24h',
                (SELECT COUNT(*) FROM coverage WHERE (art_map_n_24h + ni_map_n_24h) >= 4 AND spo2_n_24h >= 4),
                (SELECT COALESCE(SUM(death), 0) FROM coverage WHERE (art_map_n_24h + ni_map_n_24h) >= 4 AND spo2_n_24h >= 4),
                NULL::numeric,
                'minimum density screen for 24h burden feasibility'),
            ('eICU', 'coverage', 22, 'primary cohort + any MAP and SpO2 in 72h',
                (SELECT COUNT(*) FROM coverage WHERE (art_map_n_72h + ni_map_n_72h) > 0 AND spo2_n_72h > 0),
                (SELECT COALESCE(SUM(death), 0) FROM coverage WHERE (art_map_n_72h + ni_map_n_72h) > 0 AND spo2_n_72h > 0),
                NULL::numeric,
                '72h dynamic window feasibility'),
            ('eICU', 'coverage', 23, 'primary cohort + >=8 MAP and >=8 SpO2 records in 72h',
                (SELECT COUNT(*) FROM coverage WHERE (art_map_n_72h + ni_map_n_72h) >= 8 AND spo2_n_72h >= 8),
                (SELECT COALESCE(SUM(death), 0) FROM coverage WHERE (art_map_n_72h + ni_map_n_72h) >= 8 AND spo2_n_72h >= 8),
                NULL::numeric,
                'minimum density screen for 72h burden feasibility'),
            ('eICU', 'source_coverage', 30, 'any invasive MAP in 24h',
                (SELECT COUNT(*) FROM coverage WHERE art_map_n_24h > 0),
                (SELECT COALESCE(SUM(death), 0) FROM coverage WHERE art_map_n_24h > 0),
                (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY art_map_n_24h) FROM coverage WHERE art_map_n_24h > 0),
                'median_records reports nonzero stays only'),
            ('eICU', 'source_coverage', 31, 'any noninvasive MAP in 24h',
                (SELECT COUNT(*) FROM coverage WHERE ni_map_n_24h > 0),
                (SELECT COALESCE(SUM(death), 0) FROM coverage WHERE ni_map_n_24h > 0),
                (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY ni_map_n_24h) FROM coverage WHERE ni_map_n_24h > 0),
                'median_records reports nonzero stays only'),
            ('eICU', 'source_coverage', 32, 'any SpO2 in 24h',
                (SELECT COUNT(*) FROM coverage WHERE spo2_n_24h > 0),
                (SELECT COALESCE(SUM(death), 0) FROM coverage WHERE spo2_n_24h > 0),
                (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY spo2_n_24h) FROM coverage WHERE spo2_n_24h > 0),
                'median_records reports nonzero stays only'),
            ('eICU', 'source_coverage', 33, 'any invasive MAP in 72h',
                (SELECT COUNT(*) FROM coverage WHERE art_map_n_72h > 0),
                (SELECT COALESCE(SUM(death), 0) FROM coverage WHERE art_map_n_72h > 0),
                (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY art_map_n_72h) FROM coverage WHERE art_map_n_72h > 0),
                'median_records reports nonzero stays only'),
            ('eICU', 'source_coverage', 34, 'any noninvasive MAP in 72h',
                (SELECT COUNT(*) FROM coverage WHERE ni_map_n_72h > 0),
                (SELECT COALESCE(SUM(death), 0) FROM coverage WHERE ni_map_n_72h > 0),
                (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY ni_map_n_72h) FROM coverage WHERE ni_map_n_72h > 0),
                'median_records reports nonzero stays only'),
            ('eICU', 'source_coverage', 35, 'any SpO2 in 72h',
                (SELECT COUNT(*) FROM coverage WHERE spo2_n_72h > 0),
                (SELECT COALESCE(SUM(death), 0) FROM coverage WHERE spo2_n_72h > 0),
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

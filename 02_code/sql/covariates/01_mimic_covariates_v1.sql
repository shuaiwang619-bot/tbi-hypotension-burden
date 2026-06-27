-- MIMIC-IV covariates v1 for severe intracranial TBI cohort.
-- Output level: one row per stay_id in the strict severe cohort.
-- Anchor: mimiciv_icu.icustays.intime.
-- Treatment timing: baseline/ICU-entry proxies plus first-24h sensitivity variables.
-- Lab window: [0, 24h] from ICU intime.

WITH icu_base AS MATERIALIZED (
    SELECT
        i.subject_id,
        i.hadm_id,
        i.stay_id,
        i.intime,
        i.outtime,
        a.deathtime,
        a.hospital_expire_flag,
        a.admission_type,
        a.admission_location,
        a.insurance,
        a.language,
        a.marital_status,
        a.race,
        p.gender,
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
        MAX(CASE
            WHEN (d.icd_version = 9 AND (
                    d.icd_code LIKE '850%' OR d.icd_code LIKE '851%' OR d.icd_code LIKE '852%' OR
                    d.icd_code LIKE '853%' OR d.icd_code LIKE '854%'
                ))
              OR (d.icd_version = 10 AND d.icd_code LIKE 'S06%')
            THEN 1 ELSE 0
        END) AS strict_tbi_dx,
        MAX(CASE
            WHEN (d.icd_version = 9 AND (d.icd_code LIKE '8522%' OR d.icd_code LIKE '8523%'))
              OR (d.icd_version = 10 AND d.icd_code LIKE 'S065%')
            THEN 1 ELSE 0
        END) AS tbi_subdural,
        MAX(CASE
            WHEN (d.icd_version = 9 AND (d.icd_code LIKE '8520%' OR d.icd_code LIKE '8521%'))
              OR (d.icd_version = 10 AND d.icd_code LIKE 'S066%')
            THEN 1 ELSE 0
        END) AS tbi_subarachnoid,
        MAX(CASE
            WHEN (d.icd_version = 9 AND (d.icd_code LIKE '8524%' OR d.icd_code LIKE '8525%'))
              OR (d.icd_version = 10 AND d.icd_code LIKE 'S064%')
            THEN 1 ELSE 0
        END) AS tbi_epidural,
        MAX(CASE
            WHEN (d.icd_version = 9 AND d.icd_code LIKE '853%')
            THEN 1 ELSE 0
        END) AS tbi_intracerebral_hemorrhage,
        MAX(CASE
            WHEN (d.icd_version = 9 AND d.icd_code LIKE '851%')
              OR (d.icd_version = 10 AND d.icd_code LIKE 'S063%')
            THEN 1 ELSE 0
        END) AS tbi_contusion_or_laceration,
        MAX(CASE
            WHEN d.icd_version = 10 AND d.icd_code LIKE 'S062%'
            THEN 1 ELSE 0
        END) AS tbi_diffuse_axonal_injury,
        MAX(CASE
            WHEN d.icd_version = 10 AND d.icd_code LIKE 'S061%'
            THEN 1 ELSE 0
        END) AS tbi_edema
    FROM mimiciv_hosp.diagnoses_icd d
    GROUP BY d.hadm_id
),
cohort AS MATERIALIZED (
    SELECT
        a.*,
        CASE
            WHEN a.deathtime IS NOT NULL
             AND a.deathtime >= a.intime
             AND a.deathtime <= a.outtime
            THEN 1 ELSE 0
        END AS death_icu,
        a.hospital_expire_flag AS death_hospital,
        g.gcs_min,
        g.gcs_motor,
        g.gcs_verbal,
        g.gcs_eyes,
        COALESCE(dx.strict_tbi_dx, 0) AS strict_tbi_dx,
        COALESCE(dx.tbi_subdural, 0) AS tbi_subdural,
        COALESCE(dx.tbi_subarachnoid, 0) AS tbi_subarachnoid,
        COALESCE(dx.tbi_epidural, 0) AS tbi_epidural,
        COALESCE(dx.tbi_intracerebral_hemorrhage, 0) AS tbi_intracerebral_hemorrhage,
        COALESCE(dx.tbi_contusion_or_laceration, 0) AS tbi_contusion_or_laceration,
        COALESCE(dx.tbi_diffuse_axonal_injury, 0) AS tbi_diffuse_axonal_injury,
        COALESCE(dx.tbi_edema, 0) AS tbi_edema
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
vent AS MATERIALIZED (
    SELECT
        ss.stay_id,
        MAX(CASE
            WHEN v.ventilation_status IN ('InvasiveVent', 'Tracheostomy')
             AND v.starttime <= ss.intime
             AND COALESCE(v.endtime, v.starttime + INTERVAL '1 minute') > ss.intime
            THEN 1 ELSE 0
        END) AS mechanical_vent_at_icu_entry,
        MAX(CASE
            WHEN v.ventilation_status IN ('InvasiveVent', 'Tracheostomy')
             AND v.starttime < ss.intime + INTERVAL '1 hour'
             AND COALESCE(v.endtime, v.starttime + INTERVAL '1 minute') > ss.intime - INTERVAL '1 hour'
            THEN 1 ELSE 0
        END) AS mechanical_vent_entry_1h_window,
        MAX(CASE
            WHEN v.ventilation_status IN ('InvasiveVent', 'Tracheostomy')
             AND v.starttime < ss.intime + INTERVAL '24 hours'
             AND COALESCE(v.endtime, v.starttime + INTERVAL '1 minute') > ss.intime
            THEN 1 ELSE 0
        END) AS mechanical_vent_24h,
        MAX(CASE
            WHEN v.ventilation_status IN ('InvasiveVent', 'Tracheostomy', 'NonInvasiveVent', 'HFNC')
             AND v.starttime < ss.intime + INTERVAL '24 hours'
             AND COALESCE(v.endtime, v.starttime + INTERVAL '1 minute') > ss.intime
            THEN 1 ELSE 0
        END) AS any_advanced_respiratory_support_24h
    FROM strict_severe ss
    LEFT JOIN mimiciv_derived.ventilation v
      ON v.stay_id = ss.stay_id
    GROUP BY ss.stay_id
),
vaso AS MATERIALIZED (
    SELECT
        ss.stay_id,
        MAX(CASE
            WHEN va.starttime <= ss.intime
             AND COALESCE(va.endtime, va.starttime + INTERVAL '1 minute') > ss.intime
             AND (
                COALESCE(va.dopamine, 0) > 0 OR
                COALESCE(va.epinephrine, 0) > 0 OR
                COALESCE(va.norepinephrine, 0) > 0 OR
                COALESCE(va.phenylephrine, 0) > 0 OR
                COALESCE(va.vasopressin, 0) > 0 OR
                COALESCE(va.dobutamine, 0) > 0
             )
            THEN 1 ELSE 0
        END) AS vasopressor_at_icu_entry,
        MAX(CASE
            WHEN va.starttime < ss.intime + INTERVAL '1 hour'
             AND COALESCE(va.endtime, va.starttime + INTERVAL '1 minute') > ss.intime - INTERVAL '1 hour'
             AND (
                COALESCE(va.dopamine, 0) > 0 OR
                COALESCE(va.epinephrine, 0) > 0 OR
                COALESCE(va.norepinephrine, 0) > 0 OR
                COALESCE(va.phenylephrine, 0) > 0 OR
                COALESCE(va.vasopressin, 0) > 0 OR
                COALESCE(va.dobutamine, 0) > 0
             )
            THEN 1 ELSE 0
        END) AS vasopressor_entry_1h_window,
        MAX(CASE
            WHEN va.starttime < ss.intime + INTERVAL '24 hours'
             AND COALESCE(va.endtime, va.starttime + INTERVAL '1 minute') > ss.intime
             AND (
                COALESCE(va.dopamine, 0) > 0 OR
                COALESCE(va.epinephrine, 0) > 0 OR
                COALESCE(va.norepinephrine, 0) > 0 OR
                COALESCE(va.phenylephrine, 0) > 0 OR
                COALESCE(va.vasopressin, 0) > 0 OR
                COALESCE(va.dobutamine, 0) > 0
             )
            THEN 1 ELSE 0
        END) AS vasopressor_24h
    FROM strict_severe ss
    LEFT JOIN mimiciv_derived.vasoactive_agent va
      ON va.stay_id = ss.stay_id
    GROUP BY ss.stay_id
)
SELECT
    'MIMIC-IV'::text AS database_name,
    ss.subject_id,
    ss.hadm_id,
    ss.stay_id,
    ss.age_num AS age,
    ss.gender,
    CASE WHEN ss.gender = 'M' THEN 1 WHEN ss.gender = 'F' THEN 0 ELSE NULL END AS sex_male,
    ss.race,
    ss.admission_type,
    ss.admission_location,
    ss.insurance,
    ss.gcs_min AS gcs_total,
    ss.gcs_eyes,
    ss.gcs_motor,
    ss.gcs_verbal,
    ss.death_icu,
    ss.death_hospital,
    COALESCE(ss.tbi_subdural, 0) AS tbi_subdural,
    COALESCE(ss.tbi_subarachnoid, 0) AS tbi_subarachnoid,
    COALESCE(ss.tbi_epidural, 0) AS tbi_epidural,
    COALESCE(ss.tbi_intracerebral_hemorrhage, 0) AS tbi_intracerebral_hemorrhage,
    COALESCE(ss.tbi_contusion_or_laceration, 0) AS tbi_contusion_or_laceration,
    COALESCE(ss.tbi_diffuse_axonal_injury, 0) AS tbi_diffuse_axonal_injury,
    0 AS tbi_herniation,
    COALESCE(ss.tbi_edema, 0) AS tbi_edema,
    COALESCE(vent.mechanical_vent_at_icu_entry, 0) AS mechanical_vent_at_icu_entry,
    COALESCE(vent.mechanical_vent_entry_1h_window, 0) AS mechanical_vent_entry_1h_window,
    COALESCE(vent.mechanical_vent_24h, 0) AS mechanical_vent_24h,
    COALESCE(vent.any_advanced_respiratory_support_24h, 0) AS any_advanced_respiratory_support_24h,
    COALESCE(vaso.vasopressor_at_icu_entry, 0) AS vasopressor_at_icu_entry,
    COALESCE(vaso.vasopressor_entry_1h_window, 0) AS vasopressor_entry_1h_window,
    COALESCE(vaso.vasopressor_24h, 0) AS vasopressor_24h,
    COALESCE(ch.congestive_heart_failure, 0) AS hx_congestive_heart_failure,
    CASE WHEN COALESCE(ch.diabetes_without_cc, 0) = 1 OR COALESCE(ch.diabetes_with_cc, 0) = 1 THEN 1 ELSE 0 END AS hx_diabetes,
    COALESCE(ch.chronic_pulmonary_disease, 0) AS hx_chronic_pulmonary_disease,
    COALESCE(ch.renal_disease, 0) AS hx_renal_disease,
    CASE WHEN COALESCE(ch.mild_liver_disease, 0) = 1 OR COALESCE(ch.severe_liver_disease, 0) = 1 THEN 1 ELSE 0 END AS hx_liver_disease,
    CASE
        WHEN COALESCE(ch.malignant_cancer, 0) = 1
          OR COALESCE(ch.metastatic_solid_tumor, 0) = 1
          OR COALESCE(ch.aids, 0) = 1
        THEN 1 ELSE 0
    END AS hx_malignancy,
    COALESCE(ch.cerebrovascular_disease, 0) AS hx_cerebrovascular_disease,
    ch.charlson_comorbidity_index,
    aps.apsiii AS mimic_apsiii,
    sofa.sofa AS mimic_first_day_sofa,
    saps.sapsii AS mimic_sapsii,
    bg.lactate_max AS lactate_max_24h,
    lab.hemoglobin_min AS hemoglobin_min_24h,
    lab.wbc_max AS wbc_max_24h,
    lab.creatinine_max AS creatinine_max_24h,
    lab.sodium_min AS sodium_min_24h,
    lab.sodium_max AS sodium_max_24h,
    lab.glucose_max AS glucose_max_24h,
    lab.platelets_min AS platelet_min_24h,
    lab.inr_max AS inr_max_24h,
    lab.pt_max AS pt_max_24h,
    lab.ptt_max AS ptt_max_24h
FROM strict_severe ss
LEFT JOIN vent
  ON vent.stay_id = ss.stay_id
LEFT JOIN vaso
  ON vaso.stay_id = ss.stay_id
LEFT JOIN mimiciv_derived.charlson ch
  ON ch.hadm_id = ss.hadm_id
LEFT JOIN mimiciv_derived.apsiii aps
  ON aps.stay_id = ss.stay_id
LEFT JOIN mimiciv_derived.first_day_sofa sofa
  ON sofa.stay_id = ss.stay_id
LEFT JOIN mimiciv_derived.sapsii saps
  ON saps.stay_id = ss.stay_id
LEFT JOIN mimiciv_derived.first_day_bg bg
  ON bg.stay_id = ss.stay_id
LEFT JOIN mimiciv_derived.first_day_lab lab
  ON lab.stay_id = ss.stay_id
ORDER BY ss.subject_id, ss.hadm_id, ss.stay_id;

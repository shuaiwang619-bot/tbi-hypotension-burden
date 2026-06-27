-- eICU covariates v1 for severe intracranial TBI cohort.
-- Output level: one row per patientunitstayid in the strict severe cohort.
-- Anchor: eICU unit admission offset 0 minutes.
-- Treatment timing: baseline/entry proxies plus first-24h sensitivity variables.
-- Lab window: [0, 24h] from unit admission.

WITH adult_first AS MATERIALIZED (
    SELECT
        p.patientunitstayid,
        p.patienthealthsystemstayid,
        p.gender,
        p.age,
        p.ethnicity,
        p.hospitalid,
        p.apacheadmissiondx,
        p.admissionheight,
        p.admissionweight,
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
dx_flags AS MATERIALIZED (
    SELECT
        d.patientunitstayid,
        MAX(CASE
            WHEN lower(COALESCE(d.diagnosisstring, '')) LIKE '%trauma - cns|intracranial injury%'
              OR lower(COALESCE(d.diagnosisstring, '')) LIKE '%cerebral subdural hematoma|secondary to trauma%'
            THEN 1 ELSE 0
        END) AS intracranial_tbi_dx,
        MAX(CASE WHEN lower(COALESCE(d.diagnosisstring, '')) LIKE '%subdural%' THEN 1 ELSE 0 END) AS tbi_subdural,
        MAX(CASE WHEN lower(COALESCE(d.diagnosisstring, '')) LIKE '%subarachnoid%' THEN 1 ELSE 0 END) AS tbi_subarachnoid,
        MAX(CASE WHEN lower(COALESCE(d.diagnosisstring, '')) LIKE '%epidural%' THEN 1 ELSE 0 END) AS tbi_epidural,
        MAX(CASE WHEN lower(COALESCE(d.diagnosisstring, '')) LIKE '%intracerebral hemorrhage%' THEN 1 ELSE 0 END) AS tbi_intracerebral_hemorrhage,
        MAX(CASE
            WHEN lower(COALESCE(d.diagnosisstring, '')) LIKE '%cerebral contusion%'
              OR lower(COALESCE(d.diagnosisstring, '')) LIKE '%cerebral laceration%'
            THEN 1 ELSE 0
        END) AS tbi_contusion_or_laceration,
        MAX(CASE WHEN lower(COALESCE(d.diagnosisstring, '')) LIKE '%diffuse axonal injury%' THEN 1 ELSE 0 END) AS tbi_diffuse_axonal_injury,
        MAX(CASE WHEN lower(COALESCE(d.diagnosisstring, '')) LIKE '%herniation%' THEN 1 ELSE 0 END) AS tbi_herniation,
        MAX(CASE WHEN lower(COALESCE(d.diagnosisstring, '')) LIKE '%edema%' THEN 1 ELSE 0 END) AS tbi_edema
    FROM eicu_crd.diagnosis d
    GROUP BY d.patientunitstayid
),
gcs AS MATERIALIZED (
    SELECT
        a.patientunitstayid,
        a.eyes,
        a.motor,
        a.verbal,
        a.intubated,
        a.vent,
        a.dialysis,
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
        a.*,
        CASE
            WHEN a.unitdischargestatus = 'Expired' THEN 1
            WHEN a.unitdischargestatus IS NULL OR btrim(a.unitdischargestatus) = '' THEN NULL
            ELSE 0
        END AS death_icu,
        CASE
            WHEN a.hospitaldischargestatus = 'Expired' THEN 1
            WHEN a.hospitaldischargestatus IS NULL OR btrim(a.hospitaldischargestatus) = '' THEN NULL
            ELSE 0
        END AS death_hospital,
        g.eyes,
        g.motor,
        g.verbal,
        g.apache_gcs,
        g.intubated,
        g.vent,
        g.dialysis,
        COALESCE(dx.intracranial_tbi_dx, 0) AS intracranial_tbi_dx,
        COALESCE(dx.tbi_subdural, 0) AS tbi_subdural,
        COALESCE(dx.tbi_subarachnoid, 0) AS tbi_subarachnoid,
        COALESCE(dx.tbi_epidural, 0) AS tbi_epidural,
        COALESCE(dx.tbi_intracerebral_hemorrhage, 0) AS tbi_intracerebral_hemorrhage,
        COALESCE(dx.tbi_contusion_or_laceration, 0) AS tbi_contusion_or_laceration,
        COALESCE(dx.tbi_diffuse_axonal_injury, 0) AS tbi_diffuse_axonal_injury,
        COALESCE(dx.tbi_herniation, 0) AS tbi_herniation,
        COALESCE(dx.tbi_edema, 0) AS tbi_edema
    FROM adult a
    LEFT JOIN gcs g
      ON g.patientunitstayid = a.patientunitstayid
    LEFT JOIN dx_flags dx
      ON dx.patientunitstayid = a.patientunitstayid
),
strict_severe AS MATERIALIZED (
    SELECT *
    FROM cohort
    WHERE intracranial_tbi_dx = 1
      AND apache_gcs <= 8
),
severity AS MATERIALIZED (
    SELECT
        patientunitstayid,
        MAX(acutephysiologyscore) AS eicu_acute_physiology_score,
        MAX(apachescore) AS eicu_apache_score,
        MAX(NULLIF(predictedicumortality, '')::numeric) AS eicu_predicted_icu_mortality,
        MAX(NULLIF(predictedhospitalmortality, '')::numeric) AS eicu_predicted_hospital_mortality
    FROM eicu_crd.apachepatientresult
    GROUP BY patientunitstayid
),
pred AS MATERIALIZED (
    SELECT
        patientunitstayid,
        MAX(CASE WHEN ventday1 = 1 OR oobventday1 = 1 OR oobintubday1 = 1 THEN 1 ELSE 0 END) AS apache_vent_day1
    FROM eicu_crd.apachepredvar
    GROUP BY patientunitstayid
),
resp AS MATERIALIZED (
    SELECT
        patientunitstayid,
        MAX(CASE
            WHEN (
                    ventstartoffset IS NOT NULL
                AND ventstartoffset <= 0
                AND COALESCE(ventendoffset, 999999) > 0
            ) OR (
                    priorventstartoffset IS NOT NULL
                AND priorventstartoffset <= 0
                AND COALESCE(priorventendoffset, 999999) > 0
            )
            THEN 1 ELSE 0
        END) AS respiratorycare_vent_at_entry,
        MAX(CASE
            WHEN (
                    COALESCE(ventstartoffset, respcarestatusoffset) IS NOT NULL
                AND COALESCE(ventstartoffset, respcarestatusoffset) < 60
                AND COALESCE(ventendoffset, 999999) > -60
            ) OR (
                    priorventstartoffset IS NOT NULL
                AND priorventstartoffset < 60
                AND COALESCE(priorventendoffset, 999999) > -60
            )
            THEN 1 ELSE 0
        END) AS respiratorycare_vent_entry_1h_window,
        MAX(CASE
            WHEN COALESCE(ventstartoffset, respcarestatusoffset, 0) < 1440
             AND COALESCE(ventendoffset, 1440) > 0
            THEN 1 ELSE 0
        END) AS respiratorycare_vent_24h
    FROM eicu_crd.respiratorycare
    GROUP BY patientunitstayid
),
vaso AS MATERIALIZED (
    SELECT
        patientunitstayid,
        MAX(CASE
            WHEN infusionoffset >= -360
             AND infusionoffset <= 0
             AND lower(COALESCE(drugname, '')) SIMILAR TO '%(norepinephrine|levophed|epinephrine|phenylephrine|vasopressin|dopamine|dobutamine)%'
            THEN 1 ELSE 0
        END) AS vasopressor_prior_or_at_entry_6h,
        MAX(CASE
            WHEN infusionoffset >= -60
             AND infusionoffset <= 60
             AND lower(COALESCE(drugname, '')) SIMILAR TO '%(norepinephrine|levophed|epinephrine|phenylephrine|vasopressin|dopamine|dobutamine)%'
            THEN 1 ELSE 0
        END) AS vasopressor_entry_1h_window,
        MAX(CASE
            WHEN infusionoffset >= 0
             AND infusionoffset < 1440
             AND lower(COALESCE(drugname, '')) SIMILAR TO '%(norepinephrine|levophed|epinephrine|phenylephrine|vasopressin|dopamine|dobutamine)%'
            THEN 1 ELSE 0
        END) AS vasopressor_24h
    FROM eicu_crd.infusiondrug
    GROUP BY patientunitstayid
),
history AS MATERIALIZED (
    SELECT
        patientunitstayid,
        1 AS any_pasthistory_record,
        MAX(CASE WHEN lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%heart failure%' THEN 1 ELSE 0 END) AS hx_congestive_heart_failure,
        MAX(CASE WHEN lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%diabetes%' THEN 1 ELSE 0 END) AS hx_diabetes,
        MAX(CASE
            WHEN lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%copd%'
              OR lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%chronic obstructive%'
            THEN 1 ELSE 0
        END) AS hx_chronic_pulmonary_disease,
        MAX(CASE
            WHEN lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%renal%'
              OR lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%kidney%'
              OR lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%dialysis%'
            THEN 1 ELSE 0
        END) AS hx_renal_disease,
        MAX(CASE
            WHEN lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%cirrhosis%'
              OR lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%liver%'
              OR lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%hepatic%'
            THEN 1 ELSE 0
        END) AS hx_liver_disease,
        MAX(CASE
            WHEN lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%cancer%'
              OR lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%malign%'
              OR lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%metastatic%'
              OR lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%leukemia%'
              OR lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%lymphoma%'
            THEN 1 ELSE 0
        END) AS hx_malignancy,
        MAX(CASE
            WHEN lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%stroke%'
              OR lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%cva%'
              OR lower(COALESCE(pasthistorypath, '') || ' ' || COALESCE(pasthistoryvalue, '') || ' ' || COALESCE(pasthistoryvaluetext, '')) LIKE '%cerebrovascular%'
            THEN 1 ELSE 0
        END) AS hx_cerebrovascular_disease
    FROM eicu_crd.pasthistory
    GROUP BY patientunitstayid
),
labs AS MATERIALIZED (
    SELECT
        l.patientunitstayid,
        MAX(l.labresult) FILTER (WHERE lower(l.labname) = 'lactate' AND l.labresult BETWEEN 0 AND 30) AS lactate_max_24h,
        MIN(l.labresult) FILTER (WHERE l.labname = 'Hgb' AND l.labresult BETWEEN 3 AND 25) AS hemoglobin_min_24h,
        MAX(l.labresult) FILTER (WHERE l.labname = 'WBC x 1000' AND l.labresult BETWEEN 0 AND 200) AS wbc_max_24h,
        MAX(l.labresult) FILTER (WHERE lower(l.labname) = 'creatinine' AND l.labresult BETWEEN 0 AND 20) AS creatinine_max_24h,
        MIN(l.labresult) FILTER (WHERE lower(l.labname) = 'sodium' AND l.labresult BETWEEN 100 AND 180) AS sodium_min_24h,
        MAX(l.labresult) FILTER (WHERE lower(l.labname) = 'sodium' AND l.labresult BETWEEN 100 AND 180) AS sodium_max_24h,
        MAX(l.labresult) FILTER (WHERE lower(l.labname) = 'glucose' AND l.labresult BETWEEN 20 AND 1000) AS glucose_max_24h,
        MIN(l.labresult) FILTER (WHERE l.labname = 'platelets x 1000' AND l.labresult BETWEEN 0 AND 2000) AS platelet_min_24h,
        MAX(l.labresult) FILTER (WHERE l.labname = 'PT - INR' AND l.labresult BETWEEN 0.5 AND 20) AS inr_max_24h,
        MAX(l.labresult) FILTER (WHERE l.labname = 'PT' AND l.labresult BETWEEN 5 AND 200) AS pt_max_24h,
        MAX(l.labresult) FILTER (WHERE l.labname = 'PTT' AND l.labresult BETWEEN 10 AND 300) AS ptt_max_24h
    FROM eicu_crd.lab l
    JOIN strict_severe ss
      ON ss.patientunitstayid = l.patientunitstayid
    WHERE l.labresultoffset >= 0
      AND l.labresultoffset < 1440
    GROUP BY l.patientunitstayid
)
SELECT
    'eICU'::text AS database_name,
    ss.patientunitstayid,
    ss.patienthealthsystemstayid,
    ss.hospitalid,
    ss.age_num AS age,
    ss.gender,
    CASE WHEN lower(COALESCE(ss.gender, '')) = 'male' THEN 1 WHEN lower(COALESCE(ss.gender, '')) = 'female' THEN 0 ELSE NULL END AS sex_male,
    ss.ethnicity,
    ss.apacheadmissiondx,
    ss.apache_gcs AS gcs_total,
    ss.eyes AS gcs_eyes,
    ss.motor AS gcs_motor,
    ss.verbal AS gcs_verbal,
    ss.death_icu,
    ss.death_hospital,
    COALESCE(ss.tbi_subdural, 0) AS tbi_subdural,
    COALESCE(ss.tbi_subarachnoid, 0) AS tbi_subarachnoid,
    COALESCE(ss.tbi_epidural, 0) AS tbi_epidural,
    COALESCE(ss.tbi_intracerebral_hemorrhage, 0) AS tbi_intracerebral_hemorrhage,
    COALESCE(ss.tbi_contusion_or_laceration, 0) AS tbi_contusion_or_laceration,
    COALESCE(ss.tbi_diffuse_axonal_injury, 0) AS tbi_diffuse_axonal_injury,
    COALESCE(ss.tbi_herniation, 0) AS tbi_herniation,
    COALESCE(ss.tbi_edema, 0) AS tbi_edema,
    COALESCE(ss.intubated, 0) AS apache_intubated,
    COALESCE(ss.vent, 0) AS apache_vent,
    COALESCE(pred.apache_vent_day1, 0) AS apache_vent_day1,
    COALESCE(resp.respiratorycare_vent_at_entry, 0) AS respiratorycare_vent_at_entry,
    COALESCE(resp.respiratorycare_vent_entry_1h_window, 0) AS respiratorycare_vent_entry_1h_window,
    CASE
        WHEN COALESCE(ss.intubated, 0) = 1
          OR COALESCE(ss.vent, 0) = 1
          OR COALESCE(resp.respiratorycare_vent_at_entry, 0) = 1
        THEN 1 ELSE 0
    END AS mechanical_vent_baseline_proxy,
    CASE
        WHEN COALESCE(ss.intubated, 0) = 1
          OR COALESCE(ss.vent, 0) = 1
          OR COALESCE(resp.respiratorycare_vent_entry_1h_window, 0) = 1
        THEN 1 ELSE 0
    END AS mechanical_vent_entry_1h_proxy,
    COALESCE(resp.respiratorycare_vent_24h, 0) AS respiratorycare_vent_24h,
    CASE
        WHEN COALESCE(ss.intubated, 0) = 1
          OR COALESCE(ss.vent, 0) = 1
          OR COALESCE(pred.apache_vent_day1, 0) = 1
          OR COALESCE(resp.respiratorycare_vent_24h, 0) = 1
        THEN 1 ELSE 0
    END AS mechanical_vent_24h,
    COALESCE(vaso.vasopressor_prior_or_at_entry_6h, 0) AS vasopressor_prior_or_at_entry_6h,
    COALESCE(vaso.vasopressor_entry_1h_window, 0) AS vasopressor_entry_1h_window,
    COALESCE(vaso.vasopressor_24h, 0) AS vasopressor_24h,
    COALESCE(history.any_pasthistory_record, 0) AS any_pasthistory_record,
    COALESCE(history.hx_congestive_heart_failure, 0) AS hx_congestive_heart_failure,
    COALESCE(history.hx_diabetes, 0) AS hx_diabetes,
    COALESCE(history.hx_chronic_pulmonary_disease, 0) AS hx_chronic_pulmonary_disease,
    COALESCE(history.hx_renal_disease, 0) AS hx_renal_disease,
    COALESCE(history.hx_liver_disease, 0) AS hx_liver_disease,
    COALESCE(history.hx_malignancy, 0) AS hx_malignancy,
    COALESCE(history.hx_cerebrovascular_disease, 0) AS hx_cerebrovascular_disease,
    severity.eicu_acute_physiology_score,
    severity.eicu_apache_score,
    severity.eicu_predicted_icu_mortality,
    severity.eicu_predicted_hospital_mortality,
    labs.lactate_max_24h,
    labs.hemoglobin_min_24h,
    labs.wbc_max_24h,
    labs.creatinine_max_24h,
    labs.sodium_min_24h,
    labs.sodium_max_24h,
    labs.glucose_max_24h,
    labs.platelet_min_24h,
    labs.inr_max_24h,
    labs.pt_max_24h,
    labs.ptt_max_24h
FROM strict_severe ss
LEFT JOIN severity
  ON severity.patientunitstayid = ss.patientunitstayid
LEFT JOIN pred
  ON pred.patientunitstayid = ss.patientunitstayid
LEFT JOIN resp
  ON resp.patientunitstayid = ss.patientunitstayid
LEFT JOIN vaso
  ON vaso.patientunitstayid = ss.patientunitstayid
LEFT JOIN history
  ON history.patientunitstayid = ss.patientunitstayid
LEFT JOIN labs
  ON labs.patientunitstayid = ss.patientunitstayid
ORDER BY ss.patientunitstayid;

-- eICU 24h hypotension-hypoxemia burden table.
-- Anchor: eICU unit admission offset 0 minutes.
-- Population: adult first ICU unit, strict intracranial TBI, APACHE GCS <= 8.
-- Window: [0, min(24h, ICU unit discharge)].
-- Main exposure: time-weighted average deficit, not absolute cumulative area.

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
        MAX(
            CASE
                WHEN lower(COALESCE(d.diagnosisstring, '')) LIKE '%trauma - cns|intracranial injury%'
                  OR lower(COALESCE(d.diagnosisstring, '')) LIKE '%cerebral subdural hematoma|secondary to trauma%'
                THEN 1 ELSE 0
            END
        ) AS intracranial_tbi_dx
    FROM eicu_crd.diagnosis d
    GROUP BY d.patientunitstayid
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
        END AS death_icu,
        CASE
            WHEN a.hospitaldischargestatus = 'Expired' THEN 1
            WHEN a.hospitaldischargestatus IS NULL OR btrim(a.hospitaldischargestatus) = '' THEN NULL
            ELSE 0
        END AS death_hospital,
        gcs.apache_gcs,
        COALESCE(dx.intracranial_tbi_dx, 0) AS intracranial_tbi_dx
    FROM adult a
    LEFT JOIN dx_flags dx
      ON dx.patientunitstayid = a.patientunitstayid
    LEFT JOIN gcs
      ON gcs.patientunitstayid = a.patientunitstayid
),
strict_severe AS MATERIALIZED (
    SELECT
        *,
        LEAST(
            1440.0,
            CASE
                WHEN unitdischargeoffset IS NOT NULL AND unitdischargeoffset > 0
                THEN unitdischargeoffset::numeric
                ELSE 1440.0
            END
        ) AS window_end_min
    FROM cohort
    WHERE intracranial_tbi_dx = 1
      AND apache_gcs <= 8
),
map_raw AS MATERIALIZED (
    SELECT
        ss.patientunitstayid,
        v.observationoffset::numeric AS event_min,
        'map_invasive'::text AS source_name,
        1 AS source_priority,
        15.0 AS carry_forward_cap_min,
        AVG(v.systemicmean::numeric) AS value_num,
        COUNT(*) AS raw_records
    FROM strict_severe ss
    JOIN eicu_crd.vitalperiodic v
      ON v.patientunitstayid = ss.patientunitstayid
    WHERE v.observationoffset >= 0
      AND v.observationoffset < ss.window_end_min
      AND v.systemicmean BETWEEN 20 AND 200
    GROUP BY ss.patientunitstayid, v.observationoffset

    UNION ALL

    SELECT
        ss.patientunitstayid,
        v.observationoffset::numeric AS event_min,
        'map_noninvasive'::text AS source_name,
        2 AS source_priority,
        60.0 AS carry_forward_cap_min,
        AVG(v.noninvasivemean::numeric) AS value_num,
        COUNT(*) AS raw_records
    FROM strict_severe ss
    JOIN eicu_crd.vitalaperiodic v
      ON v.patientunitstayid = ss.patientunitstayid
    WHERE v.observationoffset >= 0
      AND v.observationoffset < ss.window_end_min
      AND v.noninvasivemean BETWEEN 20 AND 200
    GROUP BY ss.patientunitstayid, v.observationoffset
),
map_ranked AS MATERIALIZED (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY patientunitstayid, event_min
            ORDER BY source_priority
        ) AS rn
    FROM map_raw
),
map_events AS MATERIALIZED (
    SELECT
        patientunitstayid,
        'map'::text AS variable_name,
        source_name,
        event_min,
        value_num,
        carry_forward_cap_min,
        CASE
            WHEN carry_forward_cap_min * 2.0 < 120.0 THEN carry_forward_cap_min * 2.0
            ELSE 120.0
        END AS hard_gap_min,
        raw_records
    FROM map_ranked
    WHERE rn = 1
),
spo2_events AS MATERIALIZED (
    SELECT
        ss.patientunitstayid,
        'spo2'::text AS variable_name,
        'spo2_periodic'::text AS source_name,
        v.observationoffset::numeric AS event_min,
        AVG(v.sao2::numeric) AS value_num,
        15.0 AS carry_forward_cap_min,
        30.0 AS hard_gap_min,
        COUNT(*) AS raw_records
    FROM strict_severe ss
    JOIN eicu_crd.vitalperiodic v
      ON v.patientunitstayid = ss.patientunitstayid
    WHERE v.observationoffset >= 0
      AND v.observationoffset < ss.window_end_min
      AND v.sao2 BETWEEN 50 AND 100
    GROUP BY ss.patientunitstayid, v.observationoffset
),
all_events AS MATERIALIZED (
    SELECT * FROM map_events
    UNION ALL
    SELECT * FROM spo2_events
),
events_with_next AS MATERIALIZED (
    SELECT
        e.*,
        ss.window_end_min,
        LEAD(e.event_min) OVER (
            PARTITION BY e.patientunitstayid, e.variable_name
            ORDER BY e.event_min
        ) AS next_event_min
    FROM all_events e
    JOIN strict_severe ss
      ON ss.patientunitstayid = e.patientunitstayid
),
intervals AS MATERIALIZED (
    SELECT
        *,
        GREATEST(
            0.0,
            LEAST(COALESCE(next_event_min, window_end_min), window_end_min) - event_min
        ) AS raw_interval_min,
        LEAST(
            GREATEST(
                0.0,
                LEAST(COALESCE(next_event_min, window_end_min), window_end_min) - event_min
            ),
            carry_forward_cap_min
        ) AS effective_interval_min,
        CASE
            WHEN GREATEST(
                0.0,
                LEAST(COALESCE(next_event_min, window_end_min), window_end_min) - event_min
            ) > hard_gap_min
            THEN 1 ELSE 0
        END AS hard_gap_truncated
    FROM events_with_next
),
burden_by_stay AS MATERIALIZED (
    SELECT
        patientunitstayid,
        COUNT(*) FILTER (WHERE variable_name = 'map') AS map_records,
        COUNT(*) FILTER (WHERE variable_name = 'map' AND source_name = 'map_invasive') AS map_invasive_records,
        COUNT(*) FILTER (WHERE variable_name = 'map' AND source_name = 'map_noninvasive') AS map_noninvasive_records,
        COUNT(*) FILTER (WHERE variable_name = 'spo2') AS spo2_records,
        SUM(effective_interval_min) FILTER (WHERE variable_name = 'map') AS map_effective_min,
        SUM(effective_interval_min) FILTER (WHERE variable_name = 'spo2') AS spo2_effective_min,
        SUM(GREATEST(raw_interval_min - effective_interval_min, 0.0)) FILTER (WHERE variable_name = 'map') AS map_unobserved_gap_min,
        SUM(GREATEST(raw_interval_min - effective_interval_min, 0.0)) FILTER (WHERE variable_name = 'spo2') AS spo2_unobserved_gap_min,
        SUM(hard_gap_truncated) FILTER (WHERE variable_name = 'map') AS map_hard_gap_intervals,
        SUM(hard_gap_truncated) FILTER (WHERE variable_name = 'spo2') AS spo2_hard_gap_intervals,
        SUM(CASE WHEN variable_name = 'map' AND value_num < 65 THEN effective_interval_min ELSE 0.0 END) AS hypotension_minutes,
        SUM(CASE WHEN variable_name = 'spo2' AND value_num < 90 THEN effective_interval_min ELSE 0.0 END) AS hypoxemia_minutes,
        SUM(CASE WHEN variable_name = 'map' THEN GREATEST(65.0 - value_num, 0.0) * effective_interval_min ELSE 0.0 END) AS hypotension_area,
        SUM(CASE WHEN variable_name = 'spo2' THEN GREATEST(90.0 - value_num, 0.0) * effective_interval_min ELSE 0.0 END) AS hypoxemia_area
    FROM intervals
    GROUP BY patientunitstayid
),
features AS MATERIALIZED (
    SELECT
        'eICU'::text AS database_name,
        ss.patientunitstayid::text AS stay_key,
        ss.patientunitstayid,
        ss.patienthealthsystemstayid,
        ss.apache_gcs,
        ss.unitdischargeoffset,
        ss.window_end_min,
        ss.death_icu,
        ss.death_hospital,
        COALESCE(b.map_records, 0) AS map_records,
        COALESCE(b.map_invasive_records, 0) AS map_invasive_records,
        COALESCE(b.map_noninvasive_records, 0) AS map_noninvasive_records,
        COALESCE(b.spo2_records, 0) AS spo2_records,
        COALESCE(b.map_effective_min, 0.0) AS map_effective_min,
        COALESCE(b.spo2_effective_min, 0.0) AS spo2_effective_min,
        COALESCE(b.map_effective_min, 0.0) / 60.0 AS map_effective_hours,
        COALESCE(b.spo2_effective_min, 0.0) / 60.0 AS spo2_effective_hours,
        CASE WHEN ss.window_end_min > 0 THEN COALESCE(b.map_effective_min, 0.0) / ss.window_end_min ELSE NULL END AS map_observed_window_fraction,
        CASE WHEN ss.window_end_min > 0 THEN COALESCE(b.spo2_effective_min, 0.0) / ss.window_end_min ELSE NULL END AS spo2_observed_window_fraction,
        COALESCE(b.map_unobserved_gap_min, 0.0) AS map_unobserved_gap_min,
        COALESCE(b.spo2_unobserved_gap_min, 0.0) AS spo2_unobserved_gap_min,
        COALESCE(b.map_hard_gap_intervals, 0) AS map_hard_gap_intervals,
        COALESCE(b.spo2_hard_gap_intervals, 0) AS spo2_hard_gap_intervals,
        COALESCE(b.hypotension_minutes, 0.0) AS hypotension_minutes,
        COALESCE(b.hypoxemia_minutes, 0.0) AS hypoxemia_minutes,
        COALESCE(b.hypotension_area, 0.0) AS hypotension_area,
        COALESCE(b.hypoxemia_area, 0.0) AS hypoxemia_area,
        CASE
            WHEN COALESCE(b.map_effective_min, 0.0) > 0
            THEN b.hypotension_area / b.map_effective_min
            ELSE NULL
        END AS hypotension_twa,
        CASE
            WHEN COALESCE(b.spo2_effective_min, 0.0) > 0
            THEN b.hypoxemia_area / b.spo2_effective_min
            ELSE NULL
        END AS hypoxemia_twa,
        CASE
            WHEN COALESCE(b.map_effective_min, 0.0) >= 720.0
             AND COALESCE(b.spo2_effective_min, 0.0) >= 720.0
            THEN 1 ELSE 0
        END AS eligible_24h_12h_coverage,
        CASE
            WHEN ss.window_end_min > 0
             AND COALESCE(b.map_effective_min, 0.0) >= ss.window_end_min * 0.5
             AND COALESCE(b.spo2_effective_min, 0.0) >= ss.window_end_min * 0.5
            THEN 1 ELSE 0
        END AS eligible_observed_window_50pct,
        CASE WHEN ss.window_end_min >= 1440.0 THEN 1 ELSE 0 END AS survived_or_remained_icu_24h
    FROM strict_severe ss
    LEFT JOIN burden_by_stay b
      ON b.patientunitstayid = ss.patientunitstayid
),
standardizers AS MATERIALIZED (
    SELECT
        AVG(hypotension_twa) FILTER (WHERE eligible_24h_12h_coverage = 1) AS hypotension_mean,
        NULLIF(STDDEV_SAMP(hypotension_twa) FILTER (WHERE eligible_24h_12h_coverage = 1), 0.0) AS hypotension_sd,
        AVG(hypoxemia_twa) FILTER (WHERE eligible_24h_12h_coverage = 1) AS hypoxemia_mean,
        NULLIF(STDDEV_SAMP(hypoxemia_twa) FILTER (WHERE eligible_24h_12h_coverage = 1), 0.0) AS hypoxemia_sd
    FROM features
),
scored AS MATERIALIZED (
    SELECT
        f.*,
        CASE
            WHEN f.eligible_24h_12h_coverage = 1 AND s.hypotension_sd IS NOT NULL
            THEN (f.hypotension_twa - s.hypotension_mean) / s.hypotension_sd
            ELSE NULL
        END AS hypotension_z,
        CASE
            WHEN f.eligible_24h_12h_coverage = 1 AND s.hypoxemia_sd IS NOT NULL
            THEN (f.hypoxemia_twa - s.hypoxemia_mean) / s.hypoxemia_sd
            ELSE NULL
        END AS hypoxemia_z
    FROM features f
    CROSS JOIN standardizers s
),
scored2 AS MATERIALIZED (
    SELECT
        *,
        CASE
            WHEN hypotension_z IS NOT NULL AND hypoxemia_z IS NOT NULL
            THEN hypotension_z + hypoxemia_z
            ELSE NULL
        END AS combined_burden_z
    FROM scored
),
quartiles AS MATERIALIZED (
    SELECT
        patientunitstayid,
        NTILE(4) OVER (ORDER BY combined_burden_z) AS combined_burden_quartile
    FROM scored2
    WHERE eligible_24h_12h_coverage = 1
      AND combined_burden_z IS NOT NULL
)
SELECT
    s.database_name,
    s.stay_key,
    s.patientunitstayid,
    s.patienthealthsystemstayid,
    s.apache_gcs,
    s.unitdischargeoffset,
    ROUND(s.window_end_min, 3) AS window_end_min,
    s.survived_or_remained_icu_24h,
    s.death_icu,
    s.death_hospital,
    s.map_records,
    s.map_invasive_records,
    s.map_noninvasive_records,
    s.spo2_records,
    ROUND(s.map_effective_min, 3) AS map_effective_min,
    ROUND(s.spo2_effective_min, 3) AS spo2_effective_min,
    ROUND(s.map_effective_hours, 3) AS map_effective_hours,
    ROUND(s.spo2_effective_hours, 3) AS spo2_effective_hours,
    ROUND(s.map_observed_window_fraction, 4) AS map_observed_window_fraction,
    ROUND(s.spo2_observed_window_fraction, 4) AS spo2_observed_window_fraction,
    ROUND(s.map_unobserved_gap_min, 3) AS map_unobserved_gap_min,
    ROUND(s.spo2_unobserved_gap_min, 3) AS spo2_unobserved_gap_min,
    s.map_hard_gap_intervals,
    s.spo2_hard_gap_intervals,
    ROUND(s.hypotension_minutes, 3) AS hypotension_minutes,
    ROUND(s.hypoxemia_minutes, 3) AS hypoxemia_minutes,
    ROUND(s.hypotension_area, 3) AS hypotension_area,
    ROUND(s.hypoxemia_area, 3) AS hypoxemia_area,
    ROUND(s.hypotension_twa, 6) AS hypotension_twa,
    ROUND(s.hypoxemia_twa, 6) AS hypoxemia_twa,
    ROUND(s.hypotension_z, 6) AS hypotension_z,
    ROUND(s.hypoxemia_z, 6) AS hypoxemia_z,
    ROUND(s.combined_burden_z, 6) AS combined_burden_z,
    q.combined_burden_quartile,
    s.eligible_24h_12h_coverage,
    s.eligible_observed_window_50pct
FROM scored2 s
LEFT JOIN quartiles q
  ON q.patientunitstayid = s.patientunitstayid
ORDER BY s.patientunitstayid;

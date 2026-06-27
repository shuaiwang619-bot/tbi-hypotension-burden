-- MIMIC-IV 24h hypotension-hypoxemia burden table.
-- Anchor: mimiciv_icu.icustays.intime.
-- Population: adult first ICU stay within hospitalization, strict intracranial TBI, first-day GCS <= 8.
-- Window: [ICU intime, min(24h, ICU outtime, ICU death if inside ICU)].
-- Main exposure: time-weighted average deficit, not absolute cumulative area.

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
        ) AS strict_tbi_dx
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
        a.deathtime,
        CASE
            WHEN a.deathtime IS NOT NULL
             AND a.deathtime >= a.intime
             AND a.deathtime <= a.outtime
            THEN 1 ELSE 0
        END AS death_icu,
        a.hospital_expire_flag AS death_hospital,
        g.gcs_min,
        COALESCE(dx.strict_tbi_dx, 0) AS strict_tbi_dx
    FROM adult a
    LEFT JOIN dx_flags dx
      ON dx.hadm_id = a.hadm_id
    LEFT JOIN mimiciv_derived.first_day_gcs g
      ON g.stay_id = a.stay_id
),
strict_severe AS MATERIALIZED (
    SELECT
        *,
        EXTRACT(EPOCH FROM (
            LEAST(
                outtime,
                intime + INTERVAL '24 hours',
                CASE
                    WHEN death_icu = 1 THEN deathtime
                    ELSE intime + INTERVAL '24 hours'
                END
            ) - intime
        )) / 60.0 AS window_end_min
    FROM cohort
    WHERE strict_tbi_dx = 1
      AND gcs_min <= 8
),
map_raw AS MATERIALIZED (
    SELECT
        ss.stay_id,
        EXTRACT(EPOCH FROM (ce.charttime - ss.intime)) / 60.0 AS event_min,
        CASE
            WHEN ce.itemid = 220052 THEN 'map_invasive'
            WHEN ce.itemid = 220181 THEN 'map_noninvasive'
        END AS source_name,
        CASE
            WHEN ce.itemid = 220052 THEN 1
            WHEN ce.itemid = 220181 THEN 2
        END AS source_priority,
        60.0 AS carry_forward_cap_min,
        AVG(ce.valuenum::numeric) AS value_num,
        COUNT(*) AS raw_records
    FROM strict_severe ss
    JOIN mimiciv_icu.chartevents ce
      ON ce.stay_id = ss.stay_id
    WHERE ce.itemid IN (220052, 220181)
      AND ce.charttime >= ss.intime
      AND ce.charttime < ss.intime + (ss.window_end_min || ' minutes')::interval
      AND ce.valuenum BETWEEN 20 AND 200
    GROUP BY ss.stay_id, ce.charttime, ce.itemid, ss.intime
),
map_ranked AS MATERIALIZED (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY stay_id, event_min
            ORDER BY source_priority
        ) AS rn
    FROM map_raw
),
map_events AS MATERIALIZED (
    SELECT
        stay_id,
        'map'::text AS variable_name,
        source_name,
        event_min,
        value_num,
        carry_forward_cap_min,
        120.0 AS hard_gap_min,
        raw_records
    FROM map_ranked
    WHERE rn = 1
),
spo2_events AS MATERIALIZED (
    SELECT
        ss.stay_id,
        'spo2'::text AS variable_name,
        'spo2_chartevents'::text AS source_name,
        EXTRACT(EPOCH FROM (ce.charttime - ss.intime)) / 60.0 AS event_min,
        AVG(ce.valuenum::numeric) AS value_num,
        60.0 AS carry_forward_cap_min,
        120.0 AS hard_gap_min,
        COUNT(*) AS raw_records
    FROM strict_severe ss
    JOIN mimiciv_icu.chartevents ce
      ON ce.stay_id = ss.stay_id
    WHERE ce.itemid = 220277
      AND ce.charttime >= ss.intime
      AND ce.charttime < ss.intime + (ss.window_end_min || ' minutes')::interval
      AND ce.valuenum BETWEEN 50 AND 100
    GROUP BY ss.stay_id, ce.charttime, ss.intime
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
            PARTITION BY e.stay_id, e.variable_name
            ORDER BY e.event_min
        ) AS next_event_min
    FROM all_events e
    JOIN strict_severe ss
      ON ss.stay_id = e.stay_id
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
        stay_id,
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
    GROUP BY stay_id
),
features AS MATERIALIZED (
    SELECT
        'MIMIC-IV'::text AS database_name,
        ss.stay_id::text AS stay_key,
        ss.subject_id,
        ss.hadm_id,
        ss.stay_id,
        ss.gcs_min,
        ROUND(ss.window_end_min, 6) AS window_end_min,
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
      ON b.stay_id = ss.stay_id
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
        stay_id,
        NTILE(4) OVER (ORDER BY combined_burden_z) AS combined_burden_quartile
    FROM scored2
    WHERE eligible_24h_12h_coverage = 1
      AND combined_burden_z IS NOT NULL
)
SELECT
    s.database_name,
    s.stay_key,
    s.subject_id,
    s.hadm_id,
    s.stay_id,
    s.gcs_min,
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
  ON q.stay_id = s.stay_id
ORDER BY s.subject_id, s.hadm_id, s.stay_id;

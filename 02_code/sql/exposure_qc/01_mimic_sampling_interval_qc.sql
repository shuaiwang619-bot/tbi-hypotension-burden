-- MIMIC-IV exposure QC for severe intracranial TBI.
-- Output level: aggregate sampling interval and source-coverage summaries only.
-- No patient-level rows are exported.
-- Primary cohort: adult first ICU stay, strict intracranial TBI, first-day GCS <= 8.
-- Time zero: mimiciv_icu.icustays.intime.
-- MAP and SpO2 are extracted from raw chartevents itemids:
--   220052 = Arterial Blood Pressure mean, ABPm, mmHg
--   220181 = Non Invasive Blood Pressure mean, NBPm, mmHg
--   220277 = O2 saturation pulseoxymetry, SpO2, %

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
strict_severe AS MATERIALIZED (
    SELECT
        a.subject_id,
        a.hadm_id,
        a.stay_id,
        a.intime,
        a.outtime
    FROM adult a
    JOIN dx_flags dx
      ON dx.hadm_id = a.hadm_id
     AND dx.strict_tbi_dx = 1
    JOIN mimiciv_derived.first_day_gcs g
      ON g.stay_id = a.stay_id
     AND g.gcs_min <= 8
),
raw_events AS MATERIALIZED (
    SELECT DISTINCT
        ce.stay_id,
        CASE
            WHEN ce.itemid IN (220052, 220181) THEN 'map'
            WHEN ce.itemid = 220277 THEN 'spo2'
        END AS variable,
        CASE
            WHEN ce.itemid = 220052 THEN 'invasive_map_chartevents_220052'
            WHEN ce.itemid = 220181 THEN 'noninvasive_map_chartevents_220181'
            WHEN ce.itemid = 220277 THEN 'spo2_chartevents_220277'
        END AS source,
        EXTRACT(EPOCH FROM (ce.charttime - ss.intime)) / 60.0 AS event_min
    FROM mimiciv_icu.chartevents ce
    JOIN strict_severe ss
      ON ss.stay_id = ce.stay_id
    WHERE ce.charttime >= ss.intime
      AND ce.charttime < ss.intime + INTERVAL '72 hours'
      AND (
            (ce.itemid IN (220052, 220181) AND ce.valuenum BETWEEN 20 AND 200)
         OR (ce.itemid = 220277 AND ce.valuenum BETWEEN 50 AND 100)
      )
),
events AS MATERIALIZED (
    SELECT DISTINCT
        stay_id,
        variable,
        source,
        event_min
    FROM raw_events

    UNION ALL

    SELECT DISTINCT
        stay_id,
        'map'::text AS variable,
        'merged_any_map_distinct_charttimes'::text AS source,
        event_min
    FROM raw_events
    WHERE variable = 'map'
),
windows AS MATERIALIZED (
    SELECT *
    FROM (
        VALUES
            (24::int, 1440::numeric),
            (72::int, 4320::numeric)
    ) AS v(window_hours, window_min)
),
events_window AS MATERIALIZED (
    SELECT
        w.window_hours,
        e.stay_id,
        e.variable,
        e.source,
        e.event_min
    FROM events e
    JOIN windows w
      ON e.event_min >= 0
     AND e.event_min < w.window_min
),
combos AS MATERIALIZED (
    SELECT DISTINCT
        variable,
        source,
        window_hours
    FROM events_window
),
records_by_stay AS MATERIALIZED (
    SELECT
        variable,
        source,
        window_hours,
        stay_id,
        COUNT(*) AS record_n
    FROM events_window
    GROUP BY variable, source, window_hours, stay_id
),
lagged AS MATERIALIZED (
    SELECT
        variable,
        source,
        window_hours,
        stay_id,
        event_min,
        LAG(event_min) OVER (
            PARTITION BY variable, source, window_hours, stay_id
            ORDER BY event_min
        ) AS prev_event_min
    FROM events_window
),
intervals AS MATERIALIZED (
    SELECT
        variable,
        source,
        window_hours,
        stay_id,
        event_min - prev_event_min AS interval_min
    FROM lagged
    WHERE prev_event_min IS NOT NULL
      AND event_min >= prev_event_min
),
record_summary AS MATERIALIZED (
    SELECT
        c.variable,
        c.source,
        c.window_hours,
        (SELECT COUNT(*) FROM strict_severe) AS denominator_n,
        COUNT(rb.stay_id) AS stays_with_records,
        COALESCE(SUM(rb.record_n), 0) AS total_records,
        percentile_cont(0.25) WITHIN GROUP (ORDER BY rb.record_n) AS records_p25,
        percentile_cont(0.50) WITHIN GROUP (ORDER BY rb.record_n) AS records_median,
        percentile_cont(0.75) WITHIN GROUP (ORDER BY rb.record_n) AS records_p75
    FROM combos c
    LEFT JOIN records_by_stay rb
      ON rb.variable = c.variable
     AND rb.source = c.source
     AND rb.window_hours = c.window_hours
    GROUP BY c.variable, c.source, c.window_hours
),
interval_summary AS MATERIALIZED (
    SELECT
        variable,
        source,
        window_hours,
        COUNT(*) AS interval_n,
        percentile_cont(0.25) WITHIN GROUP (ORDER BY interval_min) AS interval_p25_min,
        percentile_cont(0.50) WITHIN GROUP (ORDER BY interval_min) AS interval_median_min,
        percentile_cont(0.75) WITHIN GROUP (ORDER BY interval_min) AS interval_p75_min,
        percentile_cont(0.90) WITHIN GROUP (ORDER BY interval_min) AS interval_p90_min,
        percentile_cont(0.95) WITHIN GROUP (ORDER BY interval_min) AS interval_p95_min,
        percentile_cont(0.99) WITHIN GROUP (ORDER BY interval_min) AS interval_p99_min,
        ROUND(100.0 * AVG((interval_min > 15)::int), 1) AS gap_gt_15_pct,
        ROUND(100.0 * AVG((interval_min > 30)::int), 1) AS gap_gt_30_pct,
        ROUND(100.0 * AVG((interval_min > 60)::int), 1) AS gap_gt_60_pct,
        ROUND(100.0 * AVG((interval_min > 120)::int), 1) AS gap_gt_120_pct
    FROM intervals
    GROUP BY variable, source, window_hours
)
SELECT
    'MIMIC-IV' AS database_name,
    'sampling_interval_qc' AS section,
    rs.variable,
    rs.source,
    rs.window_hours,
    rs.denominator_n,
    rs.stays_with_records,
    ROUND(100.0 * rs.stays_with_records / NULLIF(rs.denominator_n, 0), 1) AS stays_with_records_pct,
    rs.total_records,
    rs.records_p25,
    rs.records_median,
    rs.records_p75,
    COALESCE(isum.interval_n, 0) AS interval_n,
    isum.interval_p25_min,
    isum.interval_median_min,
    isum.interval_p75_min,
    isum.interval_p90_min,
    isum.interval_p95_min,
    isum.interval_p99_min,
    isum.gap_gt_15_pct,
    isum.gap_gt_30_pct,
    isum.gap_gt_60_pct,
    isum.gap_gt_120_pct,
    CASE
        WHEN rs.source = 'invasive_map_chartevents_220052'
        THEN '220052 Arterial Blood Pressure mean, ABPm, mmHg'
        WHEN rs.source = 'noninvasive_map_chartevents_220181'
        THEN '220181 Non Invasive Blood Pressure mean, NBPm, mmHg'
        WHEN rs.source = 'spo2_chartevents_220277'
        THEN '220277 O2 saturation pulseoxymetry, SpO2, percent'
        WHEN rs.source = 'merged_any_map_distinct_charttimes'
        THEN 'MAP merged for interval QC only; same-time invasive/noninvasive duplicates collapsed'
        ELSE 'Valid physiologic range applied before interval calculation'
    END AS notes
FROM record_summary rs
LEFT JOIN interval_summary isum
  ON isum.variable = rs.variable
 AND isum.source = rs.source
 AND isum.window_hours = rs.window_hours
ORDER BY rs.variable, rs.source, rs.window_hours;

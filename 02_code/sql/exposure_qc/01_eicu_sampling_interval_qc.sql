-- eICU exposure QC for severe intracranial TBI.
-- Output level: aggregate sampling interval and source-coverage summaries only.
-- No patient-level rows are exported.
-- Primary cohort: adult first ICU unit stay, strict intracranial TBI, APACHE GCS <= 8.
-- Time zero: eICU unit admission offset 0 minutes.

WITH adult_first AS MATERIALIZED (
    SELECT
        p.patientunitstayid,
        p.patienthealthsystemstayid,
        p.unitvisitnumber,
        p.hospitaladmitoffset,
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
strict_severe AS MATERIALIZED (
    SELECT
        a.patientunitstayid
    FROM adult a
    JOIN dx_flags dx
      ON dx.patientunitstayid = a.patientunitstayid
     AND dx.intracranial_tbi_dx = 1
    JOIN gcs
      ON gcs.patientunitstayid = a.patientunitstayid
     AND gcs.apache_gcs <= 8
),
raw_events AS MATERIALIZED (
    SELECT DISTINCT
        v.patientunitstayid,
        'map'::text AS variable,
        'invasive_map_vitalperiodic_systemicmean'::text AS source,
        v.observationoffset::numeric AS event_min
    FROM eicu_crd.vitalperiodic v
    JOIN strict_severe ss
      ON ss.patientunitstayid = v.patientunitstayid
    WHERE v.observationoffset >= 0
      AND v.observationoffset < 4320
      AND v.systemicmean BETWEEN 20 AND 200

    UNION ALL

    SELECT DISTINCT
        v.patientunitstayid,
        'map'::text AS variable,
        'noninvasive_map_vitalaperiodic_noninvasivemean'::text AS source,
        v.observationoffset::numeric AS event_min
    FROM eicu_crd.vitalaperiodic v
    JOIN strict_severe ss
      ON ss.patientunitstayid = v.patientunitstayid
    WHERE v.observationoffset >= 0
      AND v.observationoffset < 4320
      AND v.noninvasivemean BETWEEN 20 AND 200

    UNION ALL

    SELECT DISTINCT
        v.patientunitstayid,
        'spo2'::text AS variable,
        'spo2_vitalperiodic_sao2'::text AS source,
        v.observationoffset::numeric AS event_min
    FROM eicu_crd.vitalperiodic v
    JOIN strict_severe ss
      ON ss.patientunitstayid = v.patientunitstayid
    WHERE v.observationoffset >= 0
      AND v.observationoffset < 4320
      AND v.sao2 BETWEEN 50 AND 100
),
events AS MATERIALIZED (
    SELECT DISTINCT
        patientunitstayid,
        variable,
        source,
        event_min
    FROM raw_events

    UNION ALL

    SELECT DISTINCT
        patientunitstayid,
        'map'::text AS variable,
        'merged_any_map_distinct_offsets'::text AS source,
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
        e.patientunitstayid,
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
        patientunitstayid,
        COUNT(*) AS record_n
    FROM events_window
    GROUP BY variable, source, window_hours, patientunitstayid
),
lagged AS MATERIALIZED (
    SELECT
        variable,
        source,
        window_hours,
        patientunitstayid,
        event_min,
        LAG(event_min) OVER (
            PARTITION BY variable, source, window_hours, patientunitstayid
            ORDER BY event_min
        ) AS prev_event_min
    FROM events_window
),
intervals AS MATERIALIZED (
    SELECT
        variable,
        source,
        window_hours,
        patientunitstayid,
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
        COUNT(rb.patientunitstayid) AS stays_with_records,
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
    'eICU' AS database_name,
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
        WHEN rs.source = 'merged_any_map_distinct_offsets'
        THEN 'MAP merged for interval QC only; same-offset invasive/noninvasive duplicates collapsed'
        ELSE 'Valid physiologic range applied before interval calculation'
    END AS notes
FROM record_summary rs
LEFT JOIN interval_summary isum
  ON isum.variable = rs.variable
 AND isum.source = rs.source
 AND isum.window_hours = rs.window_hours
ORDER BY rs.variable, rs.source, rs.window_hours;

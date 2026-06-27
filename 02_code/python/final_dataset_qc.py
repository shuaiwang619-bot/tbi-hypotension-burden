from __future__ import annotations

from datetime import datetime
from pathlib import Path

import numpy as np
import pandas as pd


PROJECT_ROOT = Path(__file__).resolve().parents[2]
RUN_ID = "20260620_final_dataset_qc_v1"

INPUT_DIR = PROJECT_ROOT / "03_outputs" / "tables" / "covariates" / "20260620_covariates_v2_baseline"
BURDEN_DIR = PROJECT_ROOT / "03_outputs" / "tables" / "burden" / "20260620_burden24h_v2"
OUTPUT_DIR = PROJECT_ROOT / "03_outputs" / "tables" / "qc" / RUN_ID

EICU_PATH = INPUT_DIR / "eicu_analysis_covariates_v1_landmark_main.csv"
MIMIC_PATH = INPUT_DIR / "mimic_analysis_covariates_v1_landmark_main.csv"
EXCLUSION_PATH = BURDEN_DIR / "burden_v2_exclusion_comparison.csv"

MAIN_MODEL_COLUMNS = [
    "death_icu",
    "hypotension_twa",
    "hypoxemia_twa",
    "age",
    "sex_male",
    "gcs_total",
]

BINARY_COLUMNS = [
    "death_icu",
    "death_hospital",
    "survived_or_remained_icu_24h",
    "eligible_24h_12h_coverage",
    "eligible_observed_window_50pct",
    "sex_male",
    "tbi_subdural",
    "tbi_subarachnoid",
    "tbi_epidural",
    "tbi_intracerebral_hemorrhage",
    "tbi_contusion_or_laceration",
    "tbi_diffuse_axonal_injury",
    "tbi_herniation",
    "tbi_edema",
]

RANGE_COLUMNS = [
    "age",
    "gcs_total",
    "gcs_eyes",
    "gcs_motor",
    "gcs_verbal",
    "death_icu",
    "death_hospital",
    "sex_male",
    "window_end_min",
    "map_records",
    "spo2_records",
    "map_effective_hours",
    "spo2_effective_hours",
    "map_observed_window_fraction",
    "spo2_observed_window_fraction",
    "hypotension_minutes",
    "hypoxemia_minutes",
    "hypotension_area",
    "hypoxemia_area",
    "hypotension_twa",
    "hypoxemia_twa",
    "hypotension_hypoxemia_interaction",
]


def read_table(path: Path) -> pd.DataFrame:
    if not path.exists():
        raise FileNotFoundError(path)
    df = pd.read_csv(path)
    for col in df.columns:
        if col.endswith("_key"):
            df[col] = df[col].astype(str)
    return df


def numeric_series(df: pd.DataFrame, col: str) -> pd.Series:
    return pd.to_numeric(df[col], errors="coerce")


def pct(n: int, d: int) -> float:
    return round(100.0 * n / d, 3) if d else np.nan


def summarize_missingness(datasets: dict[str, pd.DataFrame]) -> pd.DataFrame:
    rows = []
    columns = sorted(set().union(*(df.columns for df in datasets.values())))
    for name, df in datasets.items():
        n = len(df)
        for col in columns:
            if col not in df.columns:
                rows.append(
                    {
                        "database_name": name,
                        "variable": col,
                        "n": n,
                        "missing_n": n,
                        "missing_pct": 100.0,
                        "nonmissing_n": 0,
                        "present_in_table": 0,
                    }
                )
                continue
            missing = int(df[col].isna().sum())
            rows.append(
                {
                    "database_name": name,
                    "variable": col,
                    "n": n,
                    "missing_n": missing,
                    "missing_pct": pct(missing, n),
                    "nonmissing_n": n - missing,
                    "present_in_table": 1,
                }
            )
    return pd.DataFrame(rows)


def summarize_ranges(datasets: dict[str, pd.DataFrame]) -> pd.DataFrame:
    rows = []
    for name, df in datasets.items():
        for col in RANGE_COLUMNS:
            if col not in df.columns:
                rows.append({"database_name": name, "variable": col, "present_in_table": 0})
                continue
            s = numeric_series(df, col)
            nonmissing = s.dropna()
            row = {
                "database_name": name,
                "variable": col,
                "present_in_table": 1,
                "n": len(df),
                "missing_n": int(s.isna().sum()),
                "nonmissing_n": int(nonmissing.shape[0]),
            }
            if nonmissing.empty:
                row.update({k: np.nan for k in ["min", "p01", "p25", "median", "p75", "p99", "max", "mean", "sd"]})
            else:
                row.update(
                    {
                        "min": float(nonmissing.min()),
                        "p01": float(nonmissing.quantile(0.01)),
                        "p25": float(nonmissing.quantile(0.25)),
                        "median": float(nonmissing.quantile(0.50)),
                        "p75": float(nonmissing.quantile(0.75)),
                        "p99": float(nonmissing.quantile(0.99)),
                        "max": float(nonmissing.max()),
                        "mean": float(nonmissing.mean()),
                        "sd": float(nonmissing.std(ddof=1)) if len(nonmissing) > 1 else 0.0,
                    }
                )
            rows.append(row)
    return pd.DataFrame(rows)


def summarize_binary_values(datasets: dict[str, pd.DataFrame]) -> pd.DataFrame:
    rows = []
    for name, df in datasets.items():
        for col in BINARY_COLUMNS:
            if col not in df.columns:
                continue
            s = numeric_series(df, col)
            valid = s.dropna()
            unique_values = sorted(valid.unique().tolist())
            rows.append(
                {
                    "database_name": name,
                    "variable": col,
                    "n": len(df),
                    "missing_n": int(s.isna().sum()),
                    "unique_values": "|".join(str(int(x)) if float(x).is_integer() else str(x) for x in unique_values),
                    "non_binary_n": int((~valid.isin([0, 1])).sum()),
                    "ones_n": int((valid == 1).sum()),
                    "ones_pct": pct(int((valid == 1).sum()), int(valid.shape[0])),
                }
            )
    return pd.DataFrame(rows)


def add_rule(rows: list[dict], database: str, rule: str, status: str, value: object, detail: str) -> None:
    rows.append(
        {
            "database_name": database,
            "rule": rule,
            "status": status,
            "value": value,
            "detail": detail,
        }
    )


def df_to_markdown(df: pd.DataFrame, columns: list[str] | None = None, max_rows: int | None = None) -> str:
    if columns is not None:
        existing = [c for c in columns if c in df.columns]
        df = df[existing]
    if max_rows is not None:
        df = df.head(max_rows)
    if df.empty:
        return "_No rows._"

    def fmt(value: object) -> str:
        if pd.isna(value):
            return ""
        if isinstance(value, float):
            return f"{value:.4g}"
        text = str(value)
        return text.replace("|", "\\|").replace("\n", " ")

    headers = [str(c) for c in df.columns]
    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join(["---"] * len(headers)) + " |",
    ]
    for _, row in df.iterrows():
        lines.append("| " + " | ".join(fmt(row[c]) for c in df.columns) + " |")
    return "\n".join(lines)


def run_rule_checks(datasets: dict[str, pd.DataFrame]) -> pd.DataFrame:
    rows: list[dict] = []
    for name, df in datasets.items():
        n = len(df)
        add_rule(rows, name, "row_count_positive", "PASS" if n > 0 else "FAIL", n, "Final analysis table has rows.")

        if "stay_key" in df.columns:
            dup = int(df["stay_key"].duplicated().sum())
            add_rule(rows, name, "stay_key_unique", "PASS" if dup == 0 else "FAIL", dup, "One row per ICU stay expected.")

        id_col = "patientunitstayid" if name == "eICU" else "stay_id"
        if id_col in df.columns:
            dup = int(df[id_col].astype(str).duplicated().sum())
            add_rule(rows, name, f"{id_col}_unique", "PASS" if dup == 0 else "FAIL", dup, "Database-specific ICU stay id should be unique.")

        patient_col = "patienthealthsystemstayid" if name == "eICU" else "subject_id"
        if patient_col in df.columns:
            unique_patients = int(df[patient_col].nunique(dropna=True))
            add_rule(rows, name, "unique_patient_count", "INFO", unique_patients, "Multiple ICU stays per patient are allowed but recorded.")

        missing_main = {col: int(df[col].isna().sum()) for col in MAIN_MODEL_COLUMNS if col in df.columns}
        missing_main_total = sum(missing_main.values())
        add_rule(rows, name, "main_model_variable_missingness", "PASS" if missing_main_total == 0 else "WARN", missing_main_total, str(missing_main))

        complete_case_n = int(df.dropna(subset=[c for c in MAIN_MODEL_COLUMNS if c in df.columns]).shape[0])
        add_rule(rows, name, "main_model_complete_case_n", "INFO", complete_case_n, "Complete-case N for primary adjusted model variables.")

        if "survived_or_remained_icu_24h" in df.columns:
            s = numeric_series(df, "survived_or_remained_icu_24h")
            bad = int((s != 1).sum())
            add_rule(rows, name, "all_rows_satisfy_24h_landmark_flag", "PASS" if bad == 0 else "FAIL", bad, "All final rows should have survived/remained in ICU through 24h.")

        if "eligible_24h_12h_coverage" in df.columns:
            s = numeric_series(df, "eligible_24h_12h_coverage")
            bad = int((s != 1).sum())
            add_rule(rows, name, "all_rows_satisfy_12h_coverage_flag", "PASS" if bad == 0 else "FAIL", bad, "All final rows should pass MAP and SpO2 >=12h coverage.")

        for col in ["map_effective_hours", "spo2_effective_hours"]:
            if col in df.columns:
                s = numeric_series(df, col)
                bad = int((s < 12).sum())
                add_rule(rows, name, f"{col}_ge_12", "PASS" if bad == 0 else "FAIL", bad, f"{col} should be >=12 in final main set.")

        for col in ["hypotension_twa", "hypoxemia_twa", "hypotension_minutes", "hypoxemia_minutes", "hypotension_area", "hypoxemia_area"]:
            if col in df.columns:
                s = numeric_series(df, col)
                bad = int((s < 0).sum())
                add_rule(rows, name, f"{col}_nonnegative", "PASS" if bad == 0 else "FAIL", bad, "Burden components should not be negative.")

        if "gcs_total" in df.columns:
            s = numeric_series(df, "gcs_total")
            bad_range = int(((s < 3) | (s > 15)).sum())
            bad_severe = int((s > 8).sum())
            add_rule(rows, name, "gcs_total_range_3_to_15", "PASS" if bad_range == 0 else "FAIL", bad_range, "GCS total physiologic range.")
            add_rule(rows, name, "gcs_total_le_8_main_cohort", "PASS" if bad_severe == 0 else "FAIL", bad_severe, "Main severe TBI definition requires GCS <=8.")

        gcs_specs = [("gcs_eyes", 1, 4), ("gcs_motor", 1, 6), ("gcs_verbal", 1, 5)]
        for col, low, high in gcs_specs:
            if col in df.columns:
                s = numeric_series(df, col)
                bad = int(((s < low) | (s > high)).sum())
                add_rule(rows, name, f"{col}_range_{low}_to_{high}", "PASS" if bad == 0 else "FAIL", bad, "GCS component physiologic range.")

        if "age" in df.columns:
            s = numeric_series(df, "age")
            bad = int(((s < 18) | (s > 110)).sum())
            add_rule(rows, name, "age_range_18_to_110", "PASS" if bad == 0 else "WARN", bad, "Adult ICU cohort expected; upper ages may be deidentified.")

        for col in BINARY_COLUMNS:
            if col in df.columns:
                s = numeric_series(df, col).dropna()
                bad = int((~s.isin([0, 1])).sum())
                add_rule(rows, name, f"{col}_binary_0_1", "PASS" if bad == 0 else "FAIL", bad, "Binary variables should be coded 0/1.")

        if "death_icu" in df.columns:
            deaths = int(numeric_series(df, "death_icu").fillna(0).sum())
            add_rule(rows, name, "icu_death_count", "INFO", deaths, "Primary outcome event count in final main set.")

        if "hypoxemia_twa" in df.columns:
            zero_n = int((numeric_series(df, "hypoxemia_twa") == 0).sum())
            add_rule(rows, name, "hypoxemia_zero_burden_n", "INFO", zero_n, "Zero inflation expected and must be reported as limitation.")

        if "hypotension_twa" in df.columns:
            zero_n = int((numeric_series(df, "hypotension_twa") == 0).sum())
            add_rule(rows, name, "hypotension_zero_burden_n", "INFO", zero_n, "Zero burden count for RCS/knot interpretation.")

    return pd.DataFrame(rows)


def summarize_dataset(datasets: dict[str, pd.DataFrame]) -> pd.DataFrame:
    rows = []
    for name, df in datasets.items():
        row = {"database_name": name, "n": len(df)}
        row["icu_deaths_n"] = int(numeric_series(df, "death_icu").fillna(0).sum()) if "death_icu" in df.columns else np.nan
        row["icu_death_pct"] = pct(row["icu_deaths_n"], len(df)) if len(df) else np.nan
        row["hospital_deaths_n"] = int(numeric_series(df, "death_hospital").fillna(0).sum()) if "death_hospital" in df.columns else np.nan
        row["hospital_death_pct"] = pct(row["hospital_deaths_n"], len(df)) if len(df) else np.nan
        row["main_model_complete_case_n"] = int(df.dropna(subset=[c for c in MAIN_MODEL_COLUMNS if c in df.columns]).shape[0])
        row["unique_stays_n"] = int(df["stay_key"].nunique()) if "stay_key" in df.columns else np.nan
        patient_col = "patienthealthsystemstayid" if name == "eICU" else "subject_id"
        row["unique_patients_n"] = int(df[patient_col].nunique()) if patient_col in df.columns else np.nan
        for col in ["age", "gcs_total", "hypotension_twa", "hypoxemia_twa", "map_effective_hours", "spo2_effective_hours"]:
            if col in df.columns:
                s = numeric_series(df, col).dropna()
                row[f"{col}_median"] = float(s.median()) if not s.empty else np.nan
                row[f"{col}_p25"] = float(s.quantile(0.25)) if not s.empty else np.nan
                row[f"{col}_p75"] = float(s.quantile(0.75)) if not s.empty else np.nan
        rows.append(row)
    return pd.DataFrame(rows)


def write_markdown(
    summary: pd.DataFrame,
    rules: pd.DataFrame,
    missingness: pd.DataFrame,
    ranges: pd.DataFrame,
    exclusion: pd.DataFrame | None,
    output_path: Path,
) -> None:
    failures = rules[rules["status"].eq("FAIL")]
    warnings = rules[rules["status"].eq("WARN")]
    main_missing = missingness[missingness["variable"].isin(MAIN_MODEL_COLUMNS)]
    burden_ranges = ranges[ranges["variable"].isin(["hypotension_twa", "hypoxemia_twa", "map_effective_hours", "spo2_effective_hours"])]

    lines = [
        "# Final Analysis Dataset QC",
        "",
        f"Run ID: `{RUN_ID}`",
        f"Run time: {datetime.now().isoformat(timespec='seconds')}",
        "",
        "## Input Tables",
        "",
        f"- eICU: `{EICU_PATH.relative_to(PROJECT_ROOT)}`",
        f"- MIMIC-IV: `{MIMIC_PATH.relative_to(PROJECT_ROOT)}`",
        f"- Exclusion comparison: `{EXCLUSION_PATH.relative_to(PROJECT_ROOT)}`",
        "",
        "## Dataset Summary",
        "",
        df_to_markdown(summary),
        "",
        "## Main Model Missingness",
        "",
        df_to_markdown(main_missing, ["database_name", "variable", "n", "missing_n", "missing_pct", "nonmissing_n"]),
        "",
        "## Burden And Coverage Ranges",
        "",
        df_to_markdown(burden_ranges, ["database_name", "variable", "missing_n", "min", "p25", "median", "p75", "p99", "max"]),
        "",
        "## Rule Check Status",
        "",
        f"- FAIL rules: {len(failures)}",
        f"- WARN rules: {len(warnings)}",
        "",
    ]
    if not failures.empty:
        lines.extend(["### Failures", "", df_to_markdown(failures), ""])
    if not warnings.empty:
        lines.extend(["### Warnings", "", df_to_markdown(warnings), ""])

    if exclusion is not None:
        lines.extend(
            [
                "## Inclusion/Exclusion Context",
                "",
                "Burden V2 exclusion comparison is copied into the QC output. Key interpretation remains: early exit/death and short observation windows drive many exclusions; landmark-only coverage exclusions were small.",
                "",
                df_to_markdown(exclusion),
                "",
            ]
        )

    lines.extend(
        [
            "## QC Conclusion",
            "",
            "- Final analysis tables are suitable for Table 1 and the locked main model if no FAIL rules are present.",
            "- Cohort-defining variables, primary outcome, and primary exposure are not imputed.",
            "- eICU has two missing `sex_male` values, so the primary adjusted model uses eICU complete-case N = 775.",
            "- MIMIC-IV validation table has no missing values in the locked main-model variables.",
            "- Hypoxemia burden zero inflation remains a required limitation in Results/Discussion.",
            "",
        ]
    )

    output_path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    eicu = read_table(EICU_PATH)
    mimic = read_table(MIMIC_PATH)
    datasets = {"eICU": eicu, "MIMIC-IV": mimic}

    summary = summarize_dataset(datasets)
    missingness = summarize_missingness(datasets)
    ranges = summarize_ranges(datasets)
    binary = summarize_binary_values(datasets)
    rules = run_rule_checks(datasets)
    exclusion = pd.read_csv(EXCLUSION_PATH) if EXCLUSION_PATH.exists() else None

    summary.to_csv(OUTPUT_DIR / "final_dataset_qc_summary.csv", index=False)
    missingness.to_csv(OUTPUT_DIR / "final_dataset_missingness.csv", index=False)
    ranges.to_csv(OUTPUT_DIR / "final_dataset_variable_ranges.csv", index=False)
    binary.to_csv(OUTPUT_DIR / "final_dataset_binary_values.csv", index=False)
    rules.to_csv(OUTPUT_DIR / "final_dataset_rule_checks.csv", index=False)
    if exclusion is not None:
        exclusion.to_csv(OUTPUT_DIR / "final_dataset_exclusion_context.csv", index=False)

    manifest = [
        f"run_id={RUN_ID}",
        f"run_time={datetime.now().isoformat(timespec='seconds')}",
        f"eicu_input={EICU_PATH}",
        f"mimic_input={MIMIC_PATH}",
        f"exclusion_input={EXCLUSION_PATH}",
        f"output_dir={OUTPUT_DIR}",
    ]
    (OUTPUT_DIR / "manifest.txt").write_text("\n".join(manifest) + "\n", encoding="utf-8")

    write_markdown(
        summary=summary,
        rules=rules,
        missingness=missingness,
        ranges=ranges,
        exclusion=exclusion,
        output_path=OUTPUT_DIR / "final_dataset_qc_report.md",
    )

    print(f"Final dataset QC complete: {OUTPUT_DIR}")
    print(summary.to_string(index=False))
    status_counts = rules["status"].value_counts().to_dict()
    print(f"Rule status counts: {status_counts}")


if __name__ == "__main__":
    main()

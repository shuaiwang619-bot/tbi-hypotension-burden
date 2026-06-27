from __future__ import annotations

import argparse
import csv
import json
import math
import os
import subprocess
from pathlib import Path

import numpy as np
import pandas as pd

from adjusted_model_v1 import (
    auc_score,
    coefficient_table,
    fit_logistic,
    fmt_float,
    performance_row,
    read_analysis,
    sigmoid,
    transform_features,
)
from adjusted_model_v3_hypotension_rcs import (
    build_main_design,
    build_rcs_design,
    build_rcs_scale,
    coefficient_table_safe,
    likelihood_ratio_test,
    predict_reference_curve,
    threshold_summary,
    write_svg_curve,
)


PROJECT_ROOT = Path(__file__).resolve().parents[2]
RUN_ID = "20260621_analysis_closure_v1"

INPUT_DIR = PROJECT_ROOT / "03_outputs" / "tables" / "covariates" / "20260620_covariates_v2_baseline"
EICU_PATH = INPUT_DIR / "eicu_analysis_covariates_v1_landmark_main.csv"
MIMIC_PATH = INPUT_DIR / "mimic_analysis_covariates_v1_landmark_main.csv"

OUTPUT_DIR = PROJECT_ROOT / "03_outputs" / "tables" / "sensitivity" / RUN_ID
FIGURE_DIR = PROJECT_ROOT / "03_outputs" / "figures" / "sensitivity" / RUN_ID
LOG_DIR = PROJECT_ROOT / "03_outputs" / "logs"

CORE_FEATURES = ["hypotension_twa", "hypoxemia_twa", "age", "sex_male", "gcs_total"]
FEATURE_ORDER = [
    "intercept",
    "hypotension_twa_per_sd",
    "hypoxemia_twa_per_sd",
    "age_per_10y",
    "sex_male",
    "gcs_per_point",
]


def ensure_dirs() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    FIGURE_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)


def select_distribution_knots(values: pd.Series, probs: list[float]) -> np.ndarray:
    clean = pd.to_numeric(values, errors="coerce").dropna()
    knots = np.array([float(clean.quantile(p)) for p in probs])
    knots = np.unique(np.round(knots, 8))
    if len(knots) != len(probs):
        raise ValueError(f"Duplicate knots from probabilities {probs}: {knots}")
    return knots


def build_transform_params(eicu_model_df: pd.DataFrame) -> dict:
    params = {
        "hypotension_twa_mean": float(eicu_model_df["hypotension_twa"].mean()),
        "hypotension_twa_sd": float(eicu_model_df["hypotension_twa"].std(ddof=0)),
        "hypoxemia_twa_mean": float(eicu_model_df["hypoxemia_twa"].mean()),
        "hypoxemia_twa_sd": float(eicu_model_df["hypoxemia_twa"].std(ddof=0)),
        "age_mean": float(eicu_model_df["age"].mean()),
        "gcs_mean": float(eicu_model_df["gcs_total"].mean()),
    }
    for key in ["hypotension_twa_sd", "hypoxemia_twa_sd"]:
        if params[key] <= 0:
            raise ValueError(f"Non-positive SD for {key}")
    return params


def model_complete_case(df: pd.DataFrame, outcome: str) -> pd.DataFrame:
    cols = [outcome] + CORE_FEATURES
    out = df.copy()
    for col in cols:
        out[col] = pd.to_numeric(out[col], errors="coerce")
    return out.dropna(subset=cols).copy()


def fit_locked_logistic(eicu: pd.DataFrame, mimic: pd.DataFrame, outcome: str, model_name: str) -> tuple[pd.DataFrame, pd.DataFrame, dict]:
    eicu_model = model_complete_case(eicu, outcome)
    mimic_model = model_complete_case(mimic, outcome)
    params = build_transform_params(eicu_model)

    x_eicu = transform_features(eicu_model, params)[FEATURE_ORDER]
    y_eicu = eicu_model[outcome].to_numpy(dtype=float)
    fit = fit_logistic(x_eicu.to_numpy(dtype=float), y_eicu)

    coef = coefficient_table(FEATURE_ORDER, fit)
    coef.insert(0, "model", model_name)
    coef.insert(1, "outcome", outcome)

    x_mimic = transform_features(mimic_model, params)[FEATURE_ORDER]
    y_mimic = mimic_model[outcome].to_numpy(dtype=float)
    mimic_lp = x_mimic.to_numpy(dtype=float) @ fit["beta"]
    mimic_pred = sigmoid(mimic_lp)

    perf = pd.DataFrame(
        [
            {"model": model_name, "outcome": outcome, **performance_row("eICU_derivation", y_eicu, fit["linear_predictor"], fit["predicted"])},
            {"model": model_name, "outcome": outcome, **performance_row("MIMIC_IV_external_validation", y_mimic, mimic_lp, mimic_pred)},
        ]
    )
    meta = {
        "model_name": model_name,
        "outcome": outcome,
        "eicu_n": int(len(eicu_model)),
        "eicu_events": int(y_eicu.sum()),
        "mimic_n": int(len(mimic_model)),
        "mimic_events": int(y_mimic.sum()),
        "params": params,
        "coefficients": {name: float(value) for name, value in zip(FEATURE_ORDER, fit["beta"])},
    }
    return coef, perf, meta


def compute_vif(eicu: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    main = model_complete_case(eicu, "death_icu")
    params = build_transform_params(main)
    x = transform_features(main, params)[FEATURE_ORDER].drop(columns=["intercept"])
    x = x.astype(float)

    rows = []
    for target in x.columns:
        y = x[target].to_numpy(dtype=float)
        others = x.drop(columns=[target]).to_numpy(dtype=float)
        design = np.column_stack([np.ones(len(others)), others])
        beta = np.linalg.pinv(design) @ y
        pred = design @ beta
        ss_total = float(np.sum((y - y.mean()) ** 2))
        ss_resid = float(np.sum((y - pred) ** 2))
        r2 = 1.0 - ss_resid / ss_total if ss_total > 0 else np.nan
        tolerance = 1.0 - r2 if math.isfinite(r2) else np.nan
        vif = 1.0 / tolerance if tolerance and tolerance > 0 else np.inf
        rows.append(
            {
                "variable": target,
                "r_squared_on_other_predictors": r2,
                "tolerance": tolerance,
                "vif": vif,
            }
        )

    z = (x - x.mean(axis=0)) / x.std(axis=0, ddof=0)
    singular = np.linalg.svd(z.to_numpy(dtype=float), compute_uv=False)
    condition_number = float(singular.max() / singular.min())
    condition = pd.DataFrame(
        [
            {
                "n": int(len(main)),
                "n_predictors_without_intercept": int(x.shape[1]),
                "condition_number_standardized_design": condition_number,
                "smallest_singular_value": float(singular.min()),
                "largest_singular_value": float(singular.max()),
            }
        ]
    )
    return pd.DataFrame(rows), condition


def compute_spearman(eicu: pd.DataFrame, mimic: pd.DataFrame) -> pd.DataFrame:
    variables = ["hypotension_twa", "hypoxemia_twa", "age", "gcs_total"]
    rows = []
    for dataset, df in [("eICU", eicu), ("MIMIC-IV", mimic)]:
        work = df[variables].apply(pd.to_numeric, errors="coerce")
        corr = work.corr(method="spearman")
        for row_var in variables:
            for col_var in variables:
                rows.append(
                    {
                        "dataset": dataset,
                        "row_variable": row_var,
                        "column_variable": col_var,
                        "spearman_rho": corr.loc[row_var, col_var],
                    }
                )
    return pd.DataFrame(rows)


def winsorize_hypotension(eicu: pd.DataFrame, mimic: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame, float]:
    eicu_main = model_complete_case(eicu, "death_icu")
    cap = float(eicu_main["hypotension_twa"].quantile(0.99))
    eicu_out = eicu.copy()
    mimic_out = mimic.copy()
    eicu_out["hypotension_twa"] = pd.to_numeric(eicu_out["hypotension_twa"], errors="coerce").clip(upper=cap)
    mimic_out["hypotension_twa"] = pd.to_numeric(mimic_out["hypotension_twa"], errors="coerce").clip(upper=cap)
    return eicu_out, mimic_out, cap


def rcs_winsor_sensitivity(eicu: pd.DataFrame, mimic: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame, dict]:
    eicu_w, mimic_w, cap = winsorize_hypotension(eicu, mimic)
    eicu_model = model_complete_case(eicu_w, "death_icu")
    mimic_model = model_complete_case(mimic_w, "death_icu")
    params = build_transform_params(eicu_model)
    knots = select_distribution_knots(eicu_model["hypotension_twa"], [0.10, 0.50, 0.90])

    y_eicu = eicu_model["death_icu"].to_numpy(dtype=float)
    y_mimic = mimic_model["death_icu"].to_numpy(dtype=float)
    main_design_eicu = build_main_design(eicu_model, params)
    main_design_mimic = build_main_design(mimic_model, params)
    main_fit = fit_logistic(main_design_eicu.to_numpy(dtype=float), y_eicu)

    scale = build_rcs_scale(eicu_model, knots)
    rcs_design_eicu = build_rcs_design(eicu_model, params, knots, scale)
    rcs_design_mimic = build_rcs_design(mimic_model, params, knots, scale)
    rcs_fit = fit_logistic(rcs_design_eicu.to_numpy(dtype=float), y_eicu)

    no_h_design = main_design_eicu.drop(columns=["hypotension_twa_per_sd"])
    no_h_fit = fit_logistic(no_h_design.to_numpy(dtype=float), y_eicu)

    lr = pd.DataFrame(
        [
            {
                "model": "winsor99_3k_rcs",
                "comparison": "winsor99_3k_rcs_vs_linear",
                **likelihood_ratio_test(main_fit["log_likelihood"], rcs_fit["log_likelihood"], len(rcs_design_eicu.columns) - len(main_design_eicu.columns)),
            },
            {
                "model": "winsor99_3k_rcs",
                "comparison": "winsor99_3k_rcs_vs_no_hypotension",
                **likelihood_ratio_test(no_h_fit["log_likelihood"], rcs_fit["log_likelihood"], len(rcs_design_eicu.columns) - len(no_h_design.columns)),
            },
        ]
    )

    perf = pd.DataFrame(
        [
            {"model": "winsor99_linear", **performance_row("eICU_derivation", y_eicu, main_design_eicu.to_numpy(dtype=float) @ main_fit["beta"], sigmoid(main_design_eicu.to_numpy(dtype=float) @ main_fit["beta"]))},
            {"model": "winsor99_linear", **performance_row("MIMIC_IV_external_validation", y_mimic, main_design_mimic.to_numpy(dtype=float) @ main_fit["beta"], sigmoid(main_design_mimic.to_numpy(dtype=float) @ main_fit["beta"]))},
            {"model": "winsor99_3k_rcs", **performance_row("eICU_derivation", y_eicu, rcs_design_eicu.to_numpy(dtype=float) @ rcs_fit["beta"], sigmoid(rcs_design_eicu.to_numpy(dtype=float) @ rcs_fit["beta"]))},
            {"model": "winsor99_3k_rcs", **performance_row("MIMIC_IV_external_validation", y_mimic, rcs_design_mimic.to_numpy(dtype=float) @ rcs_fit["beta"], sigmoid(rcs_design_mimic.to_numpy(dtype=float) @ rcs_fit["beta"]))},
        ]
    )

    coef = pd.concat(
        [
            coefficient_table(FEATURE_ORDER, main_fit).assign(model="winsor99_linear"),
            coefficient_table_safe(list(rcs_design_eicu.columns), rcs_fit, "winsor99_3k_rcs"),
        ],
        ignore_index=True,
    )
    coef.insert(0, "cap_value_eicu_p99", cap)

    curve = predict_reference_curve(eicu_model, params, knots, scale, rcs_fit)
    curve.to_csv(OUTPUT_DIR / "winsor99_rcs_prediction_curve.csv", index=False)
    write_svg_curve(
        FIGURE_DIR / "winsor99_hypotension_rcs_3k_or_curve.svg",
        curve,
        "Winsorized 99th percentile hypotension RCS",
    )

    meta = {
        "eicu_p99_cap": cap,
        "knots": [float(x) for x in knots],
        "eicu_n": int(len(eicu_model)),
        "eicu_events": int(y_eicu.sum()),
        "mimic_n": int(len(mimic_model)),
        "mimic_events": int(y_mimic.sum()),
    }
    return coef, lr, perf, meta


def make_map60_sql(sql_text: str) -> str:
    out = sql_text
    out = out.replace("value_num < 65", "value_num < 60")
    out = out.replace("GREATEST(65.0 - value_num", "GREATEST(60.0 - value_num")
    out = out.replace("below 65 mmHg", "below 60 mmHg")
    return out


def run_psql_csv(psql_path: Path, database: str, sql_file: Path, output_file: Path, log_file: Path, host: str, port: int, user: str) -> None:
    args = [
        str(psql_path),
        "-h",
        host,
        "-p",
        str(port),
        "-U",
        user,
        "-d",
        database,
        "--csv",
        "-q",
        "-X",
        "-f",
        str(sql_file),
    ]
    with output_file.open("w", encoding="utf-8", newline="") as stdout, log_file.open("w", encoding="utf-8", newline="") as stderr:
        result = subprocess.run(args, stdout=stdout, stderr=stderr, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"psql failed for {database}. See log: {log_file}")


def build_map60_tables(psql_path: Path, host: str, port: int, user: str) -> tuple[pd.DataFrame, pd.DataFrame, dict]:
    if "PGPASSWORD" not in os.environ:
        raise RuntimeError("PGPASSWORD is not set.")
    generated_dir = OUTPUT_DIR / "generated_sql"
    generated_dir.mkdir(parents=True, exist_ok=True)

    src_eicu = PROJECT_ROOT / "02_code" / "sql" / "burden" / "01_eicu_burden_24h.sql"
    src_mimic = PROJECT_ROOT / "02_code" / "sql" / "burden" / "01_mimic_burden_24h.sql"
    sql_eicu = generated_dir / "01_eicu_burden_24h_map60.sql"
    sql_mimic = generated_dir / "01_mimic_burden_24h_map60.sql"
    sql_eicu.write_text(make_map60_sql(src_eicu.read_text(encoding="utf-8")), encoding="utf-8")
    sql_mimic.write_text(make_map60_sql(src_mimic.read_text(encoding="utf-8")), encoding="utf-8")

    eicu_raw = OUTPUT_DIR / "eicu_burden_24h_map60_raw_from_sql.csv"
    mimic_raw = OUTPUT_DIR / "mimic_burden_24h_map60_raw_from_sql.csv"
    run_psql_csv(psql_path, "eicu", sql_eicu, eicu_raw, LOG_DIR / f"{RUN_ID}_eicu_map60.log", host, port, user)
    run_psql_csv(psql_path, "mimic", sql_mimic, mimic_raw, LOG_DIR / f"{RUN_ID}_mimic_map60.log", host, port, user)

    eicu = pd.read_csv(eicu_raw)
    mimic = pd.read_csv(mimic_raw)
    eicu_main = eicu[(pd.to_numeric(eicu["survived_or_remained_icu_24h"], errors="coerce") == 1) & (pd.to_numeric(eicu["eligible_24h_12h_coverage"], errors="coerce") == 1)].copy()
    mimic_main = mimic[(pd.to_numeric(mimic["survived_or_remained_icu_24h"], errors="coerce") == 1) & (pd.to_numeric(mimic["eligible_24h_12h_coverage"], errors="coerce") == 1)].copy()
    eicu_main.to_csv(OUTPUT_DIR / "eicu_burden_24h_map60_landmark_main.csv", index=False, quoting=csv.QUOTE_MINIMAL)
    mimic_main.to_csv(OUTPUT_DIR / "mimic_burden_24h_map60_landmark_main.csv", index=False, quoting=csv.QUOTE_MINIMAL)
    meta = {
        "eicu_raw_n": int(len(eicu)),
        "eicu_landmark_main_n": int(len(eicu_main)),
        "mimic_raw_n": int(len(mimic)),
        "mimic_landmark_main_n": int(len(mimic_main)),
        "eicu_sql": str(sql_eicu),
        "mimic_sql": str(sql_mimic),
    }
    return eicu_main, mimic_main, meta


def map60_model(eicu: pd.DataFrame, mimic: pd.DataFrame, psql_path: Path, host: str, port: int, user: str) -> tuple[pd.DataFrame, pd.DataFrame, dict]:
    map60_eicu, map60_mimic, meta = build_map60_tables(psql_path, host, port, user)

    eicu_map = map60_eicu[["stay_key", "hypotension_twa"]].rename(columns={"hypotension_twa": "hypotension_twa_map60"})
    mimic_map = map60_mimic[["stay_key", "hypotension_twa"]].rename(columns={"hypotension_twa": "hypotension_twa_map60"})
    eicu_work = eicu.merge(eicu_map, on="stay_key", how="left", validate="one_to_one")
    mimic_work = mimic.merge(mimic_map, on="stay_key", how="left", validate="one_to_one")

    meta["eicu_unmatched_after_merge"] = int(eicu_work["hypotension_twa_map60"].isna().sum())
    meta["mimic_unmatched_after_merge"] = int(mimic_work["hypotension_twa_map60"].isna().sum())

    eicu_work["hypotension_twa"] = pd.to_numeric(eicu_work["hypotension_twa_map60"], errors="coerce")
    mimic_work["hypotension_twa"] = pd.to_numeric(mimic_work["hypotension_twa_map60"], errors="coerce")
    coef, perf, fit_meta = fit_locked_logistic(eicu_work, mimic_work, "death_icu", "map60_threshold")
    meta.update(fit_meta)
    return coef, perf, meta


def write_summary(results: dict) -> None:
    def rel(path: Path) -> str:
        return str(path.relative_to(PROJECT_ROOT))

    vifs = results["vif"]
    condition = results["condition"].iloc[0]
    hospital_coef = results["hospital_coef"]
    hospital_hypo = hospital_coef[hospital_coef["variable"] == "hypotension_twa_per_sd"].iloc[0]
    hospital_perf = results["hospital_perf"]
    hospital_mimic = hospital_perf[hospital_perf["dataset"] == "MIMIC_IV_external_validation"].iloc[0]

    winsor_lr = results["winsor_lr"]
    winsor_nonlin = winsor_lr[winsor_lr["comparison"] == "winsor99_3k_rcs_vs_linear"].iloc[0]
    winsor_perf = results["winsor_perf"]
    winsor_rcs_mimic = winsor_perf[(winsor_perf["model"] == "winsor99_3k_rcs") & (winsor_perf["dataset"] == "MIMIC_IV_external_validation")].iloc[0]

    map60_coef = results["map60_coef"]
    map60_hypo = map60_coef[map60_coef["variable"] == "hypotension_twa_per_sd"].iloc[0]
    map60_perf = results["map60_perf"]
    map60_mimic = map60_perf[map60_perf["dataset"] == "MIMIC_IV_external_validation"].iloc[0]

    lines = [
        "# Analysis Closure Sensitivity V1",
        "",
        f"Run ID: `{RUN_ID}`",
        "",
        "## What Was Added",
        "",
        "- VIF/tolerance/condition number for the locked main model.",
        "- Spearman correlation matrix for continuous model variables.",
        "- Hospital death as an alternative outcome.",
        "- 99th percentile winsorization of hypotension burden, including linear and 3-knot RCS checks.",
        "- MAP <60 mmHg alternative hypotension burden threshold.",
        "",
        "## VIF / Collinearity",
        "",
        f"- Maximum VIF = {fmt_float(float(vifs['vif'].max()))}.",
        f"- Condition number of standardized design = {fmt_float(float(condition['condition_number_standardized_design']))}.",
        "",
        "## Hospital Death Alternative Outcome",
        "",
        f"- eICU N = {results['hospital_meta']['eicu_n']}, events = {results['hospital_meta']['eicu_events']}.",
        f"- MIMIC-IV N = {results['hospital_meta']['mimic_n']}, events = {results['hospital_meta']['mimic_events']}.",
        f"- Hypotension burden OR per eICU SD = {fmt_float(hospital_hypo['or'])}, 95% CI {fmt_float(hospital_hypo['ci_low'])}-{fmt_float(hospital_hypo['ci_high'])}, P = {fmt_float(hospital_hypo['p_value'], 4)}.",
        f"- MIMIC-IV C-index = {fmt_float(hospital_mimic['auc_c_index'])}; calibration slope = {fmt_float(hospital_mimic['calibration_slope_logistic'])}; calibration intercept = {fmt_float(hospital_mimic['calibration_intercept_logistic'])}.",
        "",
        "## 99th Percentile Winsorization",
        "",
        f"- eICU P99 cap for hypotension_twa = {fmt_float(results['winsor_meta']['eicu_p99_cap'], 4)}.",
        f"- Winsorized 3-knot RCS vs linear LR P = {fmt_float(winsor_nonlin['p_value'], 4)}.",
        f"- Winsorized 3-knot RCS MIMIC-IV C-index = {fmt_float(winsor_rcs_mimic['auc_c_index'])}; calibration slope = {fmt_float(winsor_rcs_mimic['calibration_slope_logistic'])}.",
        "",
        "## MAP <60 mmHg Alternative Threshold",
        "",
        f"- eICU landmark main N from MAP<60 extraction = {results['map60_meta']['eicu_landmark_main_n']}.",
        f"- MIMIC-IV landmark main N from MAP<60 extraction = {results['map60_meta']['mimic_landmark_main_n']}.",
        f"- Merge unmatched: eICU {results['map60_meta']['eicu_unmatched_after_merge']}, MIMIC-IV {results['map60_meta']['mimic_unmatched_after_merge']}.",
        f"- MAP<60 burden OR per eICU SD = {fmt_float(map60_hypo['or'])}, 95% CI {fmt_float(map60_hypo['ci_low'])}-{fmt_float(map60_hypo['ci_high'])}, P = {fmt_float(map60_hypo['p_value'], 4)}.",
        f"- MAP<60 MIMIC-IV C-index = {fmt_float(map60_mimic['auc_c_index'])}; calibration slope = {fmt_float(map60_mimic['calibration_slope_logistic'])}; calibration intercept = {fmt_float(map60_mimic['calibration_intercept_logistic'])}.",
        "",
        "## Interpretation Guardrails",
        "",
        "- PH assumption was not tested because the locked analysis remains landmark logistic regression, not a time-to-event Cox model.",
        "- SICdb/NWICU broad-TBI exploratory validation is intentionally not added because those databases lack a reliable GCS-based severe TBI definition.",
        "- Hypoxemia remains secondary and must be described with zero-inflation/power limitations.",
        "",
        "## Output Files",
        "",
        f"- VIF: `{rel(OUTPUT_DIR / 'main_model_vif.csv')}`",
        f"- Spearman: `{rel(OUTPUT_DIR / 'spearman_correlations.csv')}`",
        f"- Hospital death coefficients: `{rel(OUTPUT_DIR / 'hospital_death_model_coefficients.csv')}`",
        f"- Hospital death performance: `{rel(OUTPUT_DIR / 'hospital_death_model_performance.csv')}`",
        f"- Winsorized RCS tests: `{rel(OUTPUT_DIR / 'winsor99_rcs_lr_tests.csv')}`",
        f"- MAP<60 coefficients: `{rel(OUTPUT_DIR / 'map60_model_coefficients.csv')}`",
        f"- MAP<60 performance: `{rel(OUTPUT_DIR / 'map60_model_performance.csv')}`",
    ]
    (OUTPUT_DIR / "analysis_closure_sensitivity_v1_summary.md").write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--psql-path", default="psql")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5432)
    parser.add_argument("--user", default="postgres")
    args = parser.parse_args()

    ensure_dirs()
    eicu = read_analysis(EICU_PATH)
    mimic = read_analysis(MIMIC_PATH)

    vif, condition = compute_vif(eicu)
    spearman = compute_spearman(eicu, mimic)
    hospital_coef, hospital_perf, hospital_meta = fit_locked_logistic(eicu, mimic, "death_hospital", "hospital_death_outcome")
    winsor_coef, winsor_lr, winsor_perf, winsor_meta = rcs_winsor_sensitivity(eicu, mimic)
    map60_coef, map60_perf, map60_meta = map60_model(eicu, mimic, Path(args.psql_path), args.host, args.port, args.user)

    vif.to_csv(OUTPUT_DIR / "main_model_vif.csv", index=False)
    condition.to_csv(OUTPUT_DIR / "main_model_condition_number.csv", index=False)
    spearman.to_csv(OUTPUT_DIR / "spearman_correlations.csv", index=False)
    hospital_coef.to_csv(OUTPUT_DIR / "hospital_death_model_coefficients.csv", index=False, quoting=csv.QUOTE_MINIMAL)
    hospital_perf.to_csv(OUTPUT_DIR / "hospital_death_model_performance.csv", index=False)
    winsor_coef.to_csv(OUTPUT_DIR / "winsor99_model_coefficients.csv", index=False, quoting=csv.QUOTE_MINIMAL)
    winsor_lr.to_csv(OUTPUT_DIR / "winsor99_rcs_lr_tests.csv", index=False)
    winsor_perf.to_csv(OUTPUT_DIR / "winsor99_model_performance.csv", index=False)
    map60_coef.to_csv(OUTPUT_DIR / "map60_model_coefficients.csv", index=False, quoting=csv.QUOTE_MINIMAL)
    map60_perf.to_csv(OUTPUT_DIR / "map60_model_performance.csv", index=False)

    meta = {
        "run_id": RUN_ID,
        "input_dir": str(INPUT_DIR),
        "output_dir": str(OUTPUT_DIR),
        "hospital_meta": hospital_meta,
        "winsor_meta": winsor_meta,
        "map60_meta": map60_meta,
        "ph_assumption_decision": "Not tested; primary design is landmark logistic, not Cox time-to-event.",
        "extra_database_decision": "SICdb/NWICU broad-TBI exploratory validation intentionally omitted due to absent reliable GCS severity definition.",
    }
    (OUTPUT_DIR / "analysis_closure_sensitivity_v1_meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    results = {
        "vif": vif,
        "condition": condition,
        "hospital_coef": hospital_coef,
        "hospital_perf": hospital_perf,
        "hospital_meta": hospital_meta,
        "winsor_coef": winsor_coef,
        "winsor_lr": winsor_lr,
        "winsor_perf": winsor_perf,
        "winsor_meta": winsor_meta,
        "map60_coef": map60_coef,
        "map60_perf": map60_perf,
        "map60_meta": map60_meta,
    }
    write_summary(results)
    print((OUTPUT_DIR / "analysis_closure_sensitivity_v1_summary.md").read_text(encoding="utf-8"))


if __name__ == "__main__":
    main()


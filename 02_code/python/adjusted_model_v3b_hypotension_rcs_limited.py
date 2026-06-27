from __future__ import annotations

import csv
import json
from pathlib import Path

import numpy as np
import pandas as pd

from adjusted_model_v1 import (
    CORE_COLUMNS,
    EICU_PATH,
    MIMIC_PATH,
    OUTCOME,
    fit_logistic,
    fmt_float,
    performance_row,
    read_analysis,
    sigmoid,
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
RUN_ID = "20260620_adjusted_model_v3b_hypotension_rcs_limited"
OUTPUT_DIR = PROJECT_ROOT / "03_outputs" / "tables" / "models" / RUN_ID
FIGURE_DIR = PROJECT_ROOT / "03_outputs" / "figures" / "models" / RUN_ID


def select_distribution_knots(values: pd.Series, probs: list[float]) -> np.ndarray:
    values = pd.to_numeric(values, errors="coerce").dropna()
    knots = np.array([float(values.quantile(p)) for p in probs])
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
    return params


def distribution_summary(df: pd.DataFrame, dataset: str) -> pd.DataFrame:
    values = pd.to_numeric(df["hypotension_twa"], errors="coerce").dropna()
    positive = values[values > 0]
    rows = []
    for source, series in [("all", values), ("positive_only", positive)]:
        row = {
            "dataset": dataset,
            "source": source,
            "n": int(series.shape[0]),
            "zero_n": int((series == 0).sum()),
            "zero_pct": float((series == 0).mean() * 100) if len(series) else np.nan,
        }
        for p in [0, 0.05, 0.10, 0.25, 0.35, 0.50, 0.65, 0.75, 0.90, 0.95, 0.99, 1.0]:
            row[f"q{int(p * 100):02d}"] = float(series.quantile(p)) if len(series) else np.nan
        rows.append(row)
    return pd.DataFrame(rows)


def model_performance(dataset: str, model_name: str, y: np.ndarray, design: pd.DataFrame, beta: np.ndarray) -> dict:
    lp = design.to_numpy(dtype=float) @ beta
    pred = sigmoid(lp)
    row = performance_row(dataset, y, lp, pred)
    row["model"] = model_name
    return row


def crude_threshold_direction(df: pd.DataFrame, dataset: str, thresholds: pd.DataFrame) -> pd.DataFrame:
    rows = []
    y = pd.to_numeric(df[OUTCOME], errors="coerce")
    x = pd.to_numeric(df["hypotension_twa"], errors="coerce")
    for _, threshold in thresholds.iterrows():
        cut = threshold["first_hypotension_twa_reaching_target"]
        if pd.isna(cut):
            continue
        high = x >= cut
        low = x < cut
        high_events = int(y[high].sum())
        low_events = int(y[low].sum())
        high_n = int(high.sum())
        low_n = int(low.sum())
        high_nonevents = high_n - high_events
        low_nonevents = low_n - low_events
        crude_or = ((high_events + 0.5) * (low_nonevents + 0.5)) / ((high_nonevents + 0.5) * (low_events + 0.5))
        rows.append(
            {
                "dataset": dataset,
                "target_or_vs_zero": threshold["target_or_vs_zero"],
                "threshold": cut,
                "below_n": low_n,
                "below_events": low_events,
                "below_event_rate": low_events / low_n if low_n else np.nan,
                "above_n": high_n,
                "above_events": high_events,
                "above_event_rate": high_events / high_n if high_n else np.nan,
                "crude_or_above_vs_below_haldane": crude_or,
            }
        )
    return pd.DataFrame(rows)


def fit_rcs_variant(name: str, eicu: pd.DataFrame, mimic: pd.DataFrame, params: dict, knots: np.ndarray) -> dict:
    scale = build_rcs_scale(eicu, knots)
    y_eicu = eicu[OUTCOME].to_numpy(dtype=float)
    y_mimic = mimic[OUTCOME].to_numpy(dtype=float)
    design_eicu = build_rcs_design(eicu, params, knots, scale)
    design_mimic = build_rcs_design(mimic, params, knots, scale)
    fit = fit_logistic(design_eicu.to_numpy(dtype=float), y_eicu)
    perf = [
        model_performance("eICU_derivation", name, y_eicu, design_eicu, fit["beta"]),
        model_performance("MIMIC_IV_external_validation", name, y_mimic, design_mimic, fit["beta"]),
    ]
    return {
        "name": name,
        "knots": knots,
        "scale": scale,
        "design_eicu": design_eicu,
        "design_mimic": design_mimic,
        "fit": fit,
        "performance": perf,
    }


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    FIGURE_DIR.mkdir(parents=True, exist_ok=True)

    eicu_raw = read_analysis(EICU_PATH)
    mimic_raw = read_analysis(MIMIC_PATH)
    eicu = eicu_raw.dropna(subset=CORE_COLUMNS).copy()
    mimic = mimic_raw.dropna(subset=CORE_COLUMNS).copy()
    params = build_transform_params(eicu)

    y_eicu = eicu[OUTCOME].to_numpy(dtype=float)
    y_mimic = mimic[OUTCOME].to_numpy(dtype=float)

    knot_3 = select_distribution_knots(eicu["hypotension_twa"], [0.10, 0.50, 0.90])
    knot_4 = select_distribution_knots(eicu["hypotension_twa"], [0.05, 0.35, 0.65, 0.95])

    main_design_eicu = build_main_design(eicu, params)
    main_design_mimic = build_main_design(mimic, params)
    main_fit = fit_logistic(main_design_eicu.to_numpy(dtype=float), y_eicu)

    primary = fit_rcs_variant("hypotension_rcs_3k_primary", eicu, mimic, params, knot_3)
    sensitivity = fit_rcs_variant("hypotension_rcs_4k_sensitivity", eicu, mimic, params, knot_4)

    coef_main = coefficient_table_safe(list(main_design_eicu.columns), main_fit, "linear_hypotension_v1")
    coef_3 = coefficient_table_safe(list(primary["design_eicu"].columns), primary["fit"], primary["name"])
    coef_4 = coefficient_table_safe(list(sensitivity["design_eicu"].columns), sensitivity["fit"], sensitivity["name"])
    pd.concat([coef_main, coef_3, coef_4], ignore_index=True).to_csv(
        OUTPUT_DIR / "adjusted_model_v3b_rcs_coefficients.csv",
        index=False,
        quoting=csv.QUOTE_MINIMAL,
    )

    no_h_design = main_design_eicu.drop(columns=["hypotension_twa_per_sd"])
    no_h_fit = fit_logistic(no_h_design.to_numpy(dtype=float), y_eicu)

    lr_rows = []
    for item in [primary, sensitivity]:
        lr_rows.append(
            {
                "model": item["name"],
                "comparison": f"{item['name']}_vs_linear_hypotension",
                **likelihood_ratio_test(
                    main_fit["log_likelihood"],
                    item["fit"]["log_likelihood"],
                    len(item["design_eicu"].columns) - len(main_design_eicu.columns),
                ),
            }
        )
        lr_rows.append(
            {
                "model": item["name"],
                "comparison": f"{item['name']}_vs_no_hypotension",
                **likelihood_ratio_test(
                    no_h_fit["log_likelihood"],
                    item["fit"]["log_likelihood"],
                    len(item["design_eicu"].columns) - len(no_h_design.columns),
                ),
            }
        )
    lr = pd.DataFrame(lr_rows)
    lr.to_csv(OUTPUT_DIR / "adjusted_model_v3b_rcs_lr_tests.csv", index=False)

    perf_rows = [
        model_performance("eICU_derivation", "linear_hypotension_v1", y_eicu, main_design_eicu, main_fit["beta"]),
        model_performance("MIMIC_IV_external_validation", "linear_hypotension_v1", y_mimic, main_design_mimic, main_fit["beta"]),
    ]
    perf_rows.extend(primary["performance"])
    perf_rows.extend(sensitivity["performance"])
    perf = pd.DataFrame(perf_rows)
    perf = perf[["model"] + [c for c in perf.columns if c != "model"]]
    perf.to_csv(OUTPUT_DIR / "adjusted_model_v3b_rcs_performance.csv", index=False)

    dist = pd.concat(
        [
            distribution_summary(eicu, "eICU_model_set"),
            distribution_summary(mimic, "MIMIC_IV_validation_set"),
        ],
        ignore_index=True,
    )
    dist.to_csv(OUTPUT_DIR / "adjusted_model_v3b_hypotension_distribution.csv", index=False)

    threshold_parts = []
    threshold_direction_parts = []
    curve_parts = []
    for item in [primary, sensitivity]:
        curve = predict_reference_curve(eicu, params, item["knots"], item["scale"], item["fit"])
        curve["model"] = item["name"]
        curve_parts.append(curve)
        thresholds = threshold_summary(curve)
        thresholds.insert(0, "model", item["name"])
        threshold_parts.append(thresholds)
        threshold_direction_parts.append(crude_threshold_direction(eicu, f"eICU__{item['name']}", thresholds))
        threshold_direction_parts.append(crude_threshold_direction(mimic, f"MIMIC_IV__{item['name']}", thresholds))
        write_svg_curve(
            FIGURE_DIR / f"{item['name']}_or_curve.svg",
            curve,
            f"{item['name']}: OR vs zero burden",
        )

    curves = pd.concat(curve_parts, ignore_index=True)
    curves.to_csv(OUTPUT_DIR / "adjusted_model_v3b_rcs_prediction_curves.csv", index=False)
    thresholds_all = pd.concat(threshold_parts, ignore_index=True)
    thresholds_all.to_csv(OUTPUT_DIR / "adjusted_model_v3b_rcs_threshold_summary.csv", index=False)
    pd.concat(threshold_direction_parts, ignore_index=True).to_csv(
        OUTPUT_DIR / "adjusted_model_v3b_threshold_direction_by_database.csv",
        index=False,
    )

    package = {
        "run_id": RUN_ID,
        "primary_knots_3": [float(x) for x in knot_3],
        "sensitivity_knots_4": [float(x) for x in knot_4],
        "decision_rule": "Use v1 linear as primary unless 3-knot RCS shows nonlinearity and does not worsen MIMIC calibration slope versus v1 linear.",
        "models": {
            "linear_hypotension_v1": {
                "columns": list(main_design_eicu.columns),
                "coefficients": {col: float(beta) for col, beta in zip(main_design_eicu.columns, main_fit["beta"])},
            },
            primary["name"]: {
                "columns": list(primary["design_eicu"].columns),
                "coefficients": {col: float(beta) for col, beta in zip(primary["design_eicu"].columns, primary["fit"]["beta"])},
                "knots": [float(x) for x in knot_3],
            },
            sensitivity["name"]: {
                "columns": list(sensitivity["design_eicu"].columns),
                "coefficients": {col: float(beta) for col, beta in zip(sensitivity["design_eicu"].columns, sensitivity["fit"]["beta"])},
                "knots": [float(x) for x in knot_4],
            },
        },
    }
    (OUTPUT_DIR / "adjusted_model_v3b_rcs_model_package.json").write_text(
        json.dumps(package, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    primary_nonlin = lr[(lr["model"] == primary["name"]) & (lr["comparison"].str.endswith("_vs_linear_hypotension"))].iloc[0]
    primary_overall = lr[(lr["model"] == primary["name"]) & (lr["comparison"].str.endswith("_vs_no_hypotension"))].iloc[0]
    sens_nonlin = lr[(lr["model"] == sensitivity["name"]) & (lr["comparison"].str.endswith("_vs_linear_hypotension"))].iloc[0]

    lin_mimic = perf[(perf["model"] == "linear_hypotension_v1") & (perf["dataset"] == "MIMIC_IV_external_validation")].iloc[0]
    primary_mimic = perf[(perf["model"] == primary["name"]) & (perf["dataset"] == "MIMIC_IV_external_validation")].iloc[0]
    sens_mimic = perf[(perf["model"] == sensitivity["name"]) & (perf["dataset"] == "MIMIC_IV_external_validation")].iloc[0]

    primary_thresholds = thresholds_all[thresholds_all["model"] == primary["name"]]
    summary = [
        "# Adjusted Model V3b Limited Hypotension RCS Summary",
        "",
        f"Run ID: `{RUN_ID}`",
        "",
        "## Why V3b",
        "",
        "- RCS degrees of freedom were limited by event count rather than sample size.",
        "- Primary RCS uses 3 knots (2 df).",
        "- Four-knot RCS is sensitivity only.",
        "- The prior 5-knot RCS is retired from primary-result consideration.",
        "",
        "## Knot Selection",
        "",
        f"- Primary 3 knots from eICU all-value 10/50/90 percentiles: {', '.join(fmt_float(x, 4) for x in knot_3)}.",
        f"- Sensitivity 4 knots from eICU all-value 5/35/65/95 percentiles: {', '.join(fmt_float(x, 4) for x in knot_4)}.",
        "- eICU hypotension_twa zero mass: 264/777 before sex complete-case, about 34%.",
        "",
        "## Primary 3-Knot RCS",
        "",
        f"- RCS vs linear hypotension LR chi-square = {fmt_float(primary_nonlin['lr_chisq'])}, df = {int(primary_nonlin['df'])}, P = {fmt_float(primary_nonlin['p_value'], 4)}.",
        f"- Overall hypotension RCS vs no hypotension LR chi-square = {fmt_float(primary_overall['lr_chisq'])}, df = {int(primary_overall['df'])}, P = {fmt_float(primary_overall['p_value'], 4)}.",
        "",
        "## External Validation",
        "",
        f"- Linear v1 MIMIC-IV C-index = {fmt_float(lin_mimic['auc_c_index'])}; calibration slope = {fmt_float(lin_mimic['calibration_slope_logistic'])}.",
        f"- 3-knot RCS MIMIC-IV C-index = {fmt_float(primary_mimic['auc_c_index'])}; calibration slope = {fmt_float(primary_mimic['calibration_slope_logistic'])}.",
        f"- 4-knot sensitivity MIMIC-IV C-index = {fmt_float(sens_mimic['auc_c_index'])}; calibration slope = {fmt_float(sens_mimic['calibration_slope_logistic'])}.",
        "",
        "## Four-Knot Sensitivity",
        "",
        f"- 4-knot RCS vs linear LR chi-square = {fmt_float(sens_nonlin['lr_chisq'])}, df = {int(sens_nonlin['df'])}, P = {fmt_float(sens_nonlin['p_value'], 4)}.",
        "",
        "## 3-Knot Threshold Hints",
        "",
    ]
    for _, row in primary_thresholds.iterrows():
        value = row["first_hypotension_twa_reaching_target"]
        summary.append(
            f"- OR vs zero >= {fmt_float(row['target_or_vs_zero'], 2)} first reached at hypotension_twa = {fmt_float(value, 4) if pd.notna(value) else 'not reached'}."
        )
    summary.extend(
        [
            "",
            "## Outputs",
            "",
            f"- Summary: `{OUTPUT_DIR / 'adjusted_model_v3b_rcs_summary.md'}`",
            f"- LR tests: `{OUTPUT_DIR / 'adjusted_model_v3b_rcs_lr_tests.csv'}`",
            f"- Performance: `{OUTPUT_DIR / 'adjusted_model_v3b_rcs_performance.csv'}`",
            f"- Distribution: `{OUTPUT_DIR / 'adjusted_model_v3b_hypotension_distribution.csv'}`",
            f"- Threshold direction: `{OUTPUT_DIR / 'adjusted_model_v3b_threshold_direction_by_database.csv'}`",
        ]
    )
    (OUTPUT_DIR / "adjusted_model_v3b_rcs_summary.md").write_text("\n".join(summary), encoding="utf-8")

    manifest = [
        f"run_id={RUN_ID}",
        f"output_dir={OUTPUT_DIR}",
        f"figure_dir={FIGURE_DIR}",
        f"primary_knots_3={','.join(str(float(k)) for k in knot_3)}",
        f"sensitivity_knots_4={','.join(str(float(k)) for k in knot_4)}",
        f"primary_nonlin_p={primary_nonlin['p_value']}",
        f"primary_mimic_slope={primary_mimic['calibration_slope_logistic']}",
        f"linear_mimic_slope={lin_mimic['calibration_slope_logistic']}",
        f"sensitivity_nonlin_p={sens_nonlin['p_value']}",
        f"sensitivity_mimic_slope={sens_mimic['calibration_slope_logistic']}",
    ]
    (OUTPUT_DIR / "manifest.txt").write_text("\n".join(manifest), encoding="utf-8")

    print("\n".join(summary[:34]))


if __name__ == "__main__":
    main()

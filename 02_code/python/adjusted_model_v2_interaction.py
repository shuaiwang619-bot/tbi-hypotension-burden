from __future__ import annotations

import csv
import json
import math
from pathlib import Path

import numpy as np
import pandas as pd

from adjusted_model_v1 import (
    CORE_COLUMNS,
    EICU_PATH,
    MIMIC_PATH,
    OUTCOME,
    auc_score,
    build_transform_params,
    calibration_groups,
    coefficient_table,
    fit_logistic,
    fit_offset_intercept,
    fmt_float,
    normal_p_value,
    performance_row,
    read_analysis,
    sigmoid,
    transform_features,
)


PROJECT_ROOT = Path(__file__).resolve().parents[2]
RUN_ID = "20260620_adjusted_model_v2_interaction"
OUTPUT_DIR = PROJECT_ROOT / "03_outputs" / "tables" / "models" / RUN_ID


def lr_test(ll_reduced: float, ll_full: float, df: int = 1) -> dict:
    stat = max(0.0, 2.0 * (ll_full - ll_reduced))
    if df == 1:
        p_value = math.erfc(math.sqrt(stat / 2.0))
    else:
        p_value = float("nan")
    return {"lr_chisq": stat, "df": df, "p_value": p_value}


def make_design(df: pd.DataFrame, params: dict, model_type: str) -> pd.DataFrame:
    base = transform_features(df, params)
    hypox_any = (df["hypoxemia_twa"] > 0).astype(float)

    if model_type == "main_effect":
        return base[
            [
                "intercept",
                "hypotension_twa_per_sd",
                "hypoxemia_twa_per_sd",
                "age_per_10y",
                "sex_male",
                "gcs_per_point",
            ]
        ]

    if model_type == "continuous_interaction":
        out = base[
            [
                "intercept",
                "hypotension_twa_per_sd",
                "hypoxemia_twa_per_sd",
                "age_per_10y",
                "sex_male",
                "gcs_per_point",
            ]
        ].copy()
        out["hypotension_x_hypoxemia_z"] = (
            out["hypotension_twa_per_sd"] * out["hypoxemia_twa_per_sd"]
        )
        return out

    if model_type == "hypoxemia_binary":
        out = base[
            [
                "intercept",
                "hypotension_twa_per_sd",
                "age_per_10y",
                "sex_male",
                "gcs_per_point",
            ]
        ].copy()
        out["hypoxemia_any"] = hypox_any
        return out

    if model_type == "hypoxemia_binary_interaction":
        out = base[
            [
                "intercept",
                "hypotension_twa_per_sd",
                "age_per_10y",
                "sex_male",
                "gcs_per_point",
            ]
        ].copy()
        out["hypoxemia_any"] = hypox_any
        out["hypotension_z_x_hypoxemia_any"] = out["hypotension_twa_per_sd"] * hypox_any
        return out

    if model_type == "hypotension_only_adjusted":
        return base[["intercept", "hypotension_twa_per_sd", "age_per_10y", "sex_male", "gcs_per_point"]]

    raise ValueError(f"Unknown model_type: {model_type}")


def labels_for(columns: list[str]) -> dict:
    labels = {
        "intercept": "Intercept",
        "hypotension_twa_per_sd": "Hypotension burden, per eICU SD",
        "hypoxemia_twa_per_sd": "Hypoxemia burden, per eICU SD",
        "age_per_10y": "Age, per 10 years",
        "sex_male": "Male vs female",
        "gcs_per_point": "GCS, per 1-point increase",
        "hypotension_x_hypoxemia_z": "Hypotension x hypoxemia, SD-scale interaction",
        "hypoxemia_any": "Any hypoxemia burden vs none",
        "hypotension_z_x_hypoxemia_any": "Hypotension burden x any hypoxemia",
    }
    return {column: labels.get(column, column) for column in columns}


def coefficient_table_with_labels(columns: list[str], fit: dict, model_name: str) -> pd.DataFrame:
    table = coefficient_table(columns, fit)
    custom = labels_for(columns)
    table["label"] = table["variable"].map(custom).fillna(table["label"])
    table.insert(0, "model", model_name)
    return table


def fit_named_model(name: str, df: pd.DataFrame, params: dict, y: np.ndarray) -> dict:
    design = make_design(df, params, name)
    fit = fit_logistic(design.to_numpy(dtype=float), y)
    return {"name": name, "design": design, "fit": fit}


def model_performance(dataset: str, model_name: str, y: np.ndarray, design: pd.DataFrame, beta: np.ndarray) -> dict:
    lp = design.to_numpy(dtype=float) @ beta
    pred = sigmoid(lp)
    row = performance_row(dataset, y, lp, pred)
    row["model"] = model_name
    return row


def stratum_hypotension_effect(eicu_df: pd.DataFrame, params: dict) -> pd.DataFrame:
    rows = []
    for value, label in [(0, "hypoxemia_zero"), (1, "hypoxemia_nonzero")]:
        subset = eicu_df[(eicu_df["hypoxemia_twa"] > 0).astype(int) == value].copy()
        if len(subset) < 30 or subset[OUTCOME].sum() < 5:
            continue
        design = make_design(subset, params, "hypotension_only_adjusted")
        y = subset[OUTCOME].to_numpy(dtype=float)
        fit = fit_logistic(design.to_numpy(dtype=float), y)
        coef = coefficient_table_with_labels(list(design.columns), fit, f"stratum_{label}")
        h = coef.loc[coef["variable"] == "hypotension_twa_per_sd"].iloc[0].to_dict()
        h.update(
            {
                "stratum": label,
                "n": int(len(subset)),
                "events": int(y.sum()),
                "event_rate": float(y.mean()),
                "auc_c_index": auc_score(y, fit["predicted"]),
            }
        )
        rows.append(h)
    return pd.DataFrame(rows)


def exposure_summary(df: pd.DataFrame, dataset: str) -> pd.DataFrame:
    rows = []
    for variable in ["hypotension_twa", "hypoxemia_twa"]:
        values = pd.to_numeric(df[variable], errors="coerce")
        nonzero = values > 0
        rows.append(
            {
                "dataset": dataset,
                "variable": variable,
                "n": int(values.notna().sum()),
                "zero_n": int((values == 0).sum()),
                "zero_pct": float((values == 0).mean() * 100),
                "nonzero_n": int(nonzero.sum()),
                "nonzero_pct": float(nonzero.mean() * 100),
                "min": float(values.min()),
                "p25": float(values.quantile(0.25)),
                "median": float(values.quantile(0.50)),
                "p75": float(values.quantile(0.75)),
                "max": float(values.max()),
            }
        )
    return pd.DataFrame(rows)


def add_model_name_first(df: pd.DataFrame) -> pd.DataFrame:
    cols = ["model"] + [c for c in df.columns if c != "model"]
    return df[cols]


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    eicu_raw = read_analysis(EICU_PATH)
    mimic_raw = read_analysis(MIMIC_PATH)

    eicu = eicu_raw.dropna(subset=CORE_COLUMNS).copy()
    mimic = mimic_raw.dropna(subset=CORE_COLUMNS).copy()
    params = build_transform_params(eicu)

    y_eicu = eicu[OUTCOME].to_numpy(dtype=float)
    y_mimic = mimic[OUTCOME].to_numpy(dtype=float)

    model_names = [
        "main_effect",
        "continuous_interaction",
        "hypoxemia_binary",
        "hypoxemia_binary_interaction",
    ]
    fitted = {name: fit_named_model(name, eicu, params, y_eicu) for name in model_names}

    coefficient_tables = []
    for name in model_names:
        item = fitted[name]
        coefficient_tables.append(
            coefficient_table_with_labels(list(item["design"].columns), item["fit"], name)
        )
    coef_out = pd.concat(coefficient_tables, ignore_index=True)
    coef_out.to_csv(OUTPUT_DIR / "adjusted_model_v2_coefficients.csv", index=False, quoting=csv.QUOTE_MINIMAL)

    lr_rows = []
    lr_rows.append(
        {
            "comparison": "continuous_interaction_vs_main_effect",
            **lr_test(
                fitted["main_effect"]["fit"]["log_likelihood"],
                fitted["continuous_interaction"]["fit"]["log_likelihood"],
                1,
            ),
        }
    )
    lr_rows.append(
        {
            "comparison": "hypoxemia_binary_interaction_vs_hypoxemia_binary",
            **lr_test(
                fitted["hypoxemia_binary"]["fit"]["log_likelihood"],
                fitted["hypoxemia_binary_interaction"]["fit"]["log_likelihood"],
                1,
            ),
        }
    )
    pd.DataFrame(lr_rows).to_csv(OUTPUT_DIR / "adjusted_model_v2_lr_tests.csv", index=False)

    performance_rows = []
    calibration_parts = []
    for name in model_names:
        item = fitted[name]
        eicu_design = item["design"]
        mimic_design = make_design(mimic, params, name)
        beta = item["fit"]["beta"]

        eicu_lp = eicu_design.to_numpy(dtype=float) @ beta
        eicu_pred = sigmoid(eicu_lp)
        mimic_lp = mimic_design.to_numpy(dtype=float) @ beta
        mimic_pred = sigmoid(mimic_lp)

        performance_rows.append(model_performance("eICU_derivation", name, y_eicu, eicu_design, beta))
        performance_rows.append(model_performance("MIMIC_IV_external_validation", name, y_mimic, mimic_design, beta))
        calibration_parts.append(calibration_groups(f"eICU_derivation__{name}", y_eicu, eicu_pred))
        calibration_parts.append(calibration_groups(f"MIMIC_IV_external_validation__{name}", y_mimic, mimic_pred))

    perf = pd.DataFrame(performance_rows)
    perf = add_model_name_first(perf)
    perf.to_csv(OUTPUT_DIR / "adjusted_model_v2_performance.csv", index=False)
    pd.concat(calibration_parts, ignore_index=True).to_csv(
        OUTPUT_DIR / "adjusted_model_v2_calibration_groups.csv",
        index=False,
    )

    strata = stratum_hypotension_effect(eicu, params)
    strata.to_csv(OUTPUT_DIR / "adjusted_model_v2_hypoxemia_stratified_hypotension_effect.csv", index=False)

    exposure = pd.concat(
        [
            exposure_summary(eicu, "eICU_model_set"),
            exposure_summary(mimic, "MIMIC_IV_validation_set"),
        ],
        ignore_index=True,
    )
    exposure.to_csv(OUTPUT_DIR / "adjusted_model_v2_exposure_zero_summary.csv", index=False)

    package = {
        "run_id": RUN_ID,
        "input_eicu": str(EICU_PATH),
        "input_mimic": str(MIMIC_PATH),
        "eicu_n": int(len(eicu)),
        "eicu_events": int(y_eicu.sum()),
        "mimic_n": int(len(mimic)),
        "mimic_events": int(y_mimic.sum()),
        "models": {
            name: {
                "columns": list(fitted[name]["design"].columns),
                "coefficients": {
                    column: float(beta)
                    for column, beta in zip(fitted[name]["design"].columns, fitted[name]["fit"]["beta"])
                },
                "log_likelihood": float(fitted[name]["fit"]["log_likelihood"]),
                "converged": bool(fitted[name]["fit"]["converged"]),
                "iterations": int(fitted[name]["fit"]["iterations"]),
            }
            for name in model_names
        },
    }
    (OUTPUT_DIR / "adjusted_model_v2_model_package.json").write_text(
        json.dumps(package, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    cont_inter = coef_out[
        (coef_out["model"] == "continuous_interaction")
        & (coef_out["variable"] == "hypotension_x_hypoxemia_z")
    ].iloc[0]
    binary_inter = coef_out[
        (coef_out["model"] == "hypoxemia_binary_interaction")
        & (coef_out["variable"] == "hypotension_z_x_hypoxemia_any")
    ].iloc[0]
    hypox_any = coef_out[
        (coef_out["model"] == "hypoxemia_binary")
        & (coef_out["variable"] == "hypoxemia_any")
    ].iloc[0]

    cont_lr = pd.DataFrame(lr_rows).loc[
        lambda d: d["comparison"] == "continuous_interaction_vs_main_effect"
    ].iloc[0]
    bin_lr = pd.DataFrame(lr_rows).loc[
        lambda d: d["comparison"] == "hypoxemia_binary_interaction_vs_hypoxemia_binary"
    ].iloc[0]
    perf_key = perf[
        (perf["model"] == "continuous_interaction")
        & (perf["dataset"] == "MIMIC_IV_external_validation")
    ].iloc[0]

    eicu_hypox_zero = exposure[
        (exposure["dataset"] == "eICU_model_set")
        & (exposure["variable"] == "hypoxemia_twa")
    ].iloc[0]
    mimic_hypox_zero = exposure[
        (exposure["dataset"] == "MIMIC_IV_validation_set")
        & (exposure["variable"] == "hypoxemia_twa")
    ].iloc[0]

    summary = [
        "# Adjusted Model V2 Interaction Summary",
        "",
        f"Run ID: `{RUN_ID}`",
        "",
        "## Purpose",
        "",
        "- Test whether hypoxemia modifies the association between hypotension burden and ICU mortality.",
        "- Address hypoxemia zero inflation using binary/nonzero hypoxemia analyses.",
        "",
        "## Analysis Sets",
        "",
        f"- eICU model set: N = {len(eicu)}, ICU deaths = {int(y_eicu.sum())}.",
        f"- MIMIC-IV validation set: N = {len(mimic)}, ICU deaths = {int(y_mimic.sum())}.",
        f"- eICU hypoxemia_twa zero burden: {int(eicu_hypox_zero['zero_n'])}/{int(eicu_hypox_zero['n'])} ({fmt_float(eicu_hypox_zero['zero_pct'], 1)}%).",
        f"- MIMIC-IV hypoxemia_twa zero burden: {int(mimic_hypox_zero['zero_n'])}/{int(mimic_hypox_zero['n'])} ({fmt_float(mimic_hypox_zero['zero_pct'], 1)}%).",
        "",
        "## Continuous Interaction",
        "",
        "- Model: main-effect model + `hypotension_twa_per_sd * hypoxemia_twa_per_sd`.",
        f"- Interaction OR = {fmt_float(cont_inter['or'])}, 95% CI {fmt_float(cont_inter['ci_low'])}-{fmt_float(cont_inter['ci_high'])}, P = {fmt_float(cont_inter['p_value'], 4)}.",
        f"- LR test vs main-effect model: chi-square = {fmt_float(cont_lr['lr_chisq'])}, P = {fmt_float(cont_lr['p_value'], 4)}.",
        f"- MIMIC-IV C-index with continuous interaction model = {fmt_float(perf_key['auc_c_index'])}; calibration slope = {fmt_float(perf_key['calibration_slope_logistic'])}.",
        "",
        "## Binary Hypoxemia",
        "",
        "- Hypoxemia is re-coded as any nonzero hypoxemia burden vs none.",
        f"- Any hypoxemia main effect OR = {fmt_float(hypox_any['or'])}, 95% CI {fmt_float(hypox_any['ci_low'])}-{fmt_float(hypox_any['ci_high'])}, P = {fmt_float(hypox_any['p_value'], 4)}.",
        f"- Hypotension x any hypoxemia interaction OR = {fmt_float(binary_inter['or'])}, 95% CI {fmt_float(binary_inter['ci_low'])}-{fmt_float(binary_inter['ci_high'])}, P = {fmt_float(binary_inter['p_value'], 4)}.",
        f"- LR test for binary interaction: chi-square = {fmt_float(bin_lr['lr_chisq'])}, P = {fmt_float(bin_lr['p_value'], 4)}.",
        "",
        "## Stratified Hypotension Effects",
        "",
    ]
    for _, row in strata.iterrows():
        summary.append(
            f"- {row['stratum']}: N = {int(row['n'])}, deaths = {int(row['events'])}, hypotension OR per eICU SD = {fmt_float(row['or'])}, 95% CI {fmt_float(row['ci_low'])}-{fmt_float(row['ci_high'])}, P = {fmt_float(row['p_value'], 4)}."
        )
    summary.extend(
        [
            "",
            "## Outputs",
            "",
            f"- Coefficients: `{OUTPUT_DIR / 'adjusted_model_v2_coefficients.csv'}`",
            f"- LR tests: `{OUTPUT_DIR / 'adjusted_model_v2_lr_tests.csv'}`",
            f"- Performance: `{OUTPUT_DIR / 'adjusted_model_v2_performance.csv'}`",
            f"- Exposure zero summary: `{OUTPUT_DIR / 'adjusted_model_v2_exposure_zero_summary.csv'}`",
            f"- Stratified effects: `{OUTPUT_DIR / 'adjusted_model_v2_hypoxemia_stratified_hypotension_effect.csv'}`",
        ]
    )
    (OUTPUT_DIR / "adjusted_model_v2_summary.md").write_text("\n".join(summary), encoding="utf-8")

    manifest = [
        f"run_id={RUN_ID}",
        f"output_dir={OUTPUT_DIR}",
        f"eicu_n={len(eicu)}",
        f"eicu_events={int(y_eicu.sum())}",
        f"mimic_n={len(mimic)}",
        f"mimic_events={int(y_mimic.sum())}",
        f"continuous_interaction_or={cont_inter['or']}",
        f"continuous_interaction_p={cont_inter['p_value']}",
        f"binary_hypoxemia_or={hypox_any['or']}",
        f"binary_hypoxemia_p={hypox_any['p_value']}",
        f"binary_interaction_or={binary_inter['or']}",
        f"binary_interaction_p={binary_inter['p_value']}",
    ]
    (OUTPUT_DIR / "manifest.txt").write_text("\n".join(manifest), encoding="utf-8")

    print("\n".join(summary[:34]))


if __name__ == "__main__":
    main()

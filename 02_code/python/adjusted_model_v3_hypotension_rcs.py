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
    fmt_float,
    performance_row,
    read_analysis,
    sigmoid,
    transform_features,
)


PROJECT_ROOT = Path(__file__).resolve().parents[2]
RUN_ID = "20260620_adjusted_model_v3_hypotension_rcs"
OUTPUT_DIR = PROJECT_ROOT / "03_outputs" / "tables" / "models" / RUN_ID
FIGURE_DIR = PROJECT_ROOT / "03_outputs" / "figures" / "models" / RUN_ID


def likelihood_ratio_test(ll_reduced: float, ll_full: float, df: int) -> dict:
    stat = max(0.0, 2.0 * (ll_full - ll_reduced))
    if df == 1:
        p_value = math.erfc(math.sqrt(stat / 2.0))
    elif df == 2:
        # chi-square df=2 survival = exp(-x/2)
        p_value = math.exp(-stat / 2.0)
    elif df == 3:
        p_value = math.erfc(math.sqrt(stat / 2.0)) + math.sqrt(2.0 * stat / math.pi) * math.exp(-stat / 2.0)
    elif df == 4:
        p_value = math.exp(-stat / 2.0) * (1.0 + stat / 2.0)
    else:
        p_value = float("nan")
    return {"lr_chisq": stat, "df": df, "p_value": p_value}


def coefficient_table_safe(feature_names: list[str], fit: dict, model: str) -> pd.DataFrame:
    labels = {
        "intercept": "Intercept",
        "hypotension_rcs_linear": "Hypotension RCS linear basis",
        "hypotension_rcs_nonlinear_1": "Hypotension RCS nonlinear basis 1",
        "hypotension_rcs_nonlinear_2": "Hypotension RCS nonlinear basis 2",
        "hypotension_rcs_nonlinear_3": "Hypotension RCS nonlinear basis 3",
        "hypoxemia_twa_per_sd": "Hypoxemia burden, per eICU SD",
        "age_per_10y": "Age, per 10 years",
        "sex_male": "Male vs female",
        "gcs_per_point": "GCS, per 1-point increase",
    }
    rows = []
    for name, beta, se in zip(feature_names, fit["beta"], fit["se"]):
        z = beta / se if se > 0 else float("nan")
        p_value = math.erfc(abs(z) / math.sqrt(2.0)) if math.isfinite(z) else float("nan")
        report_or = not name.startswith("hypotension_rcs")
        if report_or and abs(beta) < 700 and abs(beta + 1.96 * se) < 700 and abs(beta - 1.96 * se) < 700:
            or_value = math.exp(beta)
            ci_low = math.exp(beta - 1.96 * se)
            ci_high = math.exp(beta + 1.96 * se)
        else:
            or_value = np.nan
            ci_low = np.nan
            ci_high = np.nan
        rows.append(
            {
                "model": model,
                "variable": name,
                "label": labels.get(name, name),
                "beta": beta,
                "se": se,
                "z": z,
                "p_value": p_value,
                "or": or_value,
                "ci_low": ci_low,
                "ci_high": ci_high,
                "note": "RCS basis coefficient; do not interpret as standalone OR" if name.startswith("hypotension_rcs") else "",
            }
        )
    return pd.DataFrame(rows)


def truncated_cube(x: np.ndarray, knot: float) -> np.ndarray:
    return np.maximum(x - knot, 0.0) ** 3


def rcs_basis(x: np.ndarray, knots: np.ndarray) -> np.ndarray:
    if len(knots) < 3:
        raise ValueError("RCS requires at least 3 knots.")
    if len(np.unique(knots)) != len(knots):
        raise ValueError(f"RCS knots are not unique: {knots}")
    last = knots[-1]
    penultimate = knots[-2]
    denom = last - penultimate
    if denom <= 0:
        raise ValueError("Invalid final RCS knots.")
    cols = [x]
    for knot in knots[:-2]:
        term = (
            truncated_cube(x, knot)
            - truncated_cube(x, penultimate) * (last - knot) / denom
            + truncated_cube(x, last) * (penultimate - knot) / denom
        )
        cols.append(term)
    return np.column_stack(cols)


def select_knots(values: pd.Series) -> np.ndarray:
    positive = values[values > 0]
    if len(positive) < 100:
        raise ValueError("Too few positive hypotension values for RCS knot selection.")
    # Anchor the zero mass explicitly, then place interior/tail knots on positive burden.
    knots = np.array(
        [
            0.0,
            float(positive.quantile(0.25)),
            float(positive.quantile(0.50)),
            float(positive.quantile(0.75)),
            float(positive.quantile(0.95)),
        ]
    )
    return np.unique(np.round(knots, 8))


def build_main_design(df: pd.DataFrame, params: dict) -> pd.DataFrame:
    base = transform_features(df, params)
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


def build_rcs_design(df: pd.DataFrame, params: dict, knots: np.ndarray, scale: dict) -> pd.DataFrame:
    base = transform_features(df, params)
    x = pd.to_numeric(df["hypotension_twa"], errors="coerce").to_numpy(dtype=float)
    basis = rcs_basis(x, knots)
    out = pd.DataFrame(index=df.index)
    out["intercept"] = 1.0
    out["hypotension_rcs_linear"] = (basis[:, 0] - scale["linear_mean"]) / scale["linear_sd"]
    for idx in range(1, basis.shape[1]):
        sd = scale[f"nonlinear_{idx}_sd"]
        out[f"hypotension_rcs_nonlinear_{idx}"] = (
            basis[:, idx] - scale[f"nonlinear_{idx}_mean"]
        ) / sd
    out["hypoxemia_twa_per_sd"] = base["hypoxemia_twa_per_sd"]
    out["age_per_10y"] = base["age_per_10y"]
    out["sex_male"] = base["sex_male"]
    out["gcs_per_point"] = base["gcs_per_point"]
    return out


def build_rcs_scale(eicu_df: pd.DataFrame, knots: np.ndarray) -> dict:
    basis = rcs_basis(pd.to_numeric(eicu_df["hypotension_twa"], errors="coerce").to_numpy(dtype=float), knots)
    scale = {
        "linear_mean": float(basis[:, 0].mean()),
        "linear_sd": float(basis[:, 0].std(ddof=0)),
    }
    if scale["linear_sd"] <= 0:
        raise ValueError("Non-positive RCS linear SD.")
    for idx in range(1, basis.shape[1]):
        sd = float(basis[:, idx].std(ddof=0))
        if sd <= 0:
            raise ValueError(f"Non-positive RCS nonlinear SD for basis {idx}.")
        scale[f"nonlinear_{idx}_mean"] = float(basis[:, idx].mean())
        scale[f"nonlinear_{idx}_sd"] = sd
    return scale


def model_performance(dataset: str, model_name: str, y: np.ndarray, design: pd.DataFrame, beta: np.ndarray) -> dict:
    lp = design.to_numpy(dtype=float) @ beta
    pred = sigmoid(lp)
    row = performance_row(dataset, y, lp, pred)
    row["model"] = model_name
    return row


def predict_reference_curve(
    eicu_df: pd.DataFrame,
    params: dict,
    knots: np.ndarray,
    scale: dict,
    fit: dict,
) -> pd.DataFrame:
    values = pd.to_numeric(eicu_df["hypotension_twa"], errors="coerce")
    positive = values[values > 0]
    grid = np.unique(
        np.concatenate(
            [
                np.array([0.0]),
                np.quantile(positive, np.linspace(0.01, 0.99, 120)),
            ]
        )
    )
    ref = pd.DataFrame(
        {
            "hypotension_twa": grid,
            "hypoxemia_twa": params["hypoxemia_twa_mean"],
            "age": params["age_mean"],
            "sex_male": 0.0,
            "gcs_total": params["gcs_mean"],
            OUTCOME: 0,
        }
    )
    design = build_rcs_design(ref, params, knots, scale)
    lp = design.to_numpy(dtype=float) @ fit["beta"]
    pred = sigmoid(lp)

    ref0 = ref.copy()
    ref0["hypotension_twa"] = 0.0
    design0 = build_rcs_design(ref0, params, knots, scale)
    lp0 = float((design0.iloc[[0]].to_numpy(dtype=float) @ fit["beta"])[0])

    curve = pd.DataFrame(
        {
            "hypotension_twa": grid,
            "predicted_risk": pred,
            "odds_ratio_vs_zero": np.exp(lp - lp0),
        }
    )
    curve["risk_difference_vs_zero"] = curve["predicted_risk"] - float(sigmoid(np.array([lp0]))[0])
    return curve


def threshold_summary(curve: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for target in [1.25, 1.5, 2.0, 3.0]:
        hit = curve[curve["odds_ratio_vs_zero"] >= target]
        rows.append(
            {
                "target_or_vs_zero": target,
                "first_hypotension_twa_reaching_target": float(hit["hypotension_twa"].iloc[0]) if len(hit) else np.nan,
            }
        )
    return pd.DataFrame(rows)


def write_svg_curve(path: Path, curve: pd.DataFrame, title: str) -> None:
    width, height = 760, 480
    left, right, top, bottom = 78, 28, 42, 62
    plot_w = width - left - right
    plot_h = height - top - bottom
    x_max = float(curve["hypotension_twa"].quantile(0.99))
    y_max = max(2.0, float(curve["odds_ratio_vs_zero"].quantile(0.99)) * 1.05)

    def xmap(x: float) -> float:
        return left + min(max(x / x_max, 0), 1) * plot_w

    def ymap(y: float) -> float:
        return top + (1 - min(max(y / y_max, 0), 1)) * plot_h

    pts = []
    for _, row in curve.iterrows():
        if row["hypotension_twa"] <= x_max:
            pts.append(f"{xmap(float(row['hypotension_twa'])):.1f},{ymap(float(row['odds_ratio_vs_zero'])):.1f}")
    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="white"/>',
        f'<text x="{width/2}" y="25" text-anchor="middle" font-family="Arial" font-size="16">{title}</text>',
        f'<line x1="{left}" y1="{top + plot_h}" x2="{left + plot_w}" y2="{top + plot_h}" stroke="#222"/>',
        f'<line x1="{left}" y1="{top}" x2="{left}" y2="{top + plot_h}" stroke="#222"/>',
        f'<line x1="{left}" y1="{ymap(1.0)}" x2="{left + plot_w}" y2="{ymap(1.0)}" stroke="#999" stroke-dasharray="5,5"/>',
        f'<polyline points="{" ".join(pts)}" fill="none" stroke="#b83227" stroke-width="3"/>',
        f'<text x="{left + plot_w/2}" y="{height - 18}" text-anchor="middle" font-family="Arial" font-size="13">Hypotension burden TWA</text>',
        f'<text x="18" y="{top + plot_h/2}" transform="rotate(-90 18 {top + plot_h/2})" text-anchor="middle" font-family="Arial" font-size="13">Odds ratio vs zero burden</text>',
    ]
    for tick in np.linspace(0, x_max, 6):
        x = xmap(float(tick))
        lines.append(f'<line x1="{x}" y1="{top + plot_h}" x2="{x}" y2="{top + plot_h + 5}" stroke="#222"/>')
        lines.append(f'<text x="{x}" y="{top + plot_h + 22}" text-anchor="middle" font-family="Arial" font-size="11">{tick:.2f}</text>')
    for tick in np.linspace(0, y_max, 6):
        y = ymap(float(tick))
        lines.append(f'<line x1="{left - 5}" y1="{y}" x2="{left}" y2="{y}" stroke="#222"/>')
        lines.append(f'<text x="{left - 10}" y="{y + 4}" text-anchor="end" font-family="Arial" font-size="11">{tick:.1f}</text>')
    lines.append("</svg>")
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    FIGURE_DIR.mkdir(parents=True, exist_ok=True)

    eicu_raw = read_analysis(EICU_PATH)
    mimic_raw = read_analysis(MIMIC_PATH)
    eicu = eicu_raw.dropna(subset=CORE_COLUMNS).copy()
    mimic = mimic_raw.dropna(subset=CORE_COLUMNS).copy()
    params = build_transform_params(eicu)
    knots = select_knots(pd.to_numeric(eicu["hypotension_twa"], errors="coerce"))
    scale = build_rcs_scale(eicu, knots)

    y_eicu = eicu[OUTCOME].to_numpy(dtype=float)
    y_mimic = mimic[OUTCOME].to_numpy(dtype=float)

    main_design_eicu = build_main_design(eicu, params)
    main_fit = fit_logistic(main_design_eicu.to_numpy(dtype=float), y_eicu)

    rcs_design_eicu = build_rcs_design(eicu, params, knots, scale)
    rcs_fit = fit_logistic(rcs_design_eicu.to_numpy(dtype=float), y_eicu)

    coef_main = coefficient_table(list(main_design_eicu.columns), main_fit)
    coef_main.insert(0, "model", "linear_hypotension")
    coef_main["note"] = ""
    coef_rcs = coefficient_table_safe(list(rcs_design_eicu.columns), rcs_fit, "hypotension_rcs")
    coef = pd.concat([coef_main, coef_rcs], ignore_index=True)
    coef.to_csv(OUTPUT_DIR / "adjusted_model_v3_rcs_coefficients.csv", index=False, quoting=csv.QUOTE_MINIMAL)

    lr_overall = likelihood_ratio_test(main_fit["log_likelihood"], rcs_fit["log_likelihood"], len(rcs_design_eicu.columns) - len(main_design_eicu.columns))
    linear_without_h = main_design_eicu.drop(columns=["hypotension_twa_per_sd"])
    no_h_fit = fit_logistic(linear_without_h.to_numpy(dtype=float), y_eicu)
    lr_hypotension = likelihood_ratio_test(no_h_fit["log_likelihood"], rcs_fit["log_likelihood"], len(rcs_design_eicu.columns) - len(linear_without_h.columns))
    lr_rows = pd.DataFrame(
        [
            {"comparison": "rcs_vs_linear_hypotension", **lr_overall},
            {"comparison": "overall_hypotension_rcs_vs_no_hypotension", **lr_hypotension},
        ]
    )
    lr_rows.to_csv(OUTPUT_DIR / "adjusted_model_v3_rcs_lr_tests.csv", index=False)

    rcs_design_mimic = build_rcs_design(mimic, params, knots, scale)
    main_design_mimic = build_main_design(mimic, params)
    perf_rows = []
    perf_rows.append(model_performance("eICU_derivation", "linear_hypotension", y_eicu, main_design_eicu, main_fit["beta"]))
    perf_rows.append(model_performance("MIMIC_IV_external_validation", "linear_hypotension", y_mimic, main_design_mimic, main_fit["beta"]))
    perf_rows.append(model_performance("eICU_derivation", "hypotension_rcs", y_eicu, rcs_design_eicu, rcs_fit["beta"]))
    perf_rows.append(model_performance("MIMIC_IV_external_validation", "hypotension_rcs", y_mimic, rcs_design_mimic, rcs_fit["beta"]))
    perf = pd.DataFrame(perf_rows)
    perf = perf[["model"] + [c for c in perf.columns if c != "model"]]
    perf.to_csv(OUTPUT_DIR / "adjusted_model_v3_rcs_performance.csv", index=False)

    curve = predict_reference_curve(eicu, params, knots, scale, rcs_fit)
    curve.to_csv(OUTPUT_DIR / "adjusted_model_v3_rcs_prediction_curve.csv", index=False)
    thresholds = threshold_summary(curve)
    thresholds.to_csv(OUTPUT_DIR / "adjusted_model_v3_rcs_threshold_summary.csv", index=False)
    write_svg_curve(
        FIGURE_DIR / "hypotension_rcs_or_curve.svg",
        curve,
        "Hypotension burden RCS: OR vs zero burden",
    )

    package = {
        "run_id": RUN_ID,
        "knots": [float(x) for x in knots],
        "scale": scale,
        "transform_params_from_eicu": params,
        "rcs_columns": list(rcs_design_eicu.columns),
        "rcs_coefficients": {column: float(beta) for column, beta in zip(rcs_design_eicu.columns, rcs_fit["beta"])},
        "main_columns": list(main_design_eicu.columns),
        "main_coefficients": {column: float(beta) for column, beta in zip(main_design_eicu.columns, main_fit["beta"])},
    }
    (OUTPUT_DIR / "adjusted_model_v3_rcs_model_package.json").write_text(
        json.dumps(package, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    rcs_perf_mimic = perf[(perf["model"] == "hypotension_rcs") & (perf["dataset"] == "MIMIC_IV_external_validation")].iloc[0]
    lin_perf_mimic = perf[(perf["model"] == "linear_hypotension") & (perf["dataset"] == "MIMIC_IV_external_validation")].iloc[0]
    lr_nonlin = lr_rows[lr_rows["comparison"] == "rcs_vs_linear_hypotension"].iloc[0]
    lr_overall_row = lr_rows[lr_rows["comparison"] == "overall_hypotension_rcs_vs_no_hypotension"].iloc[0]

    summary = [
        "# Adjusted Model V3 Hypotension RCS Summary",
        "",
        f"Run ID: `{RUN_ID}`",
        "",
        "## Model",
        "",
        "- RCS is applied only to hypotension_twa.",
        "- Hypoxemia remains a linear covariate from the v1 main-effect model; no hypoxemia RCS because of zero inflation.",
        "- eICU fits the model; MIMIC-IV receives locked eICU coefficients.",
        f"- RCS knots: {', '.join(fmt_float(k, 4) for k in knots)}.",
        "",
        "## Analysis Sets",
        "",
        f"- eICU model set: N = {len(eicu)}, ICU deaths = {int(y_eicu.sum())}.",
        f"- MIMIC-IV validation set: N = {len(mimic)}, ICU deaths = {int(y_mimic.sum())}.",
        "",
        "## Nonlinearity",
        "",
        f"- RCS vs linear hypotension LR chi-square = {fmt_float(lr_nonlin['lr_chisq'])}, df = {int(lr_nonlin['df'])}, P = {fmt_float(lr_nonlin['p_value'], 4)}.",
        f"- Overall hypotension RCS vs no hypotension term LR chi-square = {fmt_float(lr_overall_row['lr_chisq'])}, df = {int(lr_overall_row['df'])}, P = {fmt_float(lr_overall_row['p_value'], 4)}.",
        "",
        "## External Validation",
        "",
        f"- Linear v1 MIMIC-IV C-index = {fmt_float(lin_perf_mimic['auc_c_index'])}; calibration slope = {fmt_float(lin_perf_mimic['calibration_slope_logistic'])}.",
        f"- RCS MIMIC-IV C-index = {fmt_float(rcs_perf_mimic['auc_c_index'])}; calibration slope = {fmt_float(rcs_perf_mimic['calibration_slope_logistic'])}.",
        "",
        "## Threshold Hints",
        "",
    ]
    for _, row in thresholds.iterrows():
        value = row["first_hypotension_twa_reaching_target"]
        summary.append(
            f"- OR vs zero >= {fmt_float(row['target_or_vs_zero'], 2)} first reached at hypotension_twa = {fmt_float(value, 4) if pd.notna(value) else 'not reached'}."
        )
    summary.extend(
        [
            "",
            "## Outputs",
            "",
            f"- Coefficients: `{OUTPUT_DIR / 'adjusted_model_v3_rcs_coefficients.csv'}`",
            f"- LR tests: `{OUTPUT_DIR / 'adjusted_model_v3_rcs_lr_tests.csv'}`",
            f"- Performance: `{OUTPUT_DIR / 'adjusted_model_v3_rcs_performance.csv'}`",
            f"- Prediction curve: `{OUTPUT_DIR / 'adjusted_model_v3_rcs_prediction_curve.csv'}`",
            f"- Threshold summary: `{OUTPUT_DIR / 'adjusted_model_v3_rcs_threshold_summary.csv'}`",
            f"- Figure: `{FIGURE_DIR / 'hypotension_rcs_or_curve.svg'}`",
        ]
    )
    (OUTPUT_DIR / "adjusted_model_v3_rcs_summary.md").write_text("\n".join(summary), encoding="utf-8")

    manifest = [
        f"run_id={RUN_ID}",
        f"output_dir={OUTPUT_DIR}",
        f"figure_dir={FIGURE_DIR}",
        f"eicu_n={len(eicu)}",
        f"eicu_events={int(y_eicu.sum())}",
        f"mimic_n={len(mimic)}",
        f"mimic_events={int(y_mimic.sum())}",
        f"knots={','.join(str(float(k)) for k in knots)}",
        f"nonlinearity_lr_chisq={lr_nonlin['lr_chisq']}",
        f"nonlinearity_p={lr_nonlin['p_value']}",
        f"rcs_mimic_auc={rcs_perf_mimic['auc_c_index']}",
        f"rcs_mimic_calibration_slope={rcs_perf_mimic['calibration_slope_logistic']}",
    ]
    (OUTPUT_DIR / "manifest.txt").write_text("\n".join(manifest), encoding="utf-8")

    print("\n".join(summary[:28]))


if __name__ == "__main__":
    main()

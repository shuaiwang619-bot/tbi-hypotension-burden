from __future__ import annotations

import csv
import json
import math
from pathlib import Path

import numpy as np
import pandas as pd


PROJECT_ROOT = Path(__file__).resolve().parents[2]
RUN_ID = "20260620_adjusted_model_v1"
INPUT_DIR = PROJECT_ROOT / "03_outputs" / "tables" / "covariates" / "20260620_covariates_v2_baseline"
OUTPUT_DIR = PROJECT_ROOT / "03_outputs" / "tables" / "models" / RUN_ID
FIGURE_DIR = PROJECT_ROOT / "03_outputs" / "figures" / "models" / RUN_ID

EICU_PATH = INPUT_DIR / "eicu_analysis_covariates_v1_landmark_main.csv"
MIMIC_PATH = INPUT_DIR / "mimic_analysis_covariates_v1_landmark_main.csv"

OUTCOME = "death_icu"
CORE_COLUMNS = [
    OUTCOME,
    "hypotension_twa",
    "hypoxemia_twa",
    "age",
    "sex_male",
    "gcs_total",
]

FEATURE_ORDER = [
    "intercept",
    "hypotension_twa_per_sd",
    "hypoxemia_twa_per_sd",
    "age_per_10y",
    "sex_male",
    "gcs_per_point",
]

FEATURE_LABELS = {
    "intercept": "Intercept",
    "hypotension_twa_per_sd": "Hypotension burden, per eICU SD",
    "hypoxemia_twa_per_sd": "Hypoxemia burden, per eICU SD",
    "age_per_10y": "Age, per 10 years",
    "sex_male": "Male vs female",
    "gcs_per_point": "GCS, per 1-point increase",
}


def sigmoid(x: np.ndarray) -> np.ndarray:
    x = np.clip(x, -35, 35)
    return 1.0 / (1.0 + np.exp(-x))


def normal_p_value(z: float) -> float:
    return math.erfc(abs(z) / math.sqrt(2.0))


def fit_logistic(
    x: np.ndarray,
    y: np.ndarray,
    max_iter: int = 100,
    tol: float = 1e-9,
) -> dict:
    beta = np.zeros(x.shape[1], dtype=float)
    converged = False
    ridge = 1e-8

    for iteration in range(1, max_iter + 1):
        eta = x @ beta
        p = sigmoid(eta)
        w = np.clip(p * (1.0 - p), 1e-9, None)
        grad = x.T @ (y - p)
        hessian_positive = x.T @ (w[:, None] * x)
        try:
            step = np.linalg.solve(hessian_positive + ridge * np.eye(x.shape[1]), grad)
        except np.linalg.LinAlgError:
            step = np.linalg.pinv(hessian_positive + ridge * np.eye(x.shape[1])) @ grad
        beta_next = beta + step
        if float(np.max(np.abs(step))) < tol:
            beta = beta_next
            converged = True
            break
        beta = beta_next

    eta = x @ beta
    p = sigmoid(eta)
    w = np.clip(p * (1.0 - p), 1e-9, None)
    hessian_positive = x.T @ (w[:, None] * x)
    cov = np.linalg.pinv(hessian_positive)
    se = np.sqrt(np.clip(np.diag(cov), 0, None))
    ll = float(np.sum(y * np.log(np.clip(p, 1e-12, 1)) + (1 - y) * np.log(np.clip(1 - p, 1e-12, 1))))
    return {
        "beta": beta,
        "se": se,
        "cov": cov,
        "linear_predictor": eta,
        "predicted": p,
        "log_likelihood": ll,
        "iterations": iteration,
        "converged": converged,
    }


def fit_offset_intercept(lp: np.ndarray, y: np.ndarray, max_iter: int = 100, tol: float = 1e-10) -> float:
    alpha = 0.0
    for _ in range(max_iter):
        p = sigmoid(alpha + lp)
        grad = float(np.sum(y - p))
        hess = float(np.sum(p * (1.0 - p)))
        if hess <= 1e-12:
            break
        step = grad / hess
        alpha += step
        if abs(step) < tol:
            break
    return alpha


def auc_score(y: np.ndarray, score: np.ndarray) -> float:
    y = np.asarray(y, dtype=int)
    score = np.asarray(score, dtype=float)
    n_pos = int(np.sum(y == 1))
    n_neg = int(np.sum(y == 0))
    if n_pos == 0 or n_neg == 0:
        return float("nan")
    ranks = pd.Series(score).rank(method="average").to_numpy()
    sum_ranks_pos = float(np.sum(ranks[y == 1]))
    return (sum_ranks_pos - n_pos * (n_pos + 1) / 2.0) / (n_pos * n_neg)


def read_analysis(path: Path) -> pd.DataFrame:
    if not path.exists():
        raise FileNotFoundError(path)
    df = pd.read_csv(path)
    for col in CORE_COLUMNS:
        df[col] = pd.to_numeric(df[col], errors="coerce")
    return df


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


def transform_features(df: pd.DataFrame, params: dict) -> pd.DataFrame:
    out = pd.DataFrame(index=df.index)
    out["intercept"] = 1.0
    out["hypotension_twa_per_sd"] = (
        df["hypotension_twa"] - params["hypotension_twa_mean"]
    ) / params["hypotension_twa_sd"]
    out["hypoxemia_twa_per_sd"] = (
        df["hypoxemia_twa"] - params["hypoxemia_twa_mean"]
    ) / params["hypoxemia_twa_sd"]
    out["age_per_10y"] = (df["age"] - params["age_mean"]) / 10.0
    out["sex_male"] = df["sex_male"]
    out["gcs_per_point"] = df["gcs_total"] - params["gcs_mean"]
    return out[FEATURE_ORDER]


def coefficient_table(feature_names: list[str], fit: dict) -> pd.DataFrame:
    rows = []
    for name, beta, se in zip(feature_names, fit["beta"], fit["se"]):
        z = beta / se if se > 0 else float("nan")
        p_value = normal_p_value(z) if math.isfinite(z) else float("nan")
        rows.append(
            {
                "variable": name,
                "label": FEATURE_LABELS.get(name, name),
                "beta": beta,
                "se": se,
                "z": z,
                "p_value": p_value,
                "or": math.exp(beta),
                "ci_low": math.exp(beta - 1.96 * se),
                "ci_high": math.exp(beta + 1.96 * se),
            }
        )
    return pd.DataFrame(rows)


def performance_row(dataset: str, y: np.ndarray, lp: np.ndarray, pred: np.ndarray) -> dict:
    cal = fit_logistic(np.column_stack([np.ones(len(lp)), lp]), y)
    return {
        "dataset": dataset,
        "n": int(len(y)),
        "events": int(np.sum(y)),
        "event_rate": float(np.mean(y)),
        "auc_c_index": auc_score(y, pred),
        "brier_score": float(np.mean((y - pred) ** 2)),
        "mean_predicted_risk": float(np.mean(pred)),
        "observed_risk": float(np.mean(y)),
        "calibration_intercept_offset_slope1": fit_offset_intercept(lp, y),
        "calibration_intercept_logistic": float(cal["beta"][0]),
        "calibration_slope_logistic": float(cal["beta"][1]),
        "calibration_model_converged": bool(cal["converged"]),
    }


def calibration_groups(dataset: str, y: np.ndarray, pred: np.ndarray, n_groups: int = 5) -> pd.DataFrame:
    temp = pd.DataFrame({"y": y, "pred": pred})
    temp["group"] = pd.qcut(temp["pred"], q=n_groups, labels=False, duplicates="drop") + 1
    rows = []
    for group, data in temp.groupby("group", observed=True):
        rows.append(
            {
                "dataset": dataset,
                "risk_group": int(group),
                "n": int(len(data)),
                "events": int(data["y"].sum()),
                "mean_predicted_risk": float(data["pred"].mean()),
                "observed_risk": float(data["y"].mean()),
                "min_predicted_risk": float(data["pred"].min()),
                "max_predicted_risk": float(data["pred"].max()),
            }
        )
    return pd.DataFrame(rows)


def quartile_model(
    eicu_df: pd.DataFrame,
    base_params: dict,
    exposure: str,
    other_exposure_z: str,
) -> pd.DataFrame:
    work = eicu_df.copy()
    q_col = f"{exposure}_quartile"
    work[q_col] = pd.qcut(work[exposure], q=4, labels=False, duplicates="drop")
    feature_df = transform_features(work, base_params)
    keep_features = ["intercept", other_exposure_z, "age_per_10y", "sex_male", "gcs_per_point"]
    design = feature_df[keep_features].copy()
    max_q = int(work[q_col].max())
    for q in range(1, max_q + 1):
        design[f"{exposure}_Q{q + 1}_vs_Q1"] = (work[q_col] == q).astype(float)
    y = work[OUTCOME].to_numpy(dtype=float)
    fit = fit_logistic(design.to_numpy(dtype=float), y)
    table = coefficient_table(list(design.columns), fit)
    table.insert(0, "model", f"{exposure}_quartile_adjusted")
    return table[table["variable"].str.contains("_Q")]


def write_svg_calibration(path: Path, title: str, cal_df: pd.DataFrame) -> None:
    width, height = 640, 460
    pad_left, pad_bottom, pad_top, pad_right = 70, 60, 40, 30
    plot_w = width - pad_left - pad_right
    plot_h = height - pad_top - pad_bottom

    def xmap(v: float) -> float:
        return pad_left + v * plot_w

    def ymap(v: float) -> float:
        return pad_top + (1.0 - v) * plot_h

    points = []
    for _, row in cal_df.iterrows():
        x = xmap(float(row["mean_predicted_risk"]))
        y = ymap(float(row["observed_risk"]))
        points.append((x, y, int(row["n"])))

    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="white"/>',
        f'<text x="{width/2}" y="24" text-anchor="middle" font-family="Arial" font-size="16">{title}</text>',
        f'<line x1="{pad_left}" y1="{pad_top + plot_h}" x2="{pad_left + plot_w}" y2="{pad_top + plot_h}" stroke="#222"/>',
        f'<line x1="{pad_left}" y1="{pad_top}" x2="{pad_left}" y2="{pad_top + plot_h}" stroke="#222"/>',
        f'<line x1="{xmap(0)}" y1="{ymap(0)}" x2="{xmap(1)}" y2="{ymap(1)}" stroke="#888" stroke-dasharray="5,5"/>',
        f'<text x="{pad_left + plot_w/2}" y="{height - 18}" text-anchor="middle" font-family="Arial" font-size="13">Mean predicted risk</text>',
        f'<text x="18" y="{pad_top + plot_h/2}" text-anchor="middle" transform="rotate(-90 18 {pad_top + plot_h/2})" font-family="Arial" font-size="13">Observed risk</text>',
    ]
    for tick in np.linspace(0, 1, 6):
        x = xmap(float(tick))
        y = ymap(float(tick))
        label = f"{tick:.1f}"
        lines.append(f'<line x1="{x}" y1="{pad_top + plot_h}" x2="{x}" y2="{pad_top + plot_h + 5}" stroke="#222"/>')
        lines.append(f'<text x="{x}" y="{pad_top + plot_h + 22}" text-anchor="middle" font-family="Arial" font-size="11">{label}</text>')
        lines.append(f'<line x1="{pad_left - 5}" y1="{y}" x2="{pad_left}" y2="{y}" stroke="#222"/>')
        lines.append(f'<text x="{pad_left - 10}" y="{y + 4}" text-anchor="end" font-family="Arial" font-size="11">{label}</text>')
    for x, y, n in points:
        radius = 4 + min(10, math.sqrt(n) / 2.5)
        lines.append(f'<circle cx="{x}" cy="{y}" r="{radius:.1f}" fill="#2b6cb0" fill-opacity="0.75" stroke="#12385f"/>')
    lines.append("</svg>")
    path.write_text("\n".join(lines), encoding="utf-8")


def fmt_float(value: float, digits: int = 3) -> str:
    if not math.isfinite(value):
        return "NA"
    return f"{value:.{digits}f}"


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    FIGURE_DIR.mkdir(parents=True, exist_ok=True)

    eicu_raw = read_analysis(EICU_PATH)
    mimic_raw = read_analysis(MIMIC_PATH)

    eicu_model = eicu_raw.dropna(subset=CORE_COLUMNS).copy()
    mimic_model = mimic_raw.dropna(subset=CORE_COLUMNS).copy()

    params = build_transform_params(eicu_model)
    x_eicu_df = transform_features(eicu_model, params)
    y_eicu = eicu_model[OUTCOME].to_numpy(dtype=float)
    fit = fit_logistic(x_eicu_df.to_numpy(dtype=float), y_eicu)

    coef = coefficient_table(FEATURE_ORDER, fit)
    coef.to_csv(OUTPUT_DIR / "adjusted_model_v1_coefficients.csv", index=False, quoting=csv.QUOTE_MINIMAL)

    x_mimic_df = transform_features(mimic_model, params)
    y_mimic = mimic_model[OUTCOME].to_numpy(dtype=float)
    mimic_lp = x_mimic_df.to_numpy(dtype=float) @ fit["beta"]
    mimic_pred = sigmoid(mimic_lp)

    eicu_lp = fit["linear_predictor"]
    eicu_pred = fit["predicted"]

    perf = pd.DataFrame(
        [
            performance_row("eICU_derivation", y_eicu, eicu_lp, eicu_pred),
            performance_row("MIMIC_IV_external_validation", y_mimic, mimic_lp, mimic_pred),
        ]
    )
    perf.to_csv(OUTPUT_DIR / "adjusted_model_v1_performance.csv", index=False)

    cal_eicu = calibration_groups("eICU_derivation", y_eicu, eicu_pred)
    cal_mimic = calibration_groups("MIMIC_IV_external_validation", y_mimic, mimic_pred)
    cal = pd.concat([cal_eicu, cal_mimic], ignore_index=True)
    cal.to_csv(OUTPUT_DIR / "adjusted_model_v1_calibration_groups.csv", index=False)

    quartile_tables = []
    quartile_tables.append(quartile_model(eicu_model, params, "hypotension_twa", "hypoxemia_twa_per_sd"))
    quartile_tables.append(quartile_model(eicu_model, params, "hypoxemia_twa", "hypotension_twa_per_sd"))
    pd.concat(quartile_tables, ignore_index=True).to_csv(
        OUTPUT_DIR / "adjusted_model_v1_eicu_quartile_models.csv",
        index=False,
    )

    model_package = {
        "run_id": RUN_ID,
        "input_dir": str(INPUT_DIR),
        "modeling_decision": {
            "derivation_database": "eICU",
            "external_validation_database": "MIMIC-IV",
            "outcome": "ICU mortality after 24h landmark",
            "primary_features": FEATURE_ORDER,
            "excluded_from_primary_model": [
                "baseline_or_entry_ventilation",
                "baseline_or_entry_vasopressor",
                "first_24h_ventilation",
                "first_24h_vasopressor",
                "lactate_or_coagulation",
                "database_specific_severity_scores",
            ],
            "mimic_validation": "locked eICU coefficients only; no MIMIC refit",
        },
        "transform_params_from_eicu": params,
        "coefficients": {name: float(value) for name, value in zip(FEATURE_ORDER, fit["beta"])},
        "fit": {
            "n": int(len(eicu_model)),
            "events": int(np.sum(y_eicu)),
            "converged": bool(fit["converged"]),
            "iterations": int(fit["iterations"]),
            "log_likelihood": float(fit["log_likelihood"]),
        },
    }
    (OUTPUT_DIR / "adjusted_model_v1_model_package.json").write_text(
        json.dumps(model_package, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    write_svg_calibration(
        FIGURE_DIR / "eicu_derivation_calibration_quintiles.svg",
        "eICU derivation calibration",
        cal_eicu,
    )
    write_svg_calibration(
        FIGURE_DIR / "mimic_external_validation_calibration_quintiles.svg",
        "MIMIC-IV external validation calibration",
        cal_mimic,
    )

    h_row = coef.loc[coef["variable"] == "hypotension_twa_per_sd"].iloc[0]
    o_row = coef.loc[coef["variable"] == "hypoxemia_twa_per_sd"].iloc[0]
    eicu_perf = perf.loc[perf["dataset"] == "eICU_derivation"].iloc[0]
    mimic_perf = perf.loc[perf["dataset"] == "MIMIC_IV_external_validation"].iloc[0]

    summary = [
        "# Adjusted Model V1 Summary",
        "",
        f"Run ID: `{RUN_ID}`",
        "",
        "## Model",
        "",
        "- Derivation: eICU.",
        "- External validation: MIMIC-IV.",
        "- Outcome: ICU mortality after 24h landmark.",
        "- Primary model: `death_icu ~ hypotension_twa_per_sd + hypoxemia_twa_per_sd + age_per_10y + sex_male + gcs_per_point`.",
        "- MIMIC-IV uses locked eICU coefficients; no MIMIC refit.",
        "- Ventilation and vasopressor variables are excluded from the primary model and reserved for descriptive/sensitivity analyses.",
        "",
        "## Analysis Sets",
        "",
        f"- eICU raw landmark table: N = {len(eicu_raw)}, ICU deaths = {int(eicu_raw[OUTCOME].sum())}.",
        f"- eICU complete-case model set: N = {len(eicu_model)}, ICU deaths = {int(y_eicu.sum())}.",
        f"- MIMIC-IV validation set: N = {len(mimic_model)}, ICU deaths = {int(y_mimic.sum())}.",
        "",
        "## Main Adjusted Effects",
        "",
        f"- Hypotension burden, per eICU SD: OR = {fmt_float(h_row['or'])}, 95% CI {fmt_float(h_row['ci_low'])}-{fmt_float(h_row['ci_high'])}, P = {fmt_float(h_row['p_value'], 4)}.",
        f"- Hypoxemia burden, per eICU SD: OR = {fmt_float(o_row['or'])}, 95% CI {fmt_float(o_row['ci_low'])}-{fmt_float(o_row['ci_high'])}, P = {fmt_float(o_row['p_value'], 4)}.",
        "",
        "## Performance",
        "",
        f"- eICU C-index = {fmt_float(eicu_perf['auc_c_index'])}; Brier = {fmt_float(eicu_perf['brier_score'])}; mean predicted risk = {fmt_float(eicu_perf['mean_predicted_risk'])}; observed risk = {fmt_float(eicu_perf['observed_risk'])}.",
        f"- MIMIC-IV C-index = {fmt_float(mimic_perf['auc_c_index'])}; Brier = {fmt_float(mimic_perf['brier_score'])}; mean predicted risk = {fmt_float(mimic_perf['mean_predicted_risk'])}; observed risk = {fmt_float(mimic_perf['observed_risk'])}.",
        f"- MIMIC-IV calibration intercept (offset, slope fixed at 1) = {fmt_float(mimic_perf['calibration_intercept_offset_slope1'])}.",
        f"- MIMIC-IV calibration slope = {fmt_float(mimic_perf['calibration_slope_logistic'])}; logistic calibration intercept = {fmt_float(mimic_perf['calibration_intercept_logistic'])}.",
        "",
        "## Outputs",
        "",
        f"- Coefficients: `{OUTPUT_DIR / 'adjusted_model_v1_coefficients.csv'}`",
        f"- Performance: `{OUTPUT_DIR / 'adjusted_model_v1_performance.csv'}`",
        f"- Calibration groups: `{OUTPUT_DIR / 'adjusted_model_v1_calibration_groups.csv'}`",
        f"- Quartile models: `{OUTPUT_DIR / 'adjusted_model_v1_eicu_quartile_models.csv'}`",
        f"- Model package: `{OUTPUT_DIR / 'adjusted_model_v1_model_package.json'}`",
        f"- Calibration figures: `{FIGURE_DIR}`",
    ]
    (OUTPUT_DIR / "adjusted_model_v1_summary.md").write_text("\n".join(summary), encoding="utf-8")

    manifest = [
        f"run_id={RUN_ID}",
        f"input_dir={INPUT_DIR}",
        f"output_dir={OUTPUT_DIR}",
        f"figure_dir={FIGURE_DIR}",
        f"eicu_input={EICU_PATH}",
        f"mimic_input={MIMIC_PATH}",
        f"eicu_raw_n={len(eicu_raw)}",
        f"eicu_model_n={len(eicu_model)}",
        f"eicu_model_events={int(y_eicu.sum())}",
        f"mimic_validation_n={len(mimic_model)}",
        f"mimic_validation_events={int(y_mimic.sum())}",
        f"model_converged={fit['converged']}",
        f"model_iterations={fit['iterations']}",
    ]
    (OUTPUT_DIR / "manifest.txt").write_text("\n".join(manifest), encoding="utf-8")

    print("\n".join(summary[:24]))


if __name__ == "__main__":
    main()

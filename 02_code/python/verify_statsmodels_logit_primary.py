from __future__ import annotations

import json
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
VENDOR = PROJECT_ROOT / "03_outputs" / "qa" / "statsmodels_check_env"
if VENDOR.exists():
    sys.path.insert(0, str(VENDOR))

import numpy as np
from statsmodels.discrete.discrete_model import Logit

import adjusted_model_v1 as model


OUT_DIR = PROJECT_ROOT / "03_outputs" / "qa" / "statsmodels_logit_check"
OUT_DIR.mkdir(parents=True, exist_ok=True)


def main() -> None:
    eicu_raw = model.read_analysis(model.EICU_PATH)
    eicu_model = eicu_raw.dropna(subset=model.CORE_COLUMNS).copy()
    params = model.build_transform_params(eicu_model)
    x_df = model.transform_features(eicu_model, params)
    x = x_df.to_numpy(dtype=float)
    y = eicu_model[model.OUTCOME].to_numpy(dtype=float)

    custom = model.fit_logistic(x, y)
    sm_fit = Logit(y, x).fit(disp=False, maxiter=200)
    sm_pred = sm_fit.predict(x)

    report = {
        "n": int(len(y)),
        "events": int(np.sum(y)),
        "feature_order": model.FEATURE_ORDER,
        "max_abs_beta_diff": float(np.max(np.abs(custom["beta"] - sm_fit.params))),
        "max_abs_se_diff": float(np.max(np.abs(custom["se"] - sm_fit.bse))),
        "max_abs_predicted_probability_diff": float(np.max(np.abs(custom["predicted"] - sm_pred))),
        "custom_converged": bool(custom["converged"]),
        "custom_iterations": int(custom["iterations"]),
        "statsmodels_converged": bool(sm_fit.mle_retvals.get("converged", False)),
        "statsmodels_iterations": int(sm_fit.mle_retvals.get("iterations", -1)),
    }
    (OUT_DIR / "primary_logit_statsmodels_check.json").write_text(
        json.dumps(report, indent=2),
        encoding="utf-8",
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

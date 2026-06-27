# Table S6. RCS and winsorized RCS tests

Likelihood-ratio tests for exploratory dose-response shape analyses and locked MIMIC-IV validation performance.

| Model | Comparison | LR chi-square | df | P value | MIMIC-IV C-index | MIMIC-IV calibration slope |
| --- | --- | --- | --- | --- | --- | --- |
| Original 3-knot RCS | RCS vs linear hypotension term | 5.529 | 1 | 0.019 | 0.722 | 0.736 |
| Original 3-knot RCS | RCS vs no hypotension term | 16.428 | 2 | <0.001 | 0.722 | 0.736 |
| Original 4-knot RCS sensitivity | RCS vs linear hypotension term | 6.906 | 2 | 0.032 | 0.720 | 0.738 |
| Original 4-knot RCS sensitivity | RCS vs no hypotension term | 17.805 | 3 | <0.001 | 0.720 | 0.738 |
| 99th-percentile winsorized 3-knot RCS | RCS vs winsorized linear term | 2.273 | 1 | 0.132 | 0.727 | 0.739 |
| 99th-percentile winsorized 3-knot RCS | RCS vs no hypotension term | 17.733 | 2 | <0.001 | 0.727 | 0.739 |

Note: Restricted cubic spline (RCS) analyses were exploratory shape checks. The original 3-knot RCS showed nominal nonlinearity (P=0.019), whereas the 99th-percentile winsorized RCS no longer improved fit over the corresponding linear term (P=0.132). MIMIC-IV validation metrics were obtained by transporting the corresponding locked eICU spline model to MIMIC-IV without refitting; because two LR comparisons are reported for each spline model, the same validation metrics are repeated across comparison rows. LR, likelihood-ratio.

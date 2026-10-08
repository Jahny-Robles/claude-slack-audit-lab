# Sentinel workbook: Claude Slack Audit Overview

`claude-slack-audit-overview.workbook.json` is the exported definition of the workbook shown in
[`screenshots/32-audit-workbook.png`](../screenshots/32-audit-workbook.png) and
[`33-audit-workbook-lower.png`](../screenshots/33-audit-workbook-lower.png).

**Import:** Sentinel > Workbooks > Add workbook > Edit (`</>` Advanced Editor) > Gallery Template tab >
paste the JSON > Apply > Save (pick the `jahnylabs-sentinel` workspace).

| Tile | Question it answers |
|---|---|
| Queries per user per day | Who is using the agent, and is anyone far outside normal? (D4 looks at the same thing per 30 minutes) |
| Policy outcomes | Allowed vs Redacted vs Blocked: is the DLP actually doing work? |
| Share of messages redacted and blocked | The two numbers a manager asks for first |
| Blocks by reason | PHI vs prompt injection: which risk is the agent really facing? |
| Identifier types seen | Which identifiers do people paste (member ID, DOB, phone, SSN)? Drives training. |

All tiles read the `TimeRange` parameter (default 14 days). The simulated baseline is from late September, so the
default 30-day range is the one that shows it. Redacted shows 0% in the screenshots because the simulator only emits
Allowed and Blocked; live `redact`-mode traffic fills that column.

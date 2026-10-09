# For students: managing Azure for Students and other cloud credits

This lab doubles as a worked example for anyone learning security (or cloud) on a **student credit** such as
Azure for Students ($100, no credit card) or a free-tier account. I used up most of a $100 credit without noticing,
then caught a scary-looking budget alert before it caused harm. Both stories are real, with screenshots, and both
teach habits you can copy.

If you only read one thing: **a credit is a budget you cannot top up. Check it on a schedule, know what is spending it,
and never react to a number you have not verified.**

---

## What happened to my credit

| Step | What I saw | Evidence |
|---|---|---|
| Credit looked low | $20.52 left of $100 ($79.48 used) | [42](../screenshots/42-azure-credits-remaining.png) |
| Found the cause | Sentinel per-GB ingestion was $77.30 of the $77.46 spent Jul-Sep | [43](../screenshots/43-cost-by-service.png) |
| Found the source | Windows event logs (`Event`, `SecurityEvent`) from a *different* lab sharing the workspace | [44](../screenshots/44-usage-by-table-45d.png) |
| Added guardrails | $10 / month budget with alerts, 0.1 GB/day workspace cap | [45](../screenshots/45-budget-credit-guard.png), [46](../screenshots/46-daily-cap.png) |
| A forecast alert fired | "$32.03 vs $10 budget" while actual spend was under $0.01 | [57](../screenshots/57-cost-analysis-october-actual.png) |
| Rechecked next day | Still under $0.01, credits unchanged at $20.52 | [70](../screenshots/70-cost-recheck-accumulated-oct9.png), [71](../screenshots/71-billing-overview-credits-oct9.png) |

The full response to the forecast alert is in [`cost-alert-runbook.md`](cost-alert-runbook.md).

---

## Lessons for students

**1. Know what bills you, per service, before you turn anything on.**
Security tools are usually billed by *data volume*. Microsoft Sentinel charges per GB ingested, so a noisy log source
(Windows security events, verbose firewalls) can cost far more than the compute you were worried about. Ask "how many
GB per day will this add?" before connecting a data source. My AI-audit telemetry was about 0 GB because one chat
event is one small row; the Windows logs were the expense.

**2. Look at the `Usage` table, not your gut.**
In Log Analytics the `Usage` table shows billable ingestion by table. It answers "what is costing me?" in one query
and does not wait on billing data. The query is in the [runbook](cost-alert-runbook.md).

**3. Set a budget on day one, at subscription scope.**
Create a budget (mine is `credit-guard`, $10 / month) with email alerts at 50% and 80% **actual** spend plus a
**forecast** alert. Set it on the *subscription*, not the billing account, so it covers the thing you actually spend from.
A budget is a notification, not a hard stop: nothing is switched off when you pass it.

**4. Learn the difference between actual and forecast.**
An *actual* alert means money has been spent. A *forecast* alert is a projection, and early in the month, or after a
short burst of activity, it can be wildly wrong. Mine predicted $32 when the real bill was under a cent. Treat forecasts as
a prompt to check, never as a result. The reliable signal is **credits remaining** on the Billing overview page, so look
at that on a calendar reminder (I used one to recheck the day after the alert).

**5. Check first, act second, and prefer the least destructive fix.**
Deleting the workspace would have destroyed every detection in this repo to fix a problem that did not exist. Order of
operations: actual spend, then billable ingestion by table, then decide. See the decision table in the runbook.

**6. Understand what your safety controls cost you.**
A daily ingestion cap protects the credit but stops *all* ingestion for the rest of the day once reached, including the
tables you care about. That trade-off is acceptable in a lab and a detection gap in production, which is why the
heartbeat rule H1 exists to notice silence.

**7. Pick pay-per-use options and keep everything in one resource group.**
When I built the Logic App playbook, the form nudged me toward a Standard plan with a fixed monthly hosting cost; I chose
**Consumption** (pay per run) instead ([47](../screenshots/47-playbook-hosting-plan.png)). Keeping the whole lab in one
resource group (`jahnylabs-siem`) meant Cost analysis listed only a few resources, so nothing could hide.

**8. Share a workspace deliberately, or not at all.**
My overspend came from a second lab writing into the same workspace. If two projects share one, one can silently spend the
other's credit. Use a dedicated workspace per project, or at least check ingestion by table whenever a new source connects.

**9. Tear down on purpose.**
When a lab is finished, stop the data connectors first (that is what stops the per-GB charge), then decide whether to
delete resources. Deleting is permanent; stopping ingestion usually is not.

---

## Student checklist

Before you start a lab:

- [ ] Note your starting credit and where to read "credits remaining" (Billing overview).
- [ ] Create a subscription-scope budget with actual (50%, 80%) and forecast alerts, sent to an email you read.
- [ ] Put the lab in its own resource group so Cost analysis stays readable.
- [ ] Choose consumption / pay-per-use tiers where a choice exists; read the plan screen before clicking Create.
- [ ] Before connecting a data source, estimate its GB per day.

While it runs (weekly, on a calendar reminder):

- [ ] Read credits remaining. Write the number down so you can see the trend.
- [ ] Run the billable-ingestion-by-table query if anything looks off.
- [ ] Review Cost analysis grouped by resource.

When an alert arrives:

- [ ] Actual or forecast? Verify actual spend before changing anything.
- [ ] Use the [cost-alert runbook](cost-alert-runbook.md); record the evidence and a recheck time.

When you finish:

- [ ] Disable data connectors, then decide what to delete.

---

*Pricing and free-credit terms change. Treat the dollar figures here as my own lab's numbers, and check current Azure
pricing and your own offer's terms before relying on them.*

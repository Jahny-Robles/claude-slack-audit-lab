# From detection to response: mapping this lab to NIST CSF 2.0

This is the "so what" document for the lab. It walks one incident, a user getting around the AI-DLP control, through
**DETECT → RESPOND → RECOVER → IMPROVE** and ties every step to a real artifact in this repo, with an honest status:

- **Built**: it exists and I watched it work (screenshot linked).
- **Partial**: it exists but I have not proven every part, or it is manual.
- **Gap**: not built. Listed on purpose so nobody reads this as "fully covered".

Scope reminder: this is a self-built `@Claude`-style agent in a free Slack workspace plus a student Azure subscription.
Everything here is fictional data. It reproduces the *audit and detection problem* an enterprise AI agent creates,
not Claude Tag's internals.

---

## The scenario

An employee pastes a member ID and a diagnosis into the AI agent. The DLP control blocks it. Two minutes later the
same employee retypes the member ID with spaces (`H S 7 7 3 0 4 1 2`) and the agent answers. The *control worked*, and
then a person deliberately got past it. The question for a SOC is: who finds out, how fast, and what happens next?

I ran this for real, twice: once with the bot failing to ship logs (see the Problems table in the README), and once end to
end after fixing that and adding the playbook.

---

## DETECT (DE)

| CSF 2.0 | What the lab does | Evidence | Status |
|---|---|---|---|
| DE.CM-09 Computing assets and data monitored | The bot writes one audit event per query (user, channel, policy action, identifier types, token counts, redacted text) and ships it to `ClaudeAudit_CL` via the Logs Ingestion API. | [05](../screenshots/05-bot-shipped-to-sentinel.png), [06](../screenshots/06-sentinel-table-loaded.png) | Built |
| DE.AE-02 Events analyzed for adverse activity | Six scheduled analytics rules D1-D6: PHI submitted, injection campaign, after-hours use, volume anomaly, bulk files, **block-then-evasion**. | [21](../screenshots/21-six-active-rules.png), [23](../screenshots/23-offline-detection-validation.png) | Built |
| DE.AE-02 (intent, not just content) | D6 pairs a Blocked event with a Successful event from the same user within 10 minutes and requires shared vocabulary. It fires on the *behavior* of evasion. | [12](../screenshots/12-D6-block-then-evasion.png), [20](../screenshots/20-D6-incident-evidence-logs.png) | Built |
| DE.CM-09 Monitoring the monitor | H1 ingestion heartbeat: alert if `ClaudeAudit_CL` receives nothing for 2 h during weekday business hours. Added because the first live test failed silently. | [30](../screenshots/30-heartbeat-query-fires.png), [31](../screenshots/31-heartbeat-rule-review.png), [39](../screenshots/39-heartbeat-incidents.png) | Built |
| DE.AE-06 Adverse-event info reaches the right people | Analytics rules open Sentinel incidents with the account entity attached. | [17](../screenshots/17-D6-incident-queue.png), [18](../screenshots/18-D6-incident-overview.png), [19](../screenshots/19-D6-investigation-graph.png) | Built |
| DE.AE-03 Information correlated | Workbook gives a per-user, per-reason view across all events. | [32](../screenshots/32-audit-workbook.png), [33](../screenshots/33-audit-workbook-lower.png) | Partial (visual only; no automated cross-rule correlation) |

**What the detections cannot see:** attachment contents, anything the user types into a channel the bot is not in, and
evasion that changes the *words* as well as the format (D6 needs 2+ shared 6-letter words).

---

## RESPOND (RS)

| CSF 2.0 | What the lab does | Evidence | Status |
|---|---|---|---|
| RS.MA-02 Incident reports triaged and validated | Incident opens with the blocked message, the retry, the shared words and the user as evidence, so triage does not need a second query. | [20](../screenshots/20-D6-incident-evidence-logs.png), [37](../screenshots/37-playbook-d6-incident.png) | Built |
| RS.AN-03 Analysis of what happened | Investigation graph plus the evidence row show the sequence block → retry in seconds. | [38](../screenshots/38-playbook-d6-incident-graph.png) | Built |
| RS.CO-02 Stakeholders notified | **Automation rule + Logic App playbook.** When an incident from the D6 rule is created, Sentinel runs `pb-d6-slack-warning`, which posts a 🚨 message (title, severity, link) to a Slack audit channel. Observed in Slack four times in one test. | Build: [47](../screenshots/47-playbook-hosting-plan.png)-[54](../screenshots/54-playbook-automation-rule.png). Live: [34](../screenshots/34-playbook-live-blocked.png), [35](../screenshots/35-playbook-live-retry-answered.png), [36](../screenshots/36-playbook-slack-warnings.png) | Built |
| RS.MA-01 Plan executed once an incident is declared | Third playbook action writes a comment back onto the incident so the record shows a notification was sent. | [51](../screenshots/51-playbook-designer-three-actions.png) (designed), [68](../screenshots/68-retest-playbook-run-history.png) (run Succeeded, 1.4 s), [69](../screenshots/69-retest-playbook-comment-on-incident.png) (comment authored by the playbook on incident 110, 4 s after creation) | Built |
| RS.MI-01 Incidents contained | `POLICY_MODE` switch (`infra/set-policy-mode.ps1`): `block` stops PHI and injection from reaching the model. This is containment *for the next message*, not a response to the incident that already happened. | [55](../screenshots/55-bot-block-mode-start.png) | Built (manual) |
| RS.MI-01 Contain the *user* | Nothing disables the account, removes them from the channel, or tightens their policy automatically. | | Gap |

### Least privilege on the playbook

The playbook only needs to read incidents and add a comment. Its **system-assigned managed identity** was given
**Microsoft Sentinel Responder** on the lab resource group and nothing broader
([53](../screenshots/53-playbook-iam-role.png)). The Slack connector is authorized through Slack's OAuth consent screen and the
authorization lives in the Logic App connection, not in the repo. The Sentinel connection uses the managed identity, so there is no stored secret
([49](../screenshots/49-playbook-sentinel-connection.png)).

### What the live test taught (and what I changed)

One evasion produced **four incidents and four Slack warnings** ([56](../screenshots/56-d6-duplicate-incidents.png),
[36](../screenshots/36-playbook-slack-warnings.png)). D6 runs every 15 minutes with a 1-hour lookback, so the same
block/retry pair stays inside the window for four consecutive runs. Each run created a new alert. That is a faithful
picture of alert fatigue: a good detection plus an automated notifier turns one event into four pages.

**Change made:** event suppression on D6 ("stop running query after alert is generated", 1 hour,
[59](../screenshots/59-d6-suppression-on.png)). **Result on re-test:** one incident (110), one Slack warning and one playbook run
that started 3 seconds after the incident ([64](../screenshots/64-retest-incidents-after-one-d6.png),
[65](../screenshots/65-retest-single-slack-warning.png), [68](../screenshots/68-retest-playbook-run-history.png)).
The lesson: tune a rule before attaching a notifier to it. The trade-off is that a second, separate evasion by the same person
within the hour will not raise a new alert (the audit log still records it).

---

## RECOVER (RC)

| CSF 2.0 | What the lab does | Status |
|---|---|---|
| RC.RP-01 Recovery portion of the plan executed | Restoring normal operation after the failed live test meant restarting the bot from a normal shell and confirming `Sentinel shipping enabled` plus `Shipped N event(s)`. | Partial (documented in README, manual) |
| RC.RP-05 Restored systems verified | Verification is "an event I just sent appears in `ClaudeAudit_CL`", and the heartbeat rule going quiet. | Partial |
| Backfill of events that never shipped | Events written locally during an outage stay in `audit_events.jsonl`. There is **no replay script** that re-ships them, and the Logs Ingestion API only accepts `TimeGenerated` roughly 2 days back. | Gap |
| Return to the normal policy mode | After testing in `block`, the mode must be set back to `redact` by hand. Forgetting leaves users blocked. | Partial (manual, one script) |

---

## IMPROVE (ID.IM)

| CSF 2.0 | Lesson | Change made | Evidence |
|---|---|---|---|
| ID.IM-02 Improvements from tests and exercises | The live D6 test showed a working detection could notify four times for one evasion. | Applied 1-hour suppression on D6 and re-tested: four incidents and four warnings became one and one. | [56](../screenshots/56-d6-duplicate-incidents.png) (before), [64](../screenshots/64-retest-incidents-after-one-d6.png) (after) |
| ID.IM-02 | A test prompt I wrote ("member HS-7730412 ... diagnosis") was **not blocked**. The scanner's member-ID pattern needs a keyword (`member`/`subscriber`/`policy`/`application`) followed by `id`/`#`/`number`/`no` before the value, and PHI needs an identifier plus a clinical term. | Used the correct phrasing (`member ID HS-7730412 was diagnosed with diabetes ...`). The regex DLP limit is now an explicit Known limit. | [34](../screenshots/34-playbook-live-blocked.png) (the corrected phrasing, blocked) |
| ID.IM-03 Improvements from operational processes | The first live attempt shipped nothing and nobody noticed. | H1 heartbeat rule, plus a startup check for `Sentinel shipping enabled`. | [16](../screenshots/16-shipping-failure-az-not-on-path.png), [39](../screenshots/39-heartbeat-incidents.png) |
| ID.IM-03 | **Cost is a security-operations risk.** I burned about $77 of a $100 student credit, almost all of it Sentinel per-GB ingestion of Windows event logs from a *different* lab sharing the workspace (Event 6.97 GB and SecurityEvent 4.35 GB in 45 days; this lab's `ClaudeAudit_CL` was ~0 GB). A SIEM you cannot afford to leave on is a SIEM that is off. | Budget alert `credit-guard` ($10 / month, alerts at 50%, 80% and forecast 100%) and a 0.1 GB/day workspace cap. | [42](../screenshots/42-azure-credits-remaining.png), [43](../screenshots/43-cost-by-service.png), [44](../screenshots/44-usage-by-table-45d.png), [45](../screenshots/45-budget-credit-guard.png), [46](../screenshots/46-daily-cap.png) |
| ID.IM-03 | A **forecast** budget alert predicted $32.03 against a $10 budget while actual spend was under $0.01 and ingestion was about 0 GB. | Wrote an evidence-first response (actual spend, then ingestion by table, then decide) so a noisy alert is neither ignored nor answered by deleting the SIEM. | [57](../screenshots/57-cost-analysis-october-actual.png), [58](../screenshots/58-usage-billable-ingestion-10d.png), [runbook](cost-alert-runbook.md) |
| ID.IM-03 | A cost trap during the playbook build: the Logic App creation form defaulted me toward a **Standard "Workflow Service Plan"** (a fixed monthly hosting cost) instead of pay-per-run **Consumption**. | Chose Consumption; the plan screen is kept as a "near miss" screenshot. | [47](../screenshots/47-playbook-hosting-plan.png) |
| ID.IM-04 Plans improved | The incident response flow is now written down, mapped, and has a notification step instead of "someone looks at the portal". | This document. | |

> **Daily cap trade-off:** a 0.1 GB/day cap protects the credit, but once the cap is hit the workspace stops ingesting for
> the rest of the day, including `ClaudeAudit_CL`. In a real SOC that is itself a detection gap. That is acceptable in a lab
> and not in production. H1 would fire in that situation.

---

## Gaps, ranked

1. **Canary event for H1.** The heartbeat cannot tell a quiet team from a broken pipeline: it fired at 5:26 PM on 8 Oct just because nobody used the bot for 2 hours.
2. **Automatic containment of the user** (tighten policy for that account, or remove from channel) is not built; response is notify-and-human.
3. **Replay of locally buffered events** after a shipping outage.
4. **Real DLP** (Microsoft Purview or equivalent) so evasion by respacing is caught at the control, not only after the fact.
5. **Dedicated workspace** for this lab so its cost and its detections are not mixed with the other SOC lab's data
   (the 12-rule list in [40](../screenshots/40-twelve-active-rules.png) shows H1 and D1-D6 alongside five rules from the other lab).

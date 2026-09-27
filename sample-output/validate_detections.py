"""
validate_detections.py - offline Python re-implementation of D1-D6 over simulated_events.jsonl.

Lets you prove each planted attack fires (and baseline users don't) BEFORE touching Azure.
The KQL in /detections is the source of truth; this mirrors its logic for a local sanity check.

    python sample-output/validate_detections.py
"""

import json
import re
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

ET = timezone(timedelta(hours=-4))
events = [json.loads(l) for l in (Path(__file__).parent / "simulated_events.jsonl").read_text().splitlines()]
for e in events:
    e["_t"] = datetime.fromisoformat(e["TimeGenerated"])


def floor(t, minutes):
    return t - timedelta(minutes=t.minute % minutes, seconds=t.second, microseconds=t.microsecond)


results = {}

# D1 PHI
d1 = defaultdict(int)
for e in events:
    if e["PhiLikely"]:
        d1[e["UserName"]] += 1
results["D1 PHI submitted"] = {u: f"{n} events ({'High' if n >= 3 else 'Medium'})" for u, n in d1.items()}

# D2 injection, 15-min windows
d2 = defaultdict(lambda: [0, set()])
for e in events:
    if e["InjectionSuspected"]:
        k = (e["UserName"], floor(e["_t"], 15))
        d2[k][0] += 1
        d2[k][1].update(e["InjectionPatterns"])
results["D2 Prompt injection"] = {
    u: f"{n} attempts, {len(p)} techniques ({'High' if n >= 3 or len(p) >= 2 else 'Low'})"
    for (u, _), (n, p) in d2.items()}

# D3 after hours (7am-8pm ET weekdays)
d3 = defaultdict(int)
for e in events:
    lt = e["_t"].astimezone(ET)
    if lt.hour < 7 or lt.hour >= 20 or lt.weekday() >= 5:
        d3[e["UserName"]] += 1
results["D3 After hours"] = {u: f"{n} queries" for u, n in d3.items()}

# D4 volume, 30-min windows
d4 = defaultdict(lambda: [0, 0])
for e in events:
    if e["Outcome"] == "Success":
        k = (e["UserName"], floor(e["_t"], 30))
        d4[k][0] += 1
        d4[k][1] += e["InputTokens"] + e["OutputTokens"]
results["D4 Volume anomaly"] = {u: f"{q} queries / {t:,} tokens in 30m"
                                for (u, _), (q, t) in d4.items() if q >= 20 or t >= 150000}

# D5 files, 1h windows
d5 = defaultdict(lambda: [0, 0])
for e in events:
    if e["AttachmentCount"]:
        k = (e["UserName"], floor(e["_t"], 60))
        d5[k][0] += e["AttachmentCount"]
        d5[k][1] += sum(1 for t in e["AttachmentTypes"] if t in {"csv", "xlsx", "xls", "tsv", "json", "sql"})
results["D5 Bulk files"] = {u: f"{f} files, {d} data files" for (u, _), (f, d) in d5.items() if f >= 8}

# D6 block then evade
words = lambda s: set(re.findall(r"[a-z]{6,}", s.lower()))
d6 = {}
blocked = [e for e in events if e["PolicyAction"] == "Blocked"]
for b in blocked:
    for s in events:
        if (s["Outcome"] == "Success" and s["UserName"] == b["UserName"]
                and b["_t"] <= s["_t"] <= b["_t"] + timedelta(minutes=10)
                and len(words(b["QueryText"]) & words(s["QueryText"])) >= 2):
            d6[b["UserName"]] = f"retry {int((s['_t'] - b['_t']).total_seconds())}s later: {s['QueryText'][:60]}"
results["D6 Block->evade"] = d6

print(f"{len(events)} events, {len({e['UserName'] for e in events})} users\n")
for rule, hits in results.items():
    print(rule)
    for u, detail in (hits or {"(no hits)": ""}).items():
        print(f"   {u:<20} {detail}")

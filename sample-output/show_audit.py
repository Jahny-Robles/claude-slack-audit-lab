"""
show_audit.py - prints the local audit trail (audit_events.jsonl) as a readable table.

This is the same data that ships to ClaudeAudit_CL in Sentinel, so it's the fastest way
to confirm the DLP scanner and policy engine behaved before you go look in the SIEM.

    python sample-output/show_audit.py
    python sample-output/show_audit.py --full     # show full query text, not truncated
"""

import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--full", action="store_true", help="don't truncate QueryText")
parser.add_argument("--path", default="audit_events.jsonl")
args = parser.parse_args()

path = Path(args.path)
if not path.exists():
    raise SystemExit(f"{path} not found - run the bot and @mention it first.")

rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
if not rows:
    raise SystemExit(f"{path} is empty.")

print(f"{len(rows)} audit event(s) in {path}\n")

for i, r in enumerate(rows, 1):
    flags = []
    if r["PhiLikely"]:
        flags.append("PHI")
    if r["PiiDetected"]:
        flags.append("PII:" + ",".join(r["PiiTypes"]))
    if r["InjectionSuspected"]:
        flags.append("INJECTION:" + ",".join(r["InjectionPatterns"]))
    banner = "  [" + " | ".join(flags) + "]" if flags else ""

    text = r["QueryText"] if args.full else r["QueryText"][:78]
    print(f"[{i}] {r['TimeGenerated'][11:19]}  {r['UserName']} in #{r['ChannelName']}{banner}")
    print(f"     action={r['PolicyAction']}  outcome={r['Outcome']}  "
          f"tokens={r['InputTokens']}in/{r['OutputTokens']}out  {r['LatencyMs']}ms")
    print(f"     {text}")
    print()

# quick rollup - mirrors what the Sentinel rules key off
print("-" * 70)
print(f"  PHI events        : {sum(r['PhiLikely'] for r in rows)}          -> feeds D1")
print(f"  Injection attempts: {sum(r['InjectionSuspected'] for r in rows)}          -> feeds D2")
print(f"  Redacted          : {sum(r['PolicyAction'] == 'Redacted' for r in rows)}")
print(f"  Blocked           : {sum(r['PolicyAction'] == 'Blocked' for r in rows)}          -> feeds D6")
print(f"  Total tokens      : {sum(r['InputTokens'] + r['OutputTokens'] for r in rows):,}  -> feeds D4")

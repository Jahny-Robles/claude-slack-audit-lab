"""
audit_logger.py - ships AI-agent audit events to Microsoft Sentinel.

Uses the Azure Monitor **Logs Ingestion API** (DCR-based, OAuth via a service principal).
NOT the old HTTP Data Collector API - that one lost support on 14 Sep 2026 and new
custom tables should not be built on it.

Every event is ALSO appended to a local JSONL file, so:
  - you have a copy even if Azure is down or not set up yet
  - you can test the whole pipeline offline first
"""

import json
import logging
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path

log = logging.getLogger("audit")

STREAM_NAME = "Custom-ClaudeAudit_CL"  # must match the stream the setup script declares in the DCR

# Columns in the ClaudeAudit_CL table. Anything not in this list is dropped by Azure,
# so keep this list and infra/table_schema.json in sync (the setup script builds the table + DCR from it).
COLUMNS = [
    "TimeGenerated", "EventId", "EventType", "UserId", "UserName", "ChannelId", "ChannelName",
    "QueryText", "QueryLength", "AttachmentCount", "AttachmentTypes",
    "PiiDetected", "PiiTypes", "PhiLikely", "InjectionSuspected", "InjectionPatterns",
    "PolicyAction", "Model", "InputTokens", "OutputTokens", "LatencyMs", "Outcome",
]


def new_event(**fields) -> dict:
    """Build an event with defaults so every row has the same shape."""
    event = {
        "TimeGenerated": datetime.now(timezone.utc).isoformat(),
        "EventId": str(uuid.uuid4()),
        "EventType": "AgentInvocation",
        "UserId": "",
        "UserName": "",
        "ChannelId": "",
        "ChannelName": "",
        "QueryText": "",
        "QueryLength": 0,
        "AttachmentCount": 0,
        "AttachmentTypes": [],
        "PiiDetected": False,
        "PiiTypes": [],
        "PhiLikely": False,
        "InjectionSuspected": False,
        "InjectionPatterns": [],
        "PolicyAction": "Allowed",  # Allowed | Redacted | Blocked
        "Model": "",
        "InputTokens": 0,
        "OutputTokens": 0,
        "LatencyMs": 0,
        "Outcome": "Success",  # Success | Error | Blocked
    }
    event.update(fields)
    unknown = set(event) - set(COLUMNS)
    if unknown:
        raise ValueError(f"Unknown audit columns: {unknown}")
    return event


class AuditLogger:
    def __init__(self, local_path: str | None = None):
        self.local_path = Path(local_path or os.getenv("AUDIT_LOCAL_PATH", "audit_events.jsonl"))
        self.client = None
        self.rule_id = os.getenv("DCR_IMMUTABLE_ID")
        endpoint = os.getenv("LOGS_INGESTION_ENDPOINT")

        if endpoint and self.rule_id:
            try:
                from azure.identity import AzureCliCredential, ClientSecretCredential
                from azure.monitor.ingestion import LogsIngestionClient

                tenant = os.getenv("AZURE_TENANT_ID") or None
                if os.getenv("AZURE_CLIENT_SECRET"):
                    # preferred: dedicated service principal, role scoped to the DCR only
                    credential = ClientSecretCredential(
                        tenant_id=os.environ["AZURE_TENANT_ID"],
                        client_id=os.environ["AZURE_CLIENT_ID"],
                        client_secret=os.environ["AZURE_CLIENT_SECRET"],
                    )
                    how = "service principal"
                else:
                    # fallback for tenants that forbid app registration: reuse the
                    # signed-in `az login` session (role granted to that user on the DCR)
                    credential = AzureCliCredential(tenant_id=tenant)
                    how = "Azure CLI session"
                self.client = LogsIngestionClient(endpoint=endpoint, credential=credential)
                log.info("Sentinel shipping enabled (%s) -> %s", how, endpoint)
            except Exception as exc:  # keep the bot alive even if Azure config is wrong
                log.error("Sentinel shipping disabled, falling back to local file only: %s", exc)
        else:
            log.warning("LOGS_INGESTION_ENDPOINT / DCR_IMMUTABLE_ID not set - local file only")

    def send(self, events: list[dict]) -> None:
        with self.local_path.open("a", encoding="utf-8") as fh:
            for e in events:
                fh.write(json.dumps(e) + "\n")

        if self.client:
            try:
                self.client.upload(rule_id=self.rule_id, stream_name=STREAM_NAME, logs=events)
                log.info("Shipped %d event(s) to Sentinel", len(events))
            except Exception as exc:
                log.error("Upload to Sentinel failed (events kept locally): %s", exc)

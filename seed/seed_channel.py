"""
seed_channel.py - fills your lab Slack channel with realistic (fictional) training chatter,
so @Claude has something to summarize and the DLP scanner has something to catch.

Posts as fake personas using chat:write.customize (the bot must be in the channel first:
in Slack, open the channel -> /invite @Claude).

Usage:
    python seed/seed_channel.py                # uses the channel named in mock_conversations.json
    python seed/seed_channel.py --channel C0123ABCD
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

from dotenv import load_dotenv
from slack_sdk import WebClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))
from pii_scanner import scan  # noqa: E402

load_dotenv()


def find_channel_id(client: WebClient, name: str) -> str:
    cursor = None
    while True:
        resp = client.conversations_list(types="public_channel", limit=200, cursor=cursor)
        for ch in resp["channels"]:
            if ch["name"] == name:
                return ch["id"]
        cursor = resp.get("response_metadata", {}).get("next_cursor")
        if not cursor:
            raise SystemExit(f"Channel #{name} not found. Create it and /invite @Claude first.")


def main():
    data = json.loads((Path(__file__).parent / "mock_conversations.json").read_text(encoding="utf-8"))
    parser = argparse.ArgumentParser()
    parser.add_argument("--channel", help="Channel ID (default: look up by name from the JSON)")
    parser.add_argument("--delay", type=float, default=1.2, help="Seconds between posts (Slack rate limits)")
    args = parser.parse_args()

    client = WebClient(token=os.environ["SLACK_BOT_TOKEN"])
    channel = args.channel or find_channel_id(client, data["channel"])

    for msg in data["messages"]:
        client.chat_postMessage(
            channel=channel,
            text=msg["text"],
            username=msg["from"],
            icon_emoji=data["personas"].get(msg["from"], ":bust_in_silhouette:"),
        )
        f = scan(msg["text"])
        flag = f"  <-- PII {f.pii_types}{' PHI' if f.phi_likely else ''}" if f.pii_detected else ""
        print(f"posted: {msg['from']}: {msg['text'][:60]}...{flag}")
        time.sleep(args.delay)

    print(f"\nDone. {len(data['messages'])} messages posted.")


if __name__ == "__main__":
    main()

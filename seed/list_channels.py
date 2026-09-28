"""
list_channels.py - shows exactly which channels the bot token can see, and whether
the bot is a member. Run this when seed_channel.py says "channel not found" or when
@Claude replies that it can't read channel history.

    python seed/list_channels.py
"""

import os

from dotenv import load_dotenv
from slack_sdk import WebClient

load_dotenv()
client = WebClient(token=os.environ["SLACK_BOT_TOKEN"])

print(f"{'CHANNEL':<34} {'VISIBILITY':<10} {'BOT IS MEMBER':<14}")
print("-" * 60)

seen = False
for kind, label in (("public_channel", "public"), ("private_channel", "private")):
    cursor = None
    while True:
        try:
            resp = client.conversations_list(types=kind, limit=200, cursor=cursor)
        except Exception as exc:
            print(f"  (cannot list {label} channels: {exc})")
            break
        for ch in resp["channels"]:
            seen = True
            print(f"#{ch['name']:<33} {label:<10} {'yes' if ch.get('is_member') else 'NO':<14}")
        cursor = resp.get("response_metadata", {}).get("next_cursor")
        if not cursor:
            break

if not seen:
    print("  (no channels visible to this token at all)")

print("\nseed_channel.py only searches PUBLIC channels.")
print("The bot's channels:history scope only covers PUBLIC channels.")
print("A private channel would need groups:read + groups:history added and the app reinstalled.")

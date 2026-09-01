#!/bin/bash
# slop-relay-join.sh — point the rig's gesture forwarder at a slop.computer room.
#
#   ./slop-relay-join.sh 'https://live.slop.computer/<slug>?invite=<password>'
#
# Relay agent tokens are room-scoped (a token minted for room A is rejected in
# room B), so switching rooms means minting a fresh token. This does the whole
# dance over plain HTTP — redeem the room password, create a session, mint a
# 7-day token — then rewrites .slop-relay.env (keeping the anchor) and
# restarts slop-server so it takes effect. Run it once per show room.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
URL="${1:-}"
[ -n "$URL" ] || { echo "usage: $0 'https://live.slop.computer/<slug>?invite=...'"; exit 1; }

BASE="https://live.slop.computer"
SLUG=$(echo "$URL" | sed -E 's|https?://[^/]+/([^/?]+).*|\1|')
INVITE=$(echo "$URL" | sed -nE 's|.*[?&]invite=([^&]+).*|\1|p')
[ -n "$SLUG" ] && [ -n "$INVITE" ] || { echo "could not parse slug/invite from URL"; exit 1; }

JAR=$(mktemp)
trap 'rm -f "$JAR"' EXIT

AUTH=$(curl -sf -c "$JAR" -X POST "$BASE/v1/rooms/$SLUG/auth" \
  -H 'Content-Type: application/json' -d "{\"password\":\"$INVITE\"}")
echo "room auth: $AUTH"
curl -sf -b "$JAR" -c "$JAR" -X POST "$BASE/auth/anon" > /dev/null
TOKEN=$(curl -sf -b "$JAR" "$BASE/v1/agent-token?slug=$SLUG" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
[ -n "$TOKEN" ] || { echo "token mint failed"; exit 1; }

# Keep the anchor (whose camera window effects attach to) across room switches.
ANCHOR=$(grep -m1 '^SLOP_RELAY_ANCHOR=' "$DIR/.slop-relay.env" 2>/dev/null | cut -d= -f2 || true)
{
  echo "SLOP_RELAY_URL=$BASE"
  echo "SLOP_RELAY_TOKEN=$TOKEN"
  echo "SLOP_RELAY_ROOM=$SLUG"
  [ -n "$ANCHOR" ] && echo "SLOP_RELAY_ANCHOR=$ANCHOR"
} > "$DIR/.slop-relay.env"
chmod 600 "$DIR/.slop-relay.env"

# Restart slop-server so it reloads the env (harmless: the foreground/background
# pages auto-reconnect their SSE streams in ~1s).
pkill -f "slop-server.py" 2>/dev/null || true
sleep 1
nohup python3 -u "$DIR/slop-server.py" 9911 > /tmp/slop-server.log 2>&1 &
sleep 2
tail -1 /tmp/slop-server.log
echo "gesture forwarder now aimed at room: $SLUG (token valid 7 days)"

#!/usr/bin/env python3
"""Places buildings on a RUNNING game through the real WebSocket API.

This is the phone's own wire message ({"type": "building_placed", ...}), so it
exercises the identical server path as a phone drop - the socket's
building_placed_remote -> main_screen._on_building_placed_remote -> the
HexBuildingManager - without needing to drive touch gestures in a browser.

Handy for checking where buildings land on real terrain:

  # barracks on a few hexes spread over the map
  python3 Tests/place_building.py --cells 3,7 10,20 25,12

  # a wall (costs 100 resources) and a mine (frontier hexes only)
  python3 Tests/place_building.py --building 2 --cells 20,10
  python3 Tests/place_building.py --building 1 --cells 3,0
"""

import argparse
import json
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wss_smoke as ws  # noqa: E402  (same directory helper: framing + handshake)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="ws://127.0.0.1:9080")
    ap.add_argument("--building", type=int, default=0,
                    help="0 = barrack (free), 1 = mine (frontier only), 2 = wall (100 res)")
    ap.add_argument("--team", type=int, default=-1,
                    help="team byte to send; the server overrides it with the "
                         "team it assigned this connection")
    ap.add_argument("--cells", nargs="+", required=True,
                    help="hex cells as col,row (e.g. 3,7 10,20)")
    args = ap.parse_args()

    print("connecting to %s ..." % args.url)
    sock = ws.connect(args.url, False)
    leftover = ws.handshake(sock, args.url)
    sock.settimeout(8)
    ws.send_text(sock, json.dumps({"type": "request_terrain"}))

    # Wait for the greeting/terrain so this connection is a real, team-assigned
    # client before it starts issuing placements.
    team = None
    for _ in range(12):
        try:
            msg, leftover = ws.read_frames(sock, leftover)
        except socket.timeout:
            break
        if msg.get("type") == "terrain":
            break
        if msg.get("type") == "assigned_team":
            team = msg.get("team")
    print("assigned team: %s" % team)

    for pair in args.cells:
        col, row = (int(v) for v in pair.split(","))
        ws.send_text(sock, json.dumps({
            "type": "building_placed", "col": col, "row": row,
            "building": args.building, "team": args.team,
        }))
        print("sent building %d on hex %d,%d" % (args.building, col, row))
        time.sleep(0.5)
    time.sleep(1.0)
    sock.close()
    print("OK - %d placement message(s) sent" % len(args.cells))
    return 0


if __name__ == "__main__":
    sys.exit(main())

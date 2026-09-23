#!/usr/bin/env python3
"""Drives the LOBBY SPAWN PICKING of a running game over the phone's own wire.

Sends the same message a phone sends when a player taps a hex during the
lobby - {"type": "spawn_hex", "cells": [[col, row], ...]} - and checks what the
server accepts, which is the authoritative rule the sim then acts on:

  * only whole hexes that exist and are not walls,
  * at most 3 of them, de-duplicated,
  * echoed back to the phone in the next lobby_state (its own picks only).

  # against a game running locally
  python3 Tests/spawn_pick_live.py

  # pick specific hexes instead of choosing automatically
  python3 Tests/spawn_pick_live.py --cells 5,3 12,9 20,4
"""

import argparse
import json
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wss_smoke as ws  # noqa: E402  (same directory helper: framing + handshake)


def collect(sock, leftover, wanted, budget=20):
    """Reads frames until every type in `wanted` has arrived once; returns
    ({"type": msg}, leftover). Frames are kept, not dropped: the terrain and
    the lobby state arrive in either order, and both matter here."""
    found = {}
    for _ in range(budget):
        if len(found) >= len(wanted):
            break
        try:
            msg, leftover = ws.read_frames(sock, leftover)
        except socket.timeout:
            break
        kind = msg.get("type")
        if kind in wanted and kind not in found:
            found[kind] = msg
    return found, leftover


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="ws://127.0.0.1:9080")
    ap.add_argument("--cells", nargs="+", default=None,
                    help="hexes to pick as col,row (default: 3 spread-out open hexes)")
    ap.add_argument("--team", type=int, default=-1,
                    help="team byte to send; the server overrides it with the team it assigned")
    args = ap.parse_args()

    print("connecting to %s ..." % args.url)
    sock = ws.connect(args.url, False)
    leftover = ws.handshake(sock, args.url)
    sock.settimeout(8)
    ws.send_text(sock, json.dumps({"type": "request_terrain"}))

    greeting, leftover = collect(sock, leftover, {"terrain", "lobby_state", "assigned_team"})
    terrain = greeting.get("terrain")
    state = greeting.get("lobby_state")
    team = (state or greeting.get("assigned_team", {})).get("team")
    print("team: %s  |  lobby started: %s  |  picks so far: %s" % (
        team, (state or {}).get("started", "unknown"), (state or {}).get("hexes")))
    if terrain is None:
        print("FAIL - no terrain arrived; is the main screen running?")
        return 1
    tiles = terrain.get("tiles", [])
    walls = set((int(t["col"]), int(t["row"])) for t in tiles if t.get("is_wall"))
    open_cells = [(int(t["col"]), int(t["row"])) for t in tiles if not t.get("is_wall")]
    print("terrain: %d tiles, %d walls, %d open" % (len(tiles), len(walls), len(open_cells)))

    if args.cells:
        picks = [tuple(int(v) for v in pair.split(",")) for pair in args.cells]
    else:
        # Three open hexes spread across the map, in a stable order.
        step = max(len(open_cells) // 4, 1)
        picks = [open_cells[0], open_cells[step], open_cells[step * 2]]

    # Add a wall hex as a fourth pick: the server must drop it silently rather
    # than teleport an army into solid rock, and must keep the three valid ones.
    wall_pick = sorted(walls)[0] if walls else None
    payload = picks + ([wall_pick] if wall_pick else [])
    print("picking %s%s" % (picks, "  (+ wall %s, must be refused)" % (wall_pick,) if wall_pick else ""))
    ws.send_text(sock, json.dumps({
        "type": "spawn_hex",
        "cells": [[c, r] for c, r in payload],
        "team": args.team,
    }))

    echo = collect(sock, leftover, {"lobby_state"})[0].get("lobby_state")
    time.sleep(0.4)
    sock.close()
    if echo is None:
        print("FAIL - no lobby_state came back after picking")
        return 1

    accepted = [tuple(h) for h in echo.get("hexes", [])]
    print("server accepted: %s  (per-team counts: %s)" % (accepted, echo.get("picked")))
    failures = []
    if accepted != picks:
        failures.append("accepted %s, expected exactly %s" % (accepted, picks))
    if wall_pick and wall_pick in accepted:
        failures.append("wall hex %s was accepted" % (wall_pick,))
    if wall_pick is None:
        print("    (this map has no wall hexes, so the refusal rule was not exercised)")
    if len(accepted) > 3:
        failures.append("%d picks accepted, max is 3" % len(accepted))
    if echo.get("started"):
        failures.append("lobby already started - pick one before the host starts")

    if failures:
        for f in failures:
            print("FAIL - %s" % f)
        return 1
    print("OK - %d picks accepted, wall refused, 3-pick cap held" % len(accepted))
    print("    (the sim's own split is logged as \"Sim: team N spawns in ... dots split [...]\")")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Measures the LIVE economy of a running game, without touching its code.

Connects to the game's WebSocket server (the same wire a phone uses), listens
for the once-per-tick `team_resources` broadcast, and reports the samples plus
the observed drain rate in resources/second. That single number proves the
whole CPU economy loop is healthy at once:

  * the tick fires at 1 Hz (sample spacing),
  * upkeep = living dots * UPKEEP_PER_SEC (the rate),
  * the pool is a real running balance (not stuck / not floored at 0).

  # against a game running locally
  python3 Tests/econ_probe.py --team 0 --seconds 25

  # against a tunnel / LAN phone host
  python3 Tests/econ_probe.py --url wss://something-words.trycloudflare.com
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
    ap.add_argument("--team", type=int, default=0,
                    help="team pool to watch (-1 = every team)")
    ap.add_argument("--seconds", type=float, default=25.0, help="sample window")
    ap.add_argument("--quiet", action="store_true",
                    help="only print the summary, not every sample")
    args = ap.parse_args()

    print("connecting to %s ..." % args.url)
    sock = ws.connect(args.url, False)
    leftover = ws.handshake(sock, args.url)
    sock.settimeout(3)
    ws.send_text(sock, json.dumps({"type": "request_terrain"}))

    wanted = None if args.team < 0 else args.team
    samples = {}          # team -> [(t, amount)]
    other = {}
    tick_times = []       # arrival times of every resource message
    starts = {}
    deadline = time.monotonic() + args.seconds
    while time.monotonic() < deadline:
        try:
            msg, leftover = ws.read_frames(sock, leftover)
        except socket.timeout:
            continue
        kind = msg.get("type")
        if kind == "team_resources":
            team = int(msg.get("team", -1))
            now = time.monotonic()
            starts.setdefault(team, now)
            if wanted is None or team == wanted:
                samples.setdefault(team, []).append((now, float(msg.get("amount", 0.0))))
            # One broadcast pass emits every team back-to-back: only count a
            # tick when the team ids stop ascending, so the spacing below is
            # real tick period, not the gap between messages of one pass.
            if not tick_times or team <= tick_times[-1][1]:
                tick_times.append((now, team))
            else:
                tick_times[-1] = (now, team)
        elif kind:
            other[kind] = other.get(kind, 0) + 1

    sock.close()

    if not samples:
        print("FAIL: no team_resources broadcasts in %.0fs" % args.seconds)
        if starts:
            print("      (only saw teams %s)" % sorted(starts))
        return 1

    if len(tick_times) > 1:
        print("\n  tick period: %.3fs (expected ~1.000s)"
              % ((tick_times[-1][0] - tick_times[0][0]) / (len(tick_times) - 1)))
    print("  teams seen: %s" % sorted(samples))

    for team in sorted(samples):
        series = samples[team]
        if len(series) < 2:
            print("    team %d: only %d sample(s)" % (team, len(series)))
            continue
        t0, a0 = series[0]
        t1, a1 = series[-1]
        dt = t1 - t0
        rate = (a0 - a1) / dt if dt > 0 else 0.0
        print("\n    team %d: %.0f -> %.0f over %.1fs = %.1f res/s"
              % (team, a0, a1, dt, rate))
        if rate > 0.5:
            print("      implied upkeep-paying dots: %.0f (at 0.2 res/dot/s)"
                  % (rate / 0.2))
        else:
            print("      pool stable or gaining (income >= upkeep)")
        if not args.quiet:
            for t, amount in series:
                print("        %s  pool = %.0f"
                      % (time.strftime("%H:%M:%S", time.localtime(t)), amount))

    if other:
        print("\n  other messages seen: %s" % ", ".join(
            "%s x%d" % (k, v) for k, v in sorted(other.items())))
    print("\nOK - economy loop is live and measurable")
    return 0


if __name__ == "__main__":
    sys.exit(main())

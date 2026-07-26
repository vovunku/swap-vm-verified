"""Vercel entrypoint. One function behind every /api/* route (see ../vercel.json).

This is a SHIM, not a second implementation. It imports the same `server.py` the local demo
runs, so the hosted site and `python3 demo/server.py` cannot drift apart — which matters
more here than usual, because the thing on display is a claim about correctness.

What differs on Vercel is one flag. `server.LIVE` is False when $VERCEL is set, so `prove`
and `execute` replay `data/runs.json` instead of shelling out to `kprove` and `forge` in the
kontrol container. They have to: a serverless function has no Docker, no K, no Foundry, and
30 s against proofs that take up to 10 minutes. Every replayed response is stamped
`recorded: true` with its timestamp and command, and the UI prints that — a frozen run shown
as a live one would be the exact fake this project exists to argue against.

To make the hosted site prove for real, point it at a machine that can: set DEMO_LIVE=1 and
run this behind a tunnel to a box with the container. Nothing else changes.
"""
import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
os.environ.setdefault('VERCEL', '1')

from server import Handler as handler  # noqa: E402,F401 -- Vercel looks for `handler`

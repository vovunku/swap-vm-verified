# Front-end test

Drives the real page in a real DOM (jsdom) against the running server — clicks the
catalogue, presses Verify, edits fields, and asserts what the user actually sees.

```bash
python3 demo/server.py &                 # must be running on :8000
cd demo/test && npm install jsdom && node frontend.mjs
```

Requires node (not needed to *run* the demo, only to test it).

## What it pins

The three things that were wrong before it existed:

1. **No verdict is shown before Verify is pressed** — results appeared on load, which is
   exactly the false-assurance failure the rest of this project is about. Switching example
   or editing a field also clears a stale verdict.
2. **The catalogue is a drawer**, opening from the left over a scrim, closing on scrim click
   or Escape — not an inline list competing with the program.
3. **The GOOD/BAD pair behaves**: GOOD loads three editable blocks and proves T0/T1/T2; BAD
   loads as raw bytes with the reason, and after Verify shows T0 *not applying* plus the
   19-byte lint error.

Assertions are on rendered text and DOM state, so a change that silently stops rendering
verdicts, or starts rendering them too early, fails here.

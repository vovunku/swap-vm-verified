#!/usr/bin/env python3
"""Freeze the REAL prove/execute results into data/runs.json for the hosted deploy.

WHY THIS FILE EXISTS. `/api/prove` shells out to `kprove` inside the kontrol container and
`/api/execute` shells out to `forge`. Neither can run on Vercel — no Docker, no K, no
Foundry, and a 60 s function ceiling against proofs that take 5 s to 10 min. So the hosted
site replays runs that really happened instead of pretending to run them.

WHAT MAKES THAT HONEST, AND THE LINE IT MUST NOT CROSS. Every field below comes from an
actual invocation: the exact command, its exit code, its wall-clock, and whether `#Top`
appeared in its output. Nothing is asserted by this script -- if a spec stops proving, the
recording says so and the site shows a failure. The rule the UI must keep is that a replayed
run is LABELLED as replayed, with the command shown, so anyone can re-run it themselves. A
recording presented as a live run would be exactly the fake this project exists to argue
against.

    ./record_runs.py            # record everything
    ./record_runs.py --prove    # proofs only (fast; ~8 kprove runs)

Re-record whenever the semantics change: the definition hash is stored, and a stale
recording is a lie with a timestamp on it.
"""
import json
import pathlib
import subprocess
import sys
import time
import datetime

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import server  # noqa: E402  -- reuse the exact prove/execute implementations

OUT = HERE / 'data' / 'runs.json'


def definition_fingerprint() -> dict:
    """Identify the definition the proofs ran against, so a stale recording is detectable."""
    cmd = ['docker', 'exec', '-u', 'user', server.EXEC_CONTAINER, 'bash', '-c',
           f'cd {server.K_WORKSPACE} && '
           f'find {server.K_DEFINITION} -name "*.txt" -o -name "definition.kore" | '
           f'sort | xargs cat 2>/dev/null | sha256sum | cut -c1-16']
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        return {'sha256_16': (r.stdout or '').strip() or 'unavailable',
                'workspace': server.K_WORKSPACE, 'definition': server.K_DEFINITION}
    except Exception as e:
        return {'sha256_16': 'unavailable', 'error': str(e)}


def record_proofs() -> dict:
    """Run every spec/control pair for real and keep what came back."""
    out = {}
    for label in server.PROOF_PAIRS:
        spec, control = server.PROOF_PAIRS[label]
        print(f'  kprove {label:14s} ({spec} + {control}) ...', flush=True)
        t0 = time.time()
        res = server.prove(label)
        res['recorded'] = True
        res['commands'] = [
            f'kprove --definition {server.K_DEFINITION} proofs/{spec}.k',
            f'kprove --definition {server.K_DEFINITION} proofs/{control}.k',
        ]
        out[label] = res
        verdict = ('ok' if res.get('ok') else
                   'NOT OK' if res.get('available') else res.get('error', '?'))
        print(f'     -> {verdict}  ({time.time() - t0:.0f}s)', flush=True)
    return out


def record_executions() -> dict:
    """Run every shipped program through the real runLoop and keep the registers.

    Both sources: the three curated programs (good / one-byte-wrong / dust) and the eleven
    catalogue examples. A program the user composes in the playground has no recording and
    the site says so -- it does not guess.
    """
    out = {}
    seen = set()
    for ex in server.curated() + server.EXAMPLES:
        label, hexstr = ex.get('label'), ex.get('bytes')
        if not label or not hexstr or label in seen:
            continue
        seen.add(label)
        # The UI varies exactly one input -- the "taker holds the gate token" checkbox --
        # and leaves the rest at the executor's defaults. Record both states of it so the
        # checkbox keeps working on the hosted site. Deliberately NOT the example's own
        # `config`: that one describes the K configuration (balances as a K Map), not the
        # forge executor's inputs, and feeding it here silently means gateBalance = 0.
        for gate in (0, 5):
            cfg = {'gateBalance': gate}
            print(f'  forge  {label:16s} gate={gate} ...', flush=True)
            res = server.execute(hexstr.removeprefix('0x'), cfg)
            res['recorded'] = True
            res['config'] = cfg
            out[f'{label}|{gate}'] = res
            print(f'     -> {res.get("status") or res.get("error", "?")}', flush=True)
    return out


def main() -> int:
    only = sys.argv[1:] or ['--prove', '--execute']
    prev = json.loads(OUT.read_text()) if OUT.exists() else {}

    rec = {
        'recorded_at': datetime.datetime.now(datetime.timezone.utc)
                       .replace(microsecond=0).isoformat(),
        'definition': definition_fingerprint(),
        'proofs': prev.get('proofs', {}),
        'executions': prev.get('executions', {}),
    }

    if '--prove' in only:
        print('== recording proofs ==', flush=True)
        rec['proofs'] = record_proofs()
    if '--execute' in only:
        print('== recording executions ==', flush=True)
        rec['executions'] = record_executions()

    OUT.write_text(json.dumps(rec, indent=1, sort_keys=True) + '\n')

    bad = [k for k, v in rec['proofs'].items() if not v.get('ok')]
    print(f'\nwrote {OUT}  ({OUT.stat().st_size} bytes)')
    print(f'  proofs     {len(rec["proofs"])}  ok={len(rec["proofs"]) - len(bad)}'
          + (f'  NOT OK: {bad}' if bad else ''))
    print(f'  executions {len(rec["executions"])}')
    # A recording where a control PROVED, or a spec did not, is worth shipping only as a
    # visible failure -- so write it, then exit non-zero so a build step can refuse it.
    return 1 if bad else 0


if __name__ == '__main__':
    raise SystemExit(main())

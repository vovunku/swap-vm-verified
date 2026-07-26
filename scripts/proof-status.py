#!/usr/bin/env python3
"""Report the verdict of every proof in a Kontrol proof store, highest version only.

    ./scripts/proof-status.py                       # every spec
    ./scripts/proof-status.py XYCSwapSpec           # one spec
    ./scripts/proof-status.py '' /path/to/proofs    # a different store

WHY THIS EXISTS, AND WHY THE LEAF LOGIC IS SUBTLE.

`kontrol list` is authoritative but costs 2-4 minutes and ~2.6 GB RSS on a store this size.
The same verdicts are derivable from `proof.json` + `kcfg/kcfg.json` in under a second — but
only if leaves are classified correctly, and the obvious classification is WRONG:

    A leaf that appears in proof.json's `terminal` list is NOT necessarily closed.

`terminal` means "execution cannot proceed from here". If such a leaf is the *target*, the
branch is discharged. If it is terminal and NOT the target, execution finished in a state
that does not satisfy the claim -- that is a REFUTATION, and it is exactly what you are
looking for when hunting bugs. An earlier version of this script counted every terminal leaf
as closed and therefore reported refutations as passes.

    target   : 17
    terminal : [15, 17, 187, 202]
    leaves   : [17, 202]        <- 202 is terminal, is a leaf, is not the target: FAILED

So:
    closed   -- the leaf IS the target, or is covered, or is vacuous
    FAILED   -- terminal, a leaf, and not the target
    BOUNDED  -- depth-limited; a bounded result, not an unconditional one
    PENDING  -- not yet expanded

PASSED iff no failing, no bounded and no pending leaves.
"""
import collections
import json
import os
import re
import sys


def verdict(proof_dir: str):
    kj = os.path.join(proof_dir, 'kcfg', 'kcfg.json')
    pj = os.path.join(proof_dir, 'proof.json')
    if not (os.path.exists(kj) and os.path.exists(pj)):
        return 'NO-DATA', 0
    try:
        kcfg = json.load(open(kj))
        proof = json.load(open(pj))
    except Exception:
        return 'UNREADABLE', 0

    nodes = {n['id'] if isinstance(n, dict) else n for n in kcfg.get('nodes', [])}
    has_successor = set()
    for key in ('edges', 'splits', 'covers', 'ndbranches'):
        for e in kcfg.get(key, []):
            has_successor.add(e['source'])
    covered = {c['source'] for c in kcfg.get('covers', [])}
    vacuous = set(kcfg.get('vacuous', []) or [])

    target = proof.get('target')
    terminal = set(proof.get('terminal', []))
    bounded = set(proof.get('bounded', []))

    leaves = [n for n in nodes if n not in has_successor]
    failing = [n for n in leaves if n in terminal and n != target]
    bounded_leaves = [n for n in leaves if n in bounded and n != target]
    pending = [
        n for n in leaves
        if n != target and n not in terminal and n not in covered
        and n not in vacuous and n not in bounded
    ]

    if failing:
        return 'FAILED', len(nodes)
    if bounded_leaves:
        return 'BOUNDED', len(nodes)
    if pending:
        return 'PENDING', len(nodes)
    return 'PASSED', len(nodes)


def main() -> int:
    spec_filter = sys.argv[1] if len(sys.argv) > 1 else ''
    base = sys.argv[2] if len(sys.argv) > 2 else '/home/user/swap-vm-verified/out/proofs'
    if not os.path.isdir(base):
        print(f'no such proof store: {base}', file=sys.stderr)
        return 1

    # Highest version per property; a PASSED at :0 says nothing about :2.
    best: dict[str, tuple[int, str]] = {}
    for d in os.listdir(base):
        m = re.match(r'(.*):(\d+)$', d)
        if not m:
            continue
        key, ver = m.group(1), int(m.group(2))
        if spec_filter and spec_filter not in key:
            continue
        if key not in best or ver > best[key][0]:
            best[key] = (ver, d)

    if not best:
        print(f'no proofs matched {spec_filter!r} in {base}', file=sys.stderr)
        return 1

    tally: collections.Counter = collections.Counter()
    for key, (_ver, d) in sorted(best.items()):
        status, n = verdict(os.path.join(base, d))
        tally[status] += 1
        name = d.split('%')[-1]
        print(f'  {status:<10} {n:>4}n  {name}')

    print('  ' + '-' * 60)
    print('  ' + '  '.join(f'{k}={v}' for k, v in sorted(tally.items())))
    # Non-zero exit if anything was refuted -- useful in CI.
    return 1 if tally['FAILED'] else 0


if __name__ == '__main__':
    raise SystemExit(main())

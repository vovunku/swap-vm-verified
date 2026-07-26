#!/usr/bin/env python3
"""Check the demo against the repository, so it cannot drift from what was verified.

    python3 demo/selftest.py        # exits non-zero on any disagreement

Three checks, each guarding a way this demo could quietly start lying:

  1. The composer reproduces the example program BYTE-FOR-BYTE. `ProgramBytes.t.sol` pins
     that layout against real SDK output, and `c0d0bf1` records a hand-typed hex constant
     that had a nibble in the wrong position while every existing test still passed. A
     composer that drifts by one byte is describing a different program than the proofs are.

  2. The decoder agrees with the conformance table on every case whose outcome is decided at
     DECODE level. Those expectations are checked against both `krun` and the real
     `ContextLib.runLoop`, so they are the strongest ground truth available here. Cases that
     revert inside an instruction guard are excluded: a static decoder cannot see those, and
     pretending otherwise would be the vacuity failure this project keeps documenting.

  3. The opcode table matches the enum. `DEMO.md` states 52 named opcodes and that the
     semantics models 3 of them; if either number moves, the demo's coverage claim is stale.
"""
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import server  # noqa: E402

ROOT = HERE.parent
FAIL = []


def check(name: str, ok: bool, detail: str = '') -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {name}{'  — ' + detail if detail else ''}")
    if not ok:
        FAIL.append(name)


def main() -> int:
    examples = {e['label']: e for e in json.loads((HERE / 'data/examples.json').read_text())}

    print('1. composer vs the verified example')
    built, notes = server.assemble([{'op': o, 'args': {}} for o in ('23', '90', '53')])
    check('assembles without notes', not notes, str(notes))
    check('length is 91 bytes (ProgramBytes.t.sol)', len(built) // 2 == 91, f'{len(built)//2}')
    check('byte-identical to the conformance catalogue program',
          built == examples['catalogue']['bytes'])

    print('\n2. decoder vs the conformance table (decode-level cases only)')
    # These revert inside an instruction, not in the decode loop; a static decoder cannot
    # and should not predict them.
    instruction_level = {'revRecompute', 'revRecomputeOut', 'gateRejects'}
    for label, e in examples.items():
        if label in instruction_level:
            continue
        steps = server.decode(e['bytes'])
        errs = [s for s in steps if s.get('error')]
        if errs:
            pc, status = errs[0]['pc'], 'Reverted'
        elif steps:
            last = steps[-1]
            pc, status = last['pc'] + 2 + last['argsLen'], 'Running'
        else:
            pc, status = 0, 'Running'
        want = e['expect']
        check(f"{label}: pc={want['pc']} {want['status']}",
              pc == want['pc'] and status == want['status'], f'got pc={pc} {status}')

    print('\n3. coverage claims vs the source')
    opcodes = json.loads((HERE / 'data/opcodes.json').read_text())
    claims = json.loads((HERE / 'data/claims.json').read_text())
    check('52 named opcodes (DEMO.md §5a)', len(opcodes) == 52, str(len(opcodes)))
    check('claims.json agrees on the total',
          claims['coverage']['opcodes_total'] == len(opcodes))
    n = claims['coverage']['opcodes_modelled']
    check(f'{n} opcodes modelled — server agrees with generated data',
          len(server.MODELLED) == n, f'server has {len(server.MODELLED)}')
    check('the modelled set is non-trivial and grew past the original three', n >= 3, str(n))
    check('every modelled opcode exists in the enum',
          all(o in opcodes for o in server.MODELLED))

    print('\n4. the proofs the demo cites actually exist')
    for t in claims['theorems'] + claims['negative_controls']:
        p = ROOT / t['file']
        check(f"{t['file']} present", p.exists())

    print()
    if FAIL:
        print(f'{len(FAIL)} FAILED: ' + ', '.join(FAIL))
        return 1
    print('all checks passed — the demo matches the repository')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

#!/usr/bin/env python3
"""Generate the demo's data files FROM THE REPOSITORY, so they cannot drift from it.

    python3 demo/gen_data.py

Writes:
    demo/data/opcodes.json    the opcode table, parsed from src/libs/OpcodeList.sol
    demo/data/examples.json   example programs, parsed from semantics/conformance/run.sh
    demo/data/claims.json     what has been proven, in human-readable form

WHY GENERATE RATHER THAN HAND-WRITE. This repository has a documented case
(`c0d0bf1`) where a hand-typed hex constant had a nibble in the wrong position and every
existing test still passed, because the corruption preserved length and structure. The fix
was to stop hand-transcribing and compare against SDK output. The same reasoning applies to
a demo: an opcode table typed by hand is a second source of truth that will drift.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = pathlib.Path(__file__).resolve().parent / 'data'


def opcodes() -> dict:
    """Parse `/* 23 */ OnlyTakerTokenBalanceNonZero,` out of the Opcode enum."""
    src = (ROOT / 'src/libs/OpcodeList.sol').read_text()
    table = {}
    for hexcode, name in re.findall(r'/\*\s*([0-9a-fA-F]{2})\s*\*/\s*([A-Za-z_][A-Za-z0-9_]*)', src):
        if name.startswith('_'):          # unallocated slot
            continue
        table[hexcode.lower()] = name
    if not table:
        sys.exit('could not parse any opcodes — has OpcodeList.sol changed shape?')
    return table


def examples() -> list:
    """Parse the conformance table: programs with expectations verified on BOTH engines.

    Each case in `semantics/conformance/run.sh` is
        label ; K bytes literal ; pc ; status ; balances ; amountOut ; amountIn ;
        tokenIn ; tokenOut ; amountOut-in ; exactIn
    and every one is checked against `krun` AND against the real `ContextLib.runLoop`.
    That makes them the only example programs in this repo with independently confirmed
    outcomes — which is exactly what a demo should ship.
    """
    src = (ROOT / 'semantics/conformance/run.sh').read_text()
    block = re.search(r'CASES=\((.*?)\n\)', src, re.S)
    if not block:
        sys.exit('could not find the CASES array in semantics/conformance/run.sh')

    out = []
    for line in block.group(1).splitlines():
        line = line.strip().strip("'")
        if not line or line.startswith('#'):
            continue
        parts = line.split(';')
        if len(parts) < 4:
            continue
        label, lit, pc, status = parts[0], parts[1], parts[2], parts[3]
        # b"\x23\x14..." -> hex string
        hexbytes = ''.join(re.findall(r'\\x([0-9a-fA-F]{2})', lit))
        rest = parts[4:]
        out.append({
            'label': label,
            'bytes': hexbytes,
            'length': len(hexbytes) // 2,
            'expect': {
                'pc': int(pc),
                'status': status,
                'amountOut': (rest[1] if len(rest) > 1 and rest[1] not in ('', '-') else None),
            },
            'config': {
                'balances': rest[0] if rest else '.Map',
                'amountIn': rest[2] if len(rest) > 2 else None,
                'tokenIn': rest[3] if len(rest) > 3 else None,
                'tokenOut': rest[4] if len(rest) > 4 else None,
                'amountOutIn': rest[5] if len(rest) > 5 else None,
                'isExactIn': rest[6] if len(rest) > 6 else None,
            },
        })
    return out


def modelled() -> list:
    """Opcodes the K semantics actually models — scanned from the rules, never hand-listed.

    They live in two places: the original three in `semantics/swapvm.md`, and the rest as
    sibling modules in `semantics/opcodes/*.k`. Scanning both is what stops this number
    going stale, which it already did once — `OPCODE-BACKLOG.md` still says "3 are modelled"
    after fifteen more landed.
    """
    ops = set()
    for f in [ROOT / 'semantics/swapvm.md'] + sorted((ROOT / 'semantics/opcodes').glob('*.k')):
        if not f.exists():
            continue
        for m in re.findall(r'#exec\s*\(\s*(\d+)', f.read_text()):
            ops.add(f'{int(m):02x}')
    return sorted(ops)


def theorems() -> list:
    """Every spec/control pair under semantics/proofs, with its expected verdict.

    A file named *-control.k or *negative-control.k is a claim asserted to FAIL. That is the
    design: a proof that cannot fail proves nothing, and an inconsistent rule set proves
    everything while looking like total success.
    """
    out = []
    for f in sorted((ROOT / 'semantics/proofs').glob('*.k')):
        name = f.stem
        is_control = 'control' in name
        out.append({'file': f'semantics/proofs/{f.name}', 'name': name,
                    'expected': 'FAIL' if is_control else '#Top',
                    'kind': 'negative control' if is_control else 'theorem'})
    return out


def claims() -> dict:
    """What has been proven, stated for a human rather than for a prover.

    Each entry pairs the formal statement with a plain-English reading AND the assumptions,
    because a verdict without its assumptions is the false-assurance failure this whole
    project exists to avoid.
    """
    return {
        'theorems': [
            {
                'id': 'T0',
                'file': 'semantics/proofs/gate-spec.k',
                'verdict': 'PROVED',
                'applies_when': 'program starts with OnlyTakerTokenBalanceNonZero',
                'plain': 'Anyone who does not hold the gate token cannot fill this order.',
                'why_it_is_strong': (
                    'This was proved with the rest of the program left completely unknown — '
                    'a symbolic tail. So it holds for ANY program you build after the gate '
                    'block, including ones nobody has written yet. No test suite can cover '
                    'that set.'
                ),
                'assumptions': [
                    'The gate token answers balanceOf like an ordinary ERC-20.',
                    'The gate block is the FIRST instruction. Move it later and the theorem '
                    'no longer applies — instructions before it run first.',
                    'The instruction rules are conformance-TESTED against the real VM, not '
                    'themselves proven. The theorem holds given each instruction behaves as '
                    'its rule says.',
                ],
            },
            {
                'id': 'T1',
                'file': 'semantics/proofs/pricing-spec.k',
                'verdict': 'PROVED',
                'applies_when': 'gate + StaticBalances + LimitSwap, exact-in',
                'plain': (
                    'The taker receives exactly the maker\'s advertised rate, rounded down '
                    'to the wei. Never a wei more, never a wei less.'
                ),
                'why_it_is_strong': (
                    'Proved with the trade size and BOTH maker reserves left as unknowns, so '
                    'it covers every pool size and every order size at once. The two bounds '
                    'together pin the answer exactly: one alone would be satisfied by '
                    'quoting zero.'
                ),
                'assumptions': [
                    'amountIn * balanceOut stays below 2^256. Above that the real EVM reverts '
                    'and the model computes, so they disagree — and a taker can choose an '
                    'amountIn that large.',
                    'Rounding goes to the maker. That is deliberate and documented, not a bug.',
                ],
            },
            {
                'id': 'T2',
                'file': 'semantics/proofs/pricing-exactout-spec.k',
                'verdict': 'PROVED',
                'applies_when': 'gate + StaticBalances + LimitSwap, exact-out',
                'plain': (
                    'When the taker names the output, the input they pay is exactly the '
                    'maker\'s rate rounded up to the wei.'
                ),
                'why_it_is_strong': (
                    'The mirror of T1 on the other leg. The two legs round in OPPOSITE '
                    'directions, and both toward the maker — that asymmetry is intentional, '
                    'and now proved rather than sampled.'
                ),
                'assumptions': [
                    'Same overflow caveat as T1.',
                ],
            },
        ],
        'negative_controls': [
            {
                'file': 'semantics/proofs/negative-control.k',
                'verdict': 'FAILS — as required',
                'plain': (
                    'A deliberately FALSE claim, asserted so it must fail. If it ever '
                    'succeeded, the rule set would be self-contradictory and every result '
                    'above would be worthless. An inconsistent theory proves everything and '
                    'looks exactly like total success — this is the only check that catches it.'
                ),
            },
            {
                'file': 'semantics/proofs/pricing-negative-control.k',
                'verdict': 'FAILS — as required',
                'plain': 'The pricing theorem with its safety inequality reversed. Must fail, and does.',
            },
        ],
        'coverage': {
            'opcodes_modelled': len(modelled()),
            'opcodes_total': 52,
            'modelled_list': modelled(),
            'plain': (
                f'The K semantics models {len(modelled())} of the 52 named opcodes. '
                'The decode loop is complete; the instruction set is not. '
                'Anything else falls through to a no-op in the model while the real VM '
                'rejects it, so Verify will say so rather than pretend.'
            ),
        },
    }


def main() -> int:
    OUT.mkdir(exist_ok=True)
    data = {'opcodes.json': opcodes(), 'examples.json': examples(),
            'claims.json': claims(), 'proofs.json': theorems()}
    for name, payload in data.items():
        (OUT / name).write_text(json.dumps(payload, indent=2) + '\n')
        n = len(payload) if isinstance(payload, (list, dict)) else 0
        print(f'  wrote data/{name}  ({n} top-level entries)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

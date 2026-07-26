#!/usr/bin/env python3
"""SwapVM program composer + verifier — demo backend.

    python3 demo/server.py            # http://localhost:8000
    PORT=9000 python3 demo/server.py

Standard library only, no dependencies, no build step.

WHAT "VERIFY" MEANS HERE. Three tiers, and the UI never shows a bare green check — every
result carries the tier that produced it and the assumptions it rests on. That is not
decoration: this repository documents proofs that PASSED while proving nothing (a constructor
value read as zero), and a proof that FAILED for a reason unrelated to the bug it was
testing. A verifier that hides its assumptions ships false assurance, which is worse than
shipping none.

  PROVED    Pattern-matches the composed program against theorems already machine-checked by
            `kprove`. Instant, because the proving happened offline. T0 is the interesting
            one: it was proved over a SYMBOLIC TAIL, so it holds for programs the user
            invents here, not just for ours.
  LINT      Re-runs the argument bounds that each instruction's `build()` helper enforces.
            The finding this demo exists to show: those `require`s live in an off-chain
            builder, and `parse()` — the only thing that runs on chain — checks nothing.
  DECODE    Walks the bytes exactly as `VM.sol:118-150` does, reporting how the real run loop
            would step through them, including the bound check that reverts.
"""
import json
import os
import subprocess
import pathlib
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = pathlib.Path(__file__).resolve().parent
DATA = HERE / 'data'
STATIC = HERE / 'static'

OPCODES = json.loads((DATA / 'opcodes.json').read_text())
EXAMPLES = json.loads((DATA / 'examples.json').read_text())
CLAIMS = json.loads((DATA / 'claims.json').read_text())

# Instructions the K semantics actually models, derived by gen_data.py from the rules
# themselves (swapvm.md plus semantics/opcodes/*.k) rather than hand-listed. Everything else
# falls through to a no-op in the model while production reverts UnknownOpcode -- so Verify
# must say so, not stay silent.
MODELLED = set(CLAIMS['coverage']['modelled_list'])
PROOFS = json.loads((DATA / 'proofs.json').read_text())

# Block palette. `args` describes the fields a user edits; `size` is the byte width each
# field occupies, matching the *ArgsBuilder helpers in src/instructions/.
BLOCKS = [
    {
        'op': '23', 'name': 'OnlyTakerTokenBalanceNonZero', 'label': 'Gate: taker must hold a token',
        'blurb': 'Rejects any taker whose balance of the named token is zero. A pure guard — writes no registers.',
        'source': 'src/instructions/Controls.sol:140-144',
        'args': [{'key': 'gateToken', 'label': 'Gate token address', 'size': 20, 'type': 'address',
                  'default': '00000000000000000000000000000000000000aa'}],
    },
    {
        'op': '90', 'name': 'StaticBalances', 'label': 'Maker reserves',
        'blurb': ('Loads the maker\'s offered reserves. The pair is SWAPPED when tokenIn >= tokenOut — '
                  'arguments are stored in token-sort order, not taker order.'),
        'source': 'src/instructions/Balances.sol:37-47',
        'args': [{'key': 'balanceA', 'label': 'Balance A (low-sorting token)', 'size': 32, 'type': 'uint',
                  'default': '1000000000000000000000'},
                 {'key': 'balanceB', 'label': 'Balance B (high-sorting token)', 'size': 32, 'type': 'uint',
                  'default': '2000000000000000000000'}],
    },
    {
        'op': '53', 'name': 'LimitSwap', 'label': 'Fixed-rate limit swap',
        'blurb': ('Prices at the fixed ratio balanceOut:balanceIn. Exact-in floors, exact-out ceilings — '
                  'both round toward the maker.'),
        'source': 'src/instructions/LimitSwap.sol',
        'args': [{'key': 'makerDirectionLt', 'label': 'Maker quoted tokenIn < tokenOut', 'size': 1,
                  'type': 'bool', 'default': '01'}],
    },
]


def assemble(blocks: list) -> tuple[str, list]:
    """blocks -> program hex. Mirrors ProgramBuilder.build:
       abi.encodePacked(opcode, args.length.toUint8(), args)"""
    out, notes = '', []
    for b in blocks:
        spec = next((x for x in BLOCKS if x['op'] == b.get('op')), None)
        if spec is None:
            notes.append(f"unknown block {b.get('op')!r}")
            continue
        args = ''
        for field in spec['args']:
            raw = str(b.get('args', {}).get(field['key'], field['default'])).strip()
            width = field['size'] * 2
            if field['type'] == 'uint':
                try:
                    args += format(int(raw), f'0{width}x')
                except ValueError:
                    notes.append(f"{spec['name']}.{field['key']}: {raw!r} is not a number")
                    args += '0' * width
            else:
                h = raw.lower().removeprefix('0x')
                if not re.fullmatch(r'[0-9a-f]*', h):
                    notes.append(f"{spec['name']}.{field['key']}: {raw!r} is not hex")
                    h = ''
                args += h.rjust(width, '0')[:width]
        if len(args) // 2 > 255:
            notes.append(f"{spec['name']}: args exceed the 255-byte argsLength field")
        out += spec['op'] + format(len(args) // 2, '02x') + args
    return out, notes


def decode(hexstr: str) -> list:
    """Walk the program exactly as VM.sol:118-150 does."""
    b = bytes.fromhex(hexstr)
    steps, pc = [], 0
    while pc < len(b):
        # VM.sol:143 checks the bound AFTER advancing pc, so the revert reports the
        # ADVANCED value. semantics/swapvm.md records conformance catching exactly this
        # drift: the model said 88 where the real VM reports 91.
        if pc + 2 > len(b):
            steps.append({'pc': pc + 2, 'error': 'RunLoopExceedProgramLength',
                          'detail': 'the two-byte instruction header itself runs off the end'})
            break
        op, n = f'{b[pc]:02x}', b[pc + 1]
        end = pc + 2 + n
        if end > len(b):
            steps.append({'pc': end, 'op': op, 'name': OPCODES.get(op, 'UNKNOWN'), 'argsLen': n,
                          'error': 'RunLoopExceedProgramLength',
                          'detail': f'declares {n} argument bytes but only {len(b) - pc - 2} remain'})
            break
        steps.append({'pc': pc, 'op': op, 'name': OPCODES.get(op, f'UNKNOWN(0x{op})'),
                      'argsLen': n, 'args': b[pc + 2:end].hex(),
                      'modelled': op in MODELLED})
        pc = end
    return steps


# Human-readable notes for the conformance examples. Their outcomes are verified on BOTH
# engines (krun and the real ContextLib.runLoop), which is what makes them worth shipping.
EXAMPLE_NOTES = {
    'catalogue':        ('The permissioned swap', 'The reference program: gate, maker reserves, fixed-rate swap. This is the one the pricing theorems were proved about.'),
    'floorNotCeil':     ('Rounding goes to the maker', 'Reserves 3/2 with amountIn 1. Floor gives 0, ceiling would give 1 — so this case tells the two apart.'),
    'floorNonDividing': ('Rounding, non-dividing case', 'Reserves 3/7 with amountIn 5 gives 11. Picked so the division is not exact.'),
    'revPrices':        ('Reversed token order', 'tokenIn > tokenOut, so StaticBalances swaps the pair before pricing. Half of all token pairs take this branch — and a defect lived here.'),
    'revRecompute':     ('Recompute guard fires', 'amountOut is already set when LimitSwap runs. The guard rejects it, which is what stops a program pricing twice.'),
    'revRecomputeOut':  ('Recompute guard, exact-out', 'The mirror of the above on the other leg.'),
    'gateRejects':      ('Gate rejects the taker', 'Taker holds none of the gate token. Reverts at pc 22 — before any pricing happens. This is T0 in concrete form.'),
    'loneOpcode':       ('Truncated: no room for args', 'A single opcode byte with no length byte after it. The run loop reverts.'),
    'argsOverrun':      ('Declared args run off the end', 'Declares 64 argument bytes with none present. Reverts reporting pc 66 — the ADVANCED counter, not the instruction start.'),
    'empty':            ('Empty program', 'Zero bytes. The loop simply ends; nothing reverts.'),
    'zeroArg':          ('Unknown opcode, no args', 'An opcode the semantics does not model. Silent no-op in the model, UnknownOpcode on the real VM.'),
}


def curated() -> list:
    """Two hand-picked programs that differ by ONE BYTE, shown first in the catalogue.

    The bad one is not invented. `129aa48` records this exact defect class found during the
    Phase 1 review: the instruction rules constrain `lengthBytes(args)` but the Solidity
    constrains nothing — `address(bytes20(args))` right-zero-pads a short value without
    reverting. So a one-byte edit to a gate's length field "silently deleted the security
    gate from the model while it stayed live in production". Here it deletes the guarantee:
    the program still runs, still prices, and T0 no longer holds.
    """
    good, _ = assemble([{'op': o, 'args': {}} for o in ('23', '90', '53')])
    bad = '2313' + good[4:4 + 38] + good[4 + 40:]        # gate argsLen 0x13, not 0x14
    return [
        {'label': '__good', 'title': 'Permissioned swap — verified', 'kind': 'good',
         'bytes': good, 'length': len(good) // 2,
         'note': ('The reference order: hold the gate token, then swap at the maker\'s fixed rate. '
                  'All three theorems apply, and nothing is flagged.'),
         'expect': {'pc': 91, 'status': 'Running', 'amountOut': None}},
        {'label': '__bad', 'title': 'The same order, one byte wrong', 'kind': 'bad',
         'bytes': bad, 'length': len(bad) // 2,
         'note': ('The gate declares 19 argument bytes instead of 20. It still runs and still prices — '
                  'but it now gates a DIFFERENT address, because a short value is zero-padded rather '
                  'than rejected. The gate theorem stops applying. This defect class is recorded in '
                  'commit 129aa48.'),
         'expect': {'pc': 90, 'status': 'Running', 'amountOut': None}},
    ]


def disassemble(hexstr: str) -> tuple[list, list]:
    """bytes -> editable blocks. The inverse of assemble(), so an example can be LOADED
    into the composer and then edited, rather than shown as opaque hex."""
    blocks, unsupported = [], []
    for s in decode(hexstr):
        if s.get('error'):
            unsupported.append(f"pc {s['pc']}: {s['error']}")
            break
        spec = next((b for b in BLOCKS if b['op'] == s['op']), None)
        if spec is None:
            unsupported.append(f"pc {s['pc']}: 0x{s['op']} {s['name']} has no editable block yet")
            continue
        want = sum(a['size'] for a in spec['args'])
        if s['argsLen'] != want:
            unsupported.append(
                f"pc {s['pc']}: {spec['name']} carries {s['argsLen']} argument bytes, "
                f"but the block form expects {want} — kept as raw bytes so nothing is silently changed")
            continue
        args, off = {}, 0
        for a in spec['args']:
            chunk = s['args'][off * 2:(off + a['size']) * 2]
            args[a['key']] = str(int(chunk or '0', 16)) if a['type'] == 'uint' else chunk
            off += a['size']
        blocks.append({'op': s['op'], 'args': args})
    return blocks, unsupported


def lint(steps: list) -> list:
    """Re-run the bounds each build() helper enforces but parse() does not.

    This is the systemic finding, not a nicety: seven instructions validate in `build` and
    not in `parse`, and program bytes are maker-assembled so only `parse` ever runs on chain.
    """
    out = []
    for s in steps:
        if s.get('error'):
            continue
        op, args = s['op'], s.get('args', '')
        if op == '23' and s['argsLen'] != 20:
            out.append({'level': 'error', 'pc': s['pc'],
                        'text': f"Gate token needs exactly 20 bytes; this block declares {s['argsLen']}.",
                        'why': ('address(bytes20(args)) right-zero-pads a short value without reverting, '
                                'so the gate would silently check a DIFFERENT address than you intended.'),
                        'source': 'semantics/swapvm.md, "Malformed arguments on a MODELLED opcode"'})
        if op == '90':
            if s['argsLen'] != 64:
                out.append({'level': 'error', 'pc': s['pc'],
                            'text': f"Maker reserves need exactly 64 bytes; this block declares {s['argsLen']}.",
                            'why': ('Calldata.slice does no bounds checking, so a short args reads whatever '
                                    'follows it in calldata as a balance.'),
                            'source': 'test/kontrol/README.md, test_finding_shortArgsNeverRevert'})
            elif int(args[:64] or '0', 16) == 0 or int(args[64:] or '0', 16) == 0:
                out.append({'level': 'warn', 'pc': s['pc'],
                            'text': 'One of the reserves is zero.',
                            'why': 'LimitSwap and XYCSwap both reject a zero balance; the order cannot fill.',
                            'source': 'src/instructions/LimitSwap.sol'})
        if op == '53' and s['argsLen'] != 1:
            out.append({'level': 'warn', 'pc': s['pc'],
                        'text': f"LimitSwap expects a 1-byte direction flag; this block declares {s['argsLen']}.",
                        'why': ('The instruction places no constraint on argument length, so this will not '
                                'revert — it just reads a different byte as the direction.'),
                        'source': 'semantics/swapvm.md'})
        if not s.get('modelled'):
            out.append({'level': 'info', 'pc': s['pc'],
                        'text': f"{s['name']} is not modelled by the K semantics.",
                        'why': ('The formal model treats unknown opcodes as no-ops while the real VM reverts '
                                'UnknownOpcode. No proof below covers this instruction.'),
                        'source': 'semantics/DEMO.md §5a — 3 of 52 opcodes modelled'})
    return out


def proved(steps: list) -> list:
    """Match the composed program against theorems already discharged by kprove."""
    live = [s for s in steps if not s.get('error')]
    results = []
    T = {t['id']: t for t in CLAIMS['theorems']}

    gate_first = bool(live) and live[0]['op'] == '23' and live[0]['argsLen'] == 20
    if gate_first:
        t = T['T0']
        results.append({**t, 'holds': True,
                        'because': ('Your program begins with the gate block, and T0 was proved with '
                                    'everything after it left UNKNOWN. So it covers this program, and any '
                                    'program you go on to build from it.')})
    else:
        results.append({**T['T0'], 'holds': False,
                        'because': ('T0 needs the gate as the FIRST instruction. Anything before it runs '
                                    'first, so the theorem says nothing about this arrangement.')})

    shape = [(s['op'], s['argsLen']) for s in live]
    if shape == [('23', 20), ('90', 64), ('53', 1)]:
        for tid in ('T1', 'T2'):
            results.append({**T[tid], 'holds': True,
                            'because': ('This is exactly the three-instruction program the pricing theorems '
                                        'were proved about, with the reserves and trade size left symbolic.')})
    else:
        results.append({**T['T1'], 'holds': False,
                        'because': ('The pricing theorems were proved about the exact sequence '
                                    'gate -> maker reserves -> limit swap. This program has a different shape.')})
    return results


# Error selectors, so a revert shows a name rather than four hex bytes.
SELECTORS = {
    '9669f955': 'TakerTokenBalanceIsZero(address taker, address token)',
    'e2f4e5b1': 'SetBalancesExpectZeroBalances',
    '2a1b2dd8': 'LimitSwapRequiresBothBalancesNonZero',
    '4b9d78b6': 'LimitSwapDirectionMismatch',
    '9d4e2b04': 'LimitSwapRecomputeDetected',
}

EXEC_WORKSPACE = os.environ.get('DEMO_EXEC_WS', '/home/user/fee-work')
EXEC_CONTAINER = os.environ.get('DEMO_EXEC_CONTAINER', 'kontrol')


def execute(hexstr: str, cfg: dict) -> dict:
    """EXECUTED tier: run the composed program through the real ContextLib.runLoop.

    Inputs go in by environment variable so the test contract never changes and Foundry
    does not recompile between runs (~48 s vs ~1 ms). Returns the real registers, or the
    real revert data -- not a simulation of either.
    """
    env = {
        'DEMO_PROGRAM': '0x' + hexstr,
        'DEMO_GATE_BALANCE': str(cfg.get('gateBalance', 0)),
        'DEMO_AMOUNT_IN': str(cfg.get('amountIn', 10**18)),
        'DEMO_AMOUNT_OUT': str(cfg.get('amountOut', 0)),
        'DEMO_EXACT_IN': 'true' if cfg.get('isExactIn', True) else 'false',
    }
    cmd = ['docker', 'exec', '-u', 'user']
    for k, v in env.items():
        cmd += ['-e', f'{k}={v}']
    cmd += [EXEC_CONTAINER, 'bash', '-c',
            f'cd {EXEC_WORKSPACE} && PATH=/home/user/.foundry/bin:/usr/bin:/bin '
            f'FOUNDRY_PROFILE=default forge test --match-path "test/demo/DemoRun.t.sol" -vv']
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=180).stdout
    except Exception as e:
        return {'available': False, 'error': str(e)}

    res = {'available': True, 'raw': []}
    for line in out.splitlines():
        t = line.strip()
        for key in ('balanceIn', 'balanceOut', 'amountIn', 'amountOut', 'nextPC', 'GATE'):
            if t.startswith(key + ' '):
                res[key] = t.split(None, 1)[1]
        if t == 'OK':
            res['status'] = 'completed'
        if t == 'REVERT':
            res['status'] = 'reverted'
        if t.startswith('0x') and res.get('status') == 'reverted' and 'selector' not in res:
            res['selector'] = t[2:10]
            res['error'] = SELECTORS.get(t[2:10], f'unknown selector 0x{t[2:10]}')
    if 'status' not in res:
        res['available'] = False
        res['error'] = 'the executed tier is unavailable (container or workspace not reachable)'
    return res


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload, ctype='application/json'):
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):  # quiet
        pass

    def do_GET(self):
        path = self.path.split('?')[0]
        if path in ('/', '/index.html'):
            return self._send(200, (STATIC / 'index.html').read_bytes(), 'text/html; charset=utf-8')
        if path == '/api/bootstrap':
            examples = []
            for e in curated() + EXAMPLES:
                title, note = (e.get('title'), e.get('note')) if e.get('kind') \
                    else EXAMPLE_NOTES.get(e['label'], (e['label'], ''))
                blocks, unsupported = disassemble(e['bytes'])
                examples.append({**e, 'title': title, 'note': note,
                                 'blocks': blocks, 'unsupported': unsupported,
                                 'editable': not unsupported})
            return self._send(200, {'blocks': BLOCKS, 'opcodes': OPCODES,
                                    'examples': examples, 'claims': CLAIMS, 'proofs': PROOFS})
        return self._send(404, {'error': 'not found'})

    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        try:
            req = json.loads(self.rfile.read(n) or b'{}')
        except json.JSONDecodeError:
            return self._send(400, {'error': 'bad json'})

        if self.path == '/api/assemble':
            hexstr, notes = assemble(req.get('blocks', []))
            return self._send(200, {'hex': hexstr, 'length': len(hexstr) // 2,
                                    'notes': notes, 'steps': decode(hexstr)})
        if self.path == '/api/disassemble':
            blocks, unsupported = disassemble(req.get('hex', ''))
            return self._send(200, {'blocks': blocks, 'unsupported': unsupported})
        if self.path == '/api/execute':
            hexstr = req.get('hex') or assemble(req.get('blocks', []))[0]
            return self._send(200, execute(hexstr, req.get('config', {})))
        if self.path == '/api/verify':
            hexstr = req.get('hex')
            if hexstr is None:
                hexstr, _ = assemble(req.get('blocks', []))
            steps = decode(hexstr)
            return self._send(200, {'hex': hexstr, 'length': len(hexstr) // 2, 'steps': steps,
                                    'proved': proved(steps), 'lint': lint(steps),
                                    'coverage': CLAIMS['coverage'],
                                    'controls': CLAIMS['negative_controls']})
        return self._send(404, {'error': 'not found'})


if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8000))
    print(f'SwapVM demo on http://localhost:{port}  (ctrl-c to stop)')
    ThreadingHTTPServer(('0.0.0.0', port), Handler).serve_forever()

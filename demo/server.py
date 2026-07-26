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
SPECDOCS = json.loads((DATA / 'specdocs.json').read_text())

# Runs that really happened, frozen by record_runs.py. See LIVE below for when they are used.
RUNS = json.loads((DATA / 'runs.json').read_text()) if (DATA / 'runs.json').exists() else {}

# LIVE decides whether `prove`/`execute` shell out or replay.
#
# The two of them need `kprove` and `forge` inside the kontrol container -- a multi-gigabyte
# K definition and proofs that take 5 s to 10 min. A serverless host has none of that and
# caps a request at 60 s, so on Vercel this is False and the endpoints replay `runs.json`.
#
# THE REPLAY IS LABELLED, ALWAYS. Every replayed response carries `recorded: True`, the
# timestamp, and the exact command, and the UI prints them. A recording shown as a live run
# would be precisely the fake this project argues against -- so the fallback is allowed to
# be less impressive, and is not allowed to be silent.
LIVE = os.environ.get('DEMO_LIVE', '0' if os.environ.get('VERCEL') else '1') == '1'

# Optional escape hatch: a box that CAN prove. Set DEMO_BACKEND to the base URL of another
# copy of this server running with DEMO_LIVE=1 (a laptop behind cloudflared, say) and the
# hosted site forwards prove/execute there instead of replaying. If that box is unreachable
# the request falls back to the recording rather than erroring -- degrading to a labelled
# replay beats a demo that dies when the wifi does.
BACKEND = os.environ.get('DEMO_BACKEND', '').rstrip('/')


def _forward(endpoint: str, payload: dict):
    """POST to the live backend. Returns None on any failure, so callers can fall back."""
    if not BACKEND:
        return None
    import urllib.request
    import urllib.error
    try:
        req = urllib.request.Request(
            f'{BACKEND}/api/{endpoint}', data=json.dumps(payload).encode(),
            headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=25) as r:
            return json.loads(r.read())
    except Exception:
        return None

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
        'op': '20', 'name': 'Deadline', 'label': 'Deadline',
        'blurb': 'Reverts once block.timestamp passes the 5-byte deadline. Modelled in K with a spec and a control.',
        'source': 'src/instructions/Controls.sol · semantics/opcodes/deadline.k',
        'args': [{'key': 'deadline', 'label': 'Expiry (unix seconds)', 'size': 5, 'type': 'uint',
                  'default': '1099511627775'}],
    },
    {
        'op': '50', 'name': 'XYCSwap', 'label': 'Constant-product swap',
        'blurb': ('amountOut = floor(amountIn x balanceOut / (balanceIn + amountIn)). In Aqua mode the '
                  'reserves come from Aqua, not from a balances instruction.'),
        'source': 'src/instructions/XYCSwap.sol · semantics/opcodes/xycswap.k',
        'args': [],
    },
    {
        'op': '02', 'name': 'Salt', 'label': 'Salt (order uniqueness)',
        'blurb': 'Touches no register. Distinguishes otherwise-identical orders.',
        'source': 'src/instructions/Controls.sol · semantics/opcodes/salt.k',
        'args': [{'key': 'salt', 'label': 'Nonce', 'size': 8, 'type': 'uint', 'default': '1'}],
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


# Conformance examples that carry nothing the demo does not already show. They stay in
# examples.json -- selftest.py checks the K model against every one of them, and that is
# their real job -- but they are not worth a slot in a catalogue a person reads.
#
# The measure is: does clicking it show something the other entries do not?
def catalogue() -> list:
    """No conformance examples on the page. Deliberately empty, not accidentally.

    They remain in `examples.json` and `selftest.py` still checks the K model's prediction
    against every one of them on each run -- that is the job they were written for. What
    they were NOT earning was a slot in a catalogue a person reads: two pairs were
    byte-identical to entries above them, one duplicated the gate toggle, and the rest were
    concrete witnesses for properties the pricing theorems already cover symbolically.

    ONE THING IS LOST BY THIS. Three of them (`loneOpcode`, `argsOverrun`, `zeroArg`) were
    the visible cases where the K model no-ops and production reverts -- the honest limit of
    the approach, since an L2 theorem proved about such a program says nothing about the
    deployed VM. That claim now lives only in `semantics/swapvm.md` and `axioms.md`, not on
    the page. Worth knowing when someone asks the page what it does not cover.
    """
    return []


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
    dust, _ = assemble([{'op': '23', 'args': {}}, {'op': '20', 'args': {}},
                        {'op': '50', 'args': {}}, {'op': '02', 'args': {}}])
    bad = '2313' + good[4:4 + 38] + good[4 + 40:]        # gate argsLen 0x13, not 0x14
    return [
        {'label': '__good', 'title': 'Permissioned swap — verified', 'kind': 'good',
         'bytes': good, 'length': len(good) // 2,
         'note': ('The reference order: hold the gate token, then swap at the maker\'s fixed rate. '
                  'All three theorems apply, and nothing is flagged.'),
         'expect': {'pc': 91, 'status': 'Running', 'amountOut': None}},
        {'label': '__bad', 'title': 'The same order, one byte wrong', 'kind': 'bad',
         'bytes': bad, 'length': len(bad) // 2,
         'note': ('The gate declares 19 argument bytes instead of 20. Nothing rejects that: a short '
                  'value is zero-padded rather than refused, so the gate silently re-points from '
                  '0x…AA to 0x…90 — it absorbed the next opcode byte. T0 stops applying. Run it and '
                  'the real VM reverts, because the rest of the program is now misaligned too; the '
                  'K model instead no-ops past it. That gap between "reverts" and "quietly continues" '
                  'is the defect class recorded in commit 129aa48.'),
         'expect': {'pc': 90, 'status': 'Running', 'amountOut': None}},
        {'label': '__dust', 'title': 'DustProof — an Aqua dust order', 'kind': 'good',
         'bytes': dust, 'length': len(dust) // 2,
         'note': ('Buys a dust token for WETH through Aqua. Gate, expiry, constant-product curve, '
                  'nonce. Both theorems apply: T0 (the gate, over any tail) and D1 (the quote is '
                  'exactly the curve, for any reserves and any trade size).'),
         'expect': {'pc': 41, 'status': 'Running', 'amountOut': None}},
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

    if shape == [('23', 20), ('20', 5), ('50', 0), ('02', 8)]:
        t = T['D1']
        results.append({**t, 'holds': True,
                        'because': ('This is exactly the program DustOrderBuilder emits, and D1 was '
                                    'proved about it with the maker reserves and the trade size left '
                                    'symbolic.')})

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


# ---------------------------------------------------------------------------------------
# Sources. The page claims things about Solidity and about K files; both should be readable
# without leaving it, because "trust me, the spec says so" is the failure mode here.
# ---------------------------------------------------------------------------------------

ROOT = HERE.parent


def _dispatch_map() -> dict:
    """opcode NAME -> (solidity path, function name), read off the production dispatch table.

    Derived, not hand-listed. `src/opcodes/Opcodes.sol` is what the VM actually branches on,
    so parsing it means the page cannot drift into showing a function that no longer runs --
    and if the table changes shape, the map comes back empty rather than quietly wrong.
    """
    src = (ROOT / 'src/opcodes/Opcodes.sol')
    if not src.exists():
        return {}
    text = src.read_text()
    imports = dict(re.findall(r'import\s*\{\s*(\w+)\s*\}\s*from\s*"([^"]+)"', text))
    out = {}
    for name, lib, fn in re.findall(
            r'opcode == uint256\(Opcode\.(\w+)\)\)\s*(\w+)\.(\w+)\(', text):
        rel = imports.get(lib, f'../instructions/{lib}.sol')
        path = (src.parent / rel).resolve()
        try:
            out[name] = (str(path.relative_to(ROOT)), fn)
        except ValueError:
            continue
    return out


DISPATCH = _dispatch_map()


def _extract_fn(path: pathlib.Path, fn: str) -> str | None:
    """Pull one function plus its doc comment out of a .sol file, by brace matching.

    The function, not the whole file: the point is the code that runs for THIS opcode, and
    a 400-line file with the relevant 5 lines somewhere inside it is not evidence anyone
    reads. Returns None rather than a guess if the shape is unexpected.
    """
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return None
    start = next((i for i, l in enumerate(lines)
                  if re.match(rf'\s*function\s+{re.escape(fn)}\s*\(', l)), None)
    if start is None:
        return None
    # Walk back over the natspec block that documents it.
    head = start
    while head > 0 and re.match(r'\s*(///|\*|/\*)', lines[head - 1]):
        head -= 1
    depth, end = 0, None
    for i in range(start, len(lines)):
        depth += lines[i].count('{') - lines[i].count('}')
        if depth <= 0 and '{' in ''.join(lines[start:i + 1]):
            end = i
            break
    if end is None:
        return None
    return '\n'.join(lines[head:end + 1])


def _contract_doc(path: pathlib.Path, fn: str | None = None) -> dict:
    """What the file IS: its declaration, its own natspec, and what else it handles.

    Upstream's instruction files carry only a licence header -- no @title, no @notice -- so
    a description lifted from natspec alone would be blank for most of them. The dispatch
    table fills that in with something better than prose anyway: the full list of opcodes
    that route into this file. That is derived, checkable, and tells you the thing you
    actually want to know, which is what else is in here.
    """
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return {}
    decls = [(i, *m.groups()) for i, l in enumerate(lines)
             if (m := re.match(r'\s*(?:abstract\s+)?(contract|library|interface)\s+(\w+)', l))]
    if not decls:
        return {}
    # Pick the declaration that actually owns this code, not the first in the file. These
    # files routinely open with an `XArgsBuilder` helper library or an interface, so taking
    # decls[0] names the wrong thing -- Controls.sol would read as "ControlsArgsBuilder".
    if fn:
        at = next((i for i, l in enumerate(lines)
                   if re.match(rf'\s*function\s+{re.escape(fn)}\s*\(', l)), None)
        chosen = max((d for d in decls if at is None or d[0] < at),
                     key=lambda d: d[0], default=decls[0])
    else:
        stem = path.stem
        chosen = next((d for d in decls if d[2] == stem), decls[-1])
    i, kind, name = chosen
    head = i
    while head > 0 and re.match(r'\s*(///|\*|/\*)', lines[head - 1]):
        head -= 1
    natspec = [re.sub(r'^\s*(///|\*/?)\s?', '', l).rstrip() for l in lines[head:i]]
    natspec = [l for l in natspec if not l.startswith('@custom:')]
    rel = str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else path.name
    handles = sorted(op for op, (p, _) in DISPATCH.items() if p == rel)
    return {'kind': kind, 'name': name,
            'doc': '\n'.join(natspec).strip(),
            'handles': handles}


def sources_for(steps: list, applicable: list, proof: dict | None = None) -> dict:
    """Every artefact behind one program: the Solidity each instruction dispatches to, and
    the K specs that constrain it. Keyed by repo-relative path so the page can label them."""
    out = {}
    for s in steps:
        name = s.get('name')
        if not name or name not in DISPATCH:
            continue
        rel, fn = DISPATCH[name]
        body = _extract_fn(ROOT / rel, fn)
        if body:
            whole = (ROOT / rel).read_text()
            out[f'{rel}::{fn}'] = {'kind': 'solidity', 'path': rel, 'fn': fn,
                                   'opcode': s.get('op'), 'text': body,
                                   'full': whole, 'full_lines': whole.count('\n') + 1,
                                   'contract': _contract_doc(ROOT / rel, fn)}

    # The contracts DustProof itself is, as opposed to the instructions it composes. They
    # are not reachable from the dispatch table -- no opcode routes to them -- so without
    # this the page shows the program and the specs but never the product's own code.
    if [(s.get('op'), s.get('argsLen')) for s in steps if not s.get('error')] == \
            [('23', 20), ('20', 5), ('50', 0), ('02', 8)]:
        for rel in ('contracts/DustOrderBuilder.sol', 'contracts/DustSweeper.sol'):
            p = ROOT.parent / 'dustproof' / rel
            if p.exists():
                out[f'dustproof/{rel}'] = {
                    'kind': 'solidity', 'path': f'dustproof/{rel}', 'fn': None,
                    'opcode': None, 'text': p.read_text(),
                    'contract': _contract_doc(p)}

    def add_spec(rel):
        for base in (ROOT, ROOT.parent / 'dustproof', ROOT / 'semantics'):
            p = (base / rel)
            if p.exists() and p.is_file():
                whole = p.read_text()
                # The claim block is the invariant; everything else is imports and setup.
                # Lead with the claim and keep the file behind a second expander, for the
                # same reason the Solidity leads with the function: a reader should meet the
                # statement being proved, not hunt for it.
                m = re.search(r'(?ms)^\s*claim\b.*?(?=^\s*(?:claim|endmodule)\b)', whole)
                out[rel] = {'kind': 'k', 'path': rel,
                            'text': (m.group(0).strip() if m else whole),
                            'full': whole, 'full_lines': whole.count('\n') + 1,
                            'focused': bool(m)}
                return

    for a in applicable:
        if a.get('holds') and a.get('file'):
            add_spec(a['file'])
    if proof and proof.get('available'):
        for side in ('spec', 'control'):
            nm = (proof.get(side) or {}).get('spec')
            if nm:
                add_spec(f'semantics/proofs/{nm}.k')
                add_spec(f'../dustproof/semantics/{nm}.k')
    return out


# Error selectors, so a revert shows a name rather than four hex bytes.
SELECTORS = {
    '9669f955': 'TakerTokenBalanceIsZero(address taker, address token)',
    'e2f4e5b1': 'SetBalancesExpectZeroBalances',
    '2a1b2dd8': 'LimitSwapRequiresBothBalancesNonZero',
    '4b9d78b6': 'LimitSwapDirectionMismatch',
    '9d4e2b04': 'LimitSwapRecomputeDetected',
}

# Spec/control PAIRS. Verify runs both: the spec must return #Top, the control MUST FAIL.
# Running only the spec would be worth much less — a proof that cannot fail proves nothing,
# and an inconsistent rule set proves everything while looking like total success.
PROOF_PAIRS = {
    '__dust':      ('dustproof-spec', 'dustproof-control'),
    '__good':      ('pricing-spec', 'pricing-negative-control'),
    'catalogue':   ('pricing-spec', 'pricing-negative-control'),
    'gateRejects': ('gate-spec', 'negative-control'),
}
K_WORKSPACE = os.environ.get('DEMO_K_WS', '/home/user/sem2')
K_DEFINITION = os.environ.get('DEMO_K_DEF', 'swapvm-full')

EXEC_WORKSPACE = os.environ.get('DEMO_EXEC_WS', '/home/user/fee-work')
EXEC_CONTAINER = os.environ.get('DEMO_EXEC_CONTAINER', 'kontrol')


def execute_live(hexstr: str, cfg: dict) -> dict:
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


def _kprove(spec: str) -> dict:
    """Run kprove on one spec. Deterministic: same definition, same file, same verdict."""
    cmd = ['docker', 'exec', '-u', 'user', EXEC_CONTAINER, 'bash', '-c',
           f'cd {K_WORKSPACE} && PATH=/usr/bin:/bin timeout 600 '
           f'kprove --definition {K_DEFINITION} proofs/{spec}.k']
    import time
    t0 = time.time()
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=660)
    except Exception as e:
        return {'spec': spec, 'available': False, 'error': str(e)}
    out = (r.stdout or '') + (r.stderr or '')
    return {'spec': spec, 'available': True, 'exit': r.returncode,
            'top': '#Top' in out, 'seconds': round(time.time() - t0, 1),
            'stuck': 'WarnStuckClaimState' in out}


def prove_live(label: str) -> dict:
    """Run the spec/control pair for an example. No pattern matching, no agent — this
    executes the prover and reports what it returned."""
    pair = PROOF_PAIRS.get(label)
    if not pair:
        return {'available': False,
                'error': f'no spec is paired with {label!r}. Verification here runs a '
                         'human-written spec; it does not generate one.'}
    spec_name, control_name = pair
    spec, control = _kprove(spec_name), _kprove(control_name)
    if not (spec.get('available') and control.get('available')):
        return {'available': False, 'error': spec.get('error') or control.get('error')}

    ok = spec['top'] and control['exit'] != 0
    return {
        'available': True, 'ok': ok,
        'spec': {**spec, 'expected': '#Top',
                 'verdict': 'PROVED' if spec['top'] else 'DID NOT PROVE'},
        'control': {**control, 'expected': 'must FAIL',
                    'verdict': 'failed as required' if control['exit'] != 0
                               else 'PROVED — the rule set is INCONSISTENT and every result is void'},
    }


# ---------------------------------------------------------------------------------------
# Live-or-replay. The only difference between the local demo and the hosted one.
# ---------------------------------------------------------------------------------------

def _replay_note(rec: dict) -> dict:
    """Stamp a frozen result so the caller cannot mistake it for a live run."""
    return {**rec, 'recorded': True,
            'recorded_at': RUNS.get('recorded_at'),
            'definition': RUNS.get('definition', {}).get('sha256_16')}


def prove(label: str) -> dict:
    if LIVE:
        return {**prove_live(label), 'recorded': False}
    fwd = _forward('prove', {'label': label})
    if fwd and fwd.get('available'):
        return {**fwd, 'recorded': False, 'via': BACKEND}
    rec = RUNS.get('proofs', {}).get(label)
    if rec:
        return _replay_note(rec)
    return {'available': False, 'recorded': True,
            'error': (f'no recorded run for {label!r}. The hosted site replays proofs that '
                      'were run for real; it cannot start a prover. Run it yourself with '
                      '`./semantics/run-proofs.sh` — see VERIFY.md.')}


def execute(hexstr: str, cfg: dict) -> dict:
    if LIVE:
        return {**execute_live(hexstr, cfg), 'recorded': False}
    fwd = _forward('execute', {'hex': hexstr, 'config': cfg})
    if fwd and fwd.get('available'):
        return {**fwd, 'recorded': False, 'via': BACKEND}
    # Match by program bytes AND gate state, not by label: the front sends hex, and a
    # program the user edited is a different program even if it started from an example.
    label = _BY_HEX.get(hexstr.lower().removeprefix('0x'))
    rec = RUNS.get('executions', {}).get(f'{label}|{cfg.get("gateBalance", 0)}') if label else None
    if rec:
        return _replay_note(rec)
    return {'available': False, 'recorded': True,
            'error': ('this program has no recorded run. The hosted site replays the shipped '
                      'examples through the real VM; running an arbitrary program needs '
                      'Foundry and the repo locally — see demo/README.md.')}


_BY_HEX = {(e.get('bytes') or '').lower(): e.get('label')
           for e in (EXAMPLES + curated()) if e.get('bytes')}


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
            for e in curated() + catalogue():
                title, note = (e.get('title'), e.get('note')) if e.get('kind') \
                    else EXAMPLE_NOTES.get(e['label'], (e['label'], ''))
                blocks, unsupported = disassemble(e['bytes'])
                examples.append({**e, 'title': title, 'note': note,
                                 'provable': e['label'] in PROOF_PAIRS,
                                 'blocks': blocks, 'unsupported': unsupported,
                                 'editable': not unsupported})
            return self._send(200, {'blocks': BLOCKS, 'opcodes': OPCODES,
                                    'examples': examples, 'claims': CLAIMS, 'proofs': PROOFS,
                                    'specdocs': SPECDOCS})
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
        if self.path == '/api/prove':
            return self._send(200, prove(req.get('label', '')))
        if self.path == '/api/execute':
            hexstr = req.get('hex') or assemble(req.get('blocks', []))[0]
            return self._send(200, execute(hexstr, req.get('config', {})))
        if self.path == '/api/verify':
            hexstr = req.get('hex')
            if hexstr is None:
                hexstr, _ = assemble(req.get('blocks', []))
            steps = decode(hexstr)
            applicable = proved(steps)
            for a in applicable:
                d = SPECDOCS.get(pathlib.Path(a.get('file', '')).stem)
                if d:
                    a['docfile'] = d['file']
                a.pop('verdict', None)          # a verdict comes from kprove, never from here
            return self._send(200, {'hex': hexstr, 'length': len(hexstr) // 2, 'steps': steps,
                                    'applicable': applicable, 'lint': lint(steps),
                                    'sources': sources_for(steps, applicable),
                                    'coverage': CLAIMS['coverage'],
                                    'controls': CLAIMS['negative_controls']})
        return self._send(404, {'error': 'not found'})


if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8000))
    print(f'SwapVM demo on http://localhost:{port}  (ctrl-c to stop)')
    ThreadingHTTPServer(('0.0.0.0', port), Handler).serve_forever()

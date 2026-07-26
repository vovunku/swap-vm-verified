# `0x2c` WhitelistCoequal and `0x2d` WhitelistSequential — formal semantics

Design doc for `semantics/opcodes/whitelists.k`. Companion to `swapvm.md` (decode loop),
`opcodes/jump.k` (uint16 pc overwrite), `opcodes/extruction.md` (the D4 abstraction-boundary
template this file follows), `opcodes/deadline.k` and `opcodes/gte.k` (the Bool-predicate
arm-selection pattern this file adopts), `opcodes/privateorder.k` (the 80-bit packed-address
twin), and `src/instructions/Whitelist.sol:88-167` (the Solidity source).

This file documents the **two hardest opcodes in the Conditions & access-guards group**, and
the load-bearing design decision is the same one `opcodes/extruction.md` records for
Extruction: **abstract the unmodellable surface as a predicate, prove structural properties
about it, declare the gap honestly.**

## Sources

`src/instructions/Whitelist.sol:112-129` (0x2c) and `:131-167` (0x2d):

```solidity
// 0x2c — args = [pc:2] + N * [packedAddr:10]
function _whitelistCoequal(Context memory ctx, bytes calldata args) internal pure {
    uint80 sender = WhitelistArgsBuilder.wrapToPackedAddress(ctx.query.taker);
    bytes calldata list = args.slice(2);
    unchecked {
        uint256 i = list.length / 10;
        while (i-- > 0) {
            if (sender == list.parseWhitelistCoequalIx(i)) {
                ctx.vm.nextPC = args.parseWhitelistCoequalPC();
                return;
            }
        }
    }
    // (else fall through, no revert)
}

// 0x2d — args = [pc:2] + [start:5] + N * ([duration:2] + [packedAddr:10])
function _whitelistSequential(Context memory ctx, bytes calldata args) internal view {
    uint80 sender = WhitelistArgsBuilder.wrapToPackedAddress(ctx.query.taker);
    (uint40 start, uint256 pc) = args.parseWhitelistSequentialStartPC();
    uint256 timeLeft = block.timestamp;
    unchecked {
        if (timeLeft < start) revert WhitelistAllowedTimeViolation();
        timeLeft -= start;
        bytes calldata list = args.slice(7);
        uint256 i;
        uint256 length = list.length / 12;
        while (i < length) {
            (uint80 allowedTaker, uint256 duration) = list.parseWhitelistSequentialIx(i++);
            if (sender == allowedTaker) { ctx.vm.nextPC = pc; return; }       // JUMP
            if (timeLeft < duration) revert WhitelistAllowedTimeViolation();  // REVERT
            timeLeft -= duration;
        }
    }
    // i == length: FALL THROUGH
}
```

The packed taker is `uint80(uint160(ctx.query.taker))` — the taker's address TRUNCATED TO ITS
LOW 80 BITS (`wrapToPackedAddress`, Whitelist.sol:81-85). The collision-resistance trade-off
this entails is documented at Whitelist.sol:88-95 and is preserved by the model — see "The
80-bit packing" below.

The possible outcomes are:

- **0x2c**: JUMP (taker in list, `<pc>` overwritten) or FALL THROUGH (not in list, `<pc>`
  inherited from decode). Never reverts.
- **0x2d**: JUMP (taker is the entry unlocked at `block.timestamp`), REVERT
  `WhitelistAllowedTimeViolation` (before `start`, or in a window whose address != taker and
  whose duration has not elapsed), or FALL THROUGH (past every window). One extra outcome:
  `block.timestamp < start` reverts at the top of the function (Whitelist.sol:147).

## Why the loop is intractable to model literally

Both opcodes' main control flow is a `while` loop over a **variable-length byte array**,
parsing packed entries:

- 0x2c: `while (i-- > 0)` over `args.slice(2)`, parsing 10-byte packed addresses via
  `list.parseWhitelistCoequalIx(i)`.
- 0x2d: `while (i < length)` over `args.slice(7)`, parsing 2-byte duration + 10-byte address
  pairs via `list.parseWhitelistSequentialIx(i)`.

A literal K model would have to:

1. Compute `list.length` from symbolic bytes (`lengthBytes(ARGS) -Int 2` for 0x2c,
   `lengthBytes(ARGS) -Int 7` for 0x2d), then divide by 10 or 12 to get the loop bound. The
   bound is **symbolic** once ARGS is symbolic.
2. Unfold the loop that many times. K's symbolic execution cannot determine a fixed unfolding
   count for a symbolic bound; the Haskell backend does not reduce `while`-style iteration to
   a closed form.
3. At each iteration, parse the next packed entry from the byte array (`parseWhitelistCoequalIx`
   reads `bytes10(list[i*10:i*10+10])`), which is itself a sequence of `substrBytes` reads
   against a symbolic offset against symbolic bytes.
4. For 0x2d, additionally interleave per-iteration `timeLeft < duration` and
   `timeLeft -= duration` arithmetic against the abstract `block.timestamp`, and determine
   JUMP vs REVERT based on the **interleaving** of address matches and window expirations
   across the whole list.

This is **the same shape of unmodellability** that `opcodes/extruction.md` documents for
Extruction (an arbitrary external call) and that PLAN.md D4 names as the abstraction boundary
for external effects. The honest direction — the one this file originally took — was to
abstract the **outcome** of the loop as a Bool predicate and prove STRUCTURAL properties
about it (which arm fires given which predicate holds), rather than pretending to model the
iteration.

This is **not** the same as the Bool-predicate arm-selection pattern that Deadline/Gte/
SupplyShare adopt. Those opcodes' loops are bounded and decidable; their predicates exist
because of the **SMT encoding limitation** described in "Arm selection" below. The Whitelist
predicates existed because the loop itself was treated as unmodellable. The two reasons
compose: even if the SMT limitation were absent, the loop would still be intractable in the
SYMBOLIC case.

**UPDATE (conformance-verification pass):** the predicate abstraction turned out to be
worse than honest — it was tautological. Every symbolic spec asserted the predicate as a
premise and the rule branched on the same predicate, so the proofs established NOTHING about
whether the underlying loop matched Solidity, AND krun could not reduce the predicates on
concrete inputs either (zero conformance evidence). The conformance-verification pass
promoted BOTH opcodes out of the abstraction: 0x2c via the recursive `#coequalContains`
function, 0x2d via the recursive `#seqOutcome` function (with the time arithmetic modelled
directly, not abstracted). On CONCRETE lists (+ a concrete timestamp for 0x2d) the
recursions reduce to a concrete Bool / outcome tag via the bytes lemmas
(`semantics/lemmas.k:16-67`), giving genuine conformance evidence — see
`proofs/whitelistcoequal-concrete.k` and `proofs/whitelistsequential-concrete.k`. On
SYMBOLIC lists the recursions are STUCK (neither rule's `requires` reduces), which is the
honest posture: no false symbolic claim is admitted, but no spurious `#Top` is emitted
either. The framing above remains accurate for the SYMBOLIC case (a literal K model would
still be intractable there); what changed is that CONCRETE inputs are now handled directly
rather than abstracted, and the abstraction is no longer the load-bearing design decision.
The remainder of this file documents the current (recursive-function) design; historical
references to the predicate form are retained where they explain why the new form exists.

## The abstraction boundary (PLAN.md D4)

Per PLAN.md D4 (cross-referenced in `opcodes/extruction.md` "The abstraction boundary"):

> External effects are abstract. Token transfers, signature checks, Aqua settlement:
> abstracted to a `<status>` cell and an event trace. Modelling ERC-20 balloons the effort
> and none of the six invariants needs it.

WhitelistCoequal and WhitelistSequential are not external calls, but their loops over a
variable-length byte array were originally treated as unmodellable for the same reason an
arbitrary external call is: the K prover cannot reduce the computation to a closed form over
SYMBOLIC bytes. **As of the conformance-verification pass, BOTH opcodes have been promoted
out of that abstraction** — their loops are modelled directly by recursive functions
(`#coequalContains` for 0x2c, `#seqOutcome` for 0x2d; see "What the K rules do" below),
which evaluate on concrete lists and stay stuck on symbolic lists rather than emitting a
spurious `#Top`. The declarations are now:

```k
// 0x2c — RECURSIVE FUNCTION (conformance-verified; concrete lists evaluate, symbolic stuck)
syntax Bool ::= #coequalContains        ( Bytes , Int ) [function]

// 0x2d — RECURSIVE OUTCOME FUNCTION (conformance-verified; concrete lists+ts evaluate, symbolic stuck)
syntax Int  ::= #blockTimestamp ()              [function, no-evaluators]
syntax Int  ::= #wlJump ()        [function]
syntax Int  ::= #wlRevert ()      [function]
syntax Int  ::= #wlFallthrough () [function]
syntax Int  ::= #seqOutcome ( Bytes , Int , Int ) [function]
```

- **`#coequalContains(LIST, PACKED)`** (0x2c) — a recursive function that faithfully models
  the Solidity `while (i-- > 0)` loop (Whitelist.sol:120-128). Base case: empty list → `false`.
  Recursive case: at least 10 bytes remain → compare the first 10 bytes to `PACKED` (via
  `Bytes2Int(substrBytes(LIST, 0, 10), BE, Unsigned) ==Int PACKED`) and recurse on the tail.
  The caller passes the post-header slice `substrBytes(ARGS, 2, lengthBytes(ARGS))` so LIST
  always has length `N*10` (the canonical-pitch constraint guarantees this) and the function
  is total on its domain. On CONCRETE lists it reduces to a concrete Bool via the bytes
  lemmas (`semantics/lemmas.k:16-67`), giving genuine conformance evidence
  (`proofs/whitelistcoequal-concrete.k`). On SYMBOLIC lists neither rule's `requires`
  reduces, so the function is STUCK — the honest posture (no false symbolic claim). This
  REPLACES the prior uninterpreted predicate `#coequalWhitelistContains(ARGS, PACKED)`, which
  made every symbolic claim tautological and gave zero conformance evidence.
- **`#blockTimestamp()`** — the chain's `block.timestamp`, mirroring the declaration in
  `opcodes/deadline.k:78`. No defining rule; its value is fixed-but-unknown. The 0x2d rules
  branch on this symbol DIRECTLY: the PRE-LOOP REVERT arm tests `#blockTimestamp() <Int start`
  (mirroring Whitelist.sol:147), and the other three arms pass `#blockTimestamp() -Int start`
  as the `timeLeft` argument to `#seqOutcome`. A concrete claim fixes the timestamp via a
  premise (e.g. `requires #blockTimestamp() ==Int 10`) so the recursion reduces.
- **`#wlJump()`, `#wlRevert()`, `#wlFallthrough()`** — outcome tags for `#seqOutcome`. Each is
  a 0-arity `[function]` that reduces to a literal Int (`0`, `1`, `2`), so the four-arm rule's
  premise `#seqOutcome(...) ==Int #wlJump()` is decidable after the recursion reduces on
  concrete input. (CamelCase rather than SCREAMING_SNAKE_CASE because the K default lexer for
  `#`-prefixed symbols does not accept underscores.)
- **`#seqOutcome(LIST, TIMELEFT, PACKED)`** (0x2d) — a recursive function that faithfully
  models the Solidity `while (i < length)` loop (Whitelist.sol:155-165), INCLUDING the
  time arithmetic. `LIST` is the post-header slice `args.slice(7)` (12-byte entries);
  `TIMELEFT` is `block.timestamp - start` (caller preconditions: ts >= start);
  `PACKED` is `TAKER modInt 2^80`. Per entry: duration = `Bytes2Int(LIST[0:2], BE, Unsigned)`
  (mirroring `duration := shr(240, word)` in `parseWhitelistSequentialIx`, Whitelist.sol:77),
  allowedTaker = `Bytes2Int(LIST[2:12], BE, Unsigned)` (mirroring `allowedTaker :=
  and(shr(160, word), 0xffff...ffff)`, Whitelist.sol:76). Four rules mirror the loop body:
  (1) empty list → `#wlFallthrough()`; (2) address matches → `#wlJump()` (BEFORE duration
  check, exactly as in source); (3) address differs AND `TIMELEFT < duration` → `#wlRevert()`;
  (4) address differs AND `TIMELEFT >= duration` → recurse on the 12-byte tail with
  `TIMELEFT -Int duration`. On CONCRETE lists + a CONCRETE timestamp the recursion reduces
  to a concrete outcome tag via the bytes lemmas (`semantics/lemmas.k:16-67`), giving
  genuine conformance evidence (`proofs/whitelistsequential-concrete.k`). On SYMBOLIC lists
  neither rule's `requires` reduces, so the function is STUCK. This REPLACES the prior two
  uninterpreted Bool predicates (`#sequentialWhitelistJumps`, `#sequentialWhitelistReverts`),
  which made every symbolic claim tautological, gave zero conformance evidence, AND did not
  model the time-aware loop at all.

FALL THROUGH for 0x2d is no longer the negation of two predicates — it is one of the three
explicit outcomes returned by `#seqOutcome`, alongside JUMP and REVERT. The rule's
FALL-THROUGH arm fires when `#seqOutcome(...) ==Int #wlFallthrough()`.

## The 80-bit packing

Both opcodes compute `sender = uint80(uint160(ctx.query.taker))` — the taker's address
TRUNCATED TO ITS LOW 80 BITS. The K model FAITHFULLY preserves this via
`TAKER modInt (2 ^Int 80)`, the same shape used by the 0x2b twin (`opcodes/privateorder.k:92-95`).
The packed taker is passed to every whitelist predicate as `TAKER modInt (2 ^Int 80)`.

This is **not a fidelity gap to close** but a property to preserve. Two addresses sharing
their low 10 bytes are INDISTINGUISHABLE to these opcodes — both pass identically. This is a
DELIBERATE collision-resistance trade-off documented at Whitelist.sol:88-95: mining an 80-bit
address collision costs millions of GPU-years, and the van Oorschot–Wiener birthday attack —
though it can find 80-bit collisions efficiently — requires the attacker to CONTROL BOTH
accounts, so a whitelist bypass is not a security break (the attacker is authorising
themself). See `opcodes/privateorder.md` "The 80-bit packing" for the full trade-off.

## Arm selection — why the Bool predicate, not direct inequality

Even setting aside the loop intractability, the JUMP/REVERT/FALL-THROUGH outcomes cannot be
selected by direct inequality side conditions. The K Haskell backend's SMT encoding does NOT
propagate an inequality premise on an uninterpreted-vs-symbolic comparison into a refutation
of the opposite arm of a multi-arm rule. This was established empirically by the Deadline
subagent (`opcodes/deadline.md:125-156`) and re-confirmed by Gte (`opcodes/gte.md` "Arm
selection"), SupplyShare (`opcodes/supplyshare.md` "Arm selection"), and TxOrigin. The gate
rule at `swapvm.md:177-194` splits on `#balanceOf(...) >Int 0` vs `<=Int 0` and a spec premise
`#balanceOf(...) ==Int 0` selects the REVERT arm — but ONLY because the comparison is to a
CONSTANT (0). The identical shape comparing an uninterpreted function to a SYMBOLIC value
(e.g. `#blockTimestamp() >Int X`) does not exclude the opposite arm.

The Whitelist opcodes would have this limitation doubly:

- The JUMP outcome depends on the joint satisfiability of the address match AND the timestamp
  window — both symbolic.
- The REVERT outcome depends on the timestamp window expiring at a specific entry whose
  address != taker — also symbolic.

The fix — the SAME fix Deadline, Gte, and SupplyShare adopted — is to abstract the branch
condition itself into a free Bool predicate and split on THAT. A spec premise
`#coequalWhitelistContains(ARGS, PACKED)` (implicitly `==Bool true`) selects the 0x2c JUMP arm;
its negation selects the FALL-THROUGH arm. A spec premise `#sequentialWhitelistJumps(...)`
selects the 0x2d JUMP arm; `#sequentialWhitelistReverts(...)` selects the REVERT arm; the
conjunction of both negations selects FALL THROUGH.

The four symbols (`#blockTimestamp`, `#coequalWhitelistContains`, `#sequentialWhitelistJumps`,
`#sequentialWhitelistReverts`) are kept as **independent** uninterpreted terms — no
simplification rule equates a predicate with its conceptual expansion — so the arm-selection
condition stays a single atomic Bool the SMT solver can decide on. This is the proven-working
form for this backend, per the brief's "CRITICAL lesson" cross-referencing Deadline/Gte.

## What the K rules do

`opcodes/whitelists.k` defines a single module `SWAPVM-WHITELISTS` (one module for both
opcodes — K v7 cannot reopen `module SWAPVM` across files) holding **nine rules**:

1. **0x2c JUMP arm** — canonical-pitch ARGS (`lengthBytes(ARGS) >=Int 2` and
   `(lengthBytes(ARGS) -Int 2) modInt 10 ==Int 0`), premise
   `#coequalContains(substrBytes(ARGS, 2, lengthBytes(ARGS)), TAKER modInt 2^80)` evaluating
   to `true`: overwrites `<pc>` with `Bytes2Int(substrBytes(ARGS, 0, 2), BE, Unsigned)`,
   leaves `#run` in `<k>`. The premise is the recursive function evaluation, NOT an
   uninterpreted predicate — so this arm fires for the right reason on concrete lists.
2. **0x2c FALL-THROUGH arm** — same length constraint, premise
   `notBool #coequalContains(substrBytes(ARGS, 2, lengthBytes(ARGS)), ...)`: no-op, inherits
   decode-advanced `<pc>`, leaves `#run` in `<k>`.
3. **0x2c UNMODELLED-ARGS-LENGTH arm** — `lengthBytes(ARGS) <Int 2 orBool
   `(lengthBytes(ARGS) -Int 2) modInt 10 =/=Int 0`: reverts with `"UNMODELLED-ARGS-LENGTH"`.
4. **0x2d PRE-LOOP REVERT arm** — canonical-pitch ARGS (`lengthBytes(ARGS) >=Int 7` and
   `(lengthBytes(ARGS) -Int 7) modInt 12 ==Int 0`), premise
   `#blockTimestamp() <Int Bytes2Int(substrBytes(ARGS, 2, 7), BE, Unsigned)` (ts < start):
   reverts with `"WhitelistAllowedTimeViolation"`, mirroring the top-level check at
   Whitelist.sol:147. This arm is separate from the IN-WINDOW REVERT arm because `#seqOutcome`
   assumes `ts >= start` (its `TIMELEFT` argument is `ts - start` and must be non-negative).
5. **0x2d JUMP arm** — same length constraint + `ts >= start`, premise
   `#seqOutcome(substrBytes(ARGS, 7, lengthBytes(ARGS)), ts - start, TAKER modInt 2^80) ==Int
   #wlJump()`: overwrites `<pc>` with `Bytes2Int(substrBytes(ARGS, 0, 2), BE, Unsigned)`,
   leaves `#run` in `<k>`. The premise is the recursive function evaluation, NOT an
   uninterpreted predicate — so this arm fires for the right reason on concrete lists.
6. **0x2d IN-WINDOW REVERT arm** — same length constraint + `ts >= start`, premise
   `#seqOutcome(...) ==Int #wlRevert()`: reverts with `"WhitelistAllowedTimeViolation"`,
   mirroring Whitelist.sol:163 (`if (timeLeft < duration) revert ...;`).
7. **0x2d FALL-THROUGH arm** — same length constraint + `ts >= start`, premise
   `#seqOutcome(...) ==Int #wlFallthrough()`: no-op, inherits decode-advanced `<pc>`.
8. **0x2d UNMODELLED-ARGS-LENGTH arm** — `lengthBytes(ARGS) <Int 7 orBool
   `(lengthBytes(ARGS) -Int 7) modInt 12 =/=Int 0`: reverts with `"UNMODELLED-ARGS-LENGTH"`.

(Plus the four `#seqOutcome` recursion rules and three outcome-tag simplifications declared
in the same module — these are the function's definition, not instruction-level rules.)

The JUMP arms overwrite `<pc>` (mirroring `pcs = ctx.vm.nextPC` in VM.sol, swapvm.md:138-140),
exactly like Jump (`opcodes/jump.k`). The FALL-THROUGH arms inherit the decode-advanced `<pc>`
and leave it (same posture as Salt, Deadline, Gte, and 0x2b PASS). The REVERT arms clear `<k>`
(swapvm.md:154-156).

### Direct form, concrete conformance

The 0x2c JUMP/FALL-THROUGH arms and the 0x2d JUMP/REVERT/FALL-THROUGH arms no longer branch
on uninterpreted Bool predicates — they branch on recursive functions (`#coequalContains` for
0x2c, `#seqOutcome` for 0x2d) that evaluate the Solidity loops literally, including the
time arithmetic for 0x2d. The benefit mirrors what `opcodes/gte.md` "Direct form, concrete
conformance" records for Gte: a CONCRETE claim (`proofs/whitelistcoequal-concrete.k`,
`proofs/whitelistsequential-concrete.k`) with concrete ARGS and concrete `<taker>` (and, for
0x2d, a concrete `#blockTimestamp()` pinned by premise) makes the recursion reduce to a
concrete Bool / outcome tag via the bytes lemmas, so the rule's arm selection is decided by
the SMT solver against the REAL byte-level match and REAL time-window arithmetic. This IS
conformance evidence — the K proof verifies that for the named inputs, the K model reaches
the same `<pc>` and `<status>` as Solidity's `_whitelistCoequal` / `_whitelistSequential`
body would.

A SYMBOLIC universal claim over arbitrary ARGS does NOT prove in this form (the recursion is
stuck on symbolic bytes), which is the honest posture: the prior symbolic spec/control pairs
(`whitelistcoequal-spec.k`/`-control.k`, `whitelistsequential-spec.k`/`-control.k`) were
tautological under the uninterpreted-predicate form and have been DELETED. The concrete
pairs are the replacement — see the concrete-proof headers for the full rationale.

#### 0x2d-specific fidelity: the address-before-duration order

A non-trivial property the 0x2d recursion preserves is the Solidity rule that the address
match is checked BEFORE the duration check (Whitelist.sol:158-163):
```solidity
if (sender == allowedTaker) { ctx.vm.nextPC = pc; return; }   // checked FIRST
if (timeLeft < duration) revert WhitelistAllowedTimeViolation();  // checked SECOND
```
The `#seqOutcome` JUMP rule fires on `addr == PACKED` alone (no `TIMELEFT` constraint), so a
matching entry JUMPS even when `timeLeft < duration` would otherwise revert. Scenario A of
`proofs/whitelistsequential-concrete.k` exercises exactly this: with `timeLeft=10 <
duration=1000` AND `addr=4660 == taker=4660`, the JUMP outcome is selected, not REVERT. An
inverted order (duration checked first) would REVERT and the proof would fail — covering
this scenario guards against such a bug.

## The canonical-pitch constraint is `>=Int` + `modInt`, not `==Int`

The Solidity constrains nothing about `args.length`. `args.slice(2)` (0x2c) and `args.slice(7)`
(0x2d) silently produce whatever the bytes happen to be; the integer division `list.length / 10`
(or `/ 12`) silently ignores a trailing partial entry. The hazards:

- **A SHORT args** reads a DIFFERENT list than the maker encoded (right-zero-padded by
  Solidity's calldata semantics). On 0x2d this can also desynchronise the start-vs-timestamp
  comparison (`parseWhitelistSequentialStartPC` reads the start bytes at a wrong offset).
- **An OFF-PITCH args** (e.g. 13 bytes for 0x2c, which `length / 10` truncates to one 10-byte
  entry plus 3 ignored bytes) reads a list whose trailing partial is silently dropped. The
  maker's encoded whitelist is silently smaller than they intended.

Neither case reverts on chain. If the model only handled the canonical case and let the rest
fall through to the `[owise]` no-op (swapvm.md:349-351), every such Whitelist would be
SILENTLY DELETED from the model while staying live in production — the worst failure direction
(sound but wrong), the same hazard `swapvm.md:301-324` documents for opcodes `0x23`/`0x90`.

The structural length constraints admit exactly the args lengths whose payload is a whole
number of packed entries after the fixed header:

```k
// 0x2c: 2-byte pc + N*10 bytes
requires lengthBytes(ARGS) >=Int 2
 andBool (lengthBytes(ARGS) -Int 2) modInt 10 ==Int 0

// 0x2d: 2-byte pc + 5-byte start + N*12 bytes
requires lengthBytes(ARGS) >=Int 7
 andBool (lengthBytes(ARGS) -Int 7) modInt 12 ==Int 0
```

Anything else reverts loudly with `"UNMODELLED-ARGS-LENGTH"`, mirroring opcodes `0x23`/`0x90`
in `swapvm.md:319-324` and the twins in `opcodes/jump.k:50-54`, `opcodes/deadline.k:121-126`,
`opcodes/gte.k:142-148`, `opcodes/supplyshare.k:184-191`, `opcodes/txorigin.k:123-124`, and
`opcodes/privateorder.k:115-116`.

**The lower bound is `>=Int`, not `==Int`.** A 0-byte payload (N = 0) is LEGAL on chain:

- 0x2c with `lengthBytes(ARGS) ==Int 2`: the whitelist is always-empty, the loop never
  matches, the opcode FALLS THROUGH.
- 0x2d with `lengthBytes(ARGS) ==Int 7`: no taker is ever whitelisted; revert iff before
  `start + 0`, otherwise fall through.

These are real on-chain configurations. An `==Int 12`/`==Int 7+12k` upper-bound-style
constraint would WRONGLY exclude the empty list. The `>=Int` lower bound plus the `modInt`
pitch constraint are the faithful shape.

## Pad-and-truncate hazard

Same root cause as "The canonical-pitch constraint is `>=Int` + `modInt`" above, but called
out separately because it is the soundness argument for the UNMODELLED-ARGS-LENGTH arm. The
Solidity's `args.slice(N)` and `list.length / K` never revert for a wrong length; the model's
UNMODELLED-ARGS-LENGTH rules do (third rule for 0x2c, eighth rule for 0x2d), so a proof
touching such a Whitelist fails rather than succeeds on a fiction. This is the same pattern
all the other pad-and-truncate-hazard opcodes follow.

## Composition

- **0x2c JUMP arm** — overwrites `<pc>`, leaves `#run` in `<k>`, loop proceeds. Same shape as
  Jump (`opcodes/jump.k`). A positive claim must constrain the program so the jump lands past
  the end (loop-exit rule fires); see `proofs/whitelistcoequal-concrete.k` (scenario A).
- **0x2c FALL-THROUGH arm** — inherits decode-advanced `<pc>`, leaves `#run` in `<k>`, loop
  proceeds. Same shape as Salt/Deadline/Gte PASS arms. A positive claim must terminate
  concretely; see `proofs/whitelistcoequal-concrete.k` (scenario B).
- **0x2d PRE-LOOP REVERT arm** — clears `<k>`, loop halts. Same shape as gate-spec / deadline-
  spec / gte-spec / supplyshare-spec REVERT arms. A positive claim pins `ts < start`
  concretely (e.g. `requires #blockTimestamp() ==Int 10` plus `start > 10` in ARGS).
- **0x2d JUMP arm** — same shape as 0x2c JUMP arm. See `proofs/whitelistsequential-concrete.k`
  (scenario A).
- **0x2d IN-WINDOW REVERT arm** — clears `<k>`, loop halts. Same shape as the PRE-LOOP REVERT
  arm. See `proofs/whitelistsequential-concrete.k` (scenario B).
- **0x2d FALL-THROUGH arm** — same shape as 0x2c FALL-THROUGH arm.

The minimum positive claims (`proofs/whitelistcoequal-concrete.k`, `proofs/whitelistsequential-concrete.k`)
cover the JUMP arm of each opcode (plus, for 0x2d, the IN-WINDOW REVERT arm), with the program
constrained to a single Whitelist instruction so the jump lands past the end and the loop-exit
rule fires on the next step without decoding a tail — exactly the shape `proofs/jump-spec.k`
introduced.

## Fidelity gaps (declared per PLAN.md D3, D4, D5)

These are the elisions a reviewer needs to see written out, not inferred.

1. **The 0x2c byte-level list parse IS now modelled (D4 closed for 0x2c).** The Solidity
   iterates `while (i-- > 0)` over `args.slice(2)`, parsing 10-byte packed addresses via
   `list.parseWhitelistCoequalIx(i)`. The K model now mirrors this loop directly as the
   recursive function `#coequalContains(LIST, PACKED)` (declared and defined in
   `opcodes/whitelists.k` — base case: empty list → `false`; recursive case: compare first
   10 bytes to PACKED, recurse on tail). **Consequence:** on CONCRETE lists the recursion
   reduces to a concrete Bool via the bytes lemmas, so `proofs/whitelistcoequal-concrete.k`
   is genuine conformance evidence — the K proof verifies the actual byte-level match against
   Solidity for fixed inputs, exactly as `proofs/gte-concrete.k` verifies the actual `>=Int`
   comparison. On SYMBOLIC lists neither rule's `requires` reduces, so the function is STUCK
   (not wrong) — the honest posture. This item previously recorded the uninterpreted
   predicate `#coequalWhitelistContains(ARGS, PACKED)` as a D4 gap; that gap is now closed.
   The old symbolic spec/control pair (`whitelistcoequal-spec.k`, `-control.k`) was
   tautological under the predicate form and has been DELETED.

2. **The 0x2d byte-level list parse AND time arithmetic ARE now modelled (D4 closed for
   0x2d).** The Solidity iterates `while (i < length)`, parsing 12-byte (duration, address)
   pairs, comparing each address to `sender`, and walking `timeLeft` from
   `block.timestamp - start` down by each duration until either a match (JUMP) or an in-window
   expiration (REVERT). The K model now mirrors this loop AND its time arithmetic directly as
   the recursive function `#seqOutcome(LIST, TIMELEFT, PACKED)` (declared and defined in
   `opcodes/whitelists.k` — base case: empty list → `#wlFallthrough()`; recursive cases:
   address matches → `#wlJump()`, address differs + `timeLeft < duration` → `#wlRevert()`,
   address differs + `timeLeft >= duration` → recurse on tail with `timeLeft - duration`).
   **Consequence:** on CONCRETE lists + a CONCRETE timestamp the recursion reduces to a
   concrete outcome tag via the bytes lemmas, so `proofs/whitelistsequential-concrete.k` is
   genuine conformance evidence — the K proof verifies the actual byte-level match AND the
   actual time-window arithmetic against Solidity for fixed inputs, exactly as
   `proofs/gte-concrete.k` verifies the actual `>=Int` comparison. On SYMBOLIC lists neither
   rule's `requires` reduces, so the function is STUCK (not wrong) — the honest posture. This
   item previously recorded the uninterpreted predicates `#sequentialWhitelistJumps` /
   `#sequentialWhitelistReverts` as a D4 gap; that gap is now closed. The old symbolic
   spec/control pair (`whitelistsequential-spec.k`, `-control.k`) was tautological under the
   predicate form and has been DELETED.

3. **Mutual exclusivity between the three 0x2d outcomes is enforced by construction.** The
   recursive `#seqOutcome` returns exactly one of `#wlJump()`, `#wlRevert()`, `#wlFallthrough()`
   — the four defining rules have non-overlapping `requires` clauses (empty vs non-empty list,
   addr== vs addr=/=, `timeLeft < dur` vs `timeLeft >= dur`), so for any concrete input
   exactly one fires. This is a STRONGER guarantee than the prior uninterpreted-predicate
   form, where K happily admitted models in which both `#sequentialWhitelistJumps` and
   `#sequentialWhitelistReverts` held simultaneously and specs had to manually assert mutual
   exclusivity (see the deleted `whitelistsequential-spec.k`'s `notBool
   #sequentialWhitelistReverts(...)` guard for the old workaround). No such guard is needed
   in the concrete claims (`proofs/whitelistsequential-concrete.k`) — the recursion itself
   enforces it.

4. **Sub-canonical and off-pitch args unmodelled.** Solidity right-pads short `args` and
   silently ignores off-pitch trailing partials without reverting; the model reverts loudly
   with `"UNMODELLED-ARGS-LENGTH"` for any args whose payload after the fixed header is not a
   whole number of packed entries. This makes the gap loud rather than silent
   (`swapvm.md:314-316`), in the same safe direction chosen for opcodes `0x23`, `0x90`, `0x03`,
   `0x20`, `0x24`, `0x25`, `0x26`, and `0x2b`.

5. **Empty-list outcome preserved.** A 0-byte payload (N = 0) is legal on chain — 0x2c with
   `lengthBytes(ARGS) ==Int 2` is an always-empty whitelist (FALL THROUGH), 0x2d with
   `lengthBytes(ARGS) ==Int 7` reverts iff before `start`, otherwise FALL THROUGH. The model
   admits these via the `>=Int` lower bound, NOT an `==Int` equality. For 0x2c the recursive
   `#coequalContains` reduces to `false` on the empty list (base case), selecting the
   FALL-THROUGH arm directly — no spec assertion needed. For 0x2d the recursive `#seqOutcome`
   reduces to `#wlFallthrough()` on the empty list (base case), selecting the FALL-THROUGH arm
   directly when `ts >= start` (or the PRE-LOOP REVERT arm when `ts < start`) — again no spec
   assertion needed beyond the timestamp pin.

6. **Quote payload opaque.** Like every other revert in this system (PLAN.md D5), the K
   reason is an opaque string token. The real VM carries no error payload for
   `"UNMODELLED-ARGS-LENGTH"` (the model's invention), and for
   `"WhitelistAllowedTimeViolation"` it carries none either (Whitelist.sol:101 declares the
   error with no arguments). The token is enough to state "reverts with
   `WhitelistAllowedTimeViolation`" without modelling ABI error encoding.

7. **`ADMITTED`.** Per the trust model in PLAN.md §5a, every instruction rule starts
   `ADMITTED`. These two are not yet exercised by the conformance harness.

## Integration

`SWAPVM-WHITELISTS` is a sibling module; it does not reopen `module SWAPVM`. To wire it into
the kompile unit, add two lines to `semantics/lemmas.k` (the run harness does this
automatically via the recipe in the brief; these are NOT edits this subagent makes — they are
the recipe the integrator applies):

```k
requires "opcodes/whitelists.k"     // at top of lemmas.k, alongside the other opcode requires
...
module SWAPVM-BYTES-LEMMAS
  imports SWAPVM
  imports SWAPVM-WHITELISTS          // inside the module, alongside the other imports
  ...
endmodule
```

A single `requires` alone is **not** sufficient: K does not auto-import the modules of a
required file into the main module. (See `opcodes/extruction.md` "Integration",
`opcodes/jump.md` "Integration", and the analogous notes on every other sibling opcode file
for the same constraint.) This file uses `requires "../swapvm.md"` — resolving relative to
its own directory — so it kompiles correctly when invoked as `kompile ... lemmas.k` from
`semantics/` without an `-I` flag.

# `0x20` Deadline — formal semantics

Design doc for `semantics/opcodes/deadline.k`. Companion to `swapvm.md` (decode loop),
`opcodes/jump.k` (the closest sibling — fixed-width arg read with `UNMODELLED-ARGS-LENGTH` arm),
`opcodes/revert.k` (the conditional-revert template), `opcodes/salt.k` (the no-op pass-through
template), and the Phase 1 instruction notes (`PHASE1.md`).

## Source

`Controls.sol:129-134`:

```solidity
/// @dev Reverts if the deadline has been reached
/// @param args.deadline | 5 bytes
function _deadline(Context memory ctx, bytes calldata args) internal view {
    uint256 deadline = uint40(bytes5(args));
    require(block.timestamp <= deadline, DeadlineReached(ctx.query.taker, deadline));
}
```

`uint40(bytes5(args))` reads the first 5 bytes of `args` as a big-endian unsigned integer and
truncates to 40 bits, so `deadline` ranges over `[0, 2^40 - 1]` exactly. The `require` reverts with
`DeadlineReached(taker, deadline)` iff `block.timestamp > deadline`; otherwise it returns normally.

The `ctx` parameter is read for the revert payload (`ctx.query.taker`) but is otherwise unused —
no registers are read, none written, and no `setNextPC` is called. At execution time Deadline is a
pure conditional halt: either it reverts (clearing the continuation) or it is a no-op (passing
through to the next instruction).

## What the K rule does

The decode rule (`swapvm.md:143-149`) consumes the `[opcode:1][argsLen:1]` header and advances
`<pc>` by `2 + argsLen` **before** `#exec` fires. So a Deadline instruction with argsLen 5 lands
at `<pc> = 7` after decode. Neither arm of the Deadline rule touches `<pc>` — the value is
inherited from the decode advance and left alone, exactly as the Revert and Salt rules do. This is
the correct posture for an opcode whose Solidity never calls `setNextPC`.

The rule has three arms. The REVERT arm and PASS arm split on the DIRECT comparison
`#blockTimestamp() >Int DL` vs `#blockTimestamp() <=Int DL` — the Solidity-faithful form, no
Bool predicate intermediary (see "Direct form, concrete conformance" below for why the earlier
predicate form was abandoned); the `UNMODELLED-ARGS-LENGTH` arm catches every non-canonical args
length (see "Pad-and-truncate soundness hazard").

```k
rule <k> #exec ( 32 , ARGS ) => #revert("DeadlineReached") ... </k>
     <status> Running </status>
  requires lengthBytes(ARGS) ==Int 5
   andBool #blockTimestamp() >Int Bytes2Int(substrBytes(ARGS, 0, 5), BE, Unsigned)

rule <k> #exec ( 32 , ARGS ) => .K ... </k>
     <status> Running </status>
  requires lengthBytes(ARGS) ==Int 5
   andBool #blockTimestamp() <=Int Bytes2Int(substrBytes(ARGS, 0, 5), BE, Unsigned)
```

The REVERT arm produces `#revert("DeadlineReached")`, which by `swapvm.md:154-156` clears the
continuation and sets `<status> Reverted("DeadlineReached")`. The loop never resumes, so any tail
in the program is unconsumed. The PASS arm leaves `#run` in `<k>` and the loop proceeds to decode
the next instruction — the same posture as Salt (`opcodes/salt.k`).

The truncation to 40 bits is automatic in the modelled case: `Bytes2Int(substrBytes(ARGS, 0, 5),
BE, Unsigned)` on a 5-byte ARGS yields exactly the integer in `[0, 2^40 - 1]` — there is no
higher byte to truncate away. No separate `modInt 2^40` is required.

## Why the rule reads `Bytes2Int(substrBytes(ARGS, 0, 5), ...)`

The Solidity is `uint40(bytes5(args))` — a 5-byte read of the FIRST 5 bytes of `args`. The K
rule mirrors this exactly with `Bytes2Int(substrBytes(ARGS, 0, 5), BE, Unsigned)`. Under the
rule's `lengthBytes(ARGS) ==Int 5` side condition this is equivalent to reading the whole ARGS
(`Bytes2Int(ARGS, BE, Unsigned)`); the substr form is preferred so the rule text matches the
Solidity `bytes5(args)` read one-for-one.

The earlier predicate-form rule used the no-substr form `Bytes2Int(ARGS, BE, Unsigned)` to match
the gate rule's pattern at `swapvm.md:187` and to fire the round-trip lemma in one step. With the
switch to direct comparison, the rule reduces via the bytes simplifications in `lemmas.k` either
way, and the Solidity-mirroring substr form is the clearer choice.

Jump (`opcodes/jump.k`) uses the same substr form `Bytes2Int(substrBytes(ARGS, 0, 2), BE,
Unsigned)` for its 2-byte read. The Deadline substr here is the same pattern at width 5.

## Direct form, concrete conformance — why the predicate `#deadlineExceeded(DL)` was removed

The earlier version of this rule (and of `proofs/deadline-spec.k` / `proofs/deadline-control.k`)
branched on a Bool predicate `#deadlineExceeded(DL)` (conceptually
`#blockTimestamp() >Int DL`), keeping `#blockTimestamp()` declared but unused in the rule. The
motivation was that a SYMBOLIC universal claim `for all DL, premise implies Reverted` did not
prove against a direct-comparison rule whose arms compared an uninterpreted function to a
SYMBOLIC value: the K Haskell backend (v7.1.337, the toolchain in this repo) does not propagate
an inequality premise on an uninterpreted-vs-symbolic comparison into a refutation of the
opposite arm of a two-arm rule. With the direct-comparison rule, a spec whose premise pinned
`#blockTimestamp() >Int DL` still explored the `<=Int DL` PASS arm; the PASS arm did not halt,
the loop ran into a symbolic tail, and the all-path claim stalled with 20+ unexplored branches.
(The same arm-selection limitation was hit by the gte opcode — see `opcodes/gte.md`.) The gate
rule (`swapvm.md:182-193`) avoided this because its arms compared `#balanceOf(...)` to a
**constant** (`>Int 0` vs `<=Int 0`), and constant reasoning IS propagated.

The fix then was to abstract the comparison into a Bool predicate so a spec premise
`#deadlineExceeded(DL)` (implicitly `==Bool true`) selected the REVERT arm directly — and the
symbolic claim proved (`#Top`). **But the proof was TAUTOLOGICAL**: the spec assumed
`#deadlineExceeded(DL)` as a premise and the rule branched on the same predicate, so the proof
established nothing about whether the underlying `>` / `<=` matched Solidity. Worse, krun could
not reduce the predicate (it is uninterpreted), so there was NO conformance evidence at all —
symbolic universality bought at the cost of zero real verification.

The current rule abandons the predicate and branches on the DIRECT comparison
`#blockTimestamp() >Int DL` / `<=Int DL`. This makes the rule Solidity-faithful by construction:
the comparison the rule makes IS the comparison Solidity makes, no abstraction layer in between.
The cost is that the symbolic universal claim no longer proves — the same arm-selection
limitation returns. The compensation is that CONCRETE claims now provide REAL conformance
evidence: with both `#blockTimestamp()` (fixed by a premise, e.g.
`requires #blockTimestamp() ==Int 100`) and DL concrete Ints, the SMT solver decides `>Int` /
`<=Int` directly and arm selection is immediate. The two scenarios in `proofs/deadline-concrete.k`
verify the actual comparison against Solidity for fixed inputs — exactly the verification the
predicate-form symbolic proof could never provide.

### Diagnostic (historical)

The arm-selection limitation was isolated with a minimal reproducer that stripped away all the
decode and bytes machinery. A fake opcode `200` with a 1-byte arg, two rules:

```k
syntax Int ::= #testVal ( Int ) [function, no-evaluators]

rule <k> #exec ( 200 , ARGS ) => #revert("REVERTED") ... </k>
     <status> Running </status>
  requires lengthBytes(ARGS) ==Int 1
   andBool #testVal(Bytes2Int(ARGS, BE, Unsigned)) <=Int 0

rule <k> #exec ( 200 , ARGS ) => .K ... </k>
     <status> Running </status>
  requires lengthBytes(ARGS) ==Int 1
   andBool #testVal(Bytes2Int(ARGS, BE, Unsigned)) >Int 0
```

and a spec premise `#testVal(X) ==Int 0` — **PROVES** (`#Top`). This is the gate structure
exactly: comparison to a constant, premise as a direct equality.

The identical shape but with arms `#testVal(0) >Int Bytes2Int(...)` vs `<=Int Bytes2Int(...)`
and premise `#testVal(0) >Int X` — **FAILS**. Comparison to a symbolic value, premise as an
inequality. The PASS arm is explored and the proof stalls.

That is the limitation the current direct-form rule lives with: a symbolic universal claim over
arbitrary DL does not prove. The concrete claims in `proofs/deadline-concrete.k` are unaffected
and ARE the conformance evidence.

The reproducer was run in-tree (in `opcodes/` and `proofs/`, then removed) against the same
kompiled definition shape the real proof uses, so the result is on the same backend, not a toy.

## Pad-and-truncate soundness hazard (swapvm.md:301-324)

The Solidity constrains nothing about `args.length`. A short `args` is right-zero-padded:
`uint40(bytes5(b"\x01\x02\x03"))` reads `b"\x01\x02\x03\x00\x00"` (after the implicit padding to
`bytes5`) and yields `0x0102030000`, not `0x010203`. A long `args` is silently truncated:
`uint40(bytes5(b"\x01\x02\x03\x04\x05\x06\x07"))` reads only the first 5 bytes and yields
`0x0102030405`. Neither case reverts on chain.

If the model only handled the canonical 5-byte case and let every non-canonical length fall
through to the `[owise]` unknown-opcode no-op (`swapvm.md:349-351`), every such Deadline would be
**silently deleted from the model** while staying live in production — the worst failure
direction, sound but wrong. A real maker program with a length typo at a Deadline would silently
bypass the deadline check on chain, and the model would have nothing to say.

The mitigation follows the pattern already in `swapvm.md:319-324` for opcodes `0x23` and `0x90`,
and the twin at `opcodes/jump.k:50-54`: make the gap **loud instead of silent** by reverting with
`"UNMODELLED-ARGS-LENGTH"` for any non-canonical length. A proof touching such a Deadline then
fails rather than succeeds on a fiction.

```k
rule <k> #exec ( 32 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
  requires lengthBytes(ARGS) =/=Int 5
```

Modelling the pad-and-truncate semantics faithfully — so the rule could be stated over
arbitrary-length `args` and reduce correctly — is Phase 2 work, recorded alongside the same status
for opcodes `0x23`, `0x90`, and `0x03` (Jump).

## Integration

`deadline.k` defines a **sibling module `SWAPVM-DEADLINE`** that imports `SWAPVM`, rather than
reopening `module SWAPVM`. K v7 (the toolchain in this repo) rejects reopening a module across
files with `Module SWAPVM differs from previous declaration`; this is the same constraint that
shaped `stop.k`, `revert.k`, `salt.k`, and `jump.k`. Two lines must be added to
`semantics/lemmas.k`:

1. `requires "opcodes/deadline.k"` at the top (alongside the existing `requires "swapvm.md"` and
   the other opcode `requires`), so K parses the file and `SWAPVM-DEADLINE` is available to import.
2. `imports SWAPVM-DEADLINE` inside `module SWAPVM-BYTES-LEMMAS` (alongside the existing
   `imports SWAPVM` and the other opcode imports), so the Deadline rules — and the
   `#blockTimestamp` / `#deadlineExceeded` syntax — are in scope for every spec that imports
   `SWAPVM-BYTES-LEMMAS` (which is all of them).

A single `requires` alone is **not** sufficient: K does not auto-import the modules of a required
file into the main module. (See `opcodes/jump.md` "Integration", `opcodes/stop.md` "Integration",
and `opcodes/salt.md` "Integration" for the same constraint.) This file uses
`requires "../swapvm.md"` — resolving relative to its own directory — so it kompiles correctly
when invoked as `kompile ... lemmas.k` from `semantics/` without an `-I` flag.

And in `semantics/run-proofs.sh`, add an entry to `SPECS`:

```
'deadline-concrete|prove'      # Deadline concrete conformance: REVERT (ts 100 > dl 50), PASS (ts 50 <= dl 100)
```

## Fidelity gaps (declared per `PLAN.md` D3, D4, D5)

- **`block.timestamp` is abstract, not a concrete env cell.** Per D4, `block.timestamp` is
  modelled as ONE uninterpreted symbol, declared in `deadline.k`:
  - `#blockTimestamp()` — a nullary total function (`[function, no-evaluators]`), the direct
    abstraction of the chain's `block.timestamp`. No defining rule, no cell. Its value is
    fixed-but-unknown, constrained only by spec premises. The rule branches on
    `#blockTimestamp() >Int DL` / `<=Int DL` directly; concrete claims fix the value via a
    premise (e.g. `requires #blockTimestamp() ==Int 100`) and prove cleanly. This is the only
    symbol the current rule uses — the earlier `#deadlineExceeded(DL)` Bool predicate has been
    removed (see "Direct form, concrete conformance").

  Adding a `<timestamp>` cell to `swapvm.md` was explicitly out of scope (six sibling subagents
  depend on `swapvm.md` being untouched); this local declaration achieves the abstraction without
  that coordination cost. The pattern is the same one `#balanceOf` uses for the ERC-20 balance
  oracle in `gate-spec.k:26`.
- **`#blockTimestamp()` is opaque across calls.** The uninterpreted-function model says nothing
  about whether two calls in the same VM run return the same value. In production they do — the
  EVM fixes `block.timestamp` for an entire transaction. The model is strictly weaker. This is
  irrelevant for any proof that mentions `#blockTimestamp()` at most once (the Deadline claims
  do), and it is the right strength for an abstraction boundary: a stronger claim would have to
  be discharged against the EVM, which is out of scope for SwapVM.
- **Symbolic universal claim does not prove (arm-selection limitation).** The direct-comparison
  rule (`#blockTimestamp() >Int DL` vs `<=Int DL`) does not admit a symbolic universal claim
  over arbitrary DL in this backend (see "Direct form, concrete conformance"). This is the
  deliberate trade-off for real conformance evidence via concrete claims. A future fix would
  require either a `<timestamp>` cell with a value the prover can reason about generically, or
  an SMT encoding that propagates inequality premises on uninterpreted-vs-symbolic comparisons
  into arm refutations — both out of scope here.
- **Non-canonical args unmodelled.** Solidity right-pads short `args` and truncates long ones
  without reverting; the model reverts with `"UNMODELLED-ARGS-LENGTH"` for any `args.length`
  other than 5. This makes the gap loud rather than silent (`swapvm.md:314-316`), in the same safe
  direction chosen for opcodes `0x23`, `0x90`, and `0x03`. Recorded here so it is not mistaken for
  an oversight.
- **Revert reason collapsed to a token.** Per D5, the revert reason in the K model is an opaque
  token. The Solidity's `DeadlineReached(ctx.query.taker, deadline)` carries the taker address and
  the deadline value as error payload; the K model collapses this to the string token
  `"DeadlineReached"`. The fidelity gap — the real VM's revert data carries taker and deadline,
  K's does not — mirrors the same gap declared in `opcodes/revert.k` for `InstructionRevert`.
- **`ADMITTED`.** Per the trust model in `PLAN.md` §5a, every instruction rule starts `ADMITTED`.
  This one is exercised by the concrete conformance claims in `proofs/deadline-concrete.k`
  (REVERT and PASS arms) but not by a symbolic universal claim, which does not prove in this form
  (see above).

## Composition

Deadline is **unlike** the gate (`proofs/gate-spec.k`) on the PASS arm and **like** it on the
REVERT arm:

- The REVERT arm halts: `#revert` clears the continuation (`swapvm.md:154-156`), so any tail in
  the program is unconsumed. A positive claim COULD quantify over an arbitrary symbolic `TAIL`
  exactly as `gate-spec.k` does — except that the direct-comparison rule does not admit a symbolic
  universal claim over arbitrary DL in this backend (see "Direct form, concrete conformance").
  The concrete REVERT claim in `proofs/deadline-concrete.k` instead fixes DL=50 and
  `#blockTimestamp()=100` and asserts the exact revert outcome.
- The PASS arm does not halt: it leaves `#run` in `<k>`, so the loop proceeds to decode the byte
  at the next `<pc>`. An arbitrary symbolic tail therefore cannot be the basis of a clean
  terminating claim, for the same reason it cannot in `salt-spec.k` and `jump-spec.k`: with a
  symbolic tail the first byte of the tail is symbolic and no decode rule reduces, so the prover
  gets stuck with a residual indistinguishable from a false claim's. The concrete PASS claim in
  `proofs/deadline-concrete.k` instead makes the program exactly the 7-byte Deadline and lets the
  loop-exit rule (`swapvm.md:100-105`) fire when `<pc> = 7 >= lengthBytes(PGM)`, fixing DL=100 and
  `#blockTimestamp()=50`.

So both arms of the current rule are exercised only by concrete claims, not symbolic ones. The
symbolic-universal story awaits either a `<timestamp>` cell or an SMT-side fix to the
arm-selection limitation (see "Fidelity gaps").

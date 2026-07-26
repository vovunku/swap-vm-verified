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

The rule has three arms. The REVERT arm and PASS arm split on the Bool predicate
`#deadlineExceeded(DEADLINE)` (see "Arm selection" below for why a Bool predicate rather than the
direct `#blockTimestamp() >Int DEADLINE` comparison); the `UNMODELLED-ARGS-LENGTH` arm catches
every non-canonical args length (see "Pad-and-truncate soundness hazard").

```k
rule <k> #exec ( 32 , ARGS ) => #revert("DeadlineReached") ... </k>
     <status> Running </status>
  requires lengthBytes(ARGS) ==Int 5
   andBool #deadlineExceeded(Bytes2Int(ARGS, BE, Unsigned))

rule <k> #exec ( 32 , ARGS ) => .K ... </k>
     <status> Running </status>
  requires lengthBytes(ARGS) ==Int 5
   andBool notBool #deadlineExceeded(Bytes2Int(ARGS, BE, Unsigned))
```

The REVERT arm produces `#revert("DeadlineReached")`, which by `swapvm.md:154-156` clears the
continuation and sets `<status> Reverted("DeadlineReached")`. The loop never resumes, so any tail
in the program is unconsumed. The PASS arm leaves `#run` in `<k>` and the loop proceeds to decode
the next instruction — the same posture as Salt (`opcodes/salt.k`).

The truncation to 40 bits is automatic in the modelled case: `Bytes2Int(ARGS, BE, Unsigned)` on
a 5-byte ARGS yields exactly the integer in `[0, 2^40 - 1]` — there is no higher byte to truncate
away. No separate `modInt 2^40` is required.

## Why the rule reads `Bytes2Int(ARGS, ...)` instead of `Bytes2Int(substrBytes(ARGS, 0, 5), ...)`

The Solidity is `uint40(bytes5(args))` — a 5-byte read. The K rule reads the **whole** ARGS
(`Bytes2Int(ARGS, BE, Unsigned)`), not a substr. The two are semantically equivalent under the
rule's `lengthBytes(ARGS) ==Int 5` side condition (if ARGS is exactly 5 bytes, reading all of it
is the same as reading its first 5 bytes), and the no-substr form matches the gate rule's pattern
at `swapvm.md:187` — the gate reads `Bytes2Int(ARGS, BE, Unsigned)`, not a substr, even though the
Solidity there is `address(bytes20(args))` (a 20-byte read).

The reason to prefer the no-substr form is the round-trip lemma (`lemmas.k:64-67`):
`Bytes2Int(Int2Bytes(N, V, BE), BE, Unsigned)` rewrites to `V` in one step. With a substr, the
double substr (the decode rule extracts ARGS as `substrBytes(PGM, ...)` and the rule would take
`substrBytes(ARGS, 0, 5)`) needs several chained rewrites before the round-trip can fire, and the
extra steps make arm selection less predictable. The no-substr form is what the gate uses and what
this rule uses.

Jump (`opcodes/jump.k`) uses the substr form `Bytes2Int(substrBytes(ARGS, 0, 2), BE, Unsigned)`.
That is fine for Jump because Jump has only **one arm** — there is no sibling arm whose side
condition must be refuted, so the timing of the bytes reduction does not affect arm selection.

## Arm selection — why `#deadlineExceeded(DL)` and not `#blockTimestamp() >Int DL`

`block.timestamp` is an external environment input (no on-chain state for the VM to consult), so
per `PLAN.md` D4 it is abstracted. The natural abstraction is an uninterpreted function
`#blockTimestamp()` (declared here, per the task brief), and the natural Solidity-faithful rule
form branches on `#blockTimestamp() >Int DEADLINE` vs `#blockTimestamp() <=Int DEADLINE`. A spec
premise `#blockTimestamp() >Int DL` OUGHT to select the REVERT arm by contradicting the PASS arm.

**Empirically it does not, in this backend.** The K Haskell backend (v7.1.337, the toolchain in
this repo) does not propagate an inequality premise on an uninterpreted-vs-symbolic comparison
into a refutation of the opposite arm of a two-arm rule. So with the direct-comparison rule, a
spec whose premise pins `#blockTimestamp() >Int DL` still explores the `<=Int DL` PASS arm; the
PASS arm does not halt, the loop runs into a symbolic tail, and the all-path claim stalls with 20+
unexplored branches. The minimal diagnostic is in "Diagnostic" below.

The gate rule (`swapvm.md:182-193`) avoids this because its arms compare `#balanceOf(...)` to a
**constant** (`>Int 0` vs `<=Int 0`), not a symbolic value. Constant reasoning IS propagated:
given `#balanceOf(...) ==Int 0`, the SMT solver refutes `>Int 0` immediately. The deadline
comparison is to a **symbolic** `DEADLINE`, and that case is not handled.

The fix is to abstract the comparison itself into a Bool predicate:

```k
syntax Bool ::= #deadlineExceeded ( Int ) [function, no-evaluators]
```

conceptually `#deadlineExceeded(DL) == (#blockTimestamp() >Int DL)`, and branch on the Bool. The
REVERT arm then requires `#deadlineExceeded(DL)` and the PASS arm requires
`notBool #deadlineExceeded(DL)`. A spec premise `#deadlineExceeded(DL)` (implicitly `==Bool true`)
selects the REVERT arm exactly as `#balanceOf(...) ==Int 0` selects the gate's REVERT arm — a
direct Bool match that the SMT solver decides on without needing to reason through an inequality
on an uninterpreted function.

Both `#blockTimestamp()` and `#deadlineExceeded(DL)` are uninterpreted, both honour D4, and
neither is a cell. They are kept as independent symbols: no simplification rule equates
`#deadlineExceeded(DL)` with `#blockTimestamp() >Int DL`, because if it did, the rule's side
condition would simplify back to the direct comparison and the arm-selection problem would
return. A spec that wants to reason about the timestamp directly can still use `#blockTimestamp()`
in premises about other properties (e.g. "the timestamp is non-negative"); for the
deadline-revert property specifically, the premise goes through `#deadlineExceeded`.

### Diagnostic

The behaviour was isolated with a minimal reproducer that strips away all the decode and bytes
machinery. A fake opcode `200` with a 1-byte arg, three rules:

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

The identical shape but with a Bool predicate
`#deadlineExceeded(Bytes2Int(ARGS, BE, Unsigned))` vs `notBool ...` and premise
`#deadlineExceeded(X)` — **PROVES** (`#Top`). This is the structure the Deadline rule adopts.

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

And in `semantics/run-proofs.sh`, add two entries to `SPECS`:

```
'deadline-spec|prove'           # Deadline reverts when block.timestamp > deadline, any tail
'deadline-control|fail'         # same premises, asserts Running — must fail
```

## Fidelity gaps (declared per `PLAN.md` D3, D4, D5)

- **`block.timestamp` is abstract, not a concrete env cell.** Per D4, `block.timestamp` is
  modelled as TWO uninterpreted symbols, both declared in `deadline.k`:
  - `#blockTimestamp()` — a nullary total function (`[function, no-evaluators]`), the direct
    abstraction of the chain's `block.timestamp`. No defining rule, no cell. Its value is
    fixed-but-unknown, constrained only by spec premises. This is the symbol the task brief asked
    for; it is available for any spec that wants to reason about the timestamp directly.
  - `#deadlineExceeded(DL)` — a Bool predicate (`[function, no-evaluators]`) that the RULE
    branches on, conceptually `#blockTimestamp() >Int DL`. Required because the direct
    `#blockTimestamp() >Int DEADLINE` comparison in a two-arm rule cannot have its arm selection
    driven by an inequality premise in this backend (see "Arm selection"). The two symbols are
    kept independent (no equational simplification between them) so the arm-selection condition
    stays decidable for the SMT solver.

  Adding a `<timestamp>` cell to `swapvm.md` was explicitly out of scope (six sibling subagents
  depend on `swapvm.md` being untouched); these local declarations achieve the abstraction without
  that coordination cost. The pattern is the same one `#balanceOf` uses for the ERC-20 balance
  oracle in `gate-spec.k:26`.
- **`#blockTimestamp()` is opaque across calls.** The uninterpreted-function model says nothing
  about whether two calls in the same VM run return the same value. In production they do — the
  EVM fixes `block.timestamp` for an entire transaction. The model is strictly weaker. This is
  irrelevant for any proof that mentions `#blockTimestamp()` at most once (the Deadline theorems
  do), and it is the right strength for an abstraction boundary: a stronger claim would have to
  be discharged against the EVM, which is out of scope for SwapVM.
- **`#deadlineExceeded(DL)` does not reduce to `#blockTimestamp() >Int DL`.** Conceptually the
  two are equal, but the model deliberately provides no simplification rule equating them, because
  doing so would re-introduce the arm-selection problem this whole structure exists to avoid
  (see "Arm selection"). A spec that constrains both symbols independently (e.g.
  `#blockTimestamp() >Int DL` AND `#deadlineExceeded(DL)`) is making two uncorrelated claims
  about two uninterpreted symbols; if a future proof needs them correlated, that is a lemma to add
  then, with the arm-selection consequence worked out.
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
  This one is not yet exercised by the conformance harness.

## Composition

Deadline is **unlike** the gate (`proofs/gate-spec.k`) on the PASS arm and **like** it on the
REVERT arm:

- The REVERT arm halts: `#revert` clears the continuation (`swapvm.md:154-156`), so any tail in
  the program is unconsumed. A positive claim can quantify over an arbitrary symbolic `TAIL`
  exactly as `gate-spec.k` does. This is what `proofs/deadline-spec.k` does — it pins the
  premise `#deadlineExceeded(DL)` to select the REVERT arm, then quantifies over `TAIL`.
- The PASS arm does not halt: it leaves `#run` in `<k>`, so the loop proceeds to decode the byte
  at the next `<pc>`. An arbitrary symbolic tail therefore cannot be the basis of a clean
  terminating claim, for the same reason it cannot in `salt-spec.k` and `jump-spec.k`: with a
  symbolic tail the first byte of the tail is symbolic and no decode rule reduces, so the prover
  gets stuck with a residual indistinguishable from a false claim's (the failure mode that sank
  the first `negative-control.k` — `proofs/README.md:27-34`). A PASS-arm positive claim must
  instead terminate concretely, e.g. by making the program exactly the 7-byte Deadline and letting
  the loop-exit rule (`swapvm.md:100-105`) fire when `<pc> = 7 >= lengthBytes(PGM)`. The minimum
  positive claim here covers the REVERT arm only; a PASS-arm twin is sketched but not added to
  keep the spec tight.

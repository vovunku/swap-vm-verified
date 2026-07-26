# `0x24` OnlyTakerTokenBalanceGte — formal semantics

## Source

`Controls.sol:158-166`:

```solidity
/// @dev Checks if the taker holds at least a certain amount of tokens
/// @param args.token     | 20 bytes
/// @param args.minAmount | 32 bytes
function _onlyTakerTokenBalanceGte(Context memory ctx, bytes calldata args) internal view {
    address token = address(bytes20(args));
    uint256 minAmount = uint256(bytes32(args.slice(20)));
    uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
    require(balance >= minAmount, TakerTokenBalanceIsLessThanRequired(ctx.query.taker, token, balance, minAmount));
}
```

Opcode `0x24` = 36 decimal. Args layout: `[token:20][minAmount:32]`, total **52 bytes**. Reads
the taker's ERC-20 `balanceOf(token)` and reverts iff `balance < minAmount`; otherwise it is a
pure no-op (writes no register, no `setNextPC`).

`#exec` is fired by the decode loop (swapvm.md:141-149) AFTER the `[opcode:1][argsLen:1]`
header has been consumed and `<pc>` advanced by `2 + argsLen`, exactly mirroring
`pcs := add(pcs, 2); ... pcs := add(pcs, argsLength)` in `VM.sol:133-138`. Gte neither reads nor
writes `<pc>` beyond that, so the rule inherits the already-advanced value and leaves it — the
same posture as Revert, Salt, and Deadline.

## What the K rule does

Three rules in `opcodes/gte.k`:

1. **REVERT arm** — canonical `lengthBytes(ARGS) ==Int 52`, premise `#balanceLtMin(TOK, MIN)`
   (conceptually `#balanceOf(B, TOK, TAKER) <Int MIN`): reverts with
   `"TakerTokenBalanceIsLessThanRequired"`, clears `<k>`, sets `<status>`.
2. **PASS arm** — canonical length, premise `notBool #balanceLtMin(TOK, MIN)`: no-op, leaves
   `#run` in `<k>`, loop proceeds.
3. **UNMODELLED-ARGS-LENGTH arm** — `lengthBytes(ARGS) =/=Int 52`: reverts loudly with
   `"UNMODELLED-ARGS-LENGTH"` so a proof cannot silently succeed on a wrong length.

The token and minAmount are read with

```k
Bytes2Int(substrBytes(ARGS,  0, 20), BE, Unsigned)   // token
Bytes2Int(substrBytes(ARGS, 20, 52), BE, Unsigned)   // minAmount
```

Under `lengthBytes(ARGS) ==Int 52` these are the exact 20- and 32-byte big-endian reads the
Solidity does, and the round-trip lemma (`lemmas.k:64-67`) rewrites each `Bytes2Int(Int2Bytes(...))`
back to the symbolic Int the spec supplies, under the standard width bounds
(`0 <=Int TOK <Int 2^160`, `0 <=Int MIN`).

`<balances>` is consulted via `#balanceOf` (`swapvm.md:171-174`), the existing abstraction
boundary for ERC-20 state (`PLAN.md` D4). Gte reads `#balanceOf(B, token, taker)` — no new
external state is introduced.

## Relationship to `0x23` (OnlyTakerTokenBalanceNonZero)

The gate at `swapvm.md:177-194` (`Controls.sol:140-144`) reverts iff `balance == 0`. Since
balances are non-negative, `balance < 1 <=> balance == 0`, so the gate is exactly Gte with
`minAmount == 1`. Gte is the generalization: an arbitrary on-chain `minAmount` the maker bakes
into the program. The two opcodes share everything else — same `<taker>` / `<balances>` read,
same revert-or-pass structure, same `<pc>` posture — except Gte's args carry an extra 32-byte
`minAmount` after the 20-byte token, and the revert reason differs
(`TakerTokenBalanceIsLessThanRequired` vs `TakerTokenBalanceIsZero`).

## Arm selection — why `#balanceLtMin(TOK, MIN)` and not `#balanceOf(...) <Int MIN`

The gate rule (`swapvm.md:182-193`) splits on `#balanceOf(...) >Int 0` vs `<=Int 0`, and a spec
premise `#balanceOf(...) ==Int 0` selects the REVERT arm — but this works ONLY because the
comparison is to a **constant** (0). The K Haskell backend (v7.1.337, the toolchain in this
repo) propagates constant reasoning about `#balanceOf` immediately.

The Deadline subagent's diagnostic (`opcodes/deadline.md:125-156`) established the failure mode
for the symbolic case. A minimal reproducer with a fake opcode:

```k
syntax Int ::= #testVal ( Int ) [function, no-evaluators]

rule <k> #exec ( 200 , ARGS ) => #revert("REVERTED") ... </k>
  requires lengthBytes(ARGS) ==Int 1 andBool #testVal(0) >Int Bytes2Int(ARGS, BE, Unsigned)

rule <k> #exec ( 200 , ARGS ) => .K ... </k>
  requires lengthBytes(ARGS) ==Int 1 andBool #testVal(0) <=Int Bytes2Int(ARGS, BE, Unsigned)
```

with premise `#testVal(0) >Int X` **fails to prove**: the SMT encoding does not propagate the
inequality premise on an uninterpreted-vs-symbolic comparison into a refutation of the opposite
arm, so the PASS arm is also explored, the PASS arm does not halt, the loop runs into a
symbolic tail, and the all-path claim stalls.

Gte compares `#balanceOf(B, TOK, TAKER)` to a **symbolic** `MIN` (read from args). This is the
exact failure shape. A spec premise `#balanceOf(BALS, TOK, TAKER) <Int MIN` would NOT refute
the `>=Int MIN` PASS arm.

The fix is the same shape Deadline adopted (`opcodes/deadline.k:84-119`): abstract the
comparison itself into a Bool predicate,

```k
syntax Bool ::= #balanceLtMin ( Int , Int ) [function, no-evaluators]
```

conceptually `#balanceLtMin(TOK, MIN) == (#balanceOf(BALS, TOK, TAKER) <Int MIN)`, and branch on
the Bool. The REVERT arm requires `#balanceLtMin(TOK, MIN)` and the PASS arm requires
`notBool #balanceLtMin(TOK, MIN)`. A spec premise `#balanceLtMin(TOK, MIN)` (implicitly
`==Bool true`) then selects the REVERT arm exactly as `#balanceOf(...) ==Int 0` selects the
gate's REVERT arm and `#deadlineExceeded(DL)` selects Deadline's REVERT arm — a direct Bool
match that the SMT solver decides on without needing to reason through an inequality on an
uninterpreted function.

### Why the predicate takes `(TOK, MIN)` and not `(BALS, TOK, TAKER, MIN)`

The rule is keyed on `(TOK, MIN)` — the two values derived from the rule's two `substrBytes`
reads on `ARGS` — not on `(BALS, TOK, TAKER, MIN)`, because `BALS` and `TAKER` are cells whose
identity is fixed by the rule's LHS pattern, and only `(TOK, MIN)` are local to the opcode. The
conceptual identity is `#balanceLtMin(TOK, MIN) == (#balanceOf(BALS, TOK, TAKER) <Int MIN)` for
the `BALS` and `TAKER` in the rule's context. Keeping the predicate's arity at 2 means a spec
premise is written exactly as the rule sees the comparison, with no extra cells to thread
through.

### Two-arm form tried first, per the brief

The task brief asked to try the direct two-arm form first and fall back to the predicate form
if kprove stalled on the positive spec. Given the Deadline diagnostic already in the tree, the
direct form was used as the **starting** rule; the predicate form is what shipped. The direct
form would be:

```k
rule <k> #exec ( 36 , ARGS ) => #revert("TakerTokenBalanceIsLessThanRequired") ... </k>
     ...
  requires lengthBytes(ARGS) ==Int 52
   andBool #balanceOf(B, Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned), TAKER)
           <Int Bytes2Int(substrBytes(ARGS, 20, 52), BE, Unsigned)

rule <k> #exec ( 36 , ARGS ) => .K ... </k>
     ...
  requires lengthBytes(ARGS) ==Int 52
   andBool #balanceOf(B, Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned), TAKER)
           >=Int Bytes2Int(substrBytes(ARGS, 20, 52), BE, Unsigned)
```

— the symbolic-vs-`#balanceOf` shape that the diagnostic shows does not drive arm selection.
The shipped predicate form is the settlement; the direct form is recorded here for the audit
trail and for the day the backend grows the missing SMT propagation.

## Pad-and-truncate soundness hazard (swapvm.md:301-324)

The Solidity constrains nothing about `args.length`. A short `args` is right-zero-padded at
BOTH read sites:

- `address(bytes20(args))` pads a <20-byte args with zero bytes on the right (so e.g. a 10-byte
  args reads as a 20-byte address whose last 10 bytes are zero);
- `bytes32(args.slice(20))` pads a short tail with zero bytes (so e.g. an argsLen of 30 reads
  only 10 bytes at offset 20, then 22 zero bytes, yielding a small minAmount).

A long `args` is silently truncated at both sites (so e.g. an argsLen of 100 reads only bytes
`[0:20]` as the token and bytes `[20:52]` as minAmount, ignoring bytes `[52:100]`). Neither
case reverts on chain.

If the model only handled the canonical 52-byte case and let every non-canonical length fall
through to the `[owise]` unknown-opcode no-op (`swapvm.md:349-351`), every such Gte would be
**silently deleted from the model** while staying live in production — the worst failure
direction, sound but wrong. A real maker program with a length typo at a Gte would silently
bypass the balance check on chain, and the model would have nothing to say.

The mitigation follows the pattern already in `swapvm.md:319-324` for opcodes `0x23` and
`0x90`, and the twins at `opcodes/jump.k:50-54` and `opcodes/deadline.k:121-126`: make the gap
**loud instead of silent** by reverting with `"UNMODELLED-ARGS-LENGTH"` for any non-canonical
length. A proof touching such a Gte then fails rather than succeeds on a fiction.

```k
rule <k> #exec ( 36 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
  requires lengthBytes(ARGS) =/=Int 52
```

Modelling the pad-and-truncate semantics faithfully — so the rule could be stated over
arbitrary-length `args` and reduce correctly — is Phase 2 work, recorded alongside the same
status for opcodes `0x23`, `0x90`, `0x03` (Jump), and `0x20` (Deadline).

## Integration

`gte.k` defines a **sibling module `SWAPVM-GTE`** that imports `SWAPVM`, rather than reopening
`module SWAPVM`. K v7 (the toolchain in this repo) rejects reopening a module across files with
`Module SWAPVM differs from previous declaration`; this is the same constraint that shaped
`stop.k`, `revert.k`, `salt.k`, `jump.k`, and `deadline.k`. Two lines must be added to
`semantics/lemmas.k`:

1. `requires "opcodes/gte.k"` at the top (alongside the existing `requires "swapvm.md"` and
   the other opcode `requires`), so K parses the file and `SWAPVM-GTE` is available to import.
2. `imports SWAPVM-GTE` inside `module SWAPVM-BYTES-LEMMAS` (alongside the existing
   `imports SWAPVM` and the other opcode imports), so the Gte rules — and the `#balanceLtMin`
   syntax — are in scope for every spec that imports `SWAPVM-BYTES-LEMMAS` (which is all of
   them).

A single `requires` alone is **not** sufficient: K does not auto-import the modules of a
required file into the main module. (See `opcodes/jump.md` "Integration",
`opcodes/deadline.md` "Integration" for the same constraint.) This file uses
`requires "../swapvm.md"` — resolving relative to its own directory — so it kompiles correctly
when invoked as `kompile ... lemmas.k` from `semantics/` without an `-I` flag.

And in `semantics/run-proofs.sh`, add two entries to `SPECS`:

```
'gte-spec|prove'                  # Gte reverts when balance < minAmount, any tail
'gte-control|fail'                # same premises, asserts Running — must fail
```

## Fidelity gaps (declared per `PLAN.md` D3, D4, D5)

- **`#balanceLtMin(TOK, MIN)` does not reduce to `#balanceOf(B, TOK, TAKER) <Int MIN`.**
  Conceptually the two are equal, but the model deliberately provides no simplification rule
  equating them, because doing so would re-introduce the arm-selection problem this whole
  structure exists to avoid (see "Arm selection"). A spec that constrains both symbols
  independently (e.g. `#balanceOf(BALS, TOK, TAKER) <Int MIN` AND `#balanceLtMin(TOK, MIN)`)
  is making two uncorrelated claims about two uninterpreted symbols; if a future proof needs
  them correlated, that is a lemma to add then, with the arm-selection consequence worked out.
  This is the same trade-off Deadline made with `#deadlineExceeded` vs `#blockTimestamp`
  (`opcodes/deadline.md:239-245`).
- **Non-canonical args unmodelled.** Solidity right-pads short `args` and truncates long ones
  without reverting; the model reverts with `"UNMODELLED-ARGS-LENGTH"` for any `args.length`
  other than 52. This makes the gap loud rather than silent (`swapvm.md:314-316`), in the same
  safe direction chosen for opcodes `0x23`, `0x90`, `0x03`, and `0x20`. Recorded here so it is
  not mistaken for an oversight.
- **Revert reason collapsed to a token.** Per D5, the revert reason in the K model is an
  opaque token. The Solidity's `TakerTokenBalanceIsLessThanRequired(ctx.query.taker, token,
  balance, minAmount)` carries the taker address, token, balance, and minAmount as error
  payload; the K model collapses this to the string token
  `"TakerTokenBalanceIsLessThanRequired"`. The fidelity gap — the real VM's revert data carries
  taker, token, balance, and minAmount, K's does not — mirrors the same gap declared in
  `opcodes/revert.k` for `InstructionRevert` and in `opcodes/deadline.md:251-255` for
  `DeadlineReached`.
- **`ADMITTED`.** Per the trust model in `PLAN.md` §5a, every instruction rule starts
  `ADMITTED`. This one is not yet exercised by the conformance harness.

## Composition

Gte is **like** the gate (`proofs/gate-spec.k`) on the REVERT arm and **unlike** it on the
PASS arm:

- The REVERT arm halts: `#revert` clears the continuation (`swapvm.md:154-156`), so any tail in
  the program is unconsumed. A positive claim can quantify over an arbitrary symbolic `TAIL`
  exactly as `gate-spec.k` and `deadline-spec.k` do. This is what `proofs/gte-spec.k` does —
  it pins the premise `#balanceLtMin(TOK, MIN)` to select the REVERT arm, then quantifies over
  `TAIL`.
- The PASS arm does not halt: it leaves `#run` in `<k>`, so the loop proceeds to decode the
  byte at the next `<pc>`. An arbitrary symbolic tail therefore cannot be the basis of a clean
  terminating claim, for the same reason it cannot in `salt-spec.k`, `jump-spec.k`, and
  `deadline-spec.k`: with a symbolic tail the first byte of the tail is symbolic and no decode
  rule reduces, so the prover gets stuck with a residual indistinguishable from a false claim's
  (the failure mode that sank the first `negative-control.k` — `proofs/README.md:27-34`). A
  PASS-arm positive claim must instead terminate concretely, e.g. by making the program exactly
  the 54-byte Gte and letting the loop-exit rule (`swapvm.md:100-105`) fire when
  `<pc> = 54 >= lengthBytes(PGM)`. The minimum positive claim here covers the REVERT arm only;
  a PASS-arm twin is sketched but not added to keep the spec tight.

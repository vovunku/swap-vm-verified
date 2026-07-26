# `0x30` JumpIfDirection, `0x31` JumpIfTokenIn, `0x32` JumpIfTokenOut — formal semantics

Design doc for `semantics/opcodes/jumps.k`. The three conditional twins of `0x03` Jump
(`opcodes/jump.k`). Companion to `swapvm.md` (decode loop), `opcodes/jump.md` (unconditional
twin), `opcodes/salt.md` (no-op sibling), and the Phase 1 instruction notes (`PHASE1.md`).

## Sources

All three from `src/instructions/Controls.sol:95-127`:

```solidity
// 0x30 JumpIfDirection — Controls.sol:95-103
/// @dev Jumps if swap direction matches the expected one
function _jumpIfDirection(Context memory ctx, bytes calldata args) internal pure {
    bool expectedDirection = bytes1(args) != 0;
    bool swapDirection = ctx.query.tokenIn < ctx.query.tokenOut;
    if (expectedDirection == swapDirection) {
        uint256 nextPC = uint16(bytes2(args.slice(1)));
        ctx.setNextPC(nextPC);
    }
}

// 0x31 JumpIfTokenIn — Controls.sol:105-115
/// @param args.token  | 20 bytes
/// @param args.nextPC | 2 bytes (uint16)
function _jumpIfTokenIn(Context memory ctx, bytes calldata args) internal pure {
    address token = address(bytes20(args));
    if (token == ctx.query.tokenIn) {
        uint256 nextPC = uint16(bytes2(args.slice(20)));
        ctx.setNextPC(nextPC);
    }
}

// 0x32 JumpIfTokenOut — Controls.sol:117-127
/// @param args.token  | 20 bytes
/// @param args.nextPC | 2 bytes (uint16)
function _jumpIfTokenOut(Context memory ctx, bytes calldata args) internal pure {
    address token = address(bytes20(args));
    if (token == ctx.query.tokenOut) {
        uint256 nextPC = uint16(bytes2(args.slice(20)));
        ctx.setNextPC(nextPC);
    }
}
```

`setNextPC` (`VM.sol:94-96`) is a one-line store into `ctx.vm.nextPC`. `runLoop`
(`VM.sol:118-149`) is `while (pcs < length)` and, after dispatch, sets `pcs = ctx.vm.nextPC`.
So a taken conditional jump's effect is to overwrite whatever the loop's `pcs := add(pcs, 2);
pcs := add(pcs, argsLength)` just stored — identical to the unconditional Jump (`opcodes/jump.md`
covers this in full). A not-taken conditional jump is a pure no-op: the Solidity has no `else`
branch, so `ctx.vm.nextPC` retains the decode-advanced value and the loop falls through.

## Arg layouts

| Opcode | Name              | Total | Layout                                          |
|--------|-------------------|-------|-------------------------------------------------|
| 0x30   | JumpIfDirection   | 3 B   | `[expectedDirection:1][nextPC:2 BE uint16]`     |
| 0x31   | JumpIfTokenIn     | 22 B  | `[token:20 BE][nextPC:2 BE uint16]`             |
| 0x32   | JumpIfTokenOut    | 22 B  | `[token:20 BE][nextPC:2 BE uint16]`             |

`bytes1(args) != 0` (0x30) reads the first byte; nonzero is `true`. `address(bytes20(args))`
(0x31/0x32) reads the first 20 bytes big-endian. `uint16(bytes2(args.slice(N)))` reads 2 bytes
big-endian and truncates to 16 bits. As in `opcodes/jump.k`, the truncation is automatic and
exact on the canonical 2-byte slice — `Bytes2Int(substrBytes(ARGS, N, N+2), BE, Unsigned)`
yields exactly an integer in `[0, 65535]`, so no separate `modInt 65536` is required.

## Conditions

| Opcode | Condition (jump iff)                                                | Source                       |
|--------|---------------------------------------------------------------------|------------------------------|
| 0x30   | `(ARGS[0] =/=Int 0) ==Bool (tokenIn <Int tokenOut)`                 | Controls.sol:97-99           |
| 0x31   | `Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned) ==Int tokenIn`   | Controls.sol:110-111         |
| 0x32   | `Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned) ==Int tokenOut`  | Controls.sol:121-123         |

`swapDirection` (Controls.sol:98) is `tokenIn < tokenOut` and matches the orientation choice in
`StaticBalances` (`0x90`, swapvm.md:198-213) and `LimitSwap` (`0x53`, swapvm.md:252-298). The
direction is a property of the *query*, not the program — a maker writes a JumpIfDirection to
branch on which leg of an oriented market they are in.

## What the K rules do

The decode rule (`swapvm.md:143-149`) consumes the `[opcode:1][argsLen:1]` header and advances
`<pc>` by `2 + argsLen` **before** `#exec` fires. A conditional jump that takes its branch must
*overwrite* the already-advanced `<pc>` — exactly as `pcs = ctx.vm.nextPC` overwrites the
advanced `pcs` in the Solidity. **`swapvm.md:138-140` states this directly.** This is the single
decisive difference between a correct jump arm and a no-op: a rule that left the advanced `<pc>`
in place would model a not-taken branch (i.e. would model Salt on the taken branch). The
opposite error — making the not-taken arm write `<pc>` — has no analogue in the Solidity and
would invent control flow.

The jump arm uses `<pc> _ => Bytes2Int(substrBytes(ARGS, N, N+2), BE, Unsigned) </pc>` to
discard the decode-advanced value and install the target. The fall-through arm omits any `<pc>`
cell write (`=> .K` with no `<pc>` mention), leaving the decode-advanced value in place.

The `<status> Running </status>` guard mirrors `opcodes/jump.k` (line 47) and prevents a
conditional jump from firing after a prior Revert, matching the loop rule's own guard
(swapvm.md:103).

### Arm selection

For 0x30, the two arms use `==Bool` and `=/=Bool` side conditions on
`(ARGS [ 0 ] =/=Int 0)` vs `(TIN <Int TOUT)`. The inner comparison `TIN <Int TOUT` is between
two `<query>` cell variables, which the Haskell backend branches on natively (the
Deadline/Gte limitation was specifically about uninterpreted *function* calls vs symbolic
values, not about cell-variable comparisons).

For 0x31/0x32, the jump arm uses a `TIN ==Int Bytes2Int(substrBytes(ARGS, 0, 20), BE,` `Unsigned)` side condition (`TOUT ==Int ...` for 0x32). The first draft put the
`Bytes2Int(substrBytes(...))` term directly in the `<tokenIn>` / `<tokenOut>` cell pattern in
the LHS to force pattern unification, but kompile rejects that with "Illegal function symbol ... on
LHS of rule": K forbids hooked function symbols (`substrBytes`, `Bytes2Int`) inside cell
patterns on the LHS of a semantic rule. The side-condition form is logically equivalent — the
Haskell backend discharges on the `==Int` condition rather than on pattern unification, and the
round-trip lemma in `lemmas.k` (`Bytes2Int(Int2Bytes(N, V, BE), BE, Unsigned) => V`) reduces
the term to the integer value when ARGS is a concatenation headed by `Int2Bytes(20, TOK, BE)`.
The fall-through arm uses the cell variable form (`<tokenIn> TIN </tokenIn>`) plus a `=/=Int`
side condition, so the two arms are exhaustive and mutually exclusive for canonical-length ARGS.

The direct two-arm form (side condition on the jump arm, `=/=Int` on the fall-through arm)
compiled and proved for all three opcodes — no Bool-predicate fallback was needed. (The fallback,
had it been required, would have been a per-opcode predicate like
`#jumpIfTokenInHolds(ARGS, TIN)` placed in the jump arm's `requires` and negated in the
fall-through arm's `requires`, documented here.)

## Pad-and-truncate soundness hazard (swapvm.md:301-324)

The Solidity constrains nothing about `args.length`. `bytes1(args)` right-zero-pads a short
args and truncates a long one. `address(bytes20(args))` does the same to 20 bytes. `args.slice`
in the EVM is a `calldataload`-style read that also implicitly pads/truncates. None of these
revert.

If the model only handled the canonical lengths (3 for 0x30, 22 for 0x31/0x32) and let every
non-canonical length fall through to the `[owise]` unknown-opcode no-op (swapvm.md:349-351),
every such conditional jump would be **silently deleted from the model** while staying live in
production — the worst failure direction, sound but wrong. A maker program with a length typo at
a JumpIfDirection would silently re-route execution on chain, and the model would have nothing
to say.

The mitigation follows `swapvm.md:319-324` for opcodes `0x23` and `0x90` and the analogous arm
in `opcodes/jump.k`: make the gap **loud instead of silent** by reverting with
`"UNMODELLED-ARGS-LENGTH"` for any non-canonical length. A proof touching such an instruction
then fails rather than succeeds on a fiction.

```k
rule <k> #exec ( 48 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
  requires lengthBytes(ARGS) =/=Int 3

rule <k> #exec ( 49 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
  requires lengthBytes(ARGS) =/=Int 22

rule <k> #exec ( 50 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
  requires lengthBytes(ARGS) =/=Int 22
```

Modelling the pad-and-truncate semantics faithfully is Phase 2 work, in the same status as for
`0x03`, `0x23`, and `0x90`.

## Integration

`jumps.k` defines a **sibling module `SWAPVM-JUMPS`** that imports `SWAPVM`, rather than
reopening `module SWAPVM`. K v7 (the toolchain in this repo, v7.1.337) rejects reopening a
module across files with `Module SWAPVM differs from previous declaration`; this is the same
constraint that shaped `opcodes/jump.k`, `opcodes/stop.k`, `opcodes/revert.k`, and
`opcodes/salt.k`. Two lines must be added to `semantics/lemmas.k`:

1. `requires "opcodes/jumps.k"` at the top (alongside the existing `requires "swapvm.md"` and
   the other opcode `requires`), so K parses the file and `SWAPVM-JUMPS` is available to import.
2. `imports SWAPVM-JUMPS` inside `module SWAPVM-BYTES-LEMMAS` (alongside the existing
   `imports SWAPVM` and the other opcode imports), so the rules are in scope for every spec
   that imports `SWAPVM-BYTES-LEMMAS` (which is all of them).

A single `requires` alone is **not** sufficient: K does not auto-import the modules of a
required file into the main module. (See `opcodes/jump.md` "Integration" and `opcodes/salt.md`
"Integration" for the same constraint.) This file uses `requires "../swapvm.md"` — resolving
relative to its own directory — so it kompiles correctly when invoked as
`kompile ... lemmas.k` from `semantics/` without an `-I` flag.

## Fidelity gaps (declared per `PLAN.md` D3, D5)

- **Non-canonical args unmodelled.** Solidity right-pads short `args` and truncates long ones
  without reverting; the model reverts with `"UNMODELLED-ARGS-LENGTH"` for any `args.length`
  other than the canonical 3 (0x30) or 22 (0x31/0x32). This makes the gap loud rather than silent
  (swapvm.md:314-316), in the same safe direction chosen for opcodes `0x03`, `0x23`, and `0x90`.
- **`ADMITTED`.** Per the trust model in `PLAN.md` §5a, every instruction rule starts `ADMITTED`.
  These three are not yet exercised by the conformance harness.
- **No `Reverted` arm for the canonical case.** None of the three opcodes reverts on its own —
  the Solidity has no `require`, no `revert`, no bounds check of its own. (A taken jump landing
  past the end of the program is handled by the loop-exit rule swapvm.md:100-105, not by these
  rules.) A false `Reverted` arm is the subject of the three `*-control.k` proof files, which
  are supposed to fail.

## Composition

Like Jump (`opcodes/jump.md` "Composition") and unlike the gate (`proofs/gate-spec.k`), Stop
(`proofs/stop-spec.k`), and Revert (`proofs/revert-spec.k`) theorems, the conditional jumps do
**not** halt on their taken branch — they leave `#run` in `<k>`, so the loop proceeds to decode
the byte at the *jumped-to* `<pc>`. An arbitrary symbolic tail therefore cannot be the basis of
a clean terminating claim: after the branch fires, the loop tries to decode `TAIL[0]` (wherever
the jump landed), and with a symbolic target the prover cannot determine where execution lands.

The honest shape of a positive claim is to constrain `TGT` concretely in `[0, 65535]` and *not*
include an arbitrary tail that needs decoding — instead let the program terminate at the
jumped-to `<pc>` because the program is exactly the single instruction (so the loop-exit rule
swapvm.md:100-105 fires when `<pc>` equals `TGT >= lengthBytes(PGM)`). The positive specs
`proofs/jumpifdirection-spec.k`, `proofs/jumpiftokenin-spec.k`, `proofs/jumpiftokenout-spec.k`
state that. The negative controls `proofs/jumpifdirection-control.k`,
`proofs/jumpiftokenin-control.k`, `proofs/jumpiftokenout-control.k` assert the wrong post-jump
`<pc>` (the post-decode value, not the jumped-to value) and must fail — the sensitivity twins
of the respective specs.

### Program lengths and post-decode pcs

| Opcode | Header | Args | Program length | Post-decode pc | Spec TGT lower bound | Control TGT lower bound (strict) |
|--------|--------|------|----------------|----------------|----------------------|----------------------------------|
| 0x30   | 2 B    | 3 B  | 5              | 5              | `5 <=Int TGT`        | `5 <Int TGT`                     |
| 0x31   | 2 B    | 22 B | 24             | 24             | `24 <=Int TGT`       | `24 <Int TGT`                    |
| 0x32   | 2 B    | 22 B | 24             | 24             | `24 <=Int TGT`       | `24 <Int TGT`                    |

The strict lower bound on the control is what makes the false conclusion genuinely false: if
`TGT` could equal the post-decode pc, then the jump landing on the program boundary would
*coincidentally* satisfy the wrong conclusion and the control would pass — defeating its
purpose as a sensitivity check. This mirrors jump-control.k's `4 <Int TGT` vs jump-spec.k's
`4 <=Int TGT`.

# `0x01` Revert — formal semantics

Design doc for `semantics/opcodes/revert.k`. Companion to `swapvm.md` (decode loop),
`opcodes/stop.md` (sibling opcode), and the Phase 1 instruction notes (`PHASE1.md`).

## Source

`Controls.sol:84-87`:

```solidity
/// @dev Unconditional revert with specified reason encoded
function _revert(Context memory, bytes calldata args) internal pure {
    revert InstructionRevert(args);
}
```

`InstructionRevert` is declared at `Controls.sol:65`:

```solidity
error InstructionRevert(bytes);
```

So the revert carries the raw `args` bytes as its payload — the maker encodes whatever reason
they want. This is **unlike every other revert in the system**: `TakerTokenBalanceIsZero`,
`DeadlineReached`, etc. carry a *fixed* 4-byte selector plus strongly-typed fields. Here the
payload is user-supplied opaque bytes.

The function reads no register and writes none. It never returns control to `runLoop`: the
Solidity `revert` unwinds the call, and `runLoop` (`VM.sol:118-149`) is inside the reverted
frame.

## What the K rule does

The decode rule (`swapvm.md:143-149`) consumes the `[opcode:1][argsLen:1]` header and advances
`<pc>` by `2 + argsLen` **before** `#exec` fires. Revert does not overwrite `<pc>` (unlike
Jump and Stop), so the advanced value is inherited.

```k
rule <k> #exec ( 1 , _ ) => #revert("InstructionRevert") ... </k>
     <status> Running </status>
```

`#revert(MSG) ~> _ => .K` (`swapvm.md:154-156`) then clears the continuation *and* sets
`<status> Reverted(MSG)`. The loop never resumes: there is no `#run` left in `<k>` to step.
This is exactly the Solidity `revert` unwinding the frame.

Revert reads no register (the `Context memory` parameter is unnamed in the source) and its
`args` are carried as the error payload rather than consulted, so the rule's `ARGS` cell is a
wildcard.

## D5 modeling decision — option (a)

`InstructionRevert(args)` carries the raw args bytes, so the reason to feed `#revert` admits
three options:

- **(a)** Drop the payload, model as `#revert("InstructionRevert")`.
- **(b)** Preserve the payload stringified: `#revert("InstructionRevert:" +String ...)`.
- **(c)** Declare a distinct reason per distinct ARGS via a structural fingerprint.

**Choice: (a).** Justification in one sentence: it is consistent with `PLAN.md` D5's "reasons
are opaque tokens" and with how every other revert in `swapvm.md` is modelled
(`"TakerTokenBalanceIsZero"`, `"RunLoopExceedProgramLength"`, `"SetBalancesExpectZeroBalances"`,
etc. — all fixed tokens with their ABI fields payloads dropped).

Why not (b): K's standard library `BYTES` module does not ship a `Bytes2String` that decodes
raw byte payloads as UTF-8 (the maker's `args` need not be valid UTF-8 at all). Inventing one
would add a trusted function whose only purpose is to carry data the proof never reasons about.

Why not (c): a structural fingerprint would force every spec to case-split on `ARGS` even
though the *only* property of interest — "this program reverts" — does not depend on the
payload. It would also break the analogue of the gate theorem: the value of stating a claim
over a *symbolic* tail is that the tail cannot affect the conclusion.

## Fidelity gaps (declared per `PLAN.md` D3, D5)

- **Payload dropped.** The real VM's revert data is `keccak256("InstructionRevert(bytes)")[:4]
  ++ abi_encode(args)`. K's `<status> Reverted("InstructionRevert")` carries the opcode's
  *name* only. Observable by a theorem that pins revert data — no current claim does. The
  maker's reason encoding is an abstraction-boundary concern (D4): it is the maker's
  off-chain choice and lives outside the registers this model tracks.
- **`ADMITTED`.** Per the trust model in `PLAN.md` §5a, every instruction rule starts
  `ADMITTED`. This one is not yet exercised by the conformance harness.
- **No `Running` branch.** Revert is unconditional — unlike `0x23`
  (OnlyTakerTokenBalanceNonZero) there is no guard, so the rule has a single arm. A false
  `Running` arm is the subject of `proofs/revert-control.k`, which is supposed to fail.

## Integration

`revert.k` defines a **sibling module `SWAPVM-REVERT`** that imports `SWAPVM`, rather than
reopening `module SWAPVM`. K v7 (the toolchain in this repo, v7.1.337) rejects reopening a
module across files with `Module SWAPVM differs from previous declaration`. Two lines must be
added to `semantics/lemmas.k`:

1. `requires "opcodes/revert.k"` at the top (alongside the existing `requires "swapvm.md"`
   and `requires "opcodes/stop.k"`), so K parses the file and `SWAPVM-REVERT` is available to
   import.
2. `imports SWAPVM-REVERT` inside `module SWAPVM-BYTES-LEMMAS` (alongside the existing
   `imports SWAPVM` and `imports SWAPVM-STOP`), so the Revert rule is in scope for every spec
   that imports `SWAPVM-BYTES-LEMMAS` (which is all of them).

A single `requires` alone is **not** sufficient: K does not auto-import the modules of a
required file into the main module. (See `opcodes/stop.md` "Integration" for the same
constraint on Stop.)

## Composition

Revert with an arbitrary tail is the strict analogue of the gate theorem
(`proofs/gate-spec.k`) and the Stop theorem (`proofs/stop-spec.k`): an early-halting
instruction makes the tail irrelevant. The positive spec `proofs/revert-spec.k` states that
for `b"\x01\x00" +Bytes TAIL`, status ends `Reverted("InstructionRevert")` and the tail never
affects execution. As with the gate and Stop theorems, the tail being symbolic is the entire
value-add — the conformance suite can only sample it. The negative control
`proofs/revert-control.k` is the sensitivity twin.

# `0x00` Stop — formal semantics

Design doc for `semantics/opcodes/stop.k`. Companion to `swapvm.md` (decode loop) and the
Phase 1 instruction notes (`PHASE1.md`).

## Source

`Controls.sol:89-93`:

```solidity
/// @dev Unconditional succesful execution stop
function _stop(Context memory ctx, bytes calldata) internal pure {
    // VM has nothing to execute out of program bounds
    ctx.setNextPC(type(uint256).max);
}
```

`setNextPC` (`VM.sol:94-96`) is a one-line store into `ctx.vm.nextPC`. `runLoop`
(`VM.sol:118-149`) is `while (pcs < length)` and, after dispatch, sets `pcs = ctx.vm.nextPC`.
Setting `nextPC` to `type(uint256).max` therefore makes `pcs < length` false on the next
iteration and the loop falls through. Execution ends with status **`Running`** — not
`Reverted`, not `Settled` (settlement happens outside `runLoop`, per `swapvm.md` lines 7-9).

## What the K rule does

The decode rule (`swapvm.md:143-149`) consumes the `[opcode:1][argsLen:1]` header and advances
`<pc>` by `2 + argsLen` **before** `#exec` fires. Stop leaves this already-advanced `<pc>` in
place (it does not call `setNextPC` in the way that matters for the model — see below) and
instead clears the continuation directly:

```k
rule <k> #exec ( 0 , _ ) ~> _ => .K </k>
     <status> Running </status>
```

The `~> _ => .K` clears the whole continuation, mirroring exactly what `#revert` does
(`swapvm.md:154-156`). The Solidity sets `nextPC = type(uint256).max` and lets `runLoop`'s
`while (pcs < length)` fall through on the NEXT iteration. The obvious K analogue would be to
write a sentinel `<pc>` (e.g. `2^256`) and let the loop-exit rule (`swapvm.md:100-105`) fire
next step — but with a symbolic program length, that forces the prover to discharge every
other decode rule's side conditions against `2^256 +Int ...`, which explodes into 24+
unexplored branches and stalls (observed during integration of the core control flow group).
Clearing `<k>` directly is the observationally-equivalent shortcut: the on-chain effect of
"loop exits, status stays `Running`" is captured in one step. `<pc>` is left at the
post-decode value (2 for argsLen 0), exactly as the Revert twin leaves it (`opcodes/revert.k`,
`proofs/revert-spec.k:28`). The Solidity max-pc value is an implementation detail unobservable
to any proof that does not pin the exact pc word.

Stop ignores its args entirely (`Controls.sol:90` declares the `bytes calldata` parameter and
never reads it), so the rule's `ARGS` cell is a wildcard.

## Integration

`stop.k` defines a **sibling module `SWAPVM-STOP`** that imports `SWAPVM`, rather than
reopening `module SWAPVM`. K v7 (the toolchain in this repo, v7.1.337) rejects reopening a
module across files with `Module SWAPVM differs from previous declaration`; the task brief's
shape was refined accordingly. Two lines must be added to `semantics/lemmas.k`:

1. `requires "opcodes/stop.k"` at the top (alongside the existing `requires "swapvm.md"`),
   so K parses the file and `SWAPVM-STOP` is available to import.
2. `imports SWAPVM-STOP` inside `module SWAPVM-BYTES-LEMMAS` (alongside the existing
   `imports SWAPVM`), so the Stop rule and the `#stopSentinel()` symbol are in scope for
   every spec that imports `SWAPVM-BYTES-LEMMAS` (which is all of them).

A single `requires` alone is **not** sufficient: K does not auto-import the modules of a
required file into the main module. (If a future K version restores cross-file module
reopening, the rule could be moved back into `module SWAPVM` and only the `requires` would
be needed — see the comment at the top of `stop.k`.)

## Fidelity gaps (declared per `PLAN.md` D3, D5)

- **Literal `nextPC` value not modelled.** The Solidity writes `type(uint256).max` into
  `ctx.vm.nextPC`; the K rule leaves `<pc>` at the post-decode value and clears `<k>` directly.
  The on-chain effect ("loop exits, status stays `Running`") is preserved exactly; the literal
  pc word is not. Observable only by a theorem that pins `<pc>` to a specific bit pattern
  after Stop — which no current claim does (`stop-spec.k` pins `<pc>` to the post-decode value
  `2`). No program can read `pcs` after `runLoop` returns, so the gap is silent on-chain.
  Recorded here, not in a comment only.
- **`Running`, not `Settled`.** The Solidity returns `(amountIn, amountOut)` from `runLoop`;
  what makes that "settled" lives in the caller, outside this model (`swapvm.md:7-9`). K
  therefore ends in `Running`, matching the model's loop-exit rule. A claim that says "Stop
  ends `Settled`" would be vacuous: no rule produces `Settled` (proofs/README.md).
- **`ADMITTED`.** Per the trust model in `PLAN.md` §5a, every instruction rule starts
  `ADMITTED`. This one is not yet exercised by the conformance harness.

## Why no `Reverted` branch

Stop never reverts — the Solidity has no `require`, no `revert`, no bounds check beyond the
generic `pcs > length` one (which is satisfied trivially because `2^256 - 1` overflows the
loop *downward*: `pcs < length` is simply false). The rule therefore has a single arm. A
false `Reverted` arm is the subject of `proofs/stop-control.k`, which is supposed to fail.

## Composition

Stop with an arbitrary tail is the analogue of the gate theorem (`proofs/gate-spec.k`): the
instruction halts the VM before the tail is decoded, so the tail is irrelevant. The positive
spec `proofs/stop-spec.k` states that for `b"\x00\x00" +Bytes TAIL`, status ends `Running`
and the tail never affects execution. As with the gate, the tail being symbolic is the entire
value-add — the conformance suite can only sample it.

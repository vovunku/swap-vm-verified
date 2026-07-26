# `0x42` InvalidateTokenOut — formal semantics

## Source

`Invalidators.sol:_invalidateTokenOut1D` (lines 122-135):

```solidity
/// @notice Tracks output token distribution for partial fill orders
/// @dev Prevents overfilling by tracking cumulative amountOut per order
/// @dev QUOTE/SWAP DIVERGENCE: In quote mode (isStaticContext=true), this instruction checks
///   limits but does NOT update the filled counter. Quote may succeed while swap reverts...
function _invalidateTokenOut1D(Context memory ctx, bytes calldata /* args */) internal {
    // Wait till amountOut computed in case of isExactIn
    if (ctx.swap.amountOut == 0) { ctx.runLoop(); }
    require(ctx.swap.amountOut > 0, InvalidateTokenOutExpectsAmountOutToBeComputed());
    uint256 prefilled = tokenOutInvalidators[ctx.query.maker][ctx.query.orderHash][ctx.query.tokenOut];
    uint256 newFilled = prefilled + ctx.swap.amountOut;
    require(newFilled <= ctx.swap.balanceOut, InvalidatorsTokenOutExceeded(prefilled, ctx.swap.amountOut, ctx.swap.balanceOut));
    if (!ctx.vm.isStaticContext) {
        tokenOutInvalidators[ctx.query.maker][ctx.query.orderHash][ctx.query.tokenOut] = newFilled;
    }
}
```

Opcode `0x42` = 66 decimal. **Args are ignored** (`bytes calldata /* args */`): the args-length
byte still drives `<pc>` advance in the decode loop, but the payload is never read. Consequently
the opcode places NO constraint on `lengthBytes(ARGS)` and has NO `UNMODELLED-ARGS-LENGTH` arm —
the same posture as `0x53` LimitSwap (swapvm.md:326-328).

This is the first modelled opcode that is **not a pure conditional halt**. It does three things no
prior modelled opcode does:

1. **Reads the swap registers** `<amountOut>` and `<balanceOut>` (the gate family reads only
   `<balances>`; LimitSwap writes `<amountOut>` but does not gate on a deferral).
2. **Mutates the `<invalidators>` cell** (swapvm.md:62 — declared `.Map`, unused until now).
3. **Recurses into `runLoop`** — a yield/resume mechanism, modelled below.

`#exec` is fired by the decode loop (swapvm.md:141-149) AFTER the `[opcode:1][argsLen:1]` header
has been consumed and `<pc>` advanced by `2 + argsLen`. This opcode neither reads nor writes `<pc>`
beyond that (no `setNextPC` call): the deferral re-enters the loop but does not move `<pc>`
itself — the decode advance already did.

## What the K rule does

Five rules in `opcodes/invalidatetokenout.k`:

1. **Deferral arm** (`#exec`): `<amountOut> 0` → `#exec(66,_) => #run ~> #checkTokenOut`.
2. **Immediate arm** (`#exec`): `<amountOut>` non-zero → `#exec(66,_) => #checkTokenOut`.
3. **Arm 1** (`#checkTokenOut`): `amountOut <=Int 0` → revert
   `"InvalidateTokenOutExpectsAmountOutToBeComputed"`.
4. **Arm 2** (`#checkTokenOut`): `prefilled + amountOut > balanceOut` → revert
   `"InvalidatorsTokenOutExceeded"`.
5. **Arm 3** (`#checkTokenOut`): `prefilled + amountOut <= balanceOut` → pass and write the
   invalidator.

The check is factored into a named continuation `#checkTokenOut` because the deferred and
immediate paths run the identical require sequence.

## The runLoop recursion — the load-bearing modelling decision

`_invalidateTokenOut1D` is placed in a program BEFORE the pricer that computes `amountOut`
(the exact-in case: amountIn is known, amountOut is derived). When it runs with `amountOut`
still 0, it calls `ctx.runLoop()` — a **recursive** invocation that executes the REST of the
program from the already-advanced `nextPC` (VM.sol:118-151). Some later instruction writes
`amountOut`; when the inner loop ends (pc reaches the program end), control returns past the
`if` and the require check runs with the now-computed value.

The K decode step rewrites `<k> #run => #exec(OP, ARGS) ~> #run ... </k>`, so when `#exec(66,_)`
fires the trailing `#run` (the loop continuation) is already on the stack. The deferral rule
emits `#run ~> #checkTokenOut` in place of `#exec`:

```
<k> #run ~> #checkTokenOut ~> #run </k>
```

- The **leftmost** `#run` is the INNER loop: it processes the deferred tail starting from the
  already-advanced `<pc>`, exactly mirroring the recursive `ctx.runLoop()` call. When `<pc>`
  reaches the end it rewrites to `.K`.
- `#checkTokenOut` then runs the require check on the (possibly now-computed) `<amountOut>`.
- The **trailing** `#run` sees `<pc>` at the end and halts.

This reproduces the Solidity control flow precisely. A revert inside the deferred tail
propagates correctly: `#revert(MSG) ~> _ => .K` (swapvm.md:154-156) clears the whole
continuation, so `#checkTokenOut` never runs — matching the EVM unwind. Nested deferrals
(another `InvalidateTokenOut` in the tail) compose naturally via further stack nesting; each
is bounded by the program length, exactly as Solidity's recursion is.

The **immediate path** (`amountOut =/=Int 0`) skips the deferral: the rule emits just
`#checkTokenOut`, so `<k> = #checkTokenOut ~> #run` and the trailing `#run` proceeds to the
next instruction after the check — the normal loop step.

## The `<invalidators>` cell and `#prefilledOut`

The Solidity stores `tokenOutInvalidators[maker][orderHash][tokenOut] = filled:uint256`. The
model keys that fact with the constructor `invalOut(MAKER, OH, TOK)` in the existing
`<invalidators>` cell (swapvm.md:62, previously unused), and reads it via the `[function, total]`
helper `#prefilledOut(INV, MAKER, OH, TOK)` — a structural twin of `#balanceOf`
(swapvm.md:171-174): `orDefault 0` on a missing key, so a first fill reads prefilled = 0. The
future `0x41` InvalidateTokenIn will reuse the cell with a distinct key `invalIn(...)`.

## D4 abstraction for `maker` and `orderHash`

The `<query>` cell (swapvm.md:55-60) carries `taker`, `tokenIn`, `tokenOut`, `isExactIn` but NOT
`maker` or `orderHash`, which the Solidity reads as `ctx.query.maker` / `ctx.query.orderHash`.
These are fixed per execution (properties of the signed order), so per `PLAN.md` D4 they are
modelled as local uninterpreted nullary functions `#maker()` / `#orderHash()` — exactly the
pattern `opcodes/txorigin.k` uses for `#txOrigin()` and `opcodes/supplyshare.k` uses for
`#totalSupply(Int)`. The brief forbids editing swapvm.md, so the symbols are declared locally in
`SWAPVM-INVALIDATETOKENOUT` rather than added as cells. A concrete spec pins them via premises
(`requires #maker() ==Int 7`).

## Conformance

`proofs/invalidatetokenout-concrete.k` — three concrete claims, all proving (`#Top` under
`kprove --definition _swapvm-all`):

| Scenario | Path | Arm | amountOut | balanceOut | Result |
|---|---|---|---|---|---|
| A — overfill | immediate | 2 | 100 | 50 | `Reverted("InvalidatorsTokenOutExceeded")` |
| B — pass+write | immediate | 3 | 30 | 50 | `Running`, `invalOut(7,99,5) \|-> 30` |
| C — expects-computed | deferred | 1 | 0 | 50 | `Reverted("InvalidateTokenOutExpectsAmountOutToBeComputed")` |

Program: `b"\x42\x00"` (opcode 0x42, argsLen 0). Scenario C is the one that exercises the
**runLoop recursion**: a model that omitted the deferral would have no rule for `#exec(66,_)` at
`amountOut == 0` and would fall through to the `[owise]` unknown-opcode no-op (status `Running`) —
the wrong answer, caught here.

**Negative control** (proofs/README.md §"Why the controls exist"): a claim asserting scenario A
ends `Running` (instead of `Reverted`) **fails** (`kprove` exit 113, no `#Top`). The positive
claims are therefore discriminating, not vacuous.

The Solidity side (the real `_invalidateTokenOut1D` body and real `runLoop`) is not yet wired
into `test/conformance/InstructionConformance.t.sol`; that cross-check is the remaining work to
move this opcode from `ADMITTED` to `TESTED` in `axioms.md`.

## Known limitations (honest scope)

- **QUOTE/SWAP DIVERGENCE not modelled.** The Solidity guards the write with
  `if (!ctx.vm.isStaticContext)`: in quote (static) mode the check runs but the filled counter
  is NOT updated. The K config has no `isStaticContext` cell and no notion of quote mode — every
  execution is modelled as the SWAP path, consistently with all other modelled opcodes. The
  write is therefore unconditional in the model. Correct for swap-mode reasoning and for the
  no-replay / no-overfill properties the opcode exists to enforce; the quote-only
  check-without-write path is out of scope, not contradicted.
- **Arithmetic overflow not modelled.** `prefilled + amountOut` is Solidity 0.8 checked
  `uint256` addition (`Panic(0x11)` on wraparound); the model uses unbounded `+Int`. They
  diverge only at `prefilled + amountOut >= 2^256`, unreachable for real token balances (the
  require bounds `newFilled` to `balanceOut`, a uint256). Both engines revert in that region;
  only the reason differs. Same caveat T1 carries for `LimitSwap` multiplication (axioms.md).
- **Symbolic universal claim not attempted.** Following the documented arm-selection limitation
  (opcodes/gte.md "Arm selection", opcodes/deadline.md:125-156) — `#prefilledOut` involves an
  uninterpreted-vs-symbolic comparison that the K Haskell backend does not propagate into an
  arm refutation — conformance is carried by CONCRETE claims, as for Gte and SupplyShare.

## Integration

K v7 does not allow reopening `module SWAPVM` across files, so this opcode defines a sibling
module `SWAPVM-INVALIDATETOKENOUT` that imports `SWAPVM`. It is wired into the aggregated
definition `semantics/_lemmas-all.k`:

```k
requires "opcodes/invalidatetokenout.k"
...
module SWAPVM-BYTES-LEMMAS
  imports SWAPVM
  ...
  imports SWAPVM-INVALIDATETOKENOUT
```

Build and prove:

```
kompile --backend haskell _lemmas-all.k --main-module SWAPVM-BYTES-LEMMAS \
  --syntax-module SWAPVM-SYNTAX -o _swapvm-all
kprove --definition _swapvm-all proofs/invalidatetokenout-concrete.k   # => #Top
```

The base `lemmas.k` (which `run-proofs.sh` builds as `swapvm-haskell` for the core gate/pricing
specs) is untouched, so those proofs are unaffected.

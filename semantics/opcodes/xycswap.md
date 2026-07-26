# `0x50` XYCSwap — formal semantics

## Source

`XYCSwap.sol:_xycSwapXD`:

```solidity
function _xycSwapXD(Context memory ctx, bytes calldata /* args */) internal pure {
    require(ctx.swap.balanceIn > 0 && ctx.swap.balanceOut > 0, XYCSwapRequiresBothBalancesNonZero(...));
    if (ctx.query.isExactIn) {
        require(ctx.swap.amountOut == 0, XYCSwapRecomputeDetected());
        ctx.swap.amountOut = ((ctx.swap.amountIn * ctx.swap.balanceOut) / (ctx.swap.balanceIn + ctx.swap.amountIn));
    } else {
        require(ctx.swap.amountIn == 0, XYCSwapRecomputeDetected());
        ctx.swap.amountIn = Math.ceilDiv(ctx.swap.amountOut * ctx.swap.balanceIn, (ctx.swap.balanceOut - ctx.swap.amountOut));
    }
}
```

Opcode `0x50` = 80 decimal. **Args are ignored** (`bytes calldata /* args */`): the args-length
byte still drives `<pc>` advance, but the payload is never read. The opcode places NO constraint
on `lengthBytes(ARGS)` and has NO `UNMODELLED-ARGS-LENGTH` arm — same as `0x53` LimitSwap.

This is the **constant-product pricer** (the "xy = constant" curve, x·y=k without fees). It is a
direct structural sibling of `0x53` LimitSwap (swapvm.md:221-298): same handler shape, same two
reverts (`RequiresBothBalancesNonZero`, `RecomputeDetected`), same single-assignment guard, same
two-direction split on `<isExactIn>`, floor on exact-in / ceiling on exact-out. The ONLY
difference is the curve:

| | LimitSwap (flat rate) | XYCSwap (constant product) |
|---|---|---|
| exact-in | `amountIn * balanceOut / balanceIn` | `amountIn * balanceOut / (balanceIn + amountIn)` |
| exact-out | `ceilDiv(amountOut * balanceIn, balanceOut)` | `ceilDiv(amountOut * balanceIn, balanceOut - amountOut)` |

The XYCSwap denominator grows with the fill (`balanceIn + amountIn`), so the price **slips** as
the fill grows; LimitSwap's rate is flat. The exact-out divisor `balanceOut - amountOut` is the
dual of that slip.

`#exec` is fired by the decode loop (swapvm.md:141-149) AFTER the header is consumed and `<pc>`
advanced. XYCSwap neither reads nor writes `<pc>` beyond that: it writes exactly one register
(`<amountOut>` exact-in, `<amountIn>` exact-out), once, and leaves `#run` in `<k>`.

## What the K rule does

Seven rules in `opcodes/xycswap.k`:

1. **`xycQuoteOut`** `[function]` — the exact-in formula, definitional rule.
2. **`xycQuoteIn`** `[function]` — the exact-out formula, reusing `#ceilDiv` (swapvm.md:237-245).
3. **Guard 1** — `balanceIn <= 0 || balanceOut <= 0` → revert `XYCSwapRequiresBothBalancesNonZero`.
4. **Exact-in recompute** — `amountOut =/=Int 0` → revert `XYCSwapRecomputeDetected`.
5. **Exact-in pricing** — write `<amountOut>` with `xycQuoteOut`.
6. **Exact-out recompute + guard 3** — the `<isExactIn> false` recompute twin, plus the
   `balanceOut <= amountOut` revert (`XYCSwapAmountOutExceedsBalanceOut`) mirroring the EVM
   underflow / div-by-zero Panic.
7. **Exact-out pricing** — write `<amountIn>` with `xycQuoteIn`, guarded by `BOUT >Int AOUT`.

The arms are pairwise disjoint: guard 1 vs the rest on the balance sign; exact-in vs exact-out on
the `<isExactIn>` cell; recompute vs pricing on `amountOut` (resp. `amountIn`) `==Int 0` vs
`=/=Int 0`; exact-out guard 3 vs pricing on `BOUT <=Int AOUT` vs `BOUT >Int AOUT`.

## PLAN.md D2 — arithmetic through a named symbol

XYCSwap is the opcode `PLAN.md` §D2 uses to **prescribe** the modelling pattern:

```k
rule <k> #exec(XYCSWAP, ARGS) => .K ... </k>
     <amountOut> _ => xycQuote(AIN, BIN, BOUT) </amountOut>
rule xycQuote(AIN, BIN, BOUT) => (AIN *Int BOUT) /Int (BIN +Int AIN)   // the DEFINITION
```

The pricing appears in the dispatch rule only as a call to a named function symbol
(`xycQuoteOut` / `xycQuoteIn`); the formula lives in a separate defining rule. Weakening to
axioms — should a program-level proof stall on the arithmetic past the `PLAN.md` D3 trigger — is
then deleting the defining rule and adding axioms about the symbol, a one-line change rather than
a restructuring. This is the structure for the retreat, built in before it is needed.

## Rounding

- **Exact-in floors** (`/Int` rounds toward zero; all operands non-negative, so it is the floor):
  the sub-quotient remainder goes to the maker — the same intentional rounding `LimitSwap.sol:49`
  documents and T1 proves (axioms.md).
- **Exact-out ceilings** via `#ceilDiv` (`a == 0 ? 0 : (a-1)/b + 1`, OpenZeppelin `Math.ceilDiv`):
  the taker pays in just enough to cover the requested output, rounded up.

Both round toward the maker's advantage.

## Conformance

`proofs/xycswap-concrete.k` — five concrete claims, all proving (`#Top` under `kprove`):

| Scenario | Arm | Inputs | Result |
|---|---|---|---|
| A — exact-in pricing | exact-in price | in 100, reserves 100/100 | `amountOut => 50` |
| B — exact-out pricing | exact-out price (ceiling) | out 30, reserves 100/100 | `amountIn => 43` (NOT 42) |
| C — balances-zero | guard 1 | balanceIn 0 | `Reverted("XYCSwapRequiresBothBalancesNonZero")` |
| D — recompute | exact-in recompute | amountOut 7 (pre-set) | `Reverted("XYCSwapRecomputeDetected")` |
| E — amount-out-exceeds | exact-out guard 3 | out 150 > balanceOut 100 | `Reverted("XYCSwapAmountOutExceedsBalanceOut")` |

Program: `b"\x50\x00"`. Scenario B deliberately picks a **non-dividing** input (3000/70 = 42 r.60)
so the ceiling (43) is distinguished from the floor (42). Scenario A asserts the **exact** quote
(50), which distinguishes the constant-product curve from the flat LimitSwap rate (which would
give 100) — the same discriminator the negative control below uses.

**Negative control**: a claim asserting scenario A yields `amountOut => 100` (the flat LimitSwap
rate) **fails** (`kprove` exit 113, no `#Top`). A mutant that swapped `xycQuoteOut` for
`limitQuoteOut` would make the positive claim A pass but ALSO make this control pass — so the
control's failure is what certifies the curve is the constant-product one and not the flat one.

The Solidity side (the real `_xycSwapXD` body) is not yet wired into
`test/conformance/InstructionConformance.t.sol`; that cross-check is the remaining work to move
this opcode from `ADMITTED` to `TESTED` in `axioms.md`.

## Known limitations (honest scope)

- **Exact-out divisor — `amountOut >= balanceOut` reverts (modelled).** The exact-out
  subtraction `balanceOut - amountOut` underflows (`Panic 0x11`) when `amountOut > balanceOut`
  and `Math.ceilDiv(_, 0)` reverts (`Panic 0x12`) when equal. The model has a dedicated revert
  arm (`XYCSwapAmountOutExceedsBalanceOut`) for `BOUT <=Int AOUT`, so both engines revert
  here. The Solidity path is an arithmetic `Panic` with no contract selector, so the K reason
  is a descriptive token (D5). (An earlier revision let the pricing rule fire unconditionally
  and relied on `xycQuoteIn`'s defining rule being stuck to "fail safe" — that was wrong: a
  claim on `<status>`/`<pc>`/a downstream register would close on a `Running` state the chain
  never reaches. The revert arm fixes the soundness direction; see xycswap-concrete.k
  scenario E.)
- **Unbounded multiplication — not modelled (permissive).** `amountIn * balanceOut` (exact-in)
  and `amountOut * balanceIn` (exact-out) are Solidity 0.8 checked `uint256` multiplication
  (`Panic(0x11)` on wraparound); the model uses unbounded `*Int`, so it computes where the EVM
  reverts. This is the SAME caveat T1 carries for LimitSwap (axioms.md): "K and the EVM differ
  iff `amountIn * balanceOut >= 2^256`". Worse here on the exact-out leg: the model can write a
  value exceeding `2^256` into `<amountIn>` — not a representable uint256 at all. Read the
  theorems as "given the products do not overflow". Distinguishing input (exact-in):
  `balanceIn=1, balanceOut=2^200, amountIn=2^200` → chain `Panic(0x11)`, model computes.
- **Symbolic universal claim not attempted.** Following the documented arm-selection limitation
  (opcodes/gte.md "Arm selection"), conformance is carried by CONCRETE claims. A symbolic claim
  would additionally need the `xycQuote*` symbols' inequality properties (e.g. the constant-
  product maker-safety bound `amountOut * (balanceIn + amountIn) <= amountIn * balanceOut`),
  which is exactly the kind of axiom the D2/D3 structure is built to admit later.

## Integration

Sibling module `SWAPVM-XYCSWAP` imports `SWAPVM`. Wired into `semantics/_lemmas-all.k`:

```k
requires "opcodes/xycswap.k"
...
module SWAPVM-BYTES-LEMMAS
  imports SWAPVM
  ...
  imports SWAPVM-XYCSWAP
```

Build and prove:

```
kompile --backend haskell _lemmas-all.k --main-module SWAPVM-BYTES-LEMMAS \
  --syntax-module SWAPVM-SYNTAX -o _swapvm-all
kprove --definition _swapvm-all proofs/xycswap-concrete.k   # => #Top
```

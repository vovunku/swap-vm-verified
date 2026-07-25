# Phase 1 — three instructions and the gate theorem

Design and tech doc. Written before implementation, per the project's working rule.

**Go/no-go for the whole approach.** If the theorem will not close, or conformance disagrees,
stop and reconsider rather than pressing on.

## Scope

Three instruction rules, then one theorem over the catalogue program in
[`programs/permissioned-swap.md`](programs/permissioned-swap.md).

Everything else stays as Phase 0 left it: decode loop `TESTED`, unknown opcodes are no-ops.

## The instructions, read from source

### `0x23` OnlyTakerTokenBalanceNonZero — `Controls.sol:140-144`

```solidity
address token = address(bytes20(args));
uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
require(balance > 0, TakerTokenBalanceIsZero(ctx.query.taker, token));
```

Args: 20 bytes, an address. Reads external ERC-20 state — abstracted to the `<balances>` cell
per `PLAN.md` D4. Writes no registers; it is a pure guard.

### `0x90` StaticBalances — `Balances.sol:37-47`

```solidity
require(ctx.swap.balanceIn == 0 && ctx.swap.balanceOut == 0, SetBalancesExpectZeroBalances(...));
if (ctx.query.tokenIn < ctx.query.tokenOut) (balanceIn, balanceOut) = parse(args);
else                                        (balanceOut, balanceIn) = parse(args);
```

Args: 64 bytes, two `uint256`. **Orientation matters**: the pair is swapped when
`tokenIn >= tokenOut`. Both branches must be modelled or the semantics is wrong for half of all
token pairs.

### `0x53` LimitSwap — `LimitSwap.sol:_limitSwap1D`

```solidity
require(balanceIn > 0 && balanceOut > 0, LimitSwapRequiresBothBalancesNonZero(...));
bool makerDirectionLt = parse(args);              // one byte, != 0
bool takerDirectionLt = tokenIn < tokenOut;
require(makerDirectionLt == takerDirectionLt, LimitSwapDirectionMismatch());
if (isExactIn) { require(amountOut == 0); amountOut = amountIn * balanceOut / balanceIn; }
else           { require(amountIn  == 0); amountIn  = ceilDiv(amountOut * balanceIn, balanceOut); }
```

Args: **one byte**, not two addresses — `build(tokenIn, tokenOut)` encodes only
`tokenIn < tokenOut`. Floor on exact-in, ceiling on exact-out; both directions favour the maker.

Per `PLAN.md` D2 the arithmetic goes through named symbols — `limitQuoteOut` and
`limitQuoteIn` — even though we give them exact definitions. Weakening later is then deleting
one rule, not restructuring.

## Revert reasons

Modelled as opaque strings (`PLAN.md` D5), named after the Solidity errors so conformance can
compare them:

`TakerTokenBalanceIsZero`, `SetBalancesExpectZeroBalances`,
`LimitSwapRequiresBothBalancesNonZero`, `LimitSwapDirectionMismatch`,
`LimitSwapRecomputeDetected`.

## The theorem

> For any program `P = 0x23 0x14 G ++ TAIL` — `G` a 20-byte address, `TAIL` **arbitrary** —
> executing `P` with a taker holding zero balance of `G` ends in
> `Reverted("TakerTokenBalanceIsZero")`.

Why it is provable with a symbolic `TAIL`: the gate is the first instruction, and `#revert`
discards the rest of the continuation. `TAIL` is therefore never decoded, so its contents
cannot matter — the proof does not case-split on it. That is what makes this the right first
theorem rather than a hard one.

It needs **no arithmetic**, which is the second reason it is first.

## What this does and does not establish

Establishes: a property of an infinite family of programs, which the scenario suites in
`test/invariants/` can only sample.

Does **not** establish anything about the deployed bytecode. All three rules are `ADMITTED`;
the theorem inherits that. See `PLAN.md` §0.

## Acceptance

1. Semantics compiles.
2. `krun` on the concrete 91-byte program, taker holding the gate token, exact-in: registers
   match a Foundry run of the real instructions.
3. Same program, taker holding nothing: both revert `TakerTokenBalanceIsZero`.
4. The theorem proves under `kprove` with `TAIL` symbolic.
5. Negative control: a knowingly false variant — e.g. the same claim with the gate *second* —
   fails to prove. If it proves, the rule set is inconsistent and everything above is void.

## Risks

- **Orientation bug.** `StaticBalances` swaps on `tokenIn >= tokenOut`, `LimitSwap` requires
  the directions agree. Easy to model one and not the other. Conformance case 2 must run both
  orientations.
- **`ceilDiv` semantics.** OpenZeppelin's rounds up unless exact; K's `up/Int` must be checked
  to match rather than assumed.
- **Symbolic `TAIL` leaking into the path condition.** If the proof case-splits on `TAIL`, the
  claim is stated wrongly — the revert should make it unreachable.

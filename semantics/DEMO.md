# The demo, precisely

What the program does, how it does it, and exactly what was proved about it. Written to be
checkable line by line rather than persuasive.

## 1. The program

91 bytes, three instructions. A maker's strategy: an institutional gate in front of a
fixed-rate limit order.

```
23 14 <20-byte gate token>                          OnlyTakerTokenBalanceNonZero
90 40 <uint256 balanceA> <uint256 balanceB>         StaticBalances
53 01 <bool makerDirectionLt>                       LimitSwap
```

Encoding is `[opcode:1][argsLen:1][args:argsLen]` repeated — `ProgramBuilder.build` is
literally `abi.encodePacked(opcode, args.length.toUint8(), args)`.

**Built to this repository's contract**, verified byte-for-byte against the production
argument encoders in `src/instructions/` by `test/example/ProgramBytes.t.sol`. Note it is
**not** what `@1inch/swap-vm-sdk` emits — that SDK encodes `StaticBalances` as
`uint16 count` + 10-byte token halves + values, which `Balances.sol:20-23` does not parse.
See §6.

## 2. What each instruction does

### `0x23` OnlyTakerTokenBalanceNonZero — `Controls.sol:140-144`

```solidity
address token = address(bytes20(args));
uint256 balance = IERC20(token).balanceOf(ctx.query.taker);
require(balance > 0, TakerTokenBalanceIsZero(ctx.query.taker, token));
```

A pure guard. Reads the taker's balance of the token named in the arguments and reverts if it
is zero. Writes no registers. This is an ownership whitelist: hold the token (or NFT) or you
cannot fill.

### `0x90` StaticBalances — `Balances.sol:37-47`

```solidity
require(ctx.swap.balanceIn == 0 && ctx.swap.balanceOut == 0, SetBalancesExpectZeroBalances(...));
if (ctx.query.tokenIn < ctx.query.tokenOut) (balanceIn, balanceOut) = parse(args);
else                                        (balanceOut, balanceIn) = parse(args);
```

Loads the maker's offered reserves into the swap registers. **The pair is swapped when
`tokenIn >= tokenOut`** — the arguments are stored in token-sort order, not in taker order.
The guard makes the instruction single-assignment: a program cannot set balances twice.

### `0x53` LimitSwap — `LimitSwap.sol:_limitSwap1D`

```solidity
require(balanceIn > 0 && balanceOut > 0, LimitSwapRequiresBothBalancesNonZero(...));
require(makerDirectionLt == (tokenIn < tokenOut), LimitSwapDirectionMismatch());
if (isExactIn) { require(amountOut == 0); amountOut = amountIn * balanceOut / balanceIn; }
else           { require(amountIn  == 0); amountIn  = ceilDiv(amountOut * balanceIn, balanceOut); }
```

Prices at the fixed ratio `balanceOut : balanceIn`. **Exact-in floors, exact-out ceilings** —
both round toward the maker. The direction check makes the maker's intent explicit: the
program encodes which way round the pair was quoted, and refuses to price a taker coming the
other way. The recompute guards make pricing single-assignment.

With `1000e18 / 2000e18`, a taker sending 1 unit of the low-sorting token receives 2.

## 3. What was proved

**Exactly one theorem**, in `semantics/proofs/gate-spec.k`, `kprove` returns `#Top`:

> For any program `P = 0x23 0x14 G ++ TAIL` — `G` any 20-byte address, `TAIL` an **arbitrary
> symbolic byte string** — executing `P` with a taker holding zero balance of `G` ends in
> `Reverted("TakerTokenBalanceIsZero")`.

It is an **access-control** property. Its worth is the quantification over `TAIL`: it holds
for every program that starts with this gate, not for the 91-byte instance. No scenario test
can cover that set.

It proves cheaply for a structural reason: `#revert` discards the continuation, so `TAIL` is
never decoded and the proof does not case-split on it.

**Checks that make the result meaningful rather than decorative:**

- **Not vacuous** — a witness reaches the claimed final state under `krun`, and every
  hypothesis is load-bearing (deleting any one makes the proof fail).
- **Negative control** (`negative-control.k`): same program, balance **non-zero**, asserting
  the same revert. Must fail, and does — at `<pc> 22` with `<status> Running`, a real computed
  counterexample.
- **Sensitivity witness** (`control-sensitivity.k`): identical premises, correct conclusion.
  Must prove, and does. Without this the control's failure could be incidental.

## 4. What was NOT proved

Everything about the money:

- **Nothing about pricing.** That the ratio is computed correctly, that rounding favours the
  maker, that exact-in and exact-out agree — modelled and conformance-tested on concrete
  inputs, **not proved**.
- **Nothing about the balances.** No bound relating `amountOut` to `balanceOut`.
- **Nothing about replay or overfill.**
- **Nothing about the deployed bytecode.** All three instruction rules and the decode loop are
  `TESTED` — conformance agrees on the cases run — never `PROVEN`. The theorem holds *given
  each instruction behaves as its rule says*.

## 5. How the pieces connect

```
src/instructions/*ArgsBuilder   →  91 program bytes  →  semantics/swapvm.md  →  gate-spec.k
   (production encoders)            (ProgramBytes.t)     (K rules)              (kprove #Top)
                                            ↓
                              test/conformance/*.t.sol
                     (real runLoop, real instruction bodies, diffed vs krun)
```

Conformance is the load-bearing link: without it the K rules could describe a VM that does not
exist. It runs the **real** `ContextLib.runLoop` and the **real** instruction bodies inherited
from `Controls`, `Balances` and `LimitSwap` — only the dispatch table is ours, which is what
the production VM generates anyway.

Current: 19 Solidity tests, 6 K conformance cases, all agreeing.

## 6. Known gaps, stated plainly

- **The SDK mismatch** (§1). Unresolved whether the SDK targets Aqua deployments, this fork has
  diverged, or it is a real bug. Worth resolving before anyone builds on this.
- **Malformed argument lengths.** Solidity right-zero-pads and truncates without reverting; the
  K rules require exact lengths and now revert `UNMODELLED-ARGS-LENGTH` rather than silently
  no-opping. Loud, but not yet faithful.
- **Arithmetic overflow is unmodelled.** `amountIn * balanceOut` is checked arithmetic in
  Solidity and reverts on overflow; K's `Int` is unbounded and computes. Reachable with
  attacker-chosen `amountIn`.
- **Unmodelled opcodes are silent no-ops** in K, where production reverts `UnknownOpcode`.
  Theorems must be stated so this cannot affect the conclusion — the gate theorem is, because
  it reverts before the tail is decoded.

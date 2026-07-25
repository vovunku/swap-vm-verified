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

**Two theorems.**

### T0 — the gate (`semantics/proofs/gate-spec.k`, `#Top`)

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

### T1 — the pricing is exactly the floor (`semantics/proofs/pricing-spec.k`, `#Top`)

Runs the whole three-instruction program with `amountIn` and **both maker reserves symbolic**,
and pins the quote:

    amountOut * balanceIn       <= amountIn * balanceOut     (maker safety)
    (amountOut + 1) * balanceIn >  amountIn * balanceOut     (taker safety)

Together these determine `amountOut` uniquely as `floor(amountIn * balanceOut / balanceIn)`.
Either alone is worthless — the first is satisfied by returning 0, the second by returning
something huge.

**This proves the rounding decision `LimitSwap.sol:49` documents as intentional: the sub-wei
remainder goes to the maker on every fill.** Mutation testing had shown it was entirely
unconstrained — switching exact-in from floor to ceiling survived the whole original suite,
because the catalogue program's numbers divide evenly.

Verified enforced rather than merely stated: substituting a false `ensures` (`?AOUT ==Int
12345`) **fails**, with the existential unified to the computed cell contents
`AIN *Int BB /Int BA`. The negative control reverses the maker-safety inequality and fails
having reached `pc 91` with the real quote in the register — not the Phase 1 failure mode of
dying at `pc 0` before any instruction ran.

## 4. What was NOT proved

Everything about the money:

- **Nothing about the exact-out leg.** T1 covers exact-in only. The ceiling on exact-out is
  conformance-tested, not proved. (`PHASE2.md` lists it as T2 and it is not yet written.)
- **Nothing about the balances.** No bound relating `amountOut` to `balanceOut`.
- **Nothing about round-trip consistency.** That quoting exact-in then exact-out cannot
  extract value is `PHASE2.md`'s T3, a declared stretch goal, not attempted.
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

## 5a. Coverage: 3 of 52 opcodes

The enum in `src/libs/OpcodeList.sol` defines **52 named opcodes**. The semantics implements
**three** — `0x23`, `0x90`, `0x53` — exactly what this one program uses.

What *is* complete is the **decode loop**: fetch, argument slicing, program-counter advance and
the bound check, faithful to `VM.sol:118-150` and conformance-tested. That is the reusable
part; instructions are additive on top of it.

Everything else falls through to the `[owise]` no-op. So the honest scope of this work is *one
program, three instructions* — a demonstrator for the method, not coverage of the VM.

## 6. Known gaps, stated plainly

- **The SDK mismatch** (§1). Unresolved whether the SDK targets Aqua deployments, this fork has
  diverged, or it is a real bug. Worth resolving before anyone builds on this.
- **Malformed argument lengths.** Solidity right-zero-pads and truncates without reverting; the
  K rules require exact lengths and now revert `UNMODELLED-ARGS-LENGTH` rather than silently
  no-opping. Loud, but not yet faithful.
- **Arithmetic overflow is unmodelled, and this qualifies T1.** `LimitSwap.sol:49` is plain
  checked arithmetic — no `mulDiv` — so the divergence condition is exact: **K and the EVM
  differ iff `amountIn * balanceOut >= 2^256`**, where the EVM reverts `Panic(0x11)` and K
  computes. Below that they agree exactly.

  T1's `amountIn < 2^256` hypothesis does **not** bound the product and is **inert** — the
  claim proves without it. So T1 holds for arbitrarily large `amountIn`, over a region where
  the EVM would revert. Since `amountIn` is taker-chosen, the divergence is reachable by
  construction for any `balanceOut`, at `amountIn >= 2^256 / balanceOut`. Read T1 as *"given
  the product does not overflow"*.
- **Unmodelled opcodes are silent no-ops** in K, where production reverts `UnknownOpcode`.
  Theorems must be stated so this cannot affect the conclusion — the gate theorem is, because
  it reverts before the tail is decoded.

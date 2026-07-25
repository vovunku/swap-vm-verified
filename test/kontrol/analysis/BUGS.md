# Candidate bugs — evidence, criticality, and reachability

Working file for findings that may warrant an upstream report to 1inch / Degensoft. Nothing
here should be reported until it reaches **CONFIRMED** status, with a reproducible witness.

Every entry carries two independent judgements, and conflating them is the mistake this file
exists to prevent:

* an **evidence level** — how do we know it is real;
* a **criticality** — how much would it matter if it were.

A defect can be CONFIRMED and INFORMATIONAL at the same time (`unscaleValue`), or MEDIUM and
never once executed (nothing here, any more — that was the point of this pass).

## Evidence levels

| Level | Meaning |
|---|---|
| **CONFIRMED** | Reproduced by executing the EVM — a `forge test` witness, or a Kontrol counterexample with its path condition. Safe to report. |
| **SOURCE** | Derived by reading the source and reasoning about it. Strong, but no execution has confirmed the path is reachable. |
| **MODELLED** | Produced by a separate model of EVM semantics (e.g. a Python re-implementation), not by executing the EVM. **Must be re-validated before reporting.** |

The distinction has already earned its keep twice. `PeggedSwap`'s underflow was MODELLED and a
test pinning it did not reproduce under Kontrol on the first attempt. And the MODELLED rounding
claim below turned out to be *understated* — the leak is ulp-scaled, not a fixed wei — which a
report based on the model alone would have got wrong in the other direction.

## Criticality scale

There is no house scale, so this is the one used here, applied consistently to every entry.
The ordering axis is "how much does a real party lose, and how hard is it for them to avoid".

| Level | Meaning |
|---|---|
| **CRITICAL** | Funds move incorrectly, reachable by an ordinary party through ordinary use, with no mitigation available to the victim. |
| **HIGH** | Funds move incorrectly, but reachability needs an unusual (if legitimate) configuration, or the victim has an opt-in mitigation that most but not all will have taken. |
| **MEDIUM** | Denial of service on an otherwise-valid order, reachable through ordinary use; or wrong arithmetic whose magnitude is bounded and small but non-negligible. |
| **LOW** | Denial of service confined to degenerate, exhausted, or dust-scale states; or wrong arithmetic below any economic significance. |
| **INFORMATIONAL** | Real defect with no path from any deployed instruction, or confined to an off-chain helper. Robustness and documentation, not risk. |

Each entry states four things explicitly, because judging criticality without them is guessing:
**reachability**, **impact if reached**, **who bears the loss**, and **whether a guard elsewhere
already prevents it**.

## The reachability caveat that applies to every entry

`HARNESS-FIDELITY.md` §"Residual gaps" records that nothing in this repository models whether a
real VM *program* can drive the registers to the values a property quantifies over. That is
still true. What this pass added is one level down from a full end-to-end model, and it is worth
naming precisely:

* the register **provenance** was traced by reading `SwapVM.sol:126-166` — the taker's `amount`
  lands directly in `ctx.swap.amountIn` (exact-in) or `ctx.swap.amountOut` (exact-out) with no
  balance or sanity check before `runLoop`; `balanceIn`/`balanceOut` come from `StaticBalances`
  (maker program arguments), `DynamicBalances` (storage, accumulating past fills), or AQUA;
  instruction arguments are maker-signed program bytes, with `argsLength` a full `uint8` read at
  `VM.sol:131`;
* every witness below is still **instruction-level**, driving a hand-assembled `Context`. No test
  here drives a whole program through `ContextLib.runLoop`.

So "reachable" in this file means "the registers are reachable given how `SwapVM` populates them
and who controls each one". It does not mean an end-to-end fill has been demonstrated. Where that
distinction changes the verdict, the entry says so.

---

## CONFIRMED

### BaseFeeAdjuster — `maxPriceDecay > 1e18` inverts the adjustment against the taker

**Level: CONFIRMED.** `test/kontrol/analysis/repro/BaseFeeAdjusterRepro.t.sol`,
`test_repro_maxPriceDecayAboveOneChargesTheTakerDouble`.
**Criticality: HIGH.** The only entry in this file where a party other than the one who
configured the order loses money.

`:99` clamps with `priceDecay = Math.max(priceDecay, maxPriceDecay)` and `:100` then computes
`ctx.swap.amountIn = (amountIn * priceDecay).ceilDiv(1e18)`. Above `1e18` the "floor" is a
multiplier: the discount the instruction exists to grant becomes a surcharge. At
`maxPriceDecay = 2e18` the taker is charged **exactly double**, and the effect is a smooth dial —
`1.5e18` charges 1.5x — not a knife-edge.

Witness: `baseGasPrice = 20 gwei`, `ethToToken1Price = 3000e18`, `gasAmount = 150 000`,
`maxPriceDecay = 2e18`, `block.basefee = 100 gwei`, exact-out with `amountIn = 1000e18` in →
`amountIn = 2000e18` out.

* **Reachability.** `maxPriceDecay` is a `uint64` in maker-signed program bytes.
  `BaseFeeAdjusterArgsBuilder` performs **no validation at all** — it has no `require`, unlike
  `DutchAuctionArgsBuilder`, which at least checks its factor in `build`. The trigger is
  `block.basefee > baseGasPrice` (`:83`), so an order can sit dormant and correct through quiet
  blocks and only bite during congestion. Nothing about the parameter is unusual to express.
* **Impact.** Silent wrong arithmetic. Funds move, in the wrong amount, without a revert.
* **Who bears it.** The **taker**.
* **Guard elsewhere — partial, and opt-in.** `TakerTraits.validate` (`:191-201`) enforces
  `amountIn <= thresholdAmount` in the exact-out direction, which converts the overcharge into a
  revert. But `threshold()` (`:236-239`) reports `hasThreshold` purely from whether the taker
  supplied a 32-byte slice; a taker who omits it has **no cap on `amountIn` whatsoever**. So the
  mitigation is the taker's own slippage setting, not a protocol invariant.

That opt-in guard is why this is HIGH rather than CRITICAL. It is also the reason to report it:
a parameter that silently reverses the sign of an adjustment is a bug regardless of how many
takers happen to be protected.

### BaseFeeAdjuster — exact-out underflows before the clamp that was meant to save it

**Level: CONFIRMED.** `test_repro_exactOutUnderflowsBeforeTheClamp`.
**Criticality: MEDIUM.**

`:98` computes `1e18 - (extraCostInToken1 * 1e18 / ctx.swap.amountIn)` and `:99` clamps the
result with `Math.max(..., maxPriceDecay)`. The clamp is one line too late — the checked
subtraction has already reverted with a bare `Panic(0x11)`.

The underflow condition is `extraCostInToken1 > amountIn`: the gas compensation exceeds the whole
trade. That is precisely the case the clamp was written for.

Witness: the parameters above with a perfectly ordinary `maxPriceDecay = 0.99e18`, at
`block.basefee = 100 gwei` the compensation is 36 token1; an exact-out order for `1e18` (one
token) reverts. The **same order, same block, opposite direction** succeeds and correctly
improves `amountOut` — pinned in the same test. A `1000e18` order is unaffected.

* **Reachability.** Ordinary: a small order during a gas spike. No unusual parameter.
* **Impact.** Denial of service. Funds safe.
* **Who bears it.** Maker's order stops filling; taker loses the gas of a failed transaction.
* **Guard elsewhere.** None. The clamp that would have guarded it is unreachable.

### BaseFeeAdjuster — `maxPriceDecay > 2e18` bricks exact-in

**Level: CONFIRMED.** `test_repro_maxPriceDecayAboveTwoBricksExactIn`.
**Criticality: MEDIUM.**

`2e18 - maxPriceDecay` at `:93` is a checked subtraction on a `uint64` whose range reaches
`~1.8e19`. Bare `Panic(0x11)`.

* **Reachability.** Maker-supplied and unvalidated, but a value above `2e18` is already
  nonsensical, so this is a mis-configuration detector rather than a trap a sane maker falls
  into. It fires only once `block.basefee > baseGasPrice`, so the order looks healthy while gas
  is cheap — pinned by `test_repro_sameOrderIsHealthyWhileGasIsCheap`.
* **Impact.** Denial of service.
* **Who bears it.** Maker (unfillable order), taker (wasted gas).
* **Guard elsewhere.** None.

### MinRate — `AdjustMinRate` does not enforce the floor

**Level: CONFIRMED.** `test/kontrol/analysis/repro/MinRateAdjustStaleRegisterRepro.t.sol`,
`test_repro_adjustLeavesRateBelowFloor`.
**Criticality: MEDIUM.**

Out of Track B scope. This assessment reads `src/instructions/MinRate.sol` and drives it through
a dispatch stub in a new file under `repro/`; no `MinRate` source, spec or harness was touched
and no proof was run against one.

`_adjustMinRate1D` snapshots `amountIn`/`amountOut` at `:56-57`, **before** `ctx.runLoop()` at
`:60`. The rate comparison at `:65` correctly uses the loop's results; the correction at
`:67`/`:69` recomputes from the stale snapshot.

Witness: floor 1:1, exact-in, `amountIn = 100` on entry, inner program returns `(50, 100)`.
`:65` sees `50 < 100` and fires; `:67` sets `amountOut = 100 * 1 / 1 = 100` from the pre-loop
`100`; the registers end at `(50, 100)` — **still 0.5:1, still below the floor**. The same test
file shows `_requireMinRate1D` reverting with `MinRateFailed(50, 100, 1, 1)` on exactly the state
`_adjustMinRate1D` accepts, which is the cleanest statement of the inconsistency: the enforcing
variant and the correcting variant disagree about the same swap.

* **Reachability.** Requires the inner program to modify `ctx.swap.amountIn` — an input-side fee,
  a partial fill, a balance adjustment. All exist in the instruction set. **What is not
  established** is how common such a program shape is in deployed maker bytecode, which this
  repository does not contain. See "Reachability gaps".
* **Impact.** Silent wrong arithmetic: the order fills below the rate floor the maker attached to
  it, with no revert.
* **Who bears it.** The **maker** — they asked for a floor and did not get one.
* **Guard elsewhere.** None in the instruction. A maker who used `RequireMinRate` instead would
  be protected; the whole point of `AdjustMinRate` is to correct rather than revert.
* **Non-vacuity.** `test_repro_correctionIsRightWhenAmountInIsUnchanged` shows the correction
  behaves correctly when the inner program leaves `amountIn` alone, which is why the bug survives
  the obvious tests.

### PiecewiseLinearScale — non-terminating loop on short arguments

**Level: CONFIRMED.** `test/kontrol/analysis/repro/PiecewiseLinearScaleNonTerminationRepro.t.sol`.
**Criticality: MEDIUM.**

Two distinct causes, and a fix addressing only the first leaves the second wide open:

* `args.length <= 4` — `args.length / 5 - 1` at `:128` underflows inside `unchecked`, so `max`
  becomes `type(uint256).max` and the `++num == max` exit at `:142` is unreachable.
* `5 <= args.length <= 9` — **no underflow**; `max` is cleanly `0`. The loop still cannot
  terminate, because `num` is pre-incremented, making `++num == 0` exactly as unreachable as
  `++num == 2**256 - 1`.

The body cannot make progress either: `Calldata.slice` does no bounds checking by design, so
`parseIntervalDuration(num)` reads past the arguments and `timeLeft -= 0` is a no-op.
Consequence is **out-of-gas, not a revert** — no error to catch and nothing to attribute it to.

`test_repro_underflowRegionNeverTerminates` and `test_repro_noUnderflowRegionAlsoNeverTerminates`
witness both regions by calling with a 3 000 000 gas cap and observing an out-of-gas child frame
(failure with empty return data). `test_repro_tenBytesTerminates` pins that **ten**, not
thirteen, is the smallest terminating length.

* **Reachability.** `args.length` is the second byte of the instruction word, read at
  `VM.sol:131` as a full `uint8`; every value `0..255` is expressible. Nothing validates it —
  `runLoop` checks only `pcs <= length`, and the instruction checks nothing. A mis-assembled
  program or an off-by-one in a builder produces it directly.
* **Impact.** Denial of service, in its most expensive form: the taker's *entire gas budget* is
  consumed rather than a revert being returned. Funds safe.
* **Who bears it.** Maker's order is permanently unfillable; **every taker who quotes it burns
  their full gas limit**. That gas-trap property is what lifts this above LOW.
* **Guard elsewhere.** None.
* **Note for the proof track.** Any test pinning this must be excluded from `kontrol prove` —
  gas is off by default there, so the loop is genuinely infinite.

### DutchAuction — unguarded division by zero, at the instruction level

**Level: CONFIRMED.** `test/kontrol/analysis/repro/DutchAuctionDivByZeroRepro.t.sol`. Previously
confirmed only through `PowerSpec`'s `pow` witnesses; now reproduced against
`_dutchAuctionBalanceOut1D` itself.
**Criticality: MEDIUM.**

`:97` computes `ctx.swap.balanceOut * 1e18 / decay` where `decay = decayFactor.pow(elapsed, 1e18)`.
`decay` reaches **exactly zero** in finite time for every legal factor, and the collapse is a
cliff: the last non-zero value is 1 wei and the next step is 0.

* `decayFactor = 0.99e18` — the docstring's own headline value, "1% decay/sec" — alive at
  `elapsed = 4096`, `Panic(0x12)` at `elapsed = 4097`. About 68 minutes.
* `decayFactor = 0.5e18` — steep but legal — dies at **60 seconds**.

`duration` is a `uint16`, so up to 65 535 seconds, and `test_repro_deathIsBeforeExpiry` pins that
the `require(block.timestamp <= startTime + duration)` at `:94` still passes when the panic
fires: the auction dies **before its own advertised deadline**, and the caller sees a bare panic
rather than `DutchAuctionExpired`.

* **Reachability.** Time is the only input. No attacker, no unusual parameter — a documented
  decay factor and an ordinary duration suffice. `decayFactor < 1e18` is enforced only in
  `DutchAuctionArgsBuilder.build`, an off-chain helper; `parse` (`:36-44`) checks nothing. But
  the bound would not help anyway, since the panic happens for legal factors.
* **Impact.** Denial of service. Funds safe.
* **Who bears it.** Maker (order stops filling mid-auction), taker (wasted gas, unattributable
  error).
* **Guard elsewhere — and this is the important part.** The mirror instruction
  `_dutchAuctionBalanceIn1D` *multiplies* by `decay`, so it silently sets `balanceIn = 0`
  (`test_repro_balanceInCollapsesToZero`). That looks far worse than a panic: a constant-product
  swap against a zero input reserve would hand the taker the entire output balance for one wei.
  **It is already guarded.** `XYCSwap` reverts with `XYCSwapRequiresBothBalancesNonZero`
  (pinned in `test_repro_zeroBalanceInIsGuardedDownstream`) and `LimitSwap` with
  `LimitSwapRequiresBothBalancesNonZero` — the two curves `DutchAuction` is documented to sit
  alongside. `TWAPSwap`'s own `0.9999e18` decay likewise multiplies (`:154`) and is caught by the
  same `LimitSwap` guard. **There is no drain here**, and that is the single most important fact
  about this finding.

### PeggedSwap — rounding is not maker-favourable, and the leak is ulp-scaled

**Level: CONFIRMED** (promoted from MODELLED).
`test/kontrol/analysis/repro/PeggedSwapRoundingRepro.t.sol`, `test_repro_roundTripProfits`.
**Criticality: LOW.**

The MODELLED claim was that `amountOut` can land 1 wei above `floor(exact)` and `amountIn` 1 wei
below `ceil(exact)`, checked against a 120-digit model. Re-establishing it needed a formulation
with **no reference model at all**, since a model is exactly what was in doubt.

That formulation is a round trip. `PeggedSwap` charges no fee, so swapping `k` wei of X for Y and
immediately swapping all of it back must break even; any strict gain is rounding leaking to the
taker. The curve re-anchors from current reserves on every call (`:148-154`), so the second leg
does not remember the first.

Witness at `x0 = y0 = 1e27`, `linearWidth = 0`, `rateLt = rateGt = 1`, pool at `(1e27, 1e27)`:

| step | in | out |
|---|---|---|
| exact-in X→Y, pool `(1e27, 1e27)` | 3 | 2 |
| exact-in Y→X, pool `(1e27 - 2, 1e27 + 3)` | 2 | 5 |

3 wei in, 5 wei out. **+2 wei to the taker**, with the pool's Y reserve restored and its X reserve
short by 2. The claim is therefore confirmed — and in a *stronger* form than the model reported:

| `x0_init` | best round-trip gain |
|---|---|
| `1e26` and below | 0 |
| `1e27` | 4 wei |
| `1e28` | 40 wei |
| `1e29` | 400 wei |
| `1e30` | 4000 wei |

The gain is `~4 * x0_init / ONE` wei — a few `u`-ulps, not a fixed wei. The same mechanism, and
the same `x0_init > ONE` threshold, as the underflows below.

* **Reachability.** Requires `x0_init >= 1e27`. Nothing on chain rejects it, and
  `test/PeggedSwap.t.sol:1024` exercises `1e30` directly, but the repo's own fixture is at `1e21`
  (`test/invariants/pegged/BalancedCurve.t.sol:17-18`), where
  `test_repro_realisticPoolsDoNotLeak` shows no leak at all.
* **Impact.** Silent wrong arithmetic — the worst *class*, and here the smallest *magnitude*.
  Because the gain is proportional to `x0_init` and `x0_init` is proportional to the pool size,
  the leak is a **relative** `~4e-27` of the pool per round trip, independent of trade size.
  Extracting 1% of a pool needs `~2.5e24` round trips at `~1e5` gas each. It is systematically in
  the same direction and it is not cheaply repeatable: gas exceeds the prize by roughly twenty
  orders of magnitude.
* **Who bears it.** The maker.
* **Guard elsewhere.** None, and none is needed at this magnitude. The repo's own tests already
  accommodate the slack (`test/PeggedSwap.t.sol:509` uses `assertGe(inv1, inv0 - 5e24)`).

This is exactly the rounding case worth being careful about: same direction every time, so the
instinct to call it serious is right, but the magnitude does not survive contact with gas costs.
Report it as a correctness note, not as a vulnerability.

### PeggedSwap — `Panic(0x11)` underflow at `:215` (exact-out)

**Level: CONFIRMED.** `test/kontrol/analysis/repro/PeggedSwapUnderflowRepro.t.sol`.
**Criticality: LOW** (was implicitly treated as the strongest entry in this file; the
reachability measurement below is what changed that).

`:215` computes `Math.ceilDiv(x1 - x0, rateIn)` with a **checked** subtraction, where `x1` is
reconstructed from `x0` through `x0 -> u -> solve -> u' -> x1`. That round trip is not expansive:
normalisation at `PeggedSwapMath.sol:47` floors, and `solve` floors twice more (`:100`, `:103`).
When `x0_init` is large relative to `ONE = 1e27`, one `u`-ulp is worth `x0_init / ONE` wei of
`x0` — more than the reconstructing `ceilDiv` can add back — so `x1 < x0` is reachable and the
subtraction reverts with a **bare `Panic(0x11)`**, not a named SwapVM error.

Witness: `x0_init = y0_init = 1e30`, `linearWidth = 0`, `rateLt = rateGt = 1`,
`balanceIn = 1e30 + 1`, `balanceOut = 1`, `amountOut = 1`, `tokenIn < tokenOut`. Then `u = 1e27`
(the `+1` truncates away — one ulp here is 1000 wei), `v = 0`, `C = 1e27`, `y1 = 0`,
`u' = solve(1e27, 0) = 1e27`, `x1 = 1e30`, so **`x1 - x0 = -1`**. One wei less on `balanceIn` and
the same call succeeds — the failure is discontinuous in a single wei.

**Reachability, measured rather than assumed.** This is what the entry was missing.

* `x0_init` must exceed `ONE`. Clean at every normaliser up to and including `1e26`
  (`test_repro_thresholdIsAroundONE`); first failures around `3e26`; widespread at `1e27`+.
  Below that a `u`-ulp is worth less than a wei and the `ceilDiv` covers the loss.
* **The failing requests are dust.** On a pool at `(x0_init + 1, x0_init)` with `A = 100e27`, the
  smallest `amountOut` that prices successfully is `~10 * x0_init / ONE` wei — ten ulps:
  `1e2` at `x0_init = 1e28`, `1e3` at `1e29`, `1e4` at `1e30`
  (`test_repro_onlyDustSizedRequestsRevert`). At `1e30` the entire reverting window is
  `amountOut < 1e4` wei out of a `1e30` wei reserve, a relative size of `1e-26`.
* **Economically meaningful trades never revert.** `test_repro_meaningfulTradesNeverRevert`
  sweeps normalisers `1e18..1e30`, pools displaced 1–8 %, and requests of 0.1–0.4 % of the output
  reserve: 416 calls, zero failures.
* **Rate scaling protects rather than amplifies.** With a 6-vs-18-decimal pair (`rateLt = 1e12`)
  the final `ceilDiv(..., rateIn)` divides the lost wei away; a sweep of raw balances `1e6..1e18`
  — normalisers `1e18` up to `1e30` — produces no underflow at all
  (`test_repro_rateScalingIsNotAnAmplifier`).

* **Impact.** Denial of service on a dust-sized quote. Funds safe.
* **Who bears it.** Programs are maker-signed, so this is maker self-harm: an order configured
  this way is silently unquotable for small exact-out amounts while appearing healthy. The one
  integration hazard worth naming is that routers commonly probe an unknown pool with a dust
  amount, and such a probe receives an unattributable arithmetic panic instead of a price.
* **Guard elsewhere.** None. `parse` (`:52-61`) checks only that `x0`, `y0` are non-zero, and the
  source comments at `:162` and `:202` contemplate `x1 <= 1e30` while enforcing nothing.

**Note on provenance, worth keeping.** A Kontrol proof of this witness FAILED, which looked at
first like evidence against the finding. It was not: the spec declared its error selectors
`immutable`, and `run-constructor = false` makes immutables read as zero under Kontrol, so the
selector comparison failed while the revert reproduced exactly. **A failing proof is not evidence
against a bug until you have read why it failed.**

### PeggedSwap — the same underflow at `:179` (exact-in drain path)

**Level: CONFIRMED.** `test_repro_exactInDrainPathAlsoUnderflows`. **New entry** — `FINDINGS.md`
named `:179` alongside `:215` but this ledger tracked only `:215`, and the two have different
trigger conditions.
**Criticality: LOW.**

`:179` computes `Math.ceilDiv(x1Capped - x0, rateIn)` on the capacity/drain path, where
`x1Capped = ceilDiv(solve(targetInvariant, A) * x0_init, ONE)`. Same lost-ulp mechanism, different
entry condition.

Witness: `x0_init = y0_init = 1e28`, `A = 0`, `balanceIn = 1e28 + 1`, `balanceOut = 1`. Then
`v == 0`, so the capacity check at `:173` always trips, `uMax = 1e27`, `x1Capped = 1e28 < x0`, and
the call reverts for **every** `amountIn` — 1 wei, `1e18`, `1e28`, `2e28` all panic.

Where it differs from `:215`: once triggered it is total rather than dust-only. But the trigger is
narrower — it needs `balanceOut * ONE / y0_init == 0`, i.e. the output reserve fallen below one
`u`-ulp. At `x0_init = 1e28` that means `balanceOut <= 9`; at `balanceOut = 16` the same call
drains cleanly and returns 16 (`test_repro_exactInDrainPathRecoversAboveOneUlp`).

* **Reachability.** An exhausted output reserve on a pool with `x0_init > ONE`. `DynamicBalances`
  decrements `balanceOut` by each fill, so reaching a sub-ulp reserve is a natural end state, not
  a contrived one — but a pool in that state has nothing left to sell.
* **Impact.** Denial of service on an already-empty pool. Funds safe.
* **Who bears it.** Maker. The correct behaviour would be to drain and return `amountOut = balanceOut`.
* **Guard elsewhere.** None. `PeggedSwapBothBalancesZero` (`:104`) fires only when **both**
  balances are zero, so the one-sided exhaustion that triggers this passes straight through.

### PeggedSwap — `Panic(0x11)` overflow on exact-in, at `:163` *and* `:167`

**Level: CONFIRMED** (promoted from SOURCE).
`test/kontrol/analysis/repro/PeggedSwapOverflowRepro.t.sol`.
**Criticality: LOW.**

**Correction to the previous entry.** It attributed this to `:167` alone. That holds only for
`x0_init < ONE`. Which multiplication overflows first depends on the normaliser:

* `x0_init < ONE = 1e27` — `:167`'s `u1 * ONE` overflows first, at `x1 > ~1.16e23 * x0_init`;
* `x0_init >= ONE` — `:163`'s own `x1 * ONE` overflows first, at `x1 > 2**256/ONE ~= 1.16e50`.

Measured smallest power-of-ten `amountIn` that reverts, balanced pool
(`test_repro_thresholdScalesThenSaturates`):

| `x0_init` | 1e18 | 1e21 | 1e24 | 1e26 | 1e27 | 1e28 | 1e30 |
|---|---|---|---|---|---|---|---|
| `amountIn` | 1e42 | 1e45 | 1e48 | 1e50 | 1e51 | 1e51 | 1e51 |

which is `1.16e23 * x0_init` on the left of the crossover and a flat `1.16e50` on the right.

Neither multiplication is guarded, and the instruction *has* a designed answer for an oversized
input — the capacity check at `:173` caps `x1` at `uMax` and drains the output reserve. The
overflow happens first, so for a large enough `amountIn` the graceful clamp is never reached.
`test_repro_clampWorksJustBelowTheThreshold` pins the clamp working one order of magnitude below.

* **Reachability.** The ledger's witness (`x0 = y0 = 1`, `amountIn = 1e24`) reproduces, but a
  1-wei normaliser is the most amplifying configuration expressible. At `x0_init = 1e21` the
  threshold is `~1e44` wei — beyond the total supply of any deployed ERC20 by ten orders of
  magnitude; `test_repro_realisticNormaliserNeedsAbsurdAmountIn` shows `1e33` (roughly the largest
  real 18-decimal supply) pricing cleanly. It is nonetheless reachable, because `SwapVM` never
  checks the taker's `amount` against their balance before `runLoop`: a `quote()` probe, or a swap
  that would have failed at the transfer anyway, hits the panic.
* **Impact.** Denial of service, and a quoting-robustness defect — the caller cannot distinguish
  "over capacity" from "arithmetic fault".
* **Who bears it.** Self-inflicted in every case. No third party can push someone else's
  `amountIn` to these values.
* **Guard elsewhere.** The source comments at `:162` and `:166` assert bounds nothing enforces —
  `:166` claims `a <= 2e27` where `MAX_LINEAR_WIDTH` is `5e30`.

### XYCConcentrate — `Panic(0x12)` on a zero-liquidity pool

**Level: CONFIRMED, against the real instruction** (promoted from SOURCE).
`test/kontrol/analysis/repro/XYCConcentrateDivByZeroRepro.t.sol`.
**Criticality: LOW.**

`HARNESS-FIDELITY.md` §Tier 2 records that every `XYCConcentrate` property in this repo was proven
against a hand-written copy of `:143-159`, and that the two differentials which would connect the
copy to the deployed code have never closed. This finding therefore needed re-deriving from
`_xycConcentrateGrowLiquidity2D` itself before it could be reported. **It reproduces — the copy
was faithful on this point.**

The exact-out leg (`:155-158`) divides by `virtualBalanceOut - amountOut` with no guard. On an
empty pool `_computeL` returns `0`, so the virtual offset is `0`, so
`virtualBalanceOut == balanceOut == 0`; `amountOut` is clamped to `balanceOut` at `:153-154`,
making the divisor exactly zero. OZ's `Math.ceilDiv` validates its divisor *before*
short-circuiting on a zero numerator, so **even a zero-amount request panics**, and the request
size is irrelevant. The exact-in leg has the same hole one line up at `:145`.

What makes it worth reporting is not the panic — it is that `XYCConcentrate` is the **only swap
curve in the instruction set without a zero-balance guard**:

| instruction | guard |
|---|---|
| `XYCSwap` | `XYCSwapRequiresBothBalancesNonZero` |
| `LimitSwap` | `LimitSwapRequiresBothBalancesNonZero` |
| `PeggedSwap` | `PeggedSwapBothBalancesZero` |
| `XYCConcentrate` | *(none)* → bare `Panic(0x12)` |

An integrator that distinguishes "no liquidity" from "broken" by matching named errors will
mis-classify this one. `test_repro_siblingCurvesGuardTheSameState` pins the contrast.

* **Reachability.** An empty pool is ordinary. `StaticBalances` writes whatever the program says,
  including `(0, 0)`; `DynamicBalances` re-parses its arguments whenever
  `balanceIn | balanceOut == 0`, so a program configured with zero initial balances stays at zero.
* **Impact.** Denial of service on a pool with nothing in it. Funds safe.
* **Who bears it.** Nobody, materially. It is a liveness and error-hygiene defect.
* **Guard elsewhere.** None — that is the finding.

### Power — the trailing square panics on a representable answer

**Level: CONFIRMED.** `test/kontrol/analysis/repro/PowerTrailingSquareRepro.t.sol`, and
`test_squaring_*` in `PowerSpec`.
**Criticality: INFORMATIONAL** — this is the entry whose criticality moved most, and it moved
*down*.

`Power.pow`'s loop is `while (exponent > 0)`, so it squares `base` once more after the final set
bit has been consumed. That square is dead work — its result is never read — but it is checked
arithmetic, so it reverts on inputs whose answer is perfectly representable:

* `pow(2**128, 1, p)` reverts `Panic(0x11)` for **every** `p`, including `1e18`, though the answer
  is just `B`.
* `pow(2, 255, 1)` reverts, while `2 ** 255` is fine.

The totality frontier is exactly `precision <= type(uint128).max`: `pow(2**128 - 1, 3, 2**128 - 1)`
succeeds and `pow(2**128, 2, 2**128)` panics. solc's own `**` iterates while `exponent > 1` and
does not have this.

**Reachability — the check the entry was missing.** `Power` has exactly two callers
(`FINDINGS.md`, exhaustive grep): `DutchAuction.sol:85`/`:96` and `TWAPSwap.sol:152`.

* `TWAPSwap` passes the constant `0.9999e18`. `base <= precision` holds forever, every squaring is
  a contraction, no overflow is possible. **Unreachable.**
* `DutchAuction` passes `decayFactor`, a `uint64`. For every factor `build` permits (`< 1e18`) the
  squarings are contractions and `pow` is total — pinned across the whole `uint16` exponent range
  by `test_repro_legalFactorsNeverOverflow`. **Unreachable for legal parameters.**

It *is* reachable through `DutchAuction` with `1e18 < decayFactor <= type(uint64).max`, which
`build` rejects and `parse` does not:
`test_repro_reachableThroughDutchAuctionOnlyWithIllegalFactor` shows `decayFactor = 2e18` at
`elapsed = 128` panicking on a representable result (`2**128 * 1e18 ~= 3.4e56`). But such a factor
inverts the auction — the price gets *worse* for the taker over time — so it is maker-signed
self-harm on an already-nonsensical configuration.

* **Impact.** Denial of service, on a configuration nobody sane writes.
* **Who bears it.** The maker who wrote it.
* **Guard elsewhere.** `build`'s `require`, which is off-chain and therefore not a guard, but is
  the only way anyone assembles these arguments in practice.

Report it as a library-hardening item: it is dangerous to the *next* caller, not to the current
ones. The branchless rewrite at the end of this file removes it as a side effect.

Related: the panic code for the zero-precision case is **not uniform**. `p == 0, E > 0` gives
`Panic(0x12)` for every odd exponent and for even exponents with `base <= type(uint128).max`, but
at `base = 2**128, E = 2` the trailing square overflows first and the panic is `0x11`.

### PiecewiseLinearScale — silent truncation in `unscaleValue`

**Level: CONFIRMED.**
`test/kontrol/analysis/repro/PiecewiseLinearScaleUnscaleTruncationRepro.t.sol`.
**Criticality: INFORMATIONAL.**

`:64` computes `((value << 24) + scale) / (scale + 1)`. Solidity's `<<` is not overflow-checked —
unlike `*`, which would revert — so for `value > type(uint232).max` the top 24 bits are discarded
and the function returns a wrong answer with no revert. At `value = 2**232` it returns `0`, and
the documented round trip `scaleValue(unscaleValue(v, s), s) == v` (`:62`) is silently false.
`test_repro_multiplyWouldHaveReverted` pins that the equivalent multiplication does revert, which
is the whole bug in one comparison.

* **Reachability. None on chain.** An exhaustive grep finds `unscaleValue` in exactly three
  places: its own definition, the integration docstring at `:87`, and
  `test/PiecewiseLinearScale.t.sol`. `_runOpcode` never reaches it; `_calcScaleNow` uses
  `parsePointScale`/`parseIntervalDuration` instead. It is a maker-side helper for computing an
  order parameter off chain. And the frontier is `2**232 ~= 6.9e69` wei — thirty-five orders of
  magnitude above any token supply.
* **Impact.** A maker computing an order parameter off chain could get a wrong number back and
  sign an order that does not do what they meant. Only if they passed nonsense in the first place.
* **Who bears it.** The maker, hypothetically.
* **Guard elsewhere.** The repo's own fuzz test bounds its input
  (`test/PiecewiseLinearScale.t.sol:68`), so the precondition exists but is undocumented.

The honest framing is an undocumented precondition on a helper, not a bug in the VM. Fix is a
`require` or a `*` in place of the `<<` — either turns a silent wrong answer into a revert.

---

## SOURCE — negative claims, which no execution can witness

### Dead code: two unreachable `require`s in the PeggedSwap path

**Level: SOURCE**, and it cannot rise above that: unreachability is a negative claim, so
execution can only fail to refute it. `test/kontrol/analysis/repro/PeggedSwapDeadCodeProbe.t.sol`
does that failing-to-refute across 20 000 fuzz runs plus an exhaustive corner grid (`x0`, `y0`,
balances and amounts drawn from `{1, 2, 1e18, 1e27, 1e30, 1e33}`, widths from
`{0, 1, MAX_LINEAR_WIDTH}`, both directions). Neither error ever fired.
**Criticality: INFORMATIONAL.** Not bugs — dead code, worth reporting as cleanup.

* **`PeggedSwapMathNoSolution`** (`PeggedSwapMath.sol:95`). `discriminant = ONE + fourARightSide
  >= ONE` at `:89`, so `sqrtDiscriminant = isqrt(discriminant * ONE) >= isqrt(ONE * ONE) = ONE`
  and the `require` cannot fail. The proof needs `isqrt` monotonicity **and**
  `isqrt(ONE*ONE) == ONE`; the latter alone is not enough (corrected in `FINDINGS.md`).
* **`PeggedSwapMathInvalidInput`** (`PeggedSwap.sol:206`). The clamp at `:196` gives
  `amountOut <= balanceOut`, hence `y1 <= y0`, hence `v1 <= v` by monotonicity of flooring, hence
  `invariantV1 = isqrt(v1*ONE) + floor(a*v1/ONE) <= isqrt(u*ONE) + isqrt(v*ONE) + floor(a*(u+v)/ONE)
  = targetInvariant`.

**Corollary, and the reason the second one matters beyond tidiness:** the subtraction at `:199`
cannot underflow either, which leaves `:215` as the only candidate when attributing an exact-out
`Panic(0x11)`. That is what licenses the attribution in the `:215` entry above.

---

## Documentation contradicted by the code

Recorded here rather than in `FINDINGS.md` because each one is directly load-bearing for an entry
above. Code is authoritative in every case.

* **`DutchAuction`'s contract docstring describes a different instruction.** `:50-51` say it is
  "designed to be used **after** any swap instruction" and "applies time-based decay to the
  **amounts** calculated by the previous swap". The code does neither: `:80` and `:91` `require`
  that at least one amount register is still zero
  (`DutchAuctionShouldBeAppliedBeforeSwapAmountsComputed`), which no post-swap state satisfies —
  a completed swap has both non-zero — and the bodies adjust `balanceIn`/`balanceOut`, not the
  amounts. Anyone integrating from the docstring writes a program that reverts on this
  instruction.
* **`DutchAuctionArgsBuilder.build` is not a guard**, and neither is any other `build`. Program
  bytes are maker-assembled; `parse` is the only thing that runs on chain, and it validates
  nothing. This is what makes the `decayFactor > 1e18` path in the `Power` entry reachable at all.
* **`BaseFeeAdjusterArgsBuilder` validates nothing whatsoever** — no `require` in either `build` or
  `parse`, despite `maxPriceDecay` having two distinct out-of-range behaviours above `1e18` and
  above `2e18`.
* **`PiecewiseLinearScale._calcScaleNow`'s comment (a) is wrong twice.** `:116` says "At least two
  points provided -> `args.length >= 13` bytes" and `:128` cites it as "No underflow by (a)".
  Nothing enforces it, and 13 is not the real frontier: ten bytes terminates. A 10-byte argument
  list also reads `parsePointScale(1)` past its own arguments into the following program bytes,
  and returns that as a scale.
* Previously recorded in `FINDINGS.md` and still true: the curve equation at `PeggedSwap.sol:84`
  and `:109` is off by a factor of two and describes a fixed invariant the code does not use;
  `PeggedSwapMath`'s scale docstrings say `sqrt(ONE)` where the scale is `ONE`; and
  `docs/PeggedSwap/PeggedSwapWP.md`, cited at `:126`, does not exist.

---

## Proposed upstream fix — branchless constant-trip-count `Power.pow`

Validated bit-exactly against the current implementation on 20,000 random `(B <= p, E < 2^16)`
triples at `p` in `{1e18, 2^40, 97, 2^127}` — zero mismatches.

```solidity
/// 16 iterations, no data-dependent branch. Sound for base <= precision.
function pow16(uint256 base, uint256 exponent, uint256 precision) internal pure returns (uint256 result) {
    result = precision;
    for (uint256 i = 0; i < 16; ++i) {
        uint256 m = 0 - ((exponent >> i) & 1);
        result = (result * ((base & m) | (precision & ~m))) / precision;

        uint256 live = 0 - ((exponent >> i) != 0 ? 1 : 0);
        base = (base * ((base & live) | (precision & ~live))) / precision;
    }
}
```

The selects are exact rather than approximate: when the bit is clear the multiplier is
`precision`, and `result * precision / precision == result` with no floor loss because
`precision` divides the product.

It buys three things. It **removes the trailing-square panic** — once the exponent is exhausted
the squaring becomes the identity. It makes gas **constant**, which also makes `.gas-snapshot`
deterministic for `DutchAuction`. And it collapses every full-`uint256`-exponent property from
"needs a loop invariant" to a single-path goal.

Two caveats before proposing it. It is only sound for `base <= precision` unless the `live`
guard is kept (the sketch keeps it); `DutchAuction` satisfies this by construction *for legal
factors only*, and `TWAPSwap` by its hardcoded `0.9999e18`, but a general caller does not. And it
costs 16 mul/div pairs unconditionally, so it is roughly gas-neutral at large `elapsed` and more
expensive for small — the `uint16` bound on `duration` is what makes it specifically attractive
for `DutchAuction` rather than in general.

**It does not fix the `DutchAuction` division by zero.** `pow` still returns `0` once the decay
underflows, and `:97` still divides by it. That needs its own guard.

---

## Reachability gaps not closed

Stated rather than guessed at, because an honest unknown is worth more than a confident wrong
answer:

* **No end-to-end program was executed.** Every witness here drives a hand-assembled `Context`
  directly into an instruction. Register provenance was traced through `SwapVM.sol` by reading,
  and each entry states who controls the values it needs, but no test routes a program through
  `ContextLib.runLoop` and a real router. The gap `HARNESS-FIDELITY.md` names is narrowed, not
  closed.
* **`MinRate`**: whether deployed maker programs actually sequence an `amountIn`-modifying
  instruction between `AdjustMinRate` and the swap. The instruction set makes it expressible;
  this repository contains no corpus of real programs to say how common it is.
* **`BaseFeeAdjuster`**: what fraction of takers set a `TakerTraits` threshold. This is the whole
  difference between "taker gets overcharged" and "taker's transaction reverts", and it is not
  answerable from the source.
* **`PeggedSwap`**: whether any intended deployment uses `x0_init >= 3e26`. Both the underflow and
  the rounding leak need it, the repo's fixture is nine orders below, and the source comments
  contemplate `1e30` — three signals pointing in two directions.
* **`PeggedSwap` dust probes**: whether routers in practice quote unknown pools with dust amounts.
  That is the only path by which the `:215` window stops being economically empty.
* **`XYCConcentrate`**: the two `test_diff_*` differentials remain unproven, so the six PASSED
  properties in `XYCConcentrateSpec` are still statements about a transcription. The zero-liquidity
  finding no longer depends on them — it was re-derived against the real instruction — but nothing
  else was.
* **`DutchAuction` + `XYCConcentrate`**: the "no drain" verdict in the `DutchAuction` entry was
  executed against `XYCSwap` and read against `LimitSwap`. `XYCConcentrate` has no zero-balance
  guard either, and a `balanceIn` zeroed by `_dutchAuctionBalanceIn1D` would be priced against a
  non-zero *virtual* reserve rather than against zero — reasoning says that is not a free drain,
  but **this one was not executed**. If a single further check is worth running, it is this one.

# Candidate bugs — status and evidence

Working file for findings that may warrant an upstream report to 1inch / Degensoft. Nothing
here should be reported until it reaches **CONFIRMED** status, with a reproducible witness.

## Evidence levels

Findings carry one of three levels, and the distinction is load-bearing:

| Level | Meaning |
|---|---|
| **CONFIRMED** | Reproduced by executing the EVM — a `forge test` witness, or a Kontrol counterexample with its path condition. Safe to report. |
| **SOURCE** | Derived by reading the source and reasoning about it. Strong, but no execution has confirmed the path is reachable. |
| **MODELLED** | Produced by a separate model of EVM semantics (e.g. a Python re-implementation), not by executing the EVM. **Must be re-validated before reporting.** |

The distinction has already earned its keep. `PeggedSwap`'s underflow was MODELLED, and when a
test pinning it was put through Kontrol it did not reproduce — see below. Had it been reported
on the strength of the model alone it would have been wrong.

---

## Under investigation

### PeggedSwap — claimed `Panic(0x11)` underflow at `:179` / `:215`

**Level: MODELLED — currently contradicted by Kontrol.**

Claim: `ceilDiv(x_new - x0, rateIn)` underflows because the round trip
`x0 → u → solve → u' → x_new` is not expansive, so `x_new < x0` is reachable. Measured
threshold: clean at `x0_init <= 2e26`, first underflows at `3e26`. Claimed witness for `:215`:
`balanceIn = 1e30 + 1`, `balanceOut = 1`, `amountOut >= 1`, `x0 = y0 = 1e30`,
`linearWidth = 0`, `rateLt = rateGt = 1`, `tokenIn < tokenOut`.

Contradiction: `test_knownUnderflow_exactOutAtLargeReserves` passes under `forge test` but
**fails under Kontrol** with `=recorded witness must revert wit: 0 != 1`, status `EVMC_REVERT`,
path condition `#Top`. The witness does not revert as claimed under KEVM.

Four possibilities, under investigation: the test catches a different revert than the one it
claims (a parse-guard revert would make it pass for the wrong reason); the witness values are
wrong but some other input triggers it; the bug is not real and the finding must be retracted;
or revm and KEVM genuinely disagree, which would need strong evidence.

**Do not report this until resolved.**

### PeggedSwap — maker-favouring rounding false by 1 wei

**Level: MODELLED — not yet re-validated.**

Claim: checked against the exact curve at 120 decimal digits, `amountOut` can land 1 wei above
`floor(exact)` and `amountIn` 1 wei below `ceil(exact)`, because two floors inside `solve`
(`PeggedSwapMath.sol:100`, `:103`) round in the taker's favour.

Same provenance as the item above, so it inherits the same doubt. Needs an executed witness
before it is reported.

---

## Source-derived, awaiting an executed witness

### PiecewiseLinearScale — non-terminating loop on short args

**Level: SOURCE.** Two distinct causes, and a fix addressing only the first leaves the second
open:

- `args.length <= 4` — `args.length / 5 - 1` underflows inside `unchecked`, so `max` becomes
  `type(uint256).max` and the `++num == max` exit is unreachable.
- `5 <= args.length <= 9` — no underflow; `max` is cleanly `0`. The loop still cannot terminate
  because `num` is pre-incremented, making `++num == 0` as unreachable as `++num == 2**256-1`.

Consequence is out-of-gas, not a revert. **Ten**, not thirteen, is the smallest terminating
length. `test_argsLength_underThirteenBytesNeverTerminates` witnesses both regions under
`forge test` — that test must be excluded from `kontrol prove`, since gas is off by default
there and the loop is genuinely infinite.

### DutchAuction — unguarded division by zero

**Level: SOURCE.** `DutchAuction.sol:97` divides by `decay`. `decayFactor < 1e18` is enforced at
build time (`:28`), so repeated squaring drives `decay` to zero for large `elapsed`, giving a
reachable unguarded `Panic(0x12)`. The `decayFactor` check does not prevent it.

### PiecewiseLinearScale — silent truncation in `unscaleValue`

**Level: SOURCE, with a forge witness.** `:64` computes `value << 24`; Solidity's `<<` is not
overflow-checked, so the top 24 bits are discarded for `value > type(uint232).max` and the
function returns a wrong result with no revert. `test_value_unscaleSilentlyTruncatesAboveUint232`
pins it concretely at `value = 2**232`, where it returns `0`. The repo's own fuzz test works
around this by bounding its input (`test/PiecewiseLinearScale.t.sol:68`), so the precondition
exists but is undocumented.

### PeggedSwap — second `Panic(0x11)`, overflow at `:167`

**Level: SOURCE, found as a forge counterexample.** Distinct in kind from the `ceilDiv`
underflows above: driven by the **ratio** `amountIn / x0_init` rather than by absolute size.
`u1 = (x0 + amountIn·rateIn)·ONE / x0_init` at `:163` is bounded only by `2^256/ONE`, so
`u1 · ONE` at `:167` overflows once `u1 > ~1.16e50`. Witness at entirely ordinary parameters:
`x0 = y0 = 1`, `balanceIn = balanceOut = 1`, `rates = 1`, `linearWidth = 0`,
`amountIn = 1e24`. The source comments at `:162` and `:166` assert bounds nothing enforces.

Note this one has an executed witness and so is closer to CONFIRMED than the items above; it
needs the same Kontrol cross-check before reporting.

### BaseFeeAdjuster — three unguarded paths

**Level: SOURCE, mutation-tested specs.** Out of Track B scope, recorded for completeness.

- `maxPriceDecay > 2e18` makes the order unexecutable exact-in: `2e18 - maxPriceDecay` at `:93`
  underflows. Bare `Panic(0x11)`, not a named error, and it only fires once gas rises above
  base — so the order looks healthy while gas is cheap.
- Exact-out underflows instead of clamping: `1e18 - q` at `:98` is computed *before* the
  `Math.max` clamp at `:99`, so the clamp cannot rescue it. The same order reverts exact-out and
  succeeds exact-in under identical gas.
- `maxPriceDecay > 1e18` **inverts the adjustment against the taker** — the exact-out discount
  becomes a surcharge. This is the economically serious one.

### XYCConcentrate — `Panic(0x12)` on zero-liquidity exact-out full fill

**Level: SOURCE, with a forge witness.** When the reconstructed output offset is zero
(`vOut == balanceOut`) and the taker requests at least the whole balance, `Math.ceilDiv` divides
by zero. OZ validates the divisor *before* short-circuiting on a zero numerator, so even a
zero-amount request panics. Liveness rather than safety, but it is the exact boundary at which
the exact-out leg stops being total.

### MinRate — AdjustMinRate does not enforce the floor

**Level: SOURCE, with a forge witness.** Out of Track B scope, recorded for completeness. The
clamp reads the pre-`runLoop` register while the comparison reads `runLoop`'s result
(`MinRate.sol:56` vs `:65-67`). Witness: floor 1:1, pre-run `amountIn = 100`, program returns
`(50, 100)` — the clamp recomputes from the stale 100 and leaves the registers at 0.5:1, which
`RequireMinRate` would reject. Any input-side fee or partial fill sequenced between
`AdjustMinRate` and the swap reaches this.

---

## Dead code (not bugs, but worth reporting)

- **`PeggedSwapMathNoSolution`** (`PeggedSwapMath.sol:95`) is unreachable: `discriminant >= ONE`
  always, so `sqrtDiscriminant >= ONE`. Needs only `isqrt` monotonicity plus
  `isqrt(ONE·ONE) == ONE` to prove.
- **`PeggedSwapMathInvalidInput`** (`PeggedSwap.sol:206`) is likewise unreachable: the clamp at
  `:196` gives `amountOut <= balanceOut`, hence `v1 <= v`, and flooring is monotone. Corollary:
  the subtraction at `:199` cannot underflow, which leaves `:215` as the only candidate when
  attributing an exact-out `Panic(0x11)` — directly relevant to the investigation above.

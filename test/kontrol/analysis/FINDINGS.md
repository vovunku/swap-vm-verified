# Instruction analysis — findings and corrections

Output of a semantics-reading pass over the Tier-2/3 instructions, done before writing any
specs for them. Everything here is derived from source with `file:line` citations; where a
claim came from executing a bit-exact model rather than from reading, it is marked
**[measured]** and should be treated as "no counterexample found in the sampled region",
not as a proof.

Read this before picking up `PeggedSwap`, `XYCConcentrate`, `PiecewiseLinearScale` or
`Power`. Several of the assumptions in the first draft of `WORKPLAN.md` turned out to be
wrong, and acting on them would have wasted days.

---

## Corrections to the original work plan

**`BaseFeeAdjuster` is Tier 1, not Tier 2.** It imports only `Math` and `Calldata`;
`_baseFeeAdjuster1D` (`src/instructions/BaseFeeAdjuster.sol:72-103`) is straight-line
`mulDiv` with two clamps, **no loop and no `pow`**. The original tiering was wrong. Same for
`SeriesEpochManager` — a storage read and an equality check
(`src/instructions/SeriesEpochManager.sol:68-73`).

**Only `DutchAuction` and `TWAPSwap` use `Power`.** An exhaustive grep finds `Power`
referenced in exactly three files: `src/libs/Power.sol`, `src/instructions/DutchAuction.sol:10`
and `src/instructions/TWAPSwap.sol:9`.

**`XYCConcentrate` has two `Math.sqrt` call sites, not 54.** The "54" was a count of lines
containing the substring `sqrt` — almost all are identifiers like `sqrtPriceMin`. Only
`XYCConcentrate.sol:107` is on the execution path (`:49` is in an off-chain helper). There
are also **no loops** on that path, so it never needs `--bmc-depth`. It is more tractable
than the plan assumed.

**`PiecewiseLinearScale` has one executed loop, not two.** The second
(`PiecewiseLinearScale.sol:24`) is inside an `internal pure` args builder that is never
reached from `_runOpcode`.

**`PeggedSwap` does not use `Power` and has no loops.** Curvature `p = 0.5` is realised as
`Math.sqrt`, not a general power.

---

## Apparent bugs

Ranked by how much they matter. None is obviously taker-exploitable — programs are
maker-signed, so these are mostly maker self-harm or liveness issues — but all are real
unguarded paths.

### 1. Reachable arithmetic underflow in `PeggedSwap` **[measured]**

`PeggedSwap.sol:179` and `:215` compute `ceilDiv(x_new - x0, rateIn)` with a **checked**
subtraction. The round trip `x0 → u → solve → u' → x_new` is not expansive, so `x_new < x0`
is reachable and the subtraction panics with `Panic(0x11)`.

Two independent sources of loss: normalisation truncation at `PeggedSwapMath.sol:47`
discards up to one `u`-ulp worth `x0_init / ONE` wei, which exceeds what the reconstructing
`ceilDiv` can add back whenever `x0_init > ONE`; and `solve` is not an exact inverse of the
invariant, with a measured deficit of up to **6 ulps** of `u`.

Empirical threshold, sweeping `x0_init = y0_init`: clean at `≤ 2e26`, first underflows at
`3e26`, widespread at `1e27` and above. Realistic pools sit around `1e21`
(`test/invariants/pegged/BalancedCurve.t.sol:17-18`), nine orders below — but the source
comments contemplate `1e30` (`PeggedSwap.sol:162`, `:202`) and `test/PeggedSwap.t.sol:1024`
tests at `1e30`, and **nothing on-chain rejects it**.

Witness for `:215`: `balanceIn = 1e30 + 1`, `balanceOut = 1`, `amountOut ≥ 1`,
`x0 = y0 = 1e30`, `linearWidth = 0`, `rateLt = rateGt = 1`, `tokenIn < tokenOut`.

### 2. Non-terminating loop on malformed args in `PiecewiseLinearScale`

`PiecewiseLinearScale.sol:128` computes `args.length / 5 - 1` inside an `unchecked` block.
With `args.length ≤ 9` this underflows to `type(uint256).max`, so the `++num == max` exit at
`:142` is unreachable. Duration words are then read past the end of `args` where
`calldataload` returns zero, `timeLeft -= 0` is a no-op, and the loop never terminates —
out-of-gas rather than a revert. The `Calldata.slice` overload used at `:123`/`:125`
performs no bounds checking by design.

### 3. Unguarded division by zero in `DutchAuction`

`DutchAuction.sol:97` divides by `decay`. Since `decayFactor < 1e18` is enforced at build
time (`:28`), repeated squaring drives `decay` to zero for large `elapsed`, giving a
reachable unguarded `Panic(0x12)`. The `decayFactor` check does not prevent it.

### 4. Silent truncation in `PiecewiseLinearScale.unscaleValue`

`PiecewiseLinearScale.sol:64` computes `value << 24`. Solidity's `<<` is **not**
overflow-checked, so the top 24 bits are silently discarded for
`value > type(uint232).max` and the function returns a wrong result with no revert. The fuzz
test quietly works around this by bounding its input
(`test/PiecewiseLinearScale.t.sol:68`). `value <= type(uint232).max` is an undocumented
precondition.

### 5. Dead code: `PeggedSwapMathNoSolution` is unreachable

`PeggedSwapMath.sol:89` sets `discriminant = ONE + fourARightSide ≥ ONE`, so
`sqrtDiscriminant = isqrt(discriminant · ONE) ≥ ONE` always, and the `require` at `:95`
cannot fail. Proving it unreachable is a cheap, genuinely useful first proof — it needs only
`isqrt` monotonicity and `isqrt(ONE·ONE) == ONE`.

---

## Properties that are FALSE and must not be ported naively

**`cannotDrainPool` is false for `XYCConcentrate`.** Unlike `XYCSwap`, it has a partial-fill
clamp (`XYCConcentrate.sol:146-149`, `:153-154`), so `amountOut == balanceOut` is reachable
and the tests assert balances hitting zero (`test/XYCConcentrate.t.sol:220`, `:233`).
Copying `assertLt(amountOut, balanceOut)` from `XYCSwapSpec.t.sol:66` across would produce a
failing proof that looks like a tool problem. The correct form is `≤`.

**"Rounding always favours the maker" is false for `PeggedSwap`** **[measured]**. Checked
against the exact curve at 120 decimal digits: `amountOut` can land 1 wei *above*
`floor(exact)` and `amountIn` 1 wei *below* `ceil(exact)`. Two floors inside `solve`
(`PeggedSwapMath.sol:100`, `:103`) round in the taker's favour and are not always
compensated by the `ceilDiv`s. The provable form is a ±1-wei bound, not a zero-slack one.
The repo's own tests already accommodate this (`test/PeggedSwap.t.sol:509` uses
`assertGe(inv1, inv0 - 5e24)`).

**The `XYCConcentrate` price-bound claim may be false by a small margin.** Flooring `L` at
five independent places means the implementation's `L` under-approximates the true root, so
`P ∈ [P_min, P_max]` does not automatically survive. The repo has a test named
`test_ConcentrateGrowLiquidity_SpreadSlowlyGrowsForSomeReason`
(`test/XYCConcentrate.t.sol:451`) documenting ~4.5e-8 % drift over 100 cycles. Prove
`bGt·1e18 ≤ L·Δ + ε` with a derived `ε`, not `ε = 0`.

**`XYCConcentrate` capital efficiency is conditional.** The test docstring claims concentrate
always beats `XYCSwap` at equal capital; the actual condition is
`dOut·(x + a) ≥ y·dIn`, i.e. it wins when the geometric centre `√(P_min·P_max)` is at or
above spot. The fixtures all satisfy it; the general claim does not hold.

---

## Documentation that contradicts the code

Code is authoritative in every case.

**The `PeggedSwap` curve equation is wrong twice over.** `PeggedSwap.sol:84` and `:109` (and
the whitepaper) state `√(x/X₀) + √(y/Y₀) + A(x/X₀ + y/Y₀) = 1 + A`. At the nominal point the
left side is `2(1 + A)` — off by a factor of two, confirmed by
`test/PeggedSwap.t.sol:1122-1125`. More importantly the code does not use a constant at all:
it **recomputes the target from current reserves on every call**
(`PeggedSwap.sol:148-154`). The curve re-anchors after every state change, including changes
made by other instructions in the same program. There is therefore no fixed global invariant
to preserve — only a per-call one, whose slack can compound across calls.

**`PeggedSwapMath` scale docstrings are wrong.** `:23`, `:38` and `:60` say the invariant is
"scaled by sqrt(ONE)". It is scaled by `ONE`. Anyone deriving bounds from the docstring will
be off by ~1e13.5.

**Several `PeggedSwap` overflow-safety comments cite unenforced or wrong bounds.** `:166`
says `a ≤ 2e27` where the real cap is `5e30`; `:162` and `:202` assert `x1 ≤ 1e30` which
nothing enforces. A spec cannot cite these as facts — they must be restated as explicit
`vm.assume` preconditions and recorded as domain narrowing.

**`docs/PeggedSwap/PeggedSwapWP.md` does not exist**, though `PeggedSwap.sol:126` cites it
for the parameter guide. The parameter bands at `:127-130` are unsourced.

---

## Verification strategy per instruction

### `PiecewiseLinearScale` — tractable, and the bound is *complete*

`runLoop` reads `argsLength` as a single byte (`src/libs/VM.sol:131`), so `args.length ≤ 255`
and the segment count `max ≤ 50`. The loop's extra branches all *terminate* it, so the KCFG
is a caterpillar with `O(k)` leaves, not `2^k`.

This means `--bmc-depth 51` yields an **unconditional** result, not a bounded one: if the
harness constrains `13 ≤ args.length ≤ 255`, the path entering iteration 51 is infeasible
and Kontrol closes it as vacuous. After the run, confirm no reachable `bounded` leaves
remain. No new lemmas expected — operands at `:149` are `< 2^40`.

### `Power.pow` — the problem is path count, not trip count

The trip count is `bitlength(exponent)`: **≤ 16** for `DutchAuction` (bounded by a `uint16`
duration), ≤ 256 for `TWAPSwap`. It always terminates. Calling it "an unbounded loop" was
wrong.

The real obstacle is that the branch on `exponent & 1` has **two continuing arms**, so leaves
grow as `2^bitlength` — up to 65 536 for `DutchAuction`. BMC is nominally the right tool and
practically hopeless.

Prove order properties instead, each by induction on `bitlength` using only monotonicity of
`floor` — no exponentials: `pow(B,0,p) = p`; `pow(p,E,p) = p`; `pow(0,E,p) = 0` for `E > 0`;
`B ≤ p ⇒ pow(B,E,p) ≤ p`; `B ≤ p ∧ E₁ ≤ E₂ ⇒ pow(B,E₂,p) ≤ pow(B,E₁,p)`; `B ≤ p ⇒` no
overflow; `p = 0 ∧ E > 0 ⇒ Panic(0x12)`; `pow(B,E,1) = B^E` exactly. The fourth alone
discharges the `DutchAuction` decay-direction claim.

Note the exact-arithmetic invariant `(r/p)·(b/p)^e = (B/p)^E` holds only as an **inequality**
`pow(B,E,p) ≤ p·(B/p)^E` once the floors are present; a matching lower bound is a real
numerical-analysis lemma, not a rewriting exercise.

**Highest-leverage option: change the code.** A constant-trip-count, branchless `pow` has
exactly one execution path — no BMC, no loop invariant, and gas independent of the
exponent's Hamming weight. Since `DutchAuction` bounds the exponent to 16 bits by
construction, a fixed 16-iteration variant is cheap.

### `XYCConcentrate` — blocked on `mul512`, not on sqrt

Every `Math.mulDiv` runs `mulmod` inside `Math.mul512`, six times per swap. Without a lemma
collapsing `mul512` when the true product fits in 256 bits, KEVM cannot decide `high == 0`
at `Math.sol:209` and every `mulDiv` forks into the 512-bit path containing a Newton modular
inverse. That path is not realistically provable. **This lemma is the gate; nothing else
matters until it exists.**

Try `cse = true` in `kontrol.toml` first — compositional symbolic execution can summarise
`mulDiv` and `sqrt` once and reuse across all six call sites, and may substitute for
hand-writing the lemma.

Tractable today without any of that: a harness taking `virtualBalanceIn`/`virtualBalanceOut`
as scalars and exercising only the pricing legs (`:143-159`). Those goals reduce to exactly
the `XYCSwap` shape.

### `PeggedSwap` — abstract `Math.sqrt` or do not start

`Math.sqrt` is called four times per path. Each call has 7 data-dependent branches for the
MSB estimate (up to 128 paths) and 6 unrolled Newton steps, each a `DIV` with both operands
symbolic. Four of them compose to ~2^28 paths. This is not a `max-depth` tuning problem.

Replace `Math.sqrt` with an uninterpreted function plus characterising axioms —
`isqrt(A)² ≤ A`, `A < (isqrt(A)+1)²`, monotonicity, `isqrt(N²) = N` — and never let KEVM
descend into the body. The last axiom alone discharges the dead-code proof above.

Staging: prove all divisors non-zero first (it removes partiality guards from every later
goal), then the cheap guard properties against real bytecode, then build the sqrt-abstracted
harness for the arithmetic. Attempt the rounding properties in the ±1-wei form only — the
zero-slack forms are false and will burn hours reproducing a counterexample already recorded
above.

---

## Lemmas these instructions will need

Beyond the current `lemmas.k`:

- **`mul512` collapse** — the gate for `XYCConcentrate` and anything else using OZ `mulDiv`.
- **`mulDiv` and `mulDiv(..., Ceil)` summaries**, which then let the existing division
  lemmas apply directly.
- **`ceilDiv` bounds** — `ceilDiv(a,b)·b ≥ a`, monotonicity. Needed by `PeggedSwap`
  (five call sites) and `XYCConcentrate`.
- **Integer `sqrt` axioms** — as above. Either assume them as a clearly-flagged trust
  boundary, or prove them separately against OZ `Math.sqrt`, which is its own project.
- **Symbolic-square rules** — `X ≤ Y ⇒ X² ≤ Y²`, and a no-overflow rule for `X < 2^128`.
  `PeggedSwapMath.sol:66` and `:103` are symbolic squares, exactly where Z3 stalls.

---

## Update: findings from the spec-writing pass

Recorded after specs were written for `PeggedSwap`, `XYCConcentrate` and
`PiecewiseLinearScale`. These refine or add to the analysis above.

### A transcription harness is a trust boundary — close the diff proofs or the results are hollow

`XYCConcentrateHarness` reaches the tractable properties by promoting
`virtualBalanceIn`/`virtualBalanceOut` to scalar parameters, which keeps `_computeL` — five
`Math.mulDiv` calls and a `Math.sqrt` — off the execution path. That is what makes those
properties provable today.

But the pricing legs in that harness are a **hand transcription** of
`XYCConcentrate.sol:143-159`, not the instruction itself. Every property proven against
them is therefore a theorem about the transcription until the two `test_diff_*` properties
close, which assert that `full(...)` and `exactInLeg(virtualReserves(...))` agree
register-for-register.

**Treat closing the diff proofs as the completion criterion for XYCConcentrate, not as a
nice-to-have.** They are gated on the same `mul512` lemma as the rest of Tier B.

The harness author verified the split two ways rather than asserting it: structurally (no
call, no `using`, no function pointer can reach `_computeL` from the legs) and by gas
measurement — the legs' *maximum* cost, 1,327, sits below `full`'s *minimum* of 1,862, and
`_computeL` alone cannot fit in that gap. Worth repeating that technique for any future
transcription harness.

### The non-termination bug has two distinct causes

The analysis above records that `args.length <= 9` underflows `max` inside `unchecked`.
That is true only for `args.length <= 4`. For `5 <= args.length <= 9` there is **no
underflow** — `args.length / 5 == 1` so `max` is cleanly `0` — and the loop still cannot
terminate, because `num` is pre-incremented and `++num == 0` is as unreachable as
`++num == 2**256-1`.

A fix that only guards the subtraction closes the first region and leaves the second wide
open. **Ten**, not thirteen, is the smallest terminating `args.length`.

### Two more unguarded paths

- **`XYCConcentrate` exact-out on a zero-liquidity pool panics.** When the reconstructed
  output offset is zero (`vOut == balanceOut`) and the taker requests at least the whole
  balance, `Math.ceilDiv` divides by zero. OZ validates the divisor *before* short-circuiting
  on a zero numerator, so even a zero-amount request panics. Liveness rather than safety —
  but it is the exact boundary at which the exact-out leg stops being total, so a
  reimplementation returning `0` there would be a behavioural change, not a cleanup.
- **`Math.ceilDiv(0, 0)` panicking rather than returning zero** is the general form of the
  above, and is worth remembering wherever `ceilDiv` appears with a derived divisor.

### One property that holds and was not previously recorded

`XYCConcentrate`'s partial fill **never charges more than the taker offered**
(`swap.amountIn <= amountIn` on the exact-in leg, unconditionally). This protects the taker,
and `:148` overwrites a taker-supplied register, so its safety was not obvious. Now
specified.

### The next lemma is `ceilDiv`, and two instructions need it independently

Both the `PiecewiseLinearScale` and `XYCConcentrate` spec passes converged on the same
missing lemma without coordination:

- `ceilDiv(a, b) * b >= a`
- `a > 0  ==>  (ceilDiv(a, b) - 1) * b < a`   (minimality — the interesting half)
- monotonicity in `a`

It blocks `unscaleValue`'s round trip and `partialFillNeverChargesMoreThanOffered`, and
`PeggedSwap` has five `ceilDiv` sites that will want it too. Scope it as shared work.

As always: dump the stuck node with `kontrol show --node` and write the rule against the
term KEVM actually produces. OZ's `ceilDiv` compiles to
`SafeCast.toUint(a > 0) * ((a - 1) / b + 1)`, so the term will not look like the textbook
form.

### Anti-vacuity is part of writing a spec

Two of the three spec passes mutation-tested their own properties — deliberately breaking
the implementation, or tightening a bound, to confirm the assertions actually fail. One
also probed that every `try` body is reached, so a `catch` is not silently swallowing the
whole domain, and that the values flowing through are non-degenerate rather than `0 == 0`.

A fuzz-green spec that cannot fail is worse than no spec, because it reads as evidence.
Do this.

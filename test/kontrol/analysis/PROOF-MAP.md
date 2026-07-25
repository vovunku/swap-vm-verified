# Proof map

Single source of truth for what is proven. Maintained by the coordinator; agents read it as
hand-in and never edit it. **Updated after every subsession.**

**A property is PROVEN only when `kontrol list` reports PASSED for its HIGHEST version.**
Two traps, both of which have already produced inflated counts:

1. **Version staleness.** Kontrol mints a new proof version (`:0`, `:1`, …) whenever the spec
   or the definition changes. A PASSED at `:0` says nothing about `:2`. Count the highest
   version per property and nothing else.
2. **`forge test` is not a proof.** Passing the fuzzer is a much weaker claim, and a
   fuzz-green property can be vacuous — see `AGENT-PROTOCOL.md`.

Regenerate with:

```bash
docker exec kontrol bash -c "cd /home/user/swap-vm-verified && su user -c \
  'PATH=/home/user/.local/bin:/home/user/.foundry/bin:/usr/bin:/bin HOME=/home/user \
   FOUNDRY_PROFILE=kontrol kontrol list'"
```

Note the `su user -c` form. `docker exec -u user … kontrol list` returns empty output silently
on this host, which has twice been mistaken for lost proof state.

Legend: **P** proven · **F** failed · **S** stalled · **·** not attempted · **X** excluded

---

## Summary — 11 of 91 Track B properties proven

*Counting highest version only, against the definition built after the `preserves-definedness`
fix.*

| Spec | Properties | Proven | Attempted | Notes |
|---|---|---|---|---|
| XYCSwap | 12 | 5 | 8 | Strengthened 8→12; 4 new awaiting a rebuild |
| PeggedSwap | 31 | 1 | 8 | 19 need `--reinit` after the immutable fix |
| XYCConcentrate | 21 | 1 | 3 | Tier B needs `mul512` **and** an `isqrt` seam |
| PiecewiseLinearScale | 31 | 4 | 8 | `--bmc-depth 51` gives a complete result |
| Power | 31 | 0 | 0 | Spec written, awaiting first rebuild |
| **Track B total** | **126** | **11** | **27** | |

Track A, out of scope, listed for completeness: `LimitSwap` 9 (4 attempted, 0 proven),
`MinRate` 29, `BaseFeeAdjuster` 25.

### Proven at latest version

| Property | Ver |
|---|---|
| `PeggedSwapSpec.test_panicSelectorIsTheAbiPanicSelector` | :0 |
| `PiecewiseLinearScaleSpec.test_argsLength_tenBytesTerminates` | :0 |
| `PiecewiseLinearScaleSpec.test_guard_precedesArgumentParsing` | :0 |
| `PiecewiseLinearScaleSpec.test_guard_scaleInRevertsWhenBothAmountsSet` | :0 |
| `PiecewiseLinearScaleSpec.test_value_maximalScaleIsTheIdentity` | :0 |
| `XYCConcentrateSpec.test_exactIn_clampIsReachable_witness` | :0 |
| `XYCSwapSpec.test_exactIn_revertsOnZeroBalanceIn` | :1 |
| `XYCSwapSpec.test_exactIn_revertsOnZeroBalanceOut` | :2 |
| `XYCSwapSpec.test_exactIn_revertsWhenAmountOutAlreadySet` | :2 |
| `XYCSwapSpec.test_exactIn_zeroInputYieldsZeroOutput` | :2 |
| `XYCSwapSpec.test_exactOut_roundsInFavourOfMaker` | :2 |

`test_exactOut_roundsInFavourOfMaker` is the first property closed by a lemma we wrote — the
`ceilDiv → up/Int` normalisation in Section 5, and it needed nothing else.

### Attempted but not yet closed

`XYCSwapSpec`: `cannotDrainPool` (:4), `roundsInFavourOfMaker` (:3),
`constantProductNeverDecreases` (:1 — **was PASSED at :0, superseded**).
`PeggedSwapSpec`: 7 pending including both `knownUnderflow`/`knownOverflow` witnesses.
`XYCConcentrateSpec`: `cannotDrainPool`, `partialFillNeverChargesMoreThanOffered`.
`PiecewiseLinearScaleSpec`: `scaleNeverExpands`, both `unscale*`, `guard_scaleOut*`.

## XYCSwap — 3 / 8

| Property | State |
|---|---|
| `test_exactIn_constantProductNeverDecreases` | **P** |
| `test_exactIn_revertsOnZeroBalanceIn` | **P** — but see note |
| `test_exactIn_zeroInputYieldsZeroOutput` | **P** |
| `test_exactIn_cannotDrainPool` | **S** 12 nodes |
| `test_exactIn_roundsInFavourOfMaker` | **S** 12 nodes |
| `test_exactOut_roundsInFavourOfMaker` | **S** 16 nodes |
| `test_exactIn_revertsOnZeroBalanceOut` | · |
| `test_exactIn_revertsWhenAmountOutAlreadySet` | · |
| *new* exactness + witness properties | · (added, awaiting rebuild) |

The three proven properties are **sound but jointly too weak**: an `exactIn` returning `0`
unconditionally satisfies all of them. Two-sided exactness and a concrete witness are being
added. `revertsOnZeroBalanceIn` uses a bare `vm.expectRevert()` and so cannot distinguish
"the guard fired" from "it divided by zero".

## PeggedSwap — 0 / 31

Nothing proven. **19 properties need `--reinit`** because their cached state predates the
immutable→accessor fix; of those, **7 previously reported PASSED vacuously** (negative
selector comparisons against a zero selector), including all three dead-code claims.

Grouped by sqrt cost, per the spec author's handoff:

- **Group A** — no symbolic sqrt, cheapest: `bothBalancesZeroGuardFiresWhenBothZero`,
  `knownUnderflow_exactOutAtLargeReserves`, `knownOverflow_exactInAtSmallNormaliser`,
  `exactOut_realisticPoolPricesCleanly`, `panicSelectorIsTheAbiPanicSelector`.
- **Group B** — one symbolic sqrt: the two `bothBalancesZero_*AlonePassesTheGuard`.
- **Group C** — two sqrts, halts at the recompute guard: the two
  `recomputeGuardFiresWithExactSelector`, the two `alwaysRevertsWhen*IsPreset`.
- **Group D** — up to four sqrts but discharged from the path condition alone; correct with
  zero axioms, the risk is path count (~2^28): the four `parse_*`,
  `parse_linearWidthBoundIsInclusive`, `bothBalancesZeroGuardNeverFires*`, both
  `recomputeGuardNeverFires*`, `exactOut_amountOutIsClampedToBalanceOut`,
  `exactOut_nonZeroOutputCostsAtLeastOneWei`, both `leavesBalancesAndNetPulledUntouched`,
  `exactIn_amountInSurvivesUnlessTheOutputReserveIsDrained`.
- **Group E** — needs sqrt-value reasoning, will NOT prove without an abstraction: the three
  `deadCode_*`, both `nominalPool_*SuccessPath`.
- **Group F** — highest path count (~2^56): both `directionSymmetry_*`.

## XYCConcentrate — 1 / 21

| Property | State |
|---|---|
| `test_exactIn_clampIsReachable_witness` | **P** — concrete, refutes the strict no-drain form |
| 14 further Tier A properties | · |
| 6 Tier B properties | · — blocked |

**Tier A** keeps `_computeL` off the execution path by taking the virtual reserves as scalar
parameters. Verified two ways by the spec author: structurally, and by gas measurement (the
legs' max, 1,327, is below `full`'s min, 1,862).

**Tier B is blocked on two things, not one.** `mul512` collapse (Section 6 of `lemmas.k`)
*and* an `isqrt` abstraction — `_computeL` calls `Math.sqrt(disc)` with `disc` fully
symbolic, which Section 7 (symbolic *squares*) does not address. `test_full_cannotDrainPool`
additionally cannot be closed by Section 6 even in principle: its price bounds are free
`uint256`s, so `X *Int Y < pow256` is not derivable and the 512-bit path is genuinely
reachable. That is a specification-domain problem.

**Completion criterion:** the two `test_diff_*` properties. Until they close, every Tier A
result is a theorem about a hand transcription rather than about `XYCConcentrate`.

## PiecewiseLinearScale — 0 / 31

Nothing proven yet. Order from the spec author's handoff: the two `value_*` scale properties
first (one MUL, one SHR), then the guard group, then the concrete-shape group (2- and
3-point schedules, loop fully unrolled), then the two `value_unscale*` properties which need
the new Section 5 `ceilDiv` lemmas, then the two `*AnyLengthArgs` properties with
`--bmc-depth 51`.

**X** `test_argsLength_underThirteenBytesNeverTerminates` — excluded from `kontrol prove`.
It witnesses a non-terminating loop via a gas cap, and gas is off under Kontrol, so the
proof would never converge.

`--bmc-depth 51` should yield a **complete** result rather than a bounded one: `runLoop`
reads `argsLength` as a single byte, so the segment count is at most 50 and the path entering
iteration 51 is infeasible. Verify no reachable `bounded` leaves remain afterwards.

## Power — spec not written

Track B item B4's second half. Consumed by `DutchAuction` and `TWAPSwap`. The trip count is
`bitlength(exponent)` — bounded by 16 for `DutchAuction` — so it always terminates; the
difficulty is **path count**, since the `exponent & 1` branch has two continuing arms and
leaves grow as `2^bitlength`. Plan is order properties plus concrete witnesses at small
exponents, not the closed form.

---

## Blockers, ranked by properties unblocked

1. **`isqrt` seam** — gates PeggedSwap Groups E/F and all of XYCConcentrate Tier B. Now known
   to need a **harness seam, not a lemma**: `Math.sqrt` is inlined, `--cse` provably cannot
   see it (`find_function_calls` drops library member accesses), and `--lemmas` cannot declare
   a new symbol. The route is `kevm.freshUInt` plus paired `vm.assume` bounds at the call
   site, landing on the Section 7 symbolic-square rules already compiled in. **In progress.**
2. **Re-proving after the `preserves-definedness` fix** — the `mul512` rules were dead until
   this build, so every XYCConcentrate Tier B attempt so far was made without them.
3. **The 19 PeggedSwap properties needing `--reinit`** after the immutable→accessor fix, 7 of
   which previously reported a vacuous PASS.
4. **`_selectorOf` returning 0 on short revert data** — reintroduces the same vacuity for
   every negative selector assertion on any path reverting with an empty payload.
5. **Loop invariants for `Power.pow`** — the only technique that beats `2^bitlength` leaves.
   MakerDAO's `kontrol-dss-2024/src/invariant.md` is the one public worked example.

## Operational notes

- **Drain agents before rebuilding.** A rebuild mints new proof versions and supersedes
  in-flight work. This has already cost one round of agent progress.
- **`--lemmas` cannot test division lemmas.** pyk accepts six rule attributes and hard-errors
  on `preserves-definedness`, so the fast loop returns false negatives for every rule whose
  LHS contains a partial symbol. Those must go through a rebuild.
- **`--workers 3` per agent is a hard cap.** One agent at 6 drove load to 16.2 on 16 cores.

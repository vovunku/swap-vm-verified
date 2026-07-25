# Proof map

Single source of truth for what is proven. Maintained by the coordinator; agents read it as
hand-in and never edit it.

**A property is PROVEN only when `kontrol list` reports PASSED against the current
definition.** Passing `forge test` is a different, much weaker claim, and the two are kept
apart deliberately — see the vacuity notes in `AGENT-PROTOCOL.md` for why a green fuzz run
can mean nothing at all.

Legend: **P** proven · **F** failed · **S** stalled (node count) · **·** not attempted ·
**X** excluded, with reason

---

## Summary

| Spec | Properties | Proven | Notes |
|---|---|---|---|
| XYCSwap | 8 (+new) | 3 | Being strengthened — upper bounds alone were too weak |
| PeggedSwap | 31 | 0 | 19 need `--reinit`; 7 previously PASSED vacuously |
| XYCConcentrate | 21 | 1 | Tier B gated on `mul512` **and** an `isqrt` abstraction |
| PiecewiseLinearScale | 31 | 0 | Loop bounded at 50, so `--bmc-depth 51` is complete |
| Power | — | — | **Spec not yet written** (Track B item B4, second half) |
| **Track B total** | **91** | **4** | |

Out of scope for Track B, listed for completeness: `LimitSwap` (9), `MinRate` (29),
`BaseFeeAdjuster` (25) — Track A, owned by the other track.

---

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

1. **`isqrt` abstraction** — gates PeggedSwap Groups E/F and all of XYCConcentrate Tier B.
   `Math.sqrt` is inlined straight-line code, so axioms alone cannot fire: nothing introduces
   an `isqrt` symbol. Needs a seam — a harness parameter with the characterising bounds
   assumed, or an oracle-call interception rule. **This is the single highest-value item.**
2. **`mul512` collapse firing in practice** — Section 6 is compiled in but unexercised. If it
   does not fire, first thing to check is whether KEVM presents `MULMOD` as
   `chop((X *Int Y) modInt maxUInt256)` where the rule matches a bare `modInt`.
3. **`ceilDiv` normalisation firing in practice** — Section 5 is compiled in but unexercised.
4. **Re-proving the 19 PeggedSwap properties** after the vacuity fix.
5. **`_selectorOf` returning 0 on short revert data** — reintroduces the same vacuity for
   every negative selector assertion on any path reverting with an empty payload.

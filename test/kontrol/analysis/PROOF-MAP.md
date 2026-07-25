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

## Summary — 14 of 126 Track B properties proven

*Counting highest version only, against the definition built after the `preserves-definedness`
fix, the performance config change, and the `isqrt` seam.*

| Spec | Properties | Proven | Notes |
|---|---|---|---|
| XYCSwap | 12 | 6 | 4 new properties now in the definition, unattempted |
| PiecewiseLinearScale | 31 | 6 | `--bmc-depth 51` gives a complete result |
| PeggedSwap | 38 | 1 | +7 seam properties; 19 need `--reinit` |
| XYCConcentrate | 21 | 1 | Tier B gated on `mul512`, now un-dead |
| Power | 31 | 0 | In the definition for the first time |
| **Track B total** | **133** | **14** | |

Track A, out of scope: `LimitSwap` 9, `MinRate` 29, `BaseFeeAdjuster` 25.

### Proven at latest version

| Property | Ver |
|---|---|
| `PeggedSwapSpec.test_panicSelectorIsTheAbiPanicSelector` | :1 |
| `PiecewiseLinearScaleSpec.test_argsLength_tenBytesTerminates` | :0 |
| `PiecewiseLinearScaleSpec.test_guard_precedesArgumentParsing` | :0 |
| `PiecewiseLinearScaleSpec.test_guard_scaleInRevertsWhenBothAmountsSet` | :0 |
| `PiecewiseLinearScaleSpec.test_guard_scaleOutRevertsWhenBothAmountsSet` | :0 |
| `PiecewiseLinearScaleSpec.test_scaleIn_zeroBalanceStaysZero` | :0 |
| `PiecewiseLinearScaleSpec.test_value_maximalScaleIsTheIdentity` | :0 |
| `XYCConcentrateSpec.test_exactIn_clampIsReachable_witness` | :0 |
| `XYCSwapSpec.test_exactIn_constantProductNeverDecreases` | :2 |
| `XYCSwapSpec.test_exactIn_revertsOnZeroBalanceIn` | :1 |
| `XYCSwapSpec.test_exactIn_revertsOnZeroBalanceOut` | :2 |
| `XYCSwapSpec.test_exactIn_revertsWhenAmountOutAlreadySet` | :2 |
| `XYCSwapSpec.test_exactIn_zeroInputYieldsZeroOutput` | :2 |
| `XYCSwapSpec.test_exactOut_roundsInFavourOfMaker` | :2 |

`test_exactOut_roundsInFavourOfMaker` is the first property closed by a rule we wrote — the
`ceilDiv → up/Int` normalisation — and it needed nothing else.

**A retracted regression, worth recording as a method note.** `constantProductNeverDecreases`
was reported regressed because its `:1` sat PENDING. It had not regressed: `:1` was a stale
intermediate and the live `:2` closed. Reading a PENDING intermediate as the current state is
the trap; only the highest-numbered version describes the live definition.

## Per-spec notes

### XYCSwap — 5 / 12
Strengthened from 8 to 12 properties after an audit showed the original four exact-in
properties were **jointly satisfied by an implementation returning `0` unconditionally** —
verified empirically against a throwaway mutant, not merely argued. The four additions
(two-sided exactness on each leg, two concrete witnesses) are written and fuzz-green but
await a rebuild before they can be proven.

**Open regression.** `constantProductNeverDecreases` closed at `:0` in under ten minutes but
`:1` will not close in thirty, sitting at the same node count with one pending node. That is
the shape of a lemma or bytecode regression from a rebuild, not of a slow proof. **Bisect
before trusting the current definition.**

Remaining gap: exact-out exactness is `uint120`-narrowed, so an implementation correct below
`2^120` and overcharging above it still satisfies the spec. Closing it needs the minimality
half stated unnarrowed — safe, since `(amountIn - 1) * d < N` is bounded by `N`, a product the
instruction does form, and `lemmas.k` already has `updiv-minimal` in that shape.

### PeggedSwap — 1 / 31
**19 properties need `--reinit`** because their cached state predates the immutable→accessor
fix; **7 of those previously reported a vacuous PASS**, including all three dead-code claims.
Grouped by sqrt cost: Group A needs no symbolic sqrt (cheapest); B one; C two, halting at the
recompute guard; D up to four but discharged from the path condition alone (~2^28 paths);
**E needs sqrt-value reasoning and cannot prove without the seam**; F is ~2^56 paths.

### XYCConcentrate — 1 / 21
Tier A keeps `_computeL` off the path by taking virtual reserves as scalars — verified both
structurally and by gas measurement (legs' max 1,327 below `full`'s min 1,862).

Tier B is blocked on **two** things: the `mul512` collapse (dead until the
`preserves-definedness` fix, so every attempt so far ran without it) **and** an `isqrt` seam,
since `_computeL` calls `Math.sqrt(disc)` with `disc` fully symbolic. `test_full_cannotDrainPool`
additionally cannot close via `mul512` even in principle — its price bounds are free
`uint256`s, so the 512-bit path is genuinely reachable. That one is a specification-domain
problem.

**Completion criterion: the two `test_diff_*` properties.** Until they close, every Tier A
result is a theorem about a hand transcription rather than about `XYCConcentrate`.

### PiecewiseLinearScale — 4 / 31
`--bmc-depth 51` yields a **complete** result rather than a bounded one: `runLoop` reads
`argsLength` as a single byte, so the segment count is at most 50 and iteration 51 is
infeasible. Verify no reachable `bounded` leaves remain afterwards.

**X** `test_argsLength_underThirteenBytesNeverTerminates` — excluded from `kontrol prove`. It
witnesses a non-terminating loop via a gas cap, and gas is off under Kontrol.

### Power — 0 / 31
Spec written, never built. Single-execution-path properties (concrete exponents) should prove
first; `uint8`-exponent properties need `--bmc-depth 9`; full-`uint256`-exponent properties
need a loop invariant rather than a larger depth.

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

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

> **Naming.** "Track A" and "Track B" are the split of work between the two people on this
> project — Track A is `Controls`, `MinRate`, `Balances`, `LimitSwap`; Track B is `XYCSwap`,
> `PeggedSwap`, `XYCConcentrate`, `PiecewiseLinearScale`, `Power`. Nothing else uses A/B.
>
> `XYCConcentrate`'s internal difficulty split was previously also called "leg-level/B", which
> collided with that and caused real confusion. It is now **leg-level** (properties provable
> with `_computeL` kept off the execution path) versus **full-instruction** (properties routed
> through it). Do not reintroduce "tier" for anything.

Legend: **P** proven · **F** failed · **S** stalled · **·** not attempted · **X** excluded

---

## Summary — 42 of 133 Track B properties proven

*Counting highest version only.*

| Spec | Properties | Proven | Attempted |
|---|---|---|---|
| PiecewiseLinearScale | 31 | **18** | 20 |
| XYCSwap | 12 | **8** | 10 |
| XYCConcentrate | 21 | **6** | 8 |
| PeggedSwap | 38 | **5** | 11 |
| Power | 31 | **5** | 5 |
| **Track B total** | **133** | **42** | **54** |

Track A, out of scope: `LimitSwap`, `MinRate`, `BaseFeeAdjuster`.

**Hit rate on attempted properties is 42/54 — the bottleneck is throughput, not
provability.** Where a proof has actually been given a fair run on a quiet machine it
usually closes. Every "stuck" diagnosis in this file's history has turned out to be a
resource problem: first 57 orphaned backend servers, then a config measured 9.4x slower,
then 175% oversubscription from `max-frontier-parallel` multiplying across concurrent
agents. Suspect the environment before the mathematics.

### Landmark results

- **`PiecewiseLinearScaleSpec.test_value_unscaleThenScaleIsIdentity`** — closed by the
  Section 5 `ceilDiv -> up/Int` normalisation, the property that lemma was written for.
- **`PeggedSwapSpec.test_knownUnderflow_exactOutAtLargeReserves`** — the underflow bug
  witness is now proven under Kontrol, not merely reproduced under `forge test`. That is
  the strongest evidence level available for a bug report.
- **`PeggedSwapSpec.test_bothBalancesZeroGuardFiresWhenBothZero`** — 128 nodes, i.e. the
  full 2^7 `Math.sqrt` MSB cascade, closed without an abstraction.
- **`PowerSpec`** — 5 of 5 attempted, first time in the definition.
- **`XYCConcentrateSpec`** — 6 of 8 attempted, up from 1.

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
LEG-LEVEL keeps `_computeL` off the path by taking virtual reserves as scalars — verified both
structurally and by gas measurement (legs' max 1,327 below `full`'s min 1,862).

FULL-INSTRUCTION is blocked on **two** things: the `mul512` collapse (dead until the
`preserves-definedness` fix, so every attempt so far ran without it) **and** an `isqrt` seam,
since `_computeL` calls `Math.sqrt(disc)` with `disc` fully symbolic. `test_full_cannotDrainPool`
additionally cannot close via `mul512` even in principle — its price bounds are free
`uint256`s, so the 512-bit path is genuinely reachable. That one is a specification-domain
problem.

**Completion criterion: the two `test_diff_*` properties.** Until they close, every LEG-LEVEL
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

1. **`isqrt` seam** — gates PeggedSwap Groups E/F and all of XYCConcentrate FULL-INSTRUCTION. Now known
   to need a **harness seam, not a lemma**: `Math.sqrt` is inlined, `--cse` provably cannot
   see it (`find_function_calls` drops library member accesses), and `--lemmas` cannot declare
   a new symbol. The route is `kevm.freshUInt` plus paired `vm.assume` bounds at the call
   site, landing on the Section 7 symbolic-square rules already compiled in. **In progress.**
2. **Re-proving after the `preserves-definedness` fix** — the `mul512` rules were dead until
   this build, so every XYCConcentrate FULL-INSTRUCTION attempt so far was made without them.
3. **The 19 PeggedSwap properties needing `--reinit`** after the immutable→accessor fix, 7 of
   which previously reported a vacuous PASS.
4. **`_selectorOf` returning 0 on short revert data** — reintroduces the same vacuity for
   every negative selector assertion on any path reverting with an empty payload.
5. **Loop invariants for `Power.pow`** — the only technique that beats `2^bitlength` leaves.
   MakerDAO's `kontrol-dss-2024/src/invariant.md` is the one public worked example.

## Preserving proofs

The proof store is expensive and already persistent — 8.5 hours of CPU produced the current
1.5 GB in `out/proofs/`, and it survives kills and resumes automatically. The problem is not
persistence, it is **invalidation**:

```
total proof CPU:      8.5 h
  on live versions:   6.5 h
  on superseded:      2.0 h   (24% wasted)
  of which setUp:     21 min across 19 versions
```

**Root cause.** `Contract.Method.digest` includes `contract_digest`, the hash of the *entire*
contract JSON. Adding one property to a 31-property spec therefore invalidates **all 31**,
and Kontrol mints a fresh version for each. That is why specs carry `:0` and `:1` proofs for
properties nobody touched.

**What actually reduces the waste, in order of value:**

1. **Split spec files.** One contract per property group. An edit then invalidates only its
   group instead of the whole file. This is the structural fix and the only one that scales.
2. **Freeze a spec before starting long proofs on it.** Batch spec edits; do not add a
   property while a 20-minute proof is running against the same contract.
3. **Pass `--setup-version N`.** `setUp` is exempt from `contract_digest`
   (`if not self.is_setup else {}`), so it genuinely can be reused — 21 minutes went into
   re-proving it 19 times.
4. **Prefer `kontrol remove-node <test> <id>` and a plain resume over `--reinit`** when adding
   a lemma. `--reinit` discards the whole tree; pruning the stuck subtree keeps the prefix.
5. **Drain agents before rebuilding.** A rebuild supersedes every in-flight proof.

**Archiving.** `scripts/kontrol-proofs.sh {save|restore|prune}` archives the store out of the
container, restores it, and prunes superseded versions. Note the limit: a proof is only valid
against the definition digest it was produced under, so restore buys you machine loss and
container rebuilds — **not** spec edits. Nothing resurrects a result whose contract changed.

## Operational notes

- **Drain agents before rebuilding.** A rebuild mints new proof versions and supersedes
  in-flight work. This has already cost one round of agent progress.
- **`--lemmas` cannot test division lemmas.** pyk accepts six rule attributes and hard-errors
  on `preserves-definedness`, so the fast loop returns false negatives for every rule whose
  LHS contains a partial symbol. Those must go through a rebuild.
- **`--workers 3` per agent is a hard cap.** One agent at 6 drove load to 16.2 on 16 cores.

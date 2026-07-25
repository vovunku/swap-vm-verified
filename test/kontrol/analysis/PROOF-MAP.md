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

**`kontrol list` is expensive** — 2-4 minutes and ~2.6 GB RSS on a store this size, and
several agents polling it concurrently was itself a source of load. The same verdicts come
from `proof.json` + `kcfg/kcfg.json` in under a second: a leaf is closed iff it is target,
terminal, covered, vacuous or bounded. Prefer that for routine checks.

**This file has undercounted.** An audit found `PiecewiseLinearScale` at 16 proven while the
map said 6 — ten PASSED proofs unrecorded, because the map was updated from agent reports
rather than from the store. Regenerate from the store, never from a summary.

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

## Summary — 54 of 133 Track B properties proven

*Regenerated from the proof store, highest version only. Property totals counted from the
spec sources, not from memory.*

| Spec | Properties | Proven | Attempted |
|---|---|---|---|
| PiecewiseLinearScale | 31 | **24** | 27 |
| Power | 31 | **11** | 13 |
| XYCSwap | 13 | **8** | 10 |
| XYCConcentrate | 21 | **6** | 9 |
| PeggedSwap | 37 | **5** | 11 |
| **Track B total** | **133** | **54** | **70** |

**77% of attempted properties close.** 63 of 133 are simply unattempted, so the constraint is
throughput rather than provability. More machine time and more agents buy proofs; more lemma
engineering mostly does not.

Track A, out of scope: `LimitSwap`, `MinRate`, `BaseFeeAdjuster`.

### Landmarks

- **`PiecewiseLinearScale` 24 of 31**, the strongest spec in the project.
- **`test_value_unscaleThenScaleIsIdentity`** was FAILING and now passes, flipped by the
  Section 8 `asword-buf29-zeros` rule. The failure was a spurious `EVMC_REVERT` branch caused
  by a left shift never becoming a multiplication.
- **`test_knownUnderflow_exactOutAtLargeReserves`** is proven under Kontrol, not merely
  reproduced under `forge test` — the strongest evidence tier available for the bug report.
- **`test_bothBalancesZeroGuardFiresWhenBothZero`** closed at 128 nodes, the full 2^7
  `Math.sqrt` MSB cascade, with no abstraction.
- Both XYCSwap reachability witnesses closed first try, ~100 s each.

### The remaining stalls are understood, and none is an SMT wall

All six outstanding XYCSwap goals were put to Z3 directly with full `uint256` bounds:
**every one decided in under 60 ms.** The z3 sessions attached to those proofs sat at 0.0%
CPU for 43 minutes while the backends held 98% each. They are rewriting-bound. The cost comes
from `try`/`catch` deliberately removing the assumptions, so the instruction's own guards
split into three live arms each needing a ~3000-step edge — correct and intended, roughly 50x
the work of the assumption form.

`PiecewiseLinearScale`'s remaining four are blocked on one thing: `/Word` with a symbolic
divisor never reduces to `/Int`, so no KEVM overflow lemma can match. Section 4's
`div-word-to-int` and `mul-guard-word` target it and await a rebuild.

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

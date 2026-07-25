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

## Summary — 56 of 133 Track B properties proven

*Regenerated from the proof store, highest version only.*

| Spec | Properties | Proven | Attempted |
|---|---|---|---|
| PiecewiseLinearScale | 31 | **24** | 27 |
| Power | 31 | **12** | 15 |
| XYCSwap | 13 | **8** | 10 |
| XYCConcentrate | 21 | **6** | 9 |
| PeggedSwap | 37 | **6** | 12 |
| **Track B total** | **133** | **56** | **73** |

**77% of attempted properties close.** 60 of 133 remain unattempted, so throughput is the
constraint, not provability.

### Landmarks

- **`PiecewiseLinearScale` 24 of 31** — the strongest spec.
- **`Power` 12 of 31 from zero**, covering the whole concrete-input surface: both
  trailing-square bug witnesses, all three decay-reaches-zero witnesses for the DutchAuction
  bug, and the `2**128` totality boundary. Those findings are now machine-checked rather than
  asserted.
- **`test_knownUnderflow_exactOutAtLargeReserves`** proven under Kontrol — the strongest
  evidence tier available for the PeggedSwap bug report.
- **`test_value_unscaleThenScaleIsIdentity`** went from FAILING to PASSED on a lemma written
  against a dumped term.

### What the stalls have actually been

Every one investigated so far has been environmental or structural, never a missing lemma:

1. **The default prove profile does not generalise.** Its 9.4x A/B was measured on one
   long-straight-edged property. On a branchy instruction body the result *inverts*: a
   PeggedSwap node that would not expand at all under the default expanded in three minutes
   under `--config-profile inspect`. **Try that first when a proof stalls.**
2. **Symbolic-length `bytes calldata`.** `lengthBytes(args)` propagates into every memory
   offset. Properties built on a fixed-layout `_args(...)` with symbolic fields close;
   the same properties with a symbolic-length `bytes` do not.
3. **Rewriting-bound, not SMT-bound.** Repeatedly measured: boosters at 100% CPU while their
   `z3` children sit at 0.0%. All six outstanding XYCSwap goals were put to Z3 directly and
   decided in under 60 ms.
4. **Oversubscription.** 63 requested workers on 16 cores at one point; a `DebugApplyEquation`
   logging run held 47-52 GB and drove the box to load 34 with swap exhausted.

## Where we are, and how to advance

### The one diagnosis that explains almost everything

Across five specs the pattern is now consistent enough to act on: **what closes is concrete
arguments; what stalls is a symbolic product.**

`PowerSpec` makes it exact. All twelve of its passing properties have concrete `base` AND
concrete `precision` (or `precision == 0`, which reverts before any product forms). Every
unproven one carries a symbolic product. The file's own docstring calls the `test_unroll_*`
family "the cheapest surface in the file" because a literal exponent collapses the KCFG to
one leaf — the premise is right and the conclusion is wrong. Path count collapses; cost does
not, because `base` and `precision` stay symbolic and every iteration still carries a
symbolic 256-bit checked multiply and a symbolic division.

This reframes the project's bottleneck. It is not that we lack clever lemmas. It is that
symbolic products do not rewrite, and three levers act on that directly.

### Decision 1 — reason on the function in place; fix the prover, not the source

An earlier draft of this section proposed extracting `XYCConcentrate.sol:143-159` into its
own `internal` function so the harness could import it instead of transcribing it. **That
was the wrong call and has been dropped.**

Nothing prevents reasoning about the whole function as it stands — the `full` surface already
calls `_xycConcentrateGrowLiquidity2D` unmodified. It does not close, but the reason is
`mul512`'s `mulmod`, which is a prover limitation, not a property of the source. Restructuring
production code to work around a prover is the wrong direction of fix: if the `mul512` lemma
lands, the whole instruction becomes provable in place and both the transcription AND the
proposed extraction become unnecessary.

It also carried a cost that was underweighted. This contract is deployed at
`0x8fdd04dbf6111437b44bbca99c28882434e0958f` across twelve chains. Any source edit changes
the metadata hash, so the emitted bytecode differs even when every instruction is identical —
which means redeployment, for verification convenience. Not a trade worth making.

**The rule: a verification difficulty is a reason to improve the prover or the spec, not to
restructure deployed code.** The transcription stays for now as scaffolding, clearly marked
in `HARNESS-FIDELITY.md` as a weaker claim than a real-code proof, and is deleted once
`mul512` collapses.

### Decision 2 — fix in the spec what production already fixes

`Power.pow`'s `precision` is symbolic in every spec, and **both production callers pass
`1e18`**. A spec variant that fixes `precision = 1e18` and leaves `base` symbolic is still a
real theorem about `DutchAuction` and `TWAPSwap` — the only two things that call it — and it
removes one of the two symbolic operands from every product in the loop.

This is not weakening a spec. Narrowing a domain to buy a green checkmark is forbidden and
stays forbidden. Fixing a parameter to the only value production ever supplies is a
*different operation*: it states the theorem that is actually needed, and it should be
labelled as such in the property name and docstring so nobody later mistakes it for the
general claim.

Apply the same test elsewhere: for each symbolic parameter, ask what production actually
passes. If the answer is a constant, there is a strong theorem hiding behind a needlessly
symbolic one.

### Decision 3 — the profile, now settled

The prove default has been reversed to checkpoint (see `kontrol.toml` for the full A/B
history and the three measurements that forced it). The old settings live in
`[prove.fast]`. Non-progress under the no-checkpoint profile is indistinguishable from a
missing lemma, and that misdiagnosis has cost multiple sessions.

### Ranked next moves

1. **Crack `mul512`.** Unblocks `XYCConcentrate`'s liquidity half outright, makes the whole
   instruction provable in place, and lets the transcription be deleted with nothing put in
   its place. This is now the top item, having replaced the source-extraction proposal.
2. **Add `atProductionPrecision` variants** to `PowerSpec`, fixing `precision = 1e18`.
   Cheapest large win available; likely closes in minutes rather than hours.
4. **`merge-nodes` with `keep_values=False`.** The spike works structurally — 48 pending
   leaves collapsed to 1, with anti-unification discovering exactly the three loop registers
   — but `keep_values=True` builds a 526,612-character pairwise disjunction and converts a
   node explosion into a path-condition explosion. Dropping the disjunction is an
   over-approximation, and therefore **sound for every safety property in `PowerSpec`**,
   which are all upper bounds and orderings. It is a one-flag upstream ask.
5. **Decide the `PeggedSwap` seam's fate.** 200 lines that have never executed, against a
   ~90-line plain import in the same file that found the strongest bug in the repo. If
   restating over a fixed-layout `_args(...)` does not make it run, delete it.

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

- **CORRECTION — a rebuild does *not* mint new proof versions.** The claim above (and the
  "Version staleness" note at the top of this file) is wrong about the definition.
  `Contract.Method.digest` (`kontrol/solc_to_k.py:643-646`) hashes
  `signature + ast + contract_storage_digest + contract_digest`, all read from the **Foundry
  artifact JSON**; the kompiled K definition is not an input, and `resolve_proof_version`
  (`kontrol/foundry.py:943-980`) reuses the latest version whenever that digest matches.
  Verified across the `2026-07-25 01:39` rebuild: all six PASSED `XYCConcentrate` proofs
  stayed at `:0` and `setUp` stayed PASSED at `:3`. What a rebuild costs is the **in-flight
  runs**, not the store — so "drain agents before rebuilding" is still the right operational
  rule, for a different reason. **A spec edit is the expensive operation**, and it costs the
  whole file: `contract_digest` covers the entire contract JSON, so adding one property to a
  21-property spec invalidates all 21.
- **Kill leftover chain scripts before dispatching a new agent onto a file.** A previous
  `XYCConcentrate` subsession left `/home/user/xycrun/chain.sh` (a six-batch chain covering
  nearly the whole target list) and `/home/user/xycrun/b1.sh` (queued behind it) alive in the
  container. The incoming agent's runs and those became **two `kontrol prove` processes
  driving the same `out/proofs/<id>` directories** — the same hazard as two agents on one
  spec, except invisible, because the offender is a detached script with no agent attached to
  it. Check `ps -eo pid,ppid,etime,args | grep 'kontrol prove'` *before* launching anything,
  and reap by killing the **script tree by explicit PID** — never `pkill -f kore-rpc-booster`.
- **An empty `out/proofs/<id>/` is NOT evidence of a stuck or contended proof.** This
  misdiagnosis cost a restart. `[prove.default]` in `kontrol.toml` sets
  **`maintenance-rate = 16`** and **`max-depth = 100000`**, so pyk writes proof data only
  every 16 iterations (`pyk/proof/proof.py:384`) plus once at the end — and with a
  100k-step depth limit a leg-level proof needs only ~3-4 iterations in total. A proof
  therefore normally persists **nothing at all until it finishes**, and a run stopped by a
  wall-clock budget before either threshold loses everything. Do not infer progress from
  `find out/proofs/<id> -type f`; a directory containing only `kcfg/nodes/` is the expected
  mid-run state. Two consequences for runners: give budgets generous headroom rather than
  tight ones, and prefer letting a batch finish over killing it, because a kill before
  iteration 16 discards the whole run.
- **`nohup`/`docker exec -d` runners outlive the agent session that started them.** That is
  what makes the trap above recurrent: an agent whose session ends leaves its chain running
  for hours. Any runner should write a `.done` marker and, ideally, self-terminate on a
  wall-clock budget (`/home/user/xyc2/runw.sh` does both).
- **`--lemmas` cannot test division lemmas.** pyk accepts six rule attributes and hard-errors
  on `preserves-definedness`, so the fast loop returns false negatives for every rule whose
  LHS contains a partial symbol. Those must go through a rebuild.
- **`--workers 3` per agent is a hard cap.** One agent at 6 drove load to 16.2 on 16 cores.

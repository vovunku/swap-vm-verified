# Reconciliation — what is proven, what is not, and whether the lemmas earn their keep

Written after four agent sessions returned on the same day. It is deliberately unflattering
where the evidence is unflattering.

## 1. What we have proven

Two numbers, because the difference matters.

| Counting rule | Proven | Attempted | Of 133 |
|---|---|---|---|
| **Strict — highest version only** | **49** | 91 | 37% |
| Loose — any version ever PASSED | 56 | 91 | 42% |

| Spec | Strict proven | Attempted | Total |
|---|---|---|---|
| PiecewiseLinearScale | 18 | 30 | 31 |
| Power | 12 | 17 | 31 |
| PeggedSwap | 7 | 14 | 37 |
| XYCSwap | 6 | 12 | 13 |
| XYCConcentrate | 6 | 18 | 21 |

**The seven-property gap is version churn, and it is a real cost, not a bookkeeping quirk.**
`Contract.Method.digest` hashes the whole contract JSON, so one added property re-versions
every property in the file. A proof that PASSED at `:2` says nothing about `:4`. Several
properties now have a PASSED older version and a newer version that never flushed a node.
Report 49, not 56.

**Of the 49, six are not claims about deployed code.** The `XYCConcentrate` leg-level
properties are proven against a hand-written transcription; see `HARNESS-FIDELITY.md`. The
two differential properties that would close that gap have never persisted a single node —
one was attempted and produced nothing, the other has no proof directory at all.

So the defensible headline is: **43 properties proven about real code, 6 about a copy, 84
outstanding.**

## 2. What is actually blocking the other 84

Every stall investigated across four sessions resolved to one of these. **None of them is a
missing lemma.**

**a. The prove profile.** Three independent measurements, on three different specs:

| goal | no checkpointing | checkpointing |
|---|---|---|
| `PowerSpec.test_unroll_exponentTwo` | 0 nodes / 55 min | 20 nodes / 2 min |
| `PiecewiseLinearScale.test_scaleIn_neverExpandsBalanceIn` | 0 nodes / 88 min | 86 nodes / 20 min |
| `XYCConcentrate.test_full_exactIn_reverts…` | 0 nodes / 25 min | 197 nodes / 15 min |

Now fixed — the default was reversed. This single setting accounts for more lost time than
every other cause combined.

**b. Batching hides completed proofs.** `kontrol prove` prints per-proof verdicts only when
the whole invocation ends. One agent killed a three-property batch after 80 minutes as
"stalled"; re-run as two properties, both passed in **90 seconds**. They had almost certainly
already passed inside the killed run. **Run one property per invocation, two at most.**

**c. Dead rules.** Four rules in `lemmas.k` could never fire — `bool2word-or` subsumed them
at equal priority, and the kompiler emitted the general rule first regardless of source
order. Fixed today with explicit priorities.

**d. Two writers on one proof store.** Four coordinator dispatch collisions, plus the
discovery that a host-side `kill -9` leaves the container-side `kontrol prove` alive — one
survivor drove the same directories as its own replacement for 34 minutes.

**e. Structural spec shapes.** Symbolic-length `bytes calldata` propagates `lengthBytes` into
every memory offset. Fixed-layout `_args(...)` with symbolic fields closes; the same property
with symbolic length does not.

**f. The one genuine mathematics blocker: `Math.sqrt`.** Not `mul512` — see below. The MSB
cascade is ~2^7 leaves per call, and the differential properties invoke `_computeL` twice, so
roughly 16k leaves. This is a path-explosion problem, and a rewrite rule is probably the
wrong tool for it; `merge-nodes` on the sqrt-exit leaves is the candidate.

## 3. The lemma verdict

**68 rules. Two have confirmed firing evidence. Four were dead. The rest are unevidenced.**

| Rule | Evidence | Consequence |
|---|---|---|
| `mul512-high-zero`, `-nochop` | **CONFIRMED**, term-level | Real and decisive — see below |
| `asword-buf29-zeros-lit` | **STRONG** — flipped a FAILING proof to PASSED | Real |
| `mul-guard-word`, `-comm`, `mul-guard-or-collapse-l`, `-r` | **DEAD until today** | Zero contribution for their whole life |
| The other ~61 | **No agent has reported firing evidence for any of them** | Unknown |

**The mul512 rules are the case for lemmas, and it is a strong one.** Direct evidence from
`kontrol show --node 140` on a 197-node proof of the real instruction: the WordStack holds
`( ( KV2_balanceIn *Int ( KV6_minRaw +Int 1 ) ) /Int 1000000000000000000 )` — `Math.mulDiv`
already reduced to the plain fast-path form. Across all 197 nodes, `modInt` appears **zero**
times and `mulmod` **zero** times, while `_*Int_` appears in 80. Five `mulDiv` calls produced
**zero branches**. A live 512-bit path would leave `modInt` residue and split per call.
That rule turned an instruction half that was considered unprovable into one that executes
straight through. It is also why the `XYCConcentrate` transcription may now be removable.

**The case against is the other sixty-one.** Across four agent sessions today, lemma work
closed **zero** proofs. The five that closed were closed by running one property per
invocation. Every stall that was diagnosed turned out to be profile, process, or shadowing.
Agents repeatedly reported "no rule observed to fire" — honestly, and to their credit.

**Verdict: keep the library, stop growing it speculatively.**

1. **No new rule merges without firing evidence.** Either the label appears under `APPLIED`,
   or the post-rewrite term is observed in a dumped configuration, or node count moves with
   the rule and not without it. "It looks sound and might help" is how sixty-one rules got
   here.
2. **Audit what exists before adding more.** Every rule should be checked for shadowing
   against `definition.kore` emitted order. That check is seconds and has already found four
   dead rules; there may be more.
3. **Write a rule only against a term someone has dumped.** Three agents independently
   reported rules that did not fire because the compiled shape differed from the predicted
   one.
4. **Do not reach for a lemma when the shape is path explosion.** `Math.sqrt` is not a
   rewriting problem.

## 4. Corrections to previously recorded knowledge

- **`--lemmas` accepts `preserves-definedness`.** This document's predecessors said it
  hard-errors and that division lemmas needed a rebuild to test. **False, and propagated to
  every agent.** Verified by direct load. The real trap is that any malformed rule rejects the
  *whole file*, and the failure presents as `❌ PROOF FAILED ❌` per test with a
  `0 passed. 0 failed.` summary — indistinguishable from a refutation.
- **`mul512` is not the XYCConcentrate blocker** and has not been for some time. `Math.sqrt`
  is. Work was dispatched on the stale premise.
- **`merge-nodes` preconditions were stated wrongly.** It checks `K_CELL`, `PC_CELL`,
  `PROGRAM_CELL` and `CALLDEPTH_CELL`; leaves that differ in the first two are refused. It
  cannot merge a success continuation with a revert arm, and should not.
- **The 297 defunct boosters are zombies, not live orphans** — no CPU, no RSS. They are not a
  source of timing distortion, contrary to what was recorded.
- **The 9.4x profile A/B was real but unrepresentative**, measured on a 4-node straight-line
  proof.

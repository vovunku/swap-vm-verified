# Trust ledger

Every instruction rule is a claim about the deployed bytecode. This file tracks the status of
each one. See `PLAN.md` §5a for the model.

| State | Meaning |
|---|---|
| `ADMITTED` | Asserted. No proof, no conformance coverage. **All rules start here.** |
| `TESTED` | Conformance exercises it on concrete programs. Evidence on those inputs, not proof. |
| `PROVEN` | A Kontrol proof discharges it against the real bytecode. Phase R only, out of scope this pass. |

**Conformance is evidence, not proof.** A green suite means well-tested and still admitted.

## Instruction rules

| Opcode | Instruction | Implementation | State | Discharged by |
|---|---|---|---|---|
| `0x23` | `OnlyTakerTokenBalanceNonZero` | `Controls.sol:140-144` | `TESTED` | `InstructionConformance.t.sol` |
| `0x90` | `StaticBalances` | `Balances.sol:37-47` | `TESTED` | `InstructionConformance.t.sol` (both orientations) |
| `0x53` | `LimitSwap` | `LimitSwap.sol:_limitSwap1D` | `TESTED` | `InstructionConformance.t.sol`; D-1 fixed |

## DEFECT D-1 — FIXED. `0x53` diverged on reversed token order

**Found by conformance, on a clean build, reproducible.** The semantics is WRONG for
exact-in when `tokenIn > tokenOut`.

| case | direction byte | Solidity | K |
|---|---|---|---|
| `tokenIn < tokenOut` | `0x01` | prices | prices ✓ |
| `tokenIn > tokenOut` | `0x00` | **prices** (`amountOut = 0.5e18`) | **`Reverted("LimitSwapRecomputeDetected")`** ✗ |
| `tokenIn < tokenOut` | `0x00` | mismatch | mismatch ✓ |
| `tokenIn > tokenOut` | `0x01` | mismatch | mismatch ✓ |

Three of four combinations are correct. Only the case where `#makerDirLt` and
`tokenIn < tokenOut` are **both false** fails, and it falls through to the exact-in recompute
rule — which requires `AOUT =/=Int 0` while `AOUT` is `0`. That should be impossible, so the
success rule must be failing to apply for a reason not yet identified; `#exec(83)` then matches
the next rule instead.

Ruled out so far: the two rules are mutually exclusive on `AOUT` (verified in the compiled
source, host and container md5 identical); moving the discrimination from a cell pattern into
`requires` changes nothing; the firing rule is the **exact-in** recompute arm, confirmed by
renaming the two arms apart and re-running.

**Impact.** Half of all token pairs — every maker whose `tokenIn` sorts above `tokenOut` —
are modelled as reverting when they price. Any theorem touching `0x53` on that branch is
unsound. The Phase 1 gate theorem is unaffected: it reverts at the gate and never reaches
`0x53`.

**FIXED.** Cause: rule *selection*, not matching. The pricing rule and the recompute rule for
a given direction were both candidates for `#exec(83, _)`, and their `requires` clauses being
mutually exclusive on paper did not determine which K selected — with equal priority the
choice is unspecified, and it took the recompute arm. Adding `[priority(50)]` to the two
pricing rules and `[priority(60)]` to the two recompute arms makes the intended order explicit.

Verified on a clean rebuild — all four direction combinations now match Solidity:

| case | direction byte | Solidity | K |
|---|---|---|---|
| `tokenIn < tokenOut` | `0x01` | `amountOut = 2e18` | `2e18` ✓ |
| `tokenIn > tokenOut` | `0x00` | `amountOut = 0.5e18` | `0.5e18` ✓ |
| `tokenIn < tokenOut` | `0x00` | mismatch | mismatch ✓ |
| `tokenIn > tokenOut` | `0x01` | mismatch | mismatch ✓ |

**Lesson worth keeping: overlapping rules need explicit priorities even when their side
conditions look disjoint.** Mutual exclusion in the `requires` is not a selection order. The
same class of mistake sat in `lemmas.k` for the whole project — four rules dead because a
general rule shadowed them at equal priority. Second occurrence, same root cause.

Diagnosis that worked, after several that did not: `krun --depth N` to step to the exact
configuration before the dispatch and read the cells, rather than reasoning about what should
match. Renaming the two recompute arms apart identified which one fired.

**Downgraded after review.** A reviewer established that `semantics/conformance/run.sh` had
been broken since Phase 1 — it passed only `$PGM` while the configuration had grown six more
variables, so `krun` failed on the first case and **the K engine executed no program at all**
under the shipped harness. Every mutant to `swapvm.md` survived it trivially. The comparison
that justified `TESTED` was manual, one-time and undated. `run.sh` is now repaired, with
per-case configuration and an added gate-rejection case.

Mutation testing then found the suite missed: exact-in rounding direction (the catalogue
program divides exactly, so floor and ceiling were indistinguishable), all three secondary
revert arms, and the orientation branch — the reversed-order test asserted only a revert
selector and passed under a full orientation flip. Six tests were added; one of them found
defect D-1.

`TESTED` via `test/conformance/InstructionConformance.t.sol`, which routes opcodes to the
**real instruction bodies** inherited from `Controls`, `Balances` and `LimitSwap` — only the
dispatch table is ours, which is what the production VM generates anyway. No instruction logic
is reimplemented, so this compares K rules against production code and not against a
transcription.

Four cases agree register-for-register with `krun`: holding taker prices at 1:2
(`amountOut = 2e18`), zero-balance taker reverts `TakerTokenBalanceIsZero` with balances
untouched, reversed token order swaps the balance pair then rejects on direction, and exact-out
rounds **up** (`amountIn = 2`, where floor would give 1 — so the assertion distinguishes
rounding direction rather than merely exercising the path).

Still **not `PROVEN`**: evidence on four inputs, not a proof over all inputs.

## Generic bytes lemmas

`semantics/lemmas.k`. Not domain facts — definitional identities about `+Bytes`,
`substrBytes`, `Int2Bytes`, `Bytes2Int` that plain K does not ship. Without them a symbolic
program built by concatenation cannot be decoded at all: the prover cannot reduce
`(b"\x23\x14" +Bytes ... +Bytes TAIL) [ 0 ]` to `0x23`.

| Lemma | State | Note |
|---|---|---|
| `lengthBytes` of concat | `ADMITTED` | definitional |
| `lengthBytes(Int2Bytes(N,..)) => N` | `ADMITTED` | requires `N >= 0` |
| index into left operand | `ADMITTED` | requires `I < lengthBytes(B1)` |
| slice within left / within right | `ADMITTED` | side conditions make them total |
| full-width slice is identity | `ADMITTED` | requires `E == lengthBytes(B)` |
| `Bytes2Int ∘ Int2Bytes` round-trip | `ADMITTED` | requires `V < 2^(8N)`; the bound is what makes it exact rather than truncating |
| index into **right** operand | `ADMITTED` | added in Phase 2; without it the opcode and args-length bytes of any instruction after the first cannot be read |
| slice **straddling** the concatenation point | `ADMITTED` | added in Phase 2; splits at the boundary |

**Correction to the "side conditions make them total" claim above: it is not literally true of
the two Phase 2 additions.** Neither carries an upper bound (`I < len(B1)+len(B2)`;
`E <= len(B1)+len(B2)`). A review verified this is nonetheless **not exploitable**, but for a
different reason than totality: K's `Bytes[_]` is genuinely partial, so out of range both sides
of the rule are equally stuck — `(b"\x01\x02" +Bytes b"\x03")[5] ==Int 0` and `==Int 9` both
fail. There is no totalizing default the lemma could contradict. Sound, but the justification
recorded here was the wrong one.

The five slice/index rules were also checked for the D-1 hazard and are **pairwise disjoint**:
left-index (`I < len B1`) vs right-index (`len B1 <= I`); within-left (`E <= len B1`) vs
within-right (`len B1 <= S`) vs straddle (`S < len B1 < E`). The only overlap is straddle
against the full-width identity rule, and they are confluent.

The two Phase 2 additions were each found by a stall, not written speculatively. The pricing
claim stopped at `pc 22` — it had decoded the gate and could not read the second instruction's
args-length byte, because that byte falls in the *right* operand of a concatenation and only a
left-index rule existed.

## Decode loop

| Component | Implementation | State | Notes |
|---|---|---|---|
| fetch/decode/dispatch | `VM.sol:118-150` | `TESTED` | `opcode = shr(248,w)`, `argsLen = and(shr(240,w),0xff)`, `pc += 2 + argsLen` |
| program-length bound | `VM.sol:142` | `TESTED` | reverts `RunLoopExceedProgramLength` when `pcs > length` |

Discharged by `semantics/conformance/run.sh` — five programs agree on final `pc` and revert
status across both engines, plus six Solidity-side assertions on decoded opcodes and args
lengths. **`TESTED`, not `PROVEN`**: this is evidence on those inputs, not a proof over all
programs.

Conformance already caught one drift. The first version of the K bound-check rules reverted
with `pc` still at the instruction start, while the real VM reports the *advanced* value —
`(91, 90)` where the model said `88`. Both reverted with the same reason, so only a test that
inspects the revert arguments distinguishes them. Fixed to advance before checking.

## Theorems and what they rest on

A theorem inherits the **weakest** state among the instructions it touches.

| Theorem | Depends on | Effective state |
|---|---|---|
| `permissioned-swap-gate` | `0x23`, decode loop, bytes lemmas | `ADMITTED` |
| `pricing-exact-in-is-the-floor` (T1) | `0x23`, `0x90`, `0x53`, decode loop, bytes lemmas | `ADMITTED` |

**T1 PROVED** (`kprove` returns `#Top`) — `semantics/proofs/pricing-spec.k`. Runs the whole
three-instruction program with `amountIn` and both maker reserves **symbolic**, and pins the
quote to exactly the floor of the maker's rate:

    amountOut * balanceIn <= amountIn * balanceOut          (maker safety)
    (amountOut + 1) * balanceIn > amountIn * balanceOut     (taker safety)

Both bounds are required: the first alone is satisfied by returning 0, the second alone by
returning something huge. Together they determine `amountOut` uniquely.

This is the first theorem here about the **money** rather than about access control, and it
proves the rounding decision `LimitSwap.sol:49` documents as intentional — the sub-wei
remainder goes to the maker on every fill.

Negative control `pricing-negative-control.k` — the same claim with the maker-safety
inequality reversed — **fails as required**. It reaches the arithmetic, unlike the Phase 1
control it replaced.

**Caveat that must travel with T1, stated exactly.** `LimitSwap.sol:49` is plain checked
arithmetic — no `mulDiv` — so the divergence condition is precise: **K and the EVM differ iff
`amountIn * balanceOut >= 2^256`**, where the EVM reverts `Panic(0x11)` and K computes. Below
that they agree exactly, and the quotient is then also below `2^256`, so there is no second gap.

**The `amountIn < 2^256` hypothesis does not bound the product, and is inert** — a review
deleted it and the claim still proves. So T1 holds for arbitrarily large `amountIn`, including
the region where the EVM would revert. `amountIn` is taker-chosen, so the divergence is
reachable by construction for any `balanceOut`, at `amountIn >= 2^256 / balanceOut`.

Read T1 as *"given the product does not overflow"*.

**PROVED** (`kprove` returns `#Top`) — `semantics/proofs/gate-spec.k`. For any program
beginning `0x23 0x14 G`, with `TAIL` symbolic, a taker holding zero `G` ends
`Reverted("TakerTokenBalanceIsZero")`. `TAIL` is never decoded, because `#revert` discards the
continuation, so the proof does not case-split on it.

Effective state is `ADMITTED` because the bytes lemmas are admitted, even though all three
instructions are `TESTED`. The theorem inherits the weakest dependency.

## Abstraction log

Records every firing of the `PLAN.md` D3 trigger — an instruction weakened from an exact
definition to axioms, with the measurement that forced it. Empty is the good state.

*(none)*

## Negative controls

Statements known to be FALSE, asserted to fail. If one ever closes, the rule set is
inconsistent and every result above it is void. See `PLAN.md` §5a.

| Control | Expected | Result |
|---|---|---|
| `negative-control.k` — gate first, balance NON-zero, asserts `Reverted` | must FAIL | **FAILS at `<pc> 22`, `<status> Running`** — a real computed counterexample |
| `control-sensitivity.k` — identical premises, conclusion `Running` | must PROVE | **`#Top`** |
| `pricing-negative-control.k` — T1 with the maker-safety inequality REVERSED | must FAIL | **FAILS at `pc 91`** with the real quote in the register |
| `pricing-spec.k` itself | doubles as T1's sensitivity witness | **`#Top`** — same premises, correct conclusion |

**A sharper T1 control exists and should be added:** change `<=Int` to `<Int` in the
maker-safety bound — a **one-character** edit. It is false exactly when `balanceIn` divides
`amountIn * balanceOut`, so it discriminates the rounding decision itself rather than the
direction of an inequality. A review verified it fails. The shipped control reverses the
inequality, which is false for almost every input and is therefore a distant neighbour.

The pair is the point. A control that fails proves nothing on its own — it may be failing for
an incidental reason. The sensitivity witness has the same setup and the correct conclusion and
**proves**, which shows `kprove` is discriminating on the conclusion rather than choking on the
premises.

**The previous control was inert and has been replaced.** It dropped the gate prefix and
asserted an arbitrary program reverts. It did fail — but at `<pc> 0`, before any instruction
executed, on a residual branch where no decode rule applies to a symbolic first byte. A review
established the decisive fact: a claim that is *true* fails with a byte-identical residual. It
would have kept "failing correctly" with every instruction rule deleted. **A negative control
with a symbolic prefix cannot discriminate** — the prefix must be concrete.

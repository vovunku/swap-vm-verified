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
| `0x53` | `LimitSwap` | `LimitSwap.sol:_limitSwap1D` | **`DEFECTIVE`** | see open defect D-1 below |

## OPEN DEFECT D-1 — `0x53` diverges on reversed token order

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

**Not fixed. Do not mark `0x53` `TESTED` until it is.**

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
| `negative-control.k` — an *arbitrary* program reverts `TakerTokenBalanceIsZero` | must FAIL | **FAILS correctly** (`kprove` exit 1) |

The claim drops the gate prefix and asserts every program reverts. It does not — the empty
program terminates `Running`. If this ever proves, the rule set is inconsistent and every
result above it is void.

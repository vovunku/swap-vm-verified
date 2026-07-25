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
| `0x53` | `LimitSwap` | `LimitSwap.sol:_limitSwap1D` | `TESTED` | `InstructionConformance.t.sol` (exact-in and exact-out) |

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

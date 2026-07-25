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
| `0x23` | `OnlyTakerTokenBalanceNonZero` | `Controls.sol:140-144` | `ADMITTED` | — |
| `0x90` | `StaticBalances` | `Balances.sol` | `ADMITTED` | — |
| `0x53` | `LimitSwap` | `LimitSwap.sol` | `ADMITTED` | — |

## Decode loop

| Component | Implementation | State | Notes |
|---|---|---|---|
| fetch/decode/dispatch | `VM.sol:118-150` | `ADMITTED` | `opcode = shr(248,w)`, `argsLen = and(shr(240,w),0xff)`, `pc += 2 + argsLen` |
| program-length bound | `VM.sol:142` | `ADMITTED` | reverts `RunLoopExceedProgramLength` when `pcs > length` |

## Theorems and what they rest on

A theorem inherits the **weakest** state among the instructions it touches.

| Theorem | Depends on | Effective state |
|---|---|---|
| `permissioned-swap-gate` | `0x23`, decode loop | `ADMITTED` |

## Abstraction log

Records every firing of the `PLAN.md` D3 trigger — an instruction weakened from an exact
definition to axioms, with the measurement that forced it. Empty is the good state.

*(none)*

## Negative controls

Statements known to be FALSE, asserted to fail. If one ever closes, the rule set is
inconsistent and every result above it is void. See `PLAN.md` §5a.

| Control | Expected | Last checked |
|---|---|---|
| *(none yet)* | | |

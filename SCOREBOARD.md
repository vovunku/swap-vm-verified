# Scoreboard — what was built, in numbers

Measured, not estimated. Every figure below has the command that produced it, so a reader can
disagree with the number rather than with the claim. Where "written" and "proved" differ, both
are shown; conflating them is the single easiest way to overstate a verification project.

**Measured:** 2026-07-26. K results are from a full `run-proofs.sh` on this machine.

---

## Summary

| | count |
|---|---:|
| K proof files, run and matching expectation | **40 / 40** |
| — theorems that must prove (`#Top`) | 23 |
| — negative controls that must fail | 17 |
| Opcodes modelled in the K semantics | **20 / 52** |
| Kontrol properties written | **281** across 13 suites |
| Kontrol harnesses written | 13 |
| Confirmed bugs, with executable reproducers | **13** |
| Reproducer test files | 14 |

---

## 1 — The K semantics (layer 2: reasoning about programs)

A handwritten K semantics of the SwapVM bytecode interpreter. Decode loop complete;
instruction set partial.

| | count | source |
|---|---:|---|
| Opcodes modelled | 20 of 52 named | `demo/data/claims.json` → `coverage` |
| Per-opcode rule files | 14 | `semantics/opcodes/*.k` |
| Lines of K rules | 2,096 | `semantics/*.k` + `semantics/opcodes/*.k` |
| Decode-loop spec | 356 lines | `semantics/swapvm.md` |
| Proof files | 42 | `semantics/proofs/*.k` (40) + `dustproof/semantics/*.k` (2) |

```bash
ls semantics/opcodes/*.k | wc -l
cat semantics/*.k semantics/opcodes/*.k | wc -l
```

### Proof results — full suite, every file

All 40 registered proofs matched their expected verdict. **17 of the 40 are supposed to
fail**, and did.

| expectation | files | result |
|---|---:|---|
| must prove (`#Top`) | 23 | all PROVED |
| must fail (negative controls) | 17 | all not-proved, as required |

```bash
./semantics/run-proofs.sh          # prints one row per file; exits non-zero on any mismatch
```

The controls are not padding. A proof that cannot fail proves nothing, and an inconsistent
rule set proves *everything* while looking like a clean sweep — the controls are the only
check that catches that, which is why they are 43% of the suite rather than an afterthought.

### The named theorems

| id | claim | quantified over | file |
|---|---|---|---|
| **T0** | A taker holding none of the gate token cannot fill the order | **any program tail** (symbolic) | `semantics/proofs/gate-spec.k` |
| T1 | Exact-in output is exactly the floor of the fixed-rate quote | any reserves, any trade size | `semantics/proofs/pricing-spec.k` |
| T2 | Exact-out input is exactly the ceiling | any reserves, any trade size | `semantics/proofs/pricing-exactout-spec.k` |
| **D1** | The DustProof quote is exactly the constant-product curve | any reserves, any trade size | `dustproof/semantics/dustproof-spec.k` |

T0 is the one that generalises. It is proved with the rest of the program left *symbolic* —
an unknown tail, not an enumerated set of tails — so it already holds for programs nobody has
written. That is the reusable result; the others are about specific programs.

---

## 2 — Kontrol specs and proofs (layer 1: the instructions)

Specs written as Solidity property tests, proved against the **compiled bytecode** via
Kontrol → KEVM → K. Kontrol pinned at `1.0.255` (`deps/kontrol_release`).

### Properties written, per suite

| suite | properties |
|---|---:|
| FeeSpec | 35 |
| PeggedSwapSpec | 31 |
| PiecewiseLinearScaleSpec | 31 |
| PowerSpec | 31 |
| BaseFeeAdjusterSpec | 25 |
| WhitelistSpec | 24 |
| XYCConcentrateSpec | 21 |
| OraclePriceAdjusterSpec | 19 |
| ControlsSpec | 17 |
| XYCSwapSpec | 17 |
| MinRateSpec | 13 |
| LimitSwapSpec | 9 |
| BalancesSpec | 8 |
| **total** | **281** |

```bash
for f in test/kontrol/*Spec.t.sol; do
  printf '%-32s %3d\n' "$(basename $f)" "$(grep -c 'function test_' $f)"; done
```

### Written ≠ proved — read this before quoting 281

281 is **properties written**, not properties discharged. The proof store (`out/proofs/`) is
per-machine and gitignored, so a global "proved" count cannot be asserted from a checkout.
`test/kontrol/analysis/INSTRUCTION-STATUS.md` carries the per-instruction figures that were
recorded when each suite last ran, and marks the rest.

Properties that are known not to close are tagged in the source, so the gap is visible where
the property is rather than only in a summary:

| tag | count | meaning |
|---|---:|---|
| `OPEN` | 10 | stated at full width; the closed form is narrower |
| `NOT CLOSED` | 6 | stalled or starved — **not** a refutation, no counterexample leaf |
| `REFUTED` | 2 | deliberately: a false twin that must fail, and did |
| `FAILED-ON-PROVER-INCOMPLETENESS` | 1 | the prover gave up; the code is not implicated |
| `narrowed` | 1 | a parameter pinned, with the reason recorded |

```bash
grep -rho "@custom:kontrol-status [A-Za-z-]*" test/kontrol/*.t.sol | sort | uniq -c
```

### Coverage of the instruction set

| | count |
|---|---:|
| Instruction files in `src/instructions/` | 20 |
| With a Kontrol spec suite | 13 |
| With no spec yet | 7 (`DutchAuction`, `Invalidators`, `SeriesEpochManager`, `TWAPSwap`, `Decay`, `Extruction`, `FeeExperimental`) |
| Modelled in the K semantics | 3 files (`Controls`, `Balances`, `LimitSwap`) + `XYCSwap` |

---

## 3 — Bugs found

13 confirmed, each reproduced by executing the EVM before being called confirmed.

| evidence level | count | what it means |
|---|---:|---|
| **CONFIRMED** | 13 | reproduced by a `forge test` witness or a Kontrol counterexample with its path condition |
| SOURCE | 1 | argued from reading the code; not yet executed |

| criticality | count |
|---|---:|
| HIGH | 1 |
| MEDIUM | 5 |
| LOW | 5 |
| INFORMATIONAL | 3 |

Criticality and evidence are independent axes on purpose: a defect can be CONFIRMED and
INFORMATIONAL at once, or MEDIUM and only MODELLED. Every entry also carries a reachability
assessment, because a prover finding something is not the same as it being exploitable from a
transaction.

| | count |
|---|---:|
| Reproducer test files | 14 (`test/kontrol/analysis/repro/*.t.sol`) |

```bash
awk '/^## CONFIRMED/{f=1;next}/^## [A-Z]/{f=0}f&&/^### /{c++}END{print c}' \
  test/kontrol/analysis/BUGS.md
ls test/kontrol/analysis/repro/*.t.sol | wc -l
```

### One finding worth its own line

Three instructions were added **after every audit closed**: `PiecewiseLinearScale`
(2026-06-03), `SeriesEpochManager` (2026-06-04), `Whitelist` (2026-06-05). Across all eight
audit PDFs they are mentioned 0, 0, and 2 times respectively. `PiecewiseLinearScale` has 31
properties written and 2 confirmed defects. Unaudited-and-recent turned out to predict where
the bugs were better than any measure of complexity.

---

## 4 — DustProof (the worked example)

A dust sweeper on Aqua/SwapVM: one transaction empties several dust balances into ETH.

| | |
|---|---|
| Contracts | 2 (`DustOrderBuilder.sol`, `DustSweeper.sol`) |
| Program shape it can emit | exactly 1 — gate → deadline → XYCSwap → salt |
| Proof | D1 + its negative control, both run by `dustproof/semantics/run-proofs.sh` |
| Loop invariant needed | none — batching is OpenZeppelin `Multicall`, so there is no loop |

The builder is the guarantee: it can only emit the one shape the theorems cover, so an
arbitrary maker-supplied program never reaches the sweeper.

---

## 5 — Demo

| | |
|---|---|
| Static page | `docs/index.html`, one self-contained file, no server |
| Programs shown | 3, each with a machine-checked claim |
| Frontend tests | 47 (prebaked) + 28 (live) |
| Data integrity tests | `demo/selftest.py` — checks the page against the repository |

Every proof result on the hosted page is a **recording of a real run**, labelled as a replay
with its timestamp and command. The page has no prover behind it and says so.

---

## What these numbers do not say

- **20 of 52 opcodes.** Everything else falls through to a no-op in the model while the real
  VM reverts. Where the two disagree, a theorem about the model says nothing about
  production; `semantics/swapvm.md` documents each gap.
- **Layer-2 theorems are `ADMITTED`, not `PROVEN`.** The instruction rules they rest on are
  conformance-*tested* against the real VM, not derived from it. `axioms.md` carries the
  tiering.
- **281 properties written is not 281 proved.** See §2.

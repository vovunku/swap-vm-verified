# Verifying this project

Everything claimed here is checkable by running a command. Each claim below states its
**evidence tier**, the **command** that reproduces it, and roughly **how long** it takes.

Where a result is recorded but was **not** re-verified against the current build, it says so.
That distinction is the point of this file: a formal-verification project whose numbers cannot
be reproduced is worth less than a smaller one whose numbers can.

---

## TL;DR for a reviewer with ten minutes

```bash
docker pull runtimeverificationinc/kontrol:ubuntu-jammy-$(cat deps/kontrol_release)
./scripts/verify.sh setup       # start container, kompile the K semantics   ~5 min
./scripts/verify.sh semantics   # 4 theorems + 2 negative controls           ~30 sec
```

That second command is the strongest single result in the project and it finishes in under a
minute. It proves four theorems about a **K semantics of the SwapVM bytecode interpreter**,
one of which is quantified over an *infinite family of programs*, and runs two negative
controls that **must fail** and do.

---

## Evidence tiers

Borrowed from `test/kontrol/analysis/BUGS.md`, and used consistently:

| Tier | Meaning |
|---|---|
| **PROVED** | `kprove` returns `#Top`, or `kontrol prove` reports PASSED for the property's **highest** version. A statement about all inputs in the stated domain. |
| **TESTED** | Executed on concrete inputs — `forge test`, or K conformance. Evidence on those inputs, not proof. |
| **RECORDED** | A verdict exists in the proof store or the docs, but was produced under a **different build** and has not been re-checked. Not reproducible as-is. |

**Why RECORDED is not PROVED.** Kontrol keys a proof to a digest of the Foundry artifact
(`Contract.Method.digest`). When the artifact changes, `resolve_proof_version` mints a new
version and re-proves from scratch. A PASSED recorded at `:2` says nothing about `:4`.

---

## Claims

### 1. K semantics — 4 theorems, 2 negative controls · PROVED · ~30 s

```bash
./scripts/verify.sh semantics
```

| file | expected | what it establishes |
|---|---|---|
| `gate-spec.k` | `#Top` | **T0** — for *any* program beginning `0x23 0x14 G` with an **arbitrary symbolic tail**, a taker holding zero `G` ends `Reverted("TakerTokenBalanceIsZero")` |
| `pricing-spec.k` | `#Top` | **T1** — exact-in is *exactly* `floor(amountIn·balanceOut/balanceIn)`, two-sided |
| `pricing-exactout-spec.k` | `#Top` | **T2** — exact-out is *exactly* the ceiling |
| `control-sensitivity.k` | `#Top` | the negative control's twin: same premises, correct conclusion |
| `negative-control.k` | **FAIL** | same program, balance non-zero, asserting the same revert |
| `pricing-negative-control.k` | **FAIL** | T1 with the maker-safety inequality reversed |

T0's worth is the quantification over the tail: it holds for *every* program starting with
that gate, which no scenario test can cover.

**The two failing controls are the design, not a defect.** A proof that cannot fail proves
nothing, and the worst failure mode — an inconsistent rule set — proves *everything* while
looking like total success. If either control ever proves, every result above it is void.

### 2. Conformance: the K rules match the real VM · TESTED · ~2 min

```bash
./scripts/verify.sh conformance
```

11 programs run through both `krun` and the **real** `ContextLib.runLoop` with the real
instruction bodies; final `pc`, revert status and `amountOut` are compared. Only the dispatch
table is ours, which is what the production VM generates anyway.

*Honest limitation, from `semantics/conformance/run.sh` itself:* each side is checked against
expectations written by hand, so a shared mistake would pass both. This is weaker than a true
differential harness.

### 3. Mutation: the suite detects broken behaviour · TESTED · ~40 min

```bash
./scripts/verify.sh mutation
```

Breaks the semantics nine known ways, rebuilds, and reports which check caught each. This
exists because a green proof is unfalsifiable-looking: an audience cannot tell a real theorem
from a vacuous one. **The first mutation study here killed zero mutants** — the harness had
been silently broken since Phase 1 and the K engine was executing nothing at all.

### 4. XYCSwap — 13 of 17 properties · PROVED · ~40 min

```bash
./scripts/verify.sh kontrol      # or: ./scripts/kontrol-prove.sh xycswap
```

Nine unconditional plus four proven below 2^128. The property list lives in
`[prove.xycswap]` in `kontrol.toml`; the runner reads it from there so the two cannot drift.

**Four properties do NOT close** and are kept visible rather than deleted — full-`uint256`
two-sided exactness statements, each tagged `@custom:kontrol-status OPEN` at its definition
site, with its narrowed twin proven alongside. Run them with:

```bash
./scripts/kontrol-prove.sh xycswap-open      # expected to time out
```

`kontrol.toml` records what was ruled out by measurement — SMT, booster equation limits, this
repo's own lemma library, and CSE — so nobody repeats the search.

---

## Per-instruction coverage

`test/kontrol/analysis/INSTRUCTION-STATUS.md` is the coverage map — one row per instruction:
properties declared, properties actually **proven**, confirmed defects, whether the eight audit
firms ever saw the file, and whether it is modelled in K.

Three headline facts from it:

* **62 properties are proven** across the store (PiecewiseLinearScale 24, XYCSwap 13, Power 12,
  PeggedSwap 7, XYCConcentrate 6).
* **Four specs have no proofs in this store** — `BalancesSpec`, `ControlsSpec`,
  `BaseFeeAdjusterSpec`, `MinRateSpec`. A reproducibility gap rather than an honesty one: the
  Track A commits proved much of this and recorded it precisely, but `out/proofs/` is
  gitignored and per-machine, so those results live in another container.
* **Eight instructions have no specification at all**, including `Invalidators` — the replay and
  overfill guard.

## What is NOT claimed

**Most of the proof store is RECORDED, not PROVED.** Measured against the current build:

| spec | on current digest | stale |
|---|---|---|
| PiecewiseLinearScaleSpec | 30 | 1 |
| PowerSpec | 20 | 11 |
| XYCConcentrateSpec | 19 | 2 |
| XYCSwapSpec | 14 | 3 |
| PeggedSwapSpec | 4 | 36 |
| BaseFeeAdjusterSpec | **0** | 25 |
| LimitSwapSpec | **0** | 9 |
| MinRateSpec | **0** | 29 |
| **total** | **87** | **116** |

**116 of 203 properties are stale.** Three specs have *nothing* on the current digest. The
counts in `PROOF-MAP.md` were accurate when written; they are not reproducible without
re-running. **XYCSwap is the only spec re-verified end to end for this submission.**

Also not claimed:

* **Nothing about deployed bytecode.** Every instruction rule in the K semantics is `TESTED`,
  never `PROVEN`. See `semantics/axioms.md` — a theorem inherits the **weakest** state among
  its dependencies, so all four theorems are effectively `ADMITTED`.
* **3 of 52 opcodes** are modelled in K. The decode loop is complete and reusable; the
  instructions are not. Honest scope: one program, three instructions.
* **Six `XYCConcentrate` properties are proven against a hand-written copy**, not the real
  instruction. The two differentials that would close that gap have never persisted a node.
  See `HARNESS-FIDELITY.md`.
* **No end-to-end program was executed** for any bug finding. Every witness drives a
  hand-assembled `Context` directly into an instruction.
* **Arithmetic overflow is unmodelled in K**, which qualifies T1/T2: K and the EVM differ
  exactly when `amountIn * balanceOut >= 2^256`.

---

## Reproduction environments

### Docker (recommended for reviewers)

```bash
docker pull runtimeverificationinc/kontrol:ubuntu-jammy-$(cat deps/kontrol_release)
./scripts/verify.sh setup
```

The Kontrol version is pinned in `deps/kontrol_release`. A proof is only valid against the
definition digest it was produced under, so the pin is load-bearing, not hygiene.

### Nix

```bash
nix develop      # foundry-bin + kontrol, see flake.nix
```

`flake.nix` pins `kontrol.url = "github:runtimeverification/kontrol"` — pin it to the tag in
`deps/kontrol_release` for a reproducible result.

### Pre-built proof bundle — `proofs-all.tar.zst` (2.1 MB, committed)

Re-proving from scratch takes hours. The finished KCFGs are committed instead:

```bash
zstd -dc proofs-all.tar.zst \
  | docker exec -i kontrol tar xf - -C /home/user/swap-vm-verified/out/proofs
```

**108 proof directories, highest version only, across every spec** — 1.2 GB of KCFG JSON
compressed to 2.1 MB (0.17%), because a quarter-megabyte EVM configuration repeats
near-identically across every node of a proof graph.

Rebuild it with `./scripts/bundle-proofs.sh` (or `./scripts/bundle-proofs.sh XYCSwapSpec` for
one spec).

Shipping the *open* proofs alongside the passing ones is deliberate. They carry their pending
KCFGs, so anyone can **resume** them from where this project stopped rather than starting from
node 0 — and it shows honestly how far each unproven property actually got.

**This is the fix for a real problem, not a convenience.** `out/proofs/` is gitignored and
per-machine, which is why `test/kontrol/README.md` used to assert PASSED for proofs no reader
could check. Writing the number down does not survive; shipping the store does.

Inspect a restored proof without re-running anything:

```bash
docker exec -u user kontrol bash -c \
  "cd /home/user/swap-vm-verified && FOUNDRY_PROFILE=kontrol kontrol show \
   'XYCSwapSpec.test_exactOut_isExactlyTheCeiling_boundedTo128Bits'"
```

**Caveat, and it is a real one:** a restored proof only counts if your build produces the
same digest. `foundry.toml` pins solc 0.8.30, optimizer 700 runs, `via_ir`, and the Kontrol
profile pins `evm_version = "cancun"` — so a matching build *should* match digests, but this
has not been tested across machines. If digests differ, Kontrol silently re-proves from
scratch rather than reporting a mismatch. Treat the bundle as a time-saver, not as evidence.

---

## Findings

`test/kontrol/analysis/BUGS.md` carries 11 CONFIRMED defects, each with an executing witness
and a four-part assessment: reachability, impact, who bears the loss, and whether a guard
elsewhere already prevents it.

Reproduce them all with:

```bash
forge test --match-path 'test/kontrol/analysis/repro/*'
```

**Exception:** the non-termination reproducers (`PiecewiseLinearScaleNonTermination`,
`WhitelistGasTrap`) must be excluded from `kontrol prove` — gas is off by default there, so
those loops are not slow, they are infinite.

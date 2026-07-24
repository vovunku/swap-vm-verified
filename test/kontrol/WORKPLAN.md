# Verification work plan

Division of the instruction set between two people working in parallel, ordered so that
neither blocks the other. See `README.md` for the workflow and the tier classification
this is derived from.

**Splitting rule.** Track A takes instructions whose proofs should close with the lemma
library as it stands — little or no non-linear arithmetic, so the work is writing good
properties rather than fighting the prover. Track B takes the instructions that need lemma
engineering, loop reasoning, or square roots.

**File ownership.** One harness and one spec file per instruction, so the two tracks never
touch the same file. The single shared file is `lemmas.k`; Track B owns it. If Track A
needs a lemma, open an issue rather than editing it — a bad lemma silently invalidates
every proof in the repo, so it is worth funnelling through one pair of hands.

---

## Track A — breadth (the easier set)

Goal: cover as many instructions as possible and build fluency with the tooling. These
should mostly close without new lemmas.

### A1. `Controls` — start here

`src/instructions/Controls.sol`, 12 entrypoints, no arithmetic worth the name. The best
first target: the properties are obvious, and the proofs should be fast, so it is a clean
way to learn the build/prove/show loop before anything subtle is at stake.

Suggested properties:

- `_jump` sets `nextPC` to the 2-byte argument, and only that.
- `_stop` sets `nextPC` to `type(uint256).max` so the run loop terminates.
- `_revert` propagates its argument bytes into `InstructionRevert`.
- `_jumpIfDirection` / `_jumpIfTokenIn` / `_jumpIfTokenOut` branch **iff** the condition
  holds, and leave `nextPC` untouched otherwise. Worth proving both directions — a guard
  that always branches passes a one-sided test.
- `_deadline` reverts exactly when `block.timestamp` exceeds the 5-byte deadline. Note the
  boundary: prove the behaviour *at* equality, not just either side of it.
- Argument decoding: a truncated or oversized `args` is rejected rather than silently
  reading adjacent calldata.

### A2. `MinRate`

`src/instructions/MinRate.sol`, 2 entrypoints. `_requireMinRate` rejects a swap below the
maker's floor; `_adjustMinRate` clamps to it. Small `mulDiv`, so the existing lemmas should
suffice.

- The guard rejects exactly the rates below the floor, and accepts at the floor.
- `rateLt` / `rateGt` are selected by token ordering, not by argument position — this is a
  known vulnerability class in this codebase (see `.cursor/rules/security-review.mdc`), so
  prove the direction-dependence explicitly.
- Adjusting an already-conforming rate is a no-op.

### A3. `Balances` — static variant only

`_staticBalancesXD` writes the two balances into the registers. Skip
`_dynamicBalancesXD`: it does SLOAD/SSTORE and belongs to tier 3.

- Balances land in the registers ordered by **token address**, not by in/out. Swapping
  `tokenIn`/`tokenOut` must swap the assignment.
- The instruction is idempotent, or rejects a second application — check which, and pin it.

### A4. Prove the existing `LimitSwap` specs

`test/kontrol/LimitSwapSpec.t.sol` is already written; nobody has run it under Kontrol yet.
Running it is a self-contained task and tells us whether the lemma library generalises
beyond `XYCSwap` — which is the main open question for Track B. Report back the failing
node and path condition rather than trying to fix lemmas.

---

## Track B — depth (the harder set)

### B1. Close `XYCSwap` and `LimitSwap` — blocks everything else

The lemma library is the shared dependency. Until these two close, we do not know whether
the `mulDiv`/`ceilDiv` rules are sufficient, and every other arithmetic instruction is
guesswork. This is the highest-priority item on either track.

Expect to iterate: prove, read the failing node with
`kontrol show --failure-information --failing`, add a lemma, `--rekompile`, prune the stuck
node with `remove-node` rather than `--reinit`. Verify each new rule actually compiled in
(`grep <label> kompiled/definition.kore`) — a stale copy of `lemmas.k` survives
`--rekompile` silently.

### B2. `PeggedSwap` and `PeggedSwapMath`

`src/instructions/PeggedSwap.sol` (225 lines) plus `src/libs/PeggedSwapMath.sol`. The
curve is `√(x/X₀) + √(y/Y₀) + A(x/X₀ + y/Y₀) = 1 + A`, with curvature fixed at p = 0.5 to
admit a closed form. Square roots over 256-bit integers need their own lemmas — bounds and
monotonicity of integer `sqrt`, and the relationship between `sqrt(x)²` and `x`.

Note the docstring references `docs/PeggedSwap/PeggedSwapWP.md`, which does not exist in
the repo. Derive the specification from the source and the whitepaper, and flag the gap.

### B3. `XYCConcentrate`

54 square-root references — the hardest instruction in the set. Do not start it before B2
has produced a working `sqrt` lemma set.

### B4. `PiecewiseLinearScale` and `Power.pow`

`Power.pow` is `while (exponent > 0)` — an unbounded loop with a symbolic trip count.
Options, in increasing order of value: bound it with `--bmc-depth` and accept a bounded
result; or prove a closed-form summary lemma for exponentiation-by-squaring and use that in
place of executing the loop. The summary is the better outcome, since everything that
reaches `Power.pow` inherits it.

### B5. Gas methodology

Once a spec set closes, establish the measurement loop described in `README.md`: enumerate
KCFG leaves, `kontrol get-model` for a concrete witness per path, measure gas on each
witness. For tier-1 instructions also try `--use-gas` directly — with no loops and no
storage, gas per path is a constant rather than a symbolic expression, so proving
`new_gas <= old_gas` per path should be tractable.

---

## Not scheduled

**Tier 3** (`Invalidators`, `Decay`, `TWAPSwap`, `SeriesEpochManager`, `Fee`,
`_dynamicBalancesXD`) touch storage or make external calls, and need a different harness
shape than the pure-register one used here.

**`Extruction`** makes arbitrary external calls and cannot be verified without strong
assumptions about the callee.

**The run loop and dispatcher** (`ContextLib.runLoop`, `Opcodes._runOpcode`) are a separate
project. `runLoop` dispatches through an internal function pointer, which forces the prover
to branch over every jump destination. Note though that `_runOpcode` itself is a plain
static if/else chain and *is* directly verifiable — proving a jump-table rewrite dispatches
identically to the current 46-branch linear chain would be the single largest gas win
available, if the scope is ever widened.

---

## Higher-value targets than green-field specs

`TESTING.md` documents roughly 40 tests that disable core invariants with unresolved TODOs,
and the suite contains 98 `skip*` flags overall (38 additivity, 23 symmetry, 22
monotonicity, 15 spot-price). Several scenarios also set tolerances loose enough to be
close to vacuous — `monotonicityToleranceBps` reaches 15000, i.e. 150% slack.

Each of those is a place where someone already suspected something and responded by turning
the check off. A proof or a counterexample there is worth considerably more than confirming
that arithmetic which already works still works. Once either track has a spec pattern that
closes reliably, redirect toward these.

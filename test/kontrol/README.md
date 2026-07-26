# Kontrol proofs for SwapVM instructions

Formal verification of SwapVM instructions using [Kontrol](https://docs.runtimeverification.com/kontrol),
Runtime Verification's symbolic execution engine for Foundry.

Kontrol reinterprets ordinary Solidity property tests as formal specifications: every test
parameter becomes a symbolic variable, and the tool explores *all* reachable execution paths
against [KEVM](https://github.com/runtimeverification/evm-semantics), a complete formal
semantics of the EVM. The result is either a machine-checked proof that the assertions hold
for every input, or a concrete counterexample with the path condition that produced it.

Verification is at the **bytecode** level, so the compiler is inside the trust boundary
rather than outside it. This is also what makes the longer-term plan viable: a hand-written
Yul or assembly implementation can be proven equivalent to a readable Solidity reference.

## Scope

Specs target **individual instructions**, not the VM as a whole. This is deliberate:

- Instructions in the tier-1 set are `internal pure` functions over a memory struct. No
  storage, no external calls — so none of the symbolic-storage blowup that makes
  stateful contracts expensive to verify.
- `ContextLib.runLoop` dispatches through an **internal function pointer**
  (`VM.dispatch`). Symbolically executing through a function pointer forces the prover to
  branch over every possible jump destination. Verifying instructions in isolation avoids
  this entirely. Verifying the run loop itself is a separate, much harder project.

## Current status

**Do not look for proof counts here.** `analysis/PROOF-MAP.md` is the single source of truth
and is regenerated after every subsession; a table duplicated into this file went stale three
times before it was removed.

Two rules that live with those numbers and are easy to get wrong:

- A property is proven only when `kontrol list` reports PASSED for its **highest** version.
  Kontrol mints a new version whenever the spec or definition changes, so a PASSED at `:0`
  says nothing once `:1` exists. This has produced both an inflated count and a false
  regression report.
- Passing `forge test` is a far weaker claim than being proven, and a fuzz-green property can
  be outright vacuous. See the vacuity section of `analysis/AGENT-PROTOCOL.md`.

### Avoid putting a symbolic division in the path condition

The two in-progress proofs originally assumed their way onto the non-reverting path:

```solidity
vm.assume(amountIn <= type(uint256).max / balanceOut);   // numerator must not overflow
```

That is a *symbolic* `DIV`, which KEVM models with a divide-by-zero guard, and the proof
did not get past it — four nodes, no progress in five minutes on an otherwise idle machine.
`try`/`catch` around the harness call expresses the same intent with no division at all:

```solidity
try harness.exactIn(balanceIn, balanceOut, amountIn, "") returns (uint256 amountOut) {
    assertLt(amountOut, balanceOut);
} catch { /* reverted: nothing to bound */ }
```

Note this **strengthens** the theorem rather than narrowing it. The assumption form
quantified over a sub-domain carved out by four assumptions; this form quantifies over every
`uint256` triple, with reverting inputs satisfying it vacuously and covered separately by
the dedicated revert tests. Prefer it whenever a property is only interesting on the
success path.
**The status table that used to sit here has been removed — not because it was wrong, but
because it cannot be checked from here.**

It listed nine `BalancesSpec` proofs as PASSED, and per `e59732a` and `906e2d7` they were:
"prove all properties under Kontrol (no new lemmas required) … all PASSED, 0 failing/0 stuck",
with per-property times of 35m/24m/18m. Track A recorded its results carefully and
distinguished proven from fuzz-green throughout.

The problem is that **`out/proofs/` is gitignored and per-machine.** Those proofs live in the
container they were produced in. A different machine's store contains **zero** `BalancesSpec`,
`ControlsSpec`, `BaseFeeAdjusterSpec` or `MinRateSpec` directories, so a reader cannot verify
the table without re-running — and a table that cannot be checked drifts silently, which is
what line 31 above warns about.

**Do not add another.** Ship the store instead (`scripts/kontrol-proofs.sh save`, and see
`VERIFY.md` on the pre-built bundle), and read status from these, which cannot drift:

* `analysis/INSTRUCTION-STATUS.md` — per-instruction coverage, regenerated from the store
* `analysis/PROOF-MAP.md` — proof-store operations and per-spec counts
* the store itself, which is the only thing that cannot drift:

```bash
docker exec -u user kontrol python3 - <SpecName> < scripts/proof-status.py
```

The harness shape is confirmed to work end to end: an `internal pure` instruction, reached
through an external harness that assembles `Context` in memory, is provable. `cannotDrainPool`
is the first property that exercises `mulDiv` reasoning, and it is one of the four XYCSwap
properties still open at full `uint256` width — see `[prove.xycswap-open]` in `kontrol.toml`.

The `BalancesSpec` set closes without new lemmas (Track A3): `_staticBalancesXD` does no
arithmetic, only a `tokenIn < tokenOut` branch and two calldata word reads. All ten
properties were machine-checked on the machine that ran them — though **not in this
container's store**, which holds no `BalancesSpec` proofs at all; see the note above on
`out/proofs/` being per-machine. The claims below describe that run. The proofs are slower than their
lack of arithmetic suggests — but inspection of the KCFG shows the cost is symbolic-
execution step count (~2.7k steps just for the harness/test machinery) plus KEVM server
overhead, NOT a hard SMT goal: concrete-input proofs take ~12 min and the symbolic one
only ~5 min more. So a `lemmas.k` simplification rule would not help here — the lever for
Balances-style proofs is reducing executable steps (leaner harness) or the per-proof
server cost, not discharging arithmetic. The lemmas library is the right tool for the
Track B pricing instructions, where Z3 gets stuck on `X*Y <=Int C` with both operands
symbolic; Balances has no such goal.

The spec also documents a finding rather than a desired invariant: `parse` performs no
length check on `args` (`Calldata.slice(32)` is unchecked assembly), so a short `args`
does NOT revert — `balanceOut` silently reads the adjacent calldata. This is stated
exhaustively, not just on examples: `test_finding_shortArgsNeverRevert(bytes calldata
args)` assumes `args.length < 64` and proves the instruction never reverts for any such
input (the read register values are nondeterministic adjacent-calldata garbage, so only
the absence of a revert is asserted). The fix is a bounds check in `parse` (or the
`slice(..., bytes4)` overload); if added, this test should flip to expect that revert.
Whether short args are reachable depends on the dispatcher, which is out of scope for this
instruction-level spec.

Tightness note: the guard test pins the exact revert, not just that a revert occurs — it
expects `SetBalancesExpectZeroBalances(incomingBalanceIn, incomingBalanceOut)` (the
*incoming* register values, not the parsed `args` values). A bare `revert()`, an out-of-
gas, or a different selector would all pass a loose `vm.expectRevert()` but fail here.

Treat "passes `forge test`" and "proven" as different claims, and do not describe an
instruction as verified until the proof store says so — `scripts/proof-status.py`, not a
table in a document.

**A trap in reading the store, which cost a wrong count in this project.** A leaf listed in
`proof.json`'s `terminal` set is NOT necessarily discharged. If it is the *target*, the branch
closed; if it is terminal and NOT the target, execution finished in a state that fails the
claim — a **refutation**. Classifying every terminal leaf as closed reports refutations as
passes. `scripts/proof-status.py` gets this right and exits non-zero on any FAILED.

## Layout

```
lemmas.k                      shared K lemma library (repo root, wired via kontrol.toml)
kontrol.toml                  proof configuration
test/kontrol/
  README.md                   this file
  harnesses/*.sol             external surfaces over internal instructions
  *Spec.t.sol                 one spec file per instruction
```

`Context` embeds an internal function pointer, so it is not ABI-encodable and cannot be
passed across an external call. Each harness therefore takes the individual registers as
scalars and assembles the `Context` in memory. Harnesses leave `ctx.vm` zero-initialised;
this is safe only for instructions that never call `ctx.runLoop()`.

## Prerequisites

The repository ships a Nix flake providing Foundry and Kontrol. This is the supported path:

```bash
nix develop        # drops you into a shell with `forge` and `kontrol` on PATH
kontrol version
```

Note that `flake.nix` currently tracks Kontrol's default branch rather than a pinned
revision. A Kontrol upgrade changes the compiled definition and invalidates every cached
proof, so pin `kontrol.url` to a tag once a version is settled on.

<details>
<summary>Fallbacks, if the flake is unavailable</summary>

Native install (needs root, since `kup` is Nix-based):

```bash
bash <(curl https://kframework.org/install) && kup install kontrol
```

Docker, where root is not available:

```bash
docker pull runtimeverificationinc/kontrol:ubuntu-jammy-1.0.255
docker run -d --name kontrol -v "$PWD:/work" -w /work \
  runtimeverificationinc/kontrol:ubuntu-jammy-1.0.255 sleep infinity
```

The image's `kontrol` entrypoint resolves only under its internal `user` account (uid 1010)
— running as another uid fails with `ModuleNotFoundError: No module named 'kontrol'`.
Either run as that user, or copy the working tree to a path it owns.

</details>

## Build

> **A spec edit needs only `forge build`, not `kontrol build`.** This was documented the
> other way round here for most of the project and it was wrong — verified empirically:
> widening a property from `uint120` to `uint256` and running only `forge build` changed the
> signature Kontrol selected, with no `kontrol build` at all.
>
> In Kontrol 1.0.255 contract bytecode is **not** baked into the K definition. `prove.py:771`
> reads `contract.deployed_bytecode` from the Foundry artifacts at prove time, and
> `grep -c YourSpec out/kompiled/compiled.txt` returns 0. So after editing a spec or harness:
>
> ```bash
> FOUNDRY_PROFILE=kontrol forge build --build-info --extra-output storageLayout \
>   evm.bytecode.generatedSources evm.deployedBytecode.generatedSources
> ```
>
> That is seconds rather than minutes, and it does **not** disturb other agents — which means
> spec edits no longer need to be batched or coordinated through the build. `--reinit` is
> also unnecessary: the method digest goes stale on its own and Kontrol allocates a fresh
> version ("Creating a new version of test X because it is out of date").
>
> `kontrol build` is still required when **`lemmas.k`** changes, since those rules genuinely
> are compiled into the definition. That build remains coordinator-only and still supersedes
> in-flight proofs.

Run this once after cloning, and again after every change to a spec, a harness, a contract,
`lemmas.k`, or the compiler settings. All commands assume the repository root as the working
directory.

```bash
# 1. Toolchain — Foundry and Kontrol, from the repo flake
nix develop

# 2. Solidity dependencies
yarn install

# 3. Compile the K definition from the forge artifacts plus lemmas.k.
#    Slow: several minutes, most of it solc under via_ir.
FOUNDRY_PROFILE=kontrol kontrol build

# 4. Confirm the lemmas actually compiled in. Expect a non-zero count.
#    If this prints 0, see "Traps" below before trusting any proof result.
grep -c 'mul-bound-transfer' out/kompiled/definition.kore
```

After editing `lemmas.k`, step 3 needs `--rekompile`, and step 4 becomes mandatory rather
than merely advisable.

Kontrol tracks a per-method digest, so once you *have* rebuilt, `kontrol prove` notices a
changed spec and starts a **new proof version** (`:1`, `:2`, …) instead of reusing the stale
one — see `kontrol list`. That versioning protects you only from reusing old *results*; it
cannot conjure bytecode that was never compiled, which is why the rebuild is not optional.

## Running proofs

`--match-test` (short form `--mt`) takes a **regular expression** matched against the full
test signature, so `ContractName\.` selects every property in one spec contract. The flag
may be repeated to select several.

Each of these assumes `FOUNDRY_PROFILE=kontrol kontrol build` has been run since the spec
was last touched. If a command reports that the test does not exist, that is the missing
step, not a bad regex.

```bash
# Every property in one spec contract — the usual unit of work
kontrol prove --mt 'XYCSwapSpec\.'

# One specific property
kontrol prove --mt 'XYCSwapSpec\.test_exactIn_cannotDrainPool'

# Several, in one run (they are proven in parallel)
kontrol prove --mt 'XYCSwapSpec\.test_exactIn_zeroInputYieldsZeroOutput' \
              --mt 'XYCSwapSpec\.test_exactIn_revertsOnZeroBalanceIn'

# Everything under test/kontrol — expect this to take a long time
kontrol prove --mt '.*Spec\.'
```

Useful flags:

| Flag | When |
|---|---|
| `--workers N` | Parallelism. Roughly one per core, but each worker is memory-hungry; 4–8 is sensible. |
| `--no-fail-fast` | Report every result instead of stopping at the first failure. Usually what you want. |
| `--reinit` | Discard cached progress and start over. Needed after contract changes, otherwise you prove stale code. |
| `--bmc-depth N` | Bound an otherwise unbounded loop. Yields a result valid only up to N unrollings. |
| `--use-gas` | Include gas in the proof. See "Reasoning about gas". |

## Inspecting results

```bash
kontrol list                       # every proof: status, node count, pending nodes
kontrol show <test>                # the proof and its KCFG
kontrol view-kcfg <test>           # interactive KCFG browser
kontrol show --failure-information --failing <test>   # counterexample and path condition
```

`kontrol list` is also the live progress signal — a rising node count means the proof is
advancing, a frozen one means it is stuck. `PENDING` means unfinished, not failed.

When a proof fails, `--failure-information --failing` is the command that matters: it
prints the failing node, the path condition that reaches it, and a concrete model. The path
condition is more useful than the model, since it describes the whole failing class rather
than one example.

## The fast loop

Every spec is also an ordinary Foundry test. Use this while writing properties — it takes
seconds instead of minutes:

```bash
forge test --match-path 'test/kontrol/*'                      # all specs
forge test --match-path 'test/kontrol/XYCSwapSpec.t.sol'      # one spec
forge test --match-path 'test/kontrol/*' --match-test 'roundsInFavour'
```

A property that fails the fuzzer will certainly fail under Kontrol, so fix it there first.
The converse does not hold: passing the fuzzer only means no counterexample was sampled.

## Starting a new instruction — the full loop

Concretely, for an instruction `Foo` (see `WORKPLAN.md` for who takes what):

```bash
# 1. Write test/kontrol/harnesses/FooHarness.sol and test/kontrol/FooSpec.t.sol

# 2. Iterate against the fuzzer until green — seconds per run
forge test --match-path 'test/kontrol/FooSpec.t.sol'

# 3. Recompile so Kontrol sees the new contracts
FOUNDRY_PROFILE=kontrol kontrol build

# 4. Prove, starting with the cheapest property to validate the harness shape
kontrol prove --mt 'FooSpec\.test_someSimpleProperty' --workers 4

# 5. Then the rest
kontrol prove --mt 'FooSpec\.' --workers 4 --no-fail-fast

# 6. On failure
kontrol show --failure-information --failing 'FooSpec\.test_thatFailed'
```

Prove the cheapest property first. If the harness shape is wrong, you find out in a minute
rather than after an hour on the hardest property in the file.

## Traps

**A new or edited spec is invisible until you rebuild.** `kontrol prove` will tell you the
test does not exist — which reads like a typo in the `--match-test` regex, but means the
contract was never compiled into the definition. Rebuild. See "Build" above.

**A stale lemma file survives `--rekompile` silently.** Kontrol copies `lemmas.k` into
`out/kompiled/requires/lemmas.k` at build time and does not always refresh that copy.
`kontrol build --rekompile` will report `✅ Success` while having compiled the *previous*
version of your lemmas — so a proof that still fails looks like "the lemmas didn't help"
when in fact they were never loaded. Always verify:

```bash
grep -c 'mul-bound-transfer' out/kompiled/definition.kore   # expect > 0
```

If the count is zero, refresh the copy by hand and rebuild:

```bash
cp lemmas.k out/kompiled/requires/lemmas.k && FOUNDRY_PROFILE=kontrol kontrol build --rekompile
```

This is why every rule in `lemmas.k` carries a unique label.

**`out` must be set in the Foundry profile, or the tooling half-breaks.** Foundry defaults
`out` to `out/`, but Kontrol reads the profile itself and defaults a missing key to the
empty string — the repository root:

```python
def out(self) -> Path:
    return self._root / self.profile.get('out', '')
```

With `out` unset, Kontrol scatters `kompiled/`, `digest` and `proofs/` across the repo root
while forge still writes build-info to `out/build-info`. `kontrol prove` works, but
`kontrol show` and `kontrol view-kcfg` fail outright with `ValueError: max() arg is an empty
sequence`, because they look for build-info at the root — which removes exactly the tooling
needed to diagnose a stuck proof. `[profile.kontrol]` sets `out = "out"` for this reason.
If you see that `ValueError`, check the profile before anything else.

**`--reinit` throws away everything.** After changing lemmas the cached proof is stale, but
`--reinit` re-explores from scratch including `setUp`. Prefer pruning just the stuck
subtree and resuming:

```bash
kontrol remove-node <test> <nodeId>
kontrol prove --match-test <test>       # no --reinit; the cached prefix is reused
```

**`vm.assume` means something different here.** Under the fuzzer it rejects samples; under
Kontrol it adds a path constraint. A spec whose assumptions are near-unsatisfiable will
fail the fuzzer with `rejected too many inputs` while proving fine under Kontrol. Treat the
assumptions as part of the specification — they define the domain the property holds over.

**Gas is off by default.** See below.

## Configuration notes

`kontrol.toml` deviates from Kontrol's defaults in one way worth understanding.
`max-depth` is 2000 with `break-on-basic-blocks` and `break-on-calls` enabled, rather than
the usual 25000 with breaks disabled. Kontrol persists proof state *between* nodes, so the
distance between nodes is how much work a crash discards. With long edges, a backend crash
mid-edge loses everything since the last checkpoint and the node count stays frozen — the
proof looks hung when it is actually progressing. Frequent checkpoints cost some overhead
and buy durable, observable progress plus the ability to localise a stall to one basic
block. Raise `max-depth` for proofs known to close quickly.

`foundry.toml` gains a separate `[profile.kontrol]` rather than pinning `evm_version` in
`default`, because pinning it in `default` would change the emitted bytecode and invalidate
`.gas-snapshot`, which CI gates on. Keep `evm_version` there in sync with `schedule` in
`kontrol.toml`.

## Adding a spec for another instruction

One harness and one spec file per instruction, so concurrent work does not collide. The
only shared file is `lemmas.k`; append new rules to the relevant section rather than
editing existing ones.

1. `test/kontrol/harnesses/<Instruction>Harness.sol` — external surface, registers as scalars.
2. `test/kontrol/<Instruction>Spec.t.sol` — properties, with the reference semantics quoted
   in the doc comment.
3. `forge test --match-path test/kontrol/<Instruction>Spec.t.sol` until green.
4. `FOUNDRY_PROFILE=kontrol kontrol build && kontrol prove --match-test '<Instruction>Spec.*'`.

Derive the semantics from the **source**, not from `README.md` or the whitepaper — the
opcode numbers in both are stale relative to `src/libs/OpcodeList.sol`.

### Suggested order

Instructions classified by what the prover has to deal with:

**Tier 1** — pure, no loops, no storage, no external calls. Gas per path is constant.
`XYCSwap`, `LimitSwap`, `MinRate`, `Controls`, `FeeExperimental`.

**Tier 2** — loops or transcendental math. Correctness needs substantially more lemma work,
and gas becomes genuinely symbolic. `Whitelist` (4 loops), `PiecewiseLinearScale`,
`DutchAuction`, `TWAPSwap`, `PeggedSwap` and `XYCConcentrate` (square roots).

> `BaseFeeAdjuster` was listed here in error and is a Tier-1 target — it has no loop and no
> `pow`. See `analysis/FINDINGS.md` for the other corrections to this classification.
Anything reaching `Power.pow` hits a `while` loop with a symbolic trip count and needs
`--bmc-depth`, which yields only a bounded result.

**Tier 3** — storage or external calls; no longer pure-instruction verification.
`Balances`, `Invalidators`, `Decay`, `TWAPSwap`, `SeriesEpochManager`, `Fee` (external fee
provider), and `Extruction`, which makes arbitrary external calls and cannot be verified
without strong assumptions about the callee.

### High-value targets

`TESTING.md` documents roughly 40 tests that disable core invariants with unresolved TODOs,
and the suite contains 98 `skip*` flags in total (38 additivity, 23 symmetry, 22
monotonicity, 15 spot-price). Several scenarios also set tolerances loose enough to be
near-vacuous. Those are the places where a proof or a counterexample is worth more than
confirming that arithmetic which already works still works.

## Reasoning about gas

Gas is modelled by KEVM (`--use-gas` enables it; `--schedule` picks the hardfork) but is
disabled by default because gas terms inflate the state space.

For **tier-1 instructions** gas along a given path is a *constant*, not a symbolic
expression — there are no loops and no warm/cold storage variance — so `--use-gas` stays
tractable and can prove `new_gas <= old_gas` per path directly.

For everything else, keep gas out of the proof and recover cost information from the KCFG:

1. Prove functional equivalence with gas disabled. The KCFG leaves enumerate **all**
   execution paths — a proven-exhaustive enumeration, not a sample.
2. `kontrol get-model` on each leaf yields a concrete witness input reaching that path.
3. Measure gas concretely on each witness (`vm.startSnapshotGas`, `forge snapshot`).

Because the paths are exhaustive, per-path concrete measurement gives complete path
coverage of gas without paying for symbolic gas.

Kontrol is far too slow to sit inside a superoptimiser's search loop. Use a fast concrete
cost model to drive the search and Kontrol to validate the winner — translation validation,
not verified synthesis.

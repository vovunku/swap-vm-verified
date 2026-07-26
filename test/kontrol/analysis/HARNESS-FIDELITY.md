# What a green proof actually asserts

Every property here is proven against a **harness**, not against the deployed VM. This
document answers the only question that matters about that: how far is the thing we proved
from the thing that runs on chain, and where exactly does the gap live.

The answer is not uniform. Two harnesses contain a hand-written copy of the instruction, and
a proof about a copy is a proof about a copy. The rest call the real code. Which is which is
recorded below, along with the honest status of the properties that are supposed to close
the gap.

## The standing policy

**Harnesses stay plain. Reason on whole functions.**

A harness assembles a `Context` from scalars, calls the real internal function, and reads the
registers back. That is all it should do. It does not extract internal parts, it does not
transcribe logic, and it does not restructure the code under test to make a proof easier.

The reason is not aesthetic. Every deviation from a plain import is a claim about deployed
code that rests on a human comparison instead of on the prover, and those claims accumulate
silently — six properties in this repo currently sit behind one, and nothing machine-checked
connects them to the real instruction. A plain harness cannot drift, because there is nothing
to drift from.

**Splitting is the fallback, not the plan.** If a whole function will not yield, the first
moves are to improve the prover (a lemma) or to sharpen the spec (fix a parameter that
production fixes anyway — see `AGENT-PROTOCOL.md`). Only when both have failed is a manual
split justified, and then it must be recorded in this file at the weaker evidence tier with
a differential property named to close it.

Two such splits exist today, both from before this policy: the `XYCConcentrate` leg surface
and the `PeggedSwap` seam. Both are scaffolding to be removed, not patterns to copy. The
route to removing them is the lemma work, not more transcription.

**And never restructure the deployed source to suit the prover.** These contracts are live at
`0x8fdd04dbf6111437b44bbca99c28882434e0958f` on twelve chains; a source edit changes the
metadata hash and therefore the deployed bytecode, even when every instruction is identical.
A verification difficulty is a reason to improve the prover or the spec.

## Why harnesses exist at all

Not for convenience. Two hard constraints in the source make direct proof impossible:

1. **The instructions are `internal`.** An `internal` function on a library or base contract
   has no address and no selector, so there is nothing for a Foundry test to call. Something
   must expose it.
2. **`Context` is not ABI-encodable.** It embeds an internal function pointer (`VM.dispatch`),
   so it cannot cross an external call boundary. A harness therefore has to accept the
   registers as plain scalars and assemble the `Context` in memory on the other side.

Both are properties of the code under test, not choices. The minimum possible harness is a
thin external wrapper that assembles a `Context` and calls the real internal function — and
most of ours are exactly that.

## Tier 1 — the harness calls the real code

For these, the compiled body of the production function is inside the bytecode being
symbolically executed. There is no transcription and no second copy to keep in sync.

| Harness | Calls | Distance |
|---|---|---|
| `XYCSwapHarness` | `_xycSwapXD` | Context assembly only |
| `PeggedSwapHarness.run/exactIn/exactOut` | `_peggedSwapGrowPriceRange2D` | Context assembly only |
| `PowerHarness.pow` | `Power.pow` | Library call only |
| `PiecewiseLinearScaleHarness` | real instruction | Context assembly |
| `LimitSwapHarness`, `BaseFeeAdjusterHarness` | real instruction | Context assembly |
| `MinRateHarness` | real instruction | Context assembly **+ stub dispatch** |

`MinRate` is the one exception in this tier: it genuinely calls `ctx.runLoop()`, so the
harness must supply a dispatch stub. What is proven about `MinRate` is therefore conditional
on that stub standing in faithfully for the real loop.

**The `ctx.vm` caveat applies to the whole tier.** These harnesses leave the dispatch pointer
zero-initialised, which is sound only because the instruction under test never invokes it.
That is checked per harness and documented in each one. It is not a general licence: an
instruction that dispatches invalidates the harness shape, and the check has to be redone
whenever an instruction body changes.

## Tier 2 — the harness contains a copy

Here the proof is about a transcription. The copy has been checked by reading, and in one
case by gas measurement, but **reading is not proof**.

### `XYCConcentrate` — `exactInLeg` / `exactOutLeg`

A line-for-line transcription of `XYCConcentrate.sol:143-159`, with the two virtual reserves
promoted from locals to parameters and an added `clamped` observation flag. It was diffed
against the real source during this audit and **is faithful**: identical control flow,
identical rounding directions (`/` floors on the exact-in leg, `Math.ceilDiv` on both
partial-fill reconstructions), identical guard placement.

The reason for the copy is real: the liquidity half of the instruction runs `Math.mulDiv`
five times, every `mulDiv` calls `mulmod` inside `Math.mul512`, and KEVM cannot currently
collapse it. Anything routed through the liquidity half is unprovable today. The pricing
half needs none of that.

**The trust boundary is currently OPEN.** `XYCConcentrateSpec` declares two properties to
close it — `test_diff_exactIn_fullMatchesLegs` and `test_diff_exactOut_fullMatchesLegs`,
asserting that `full(...)` and `exactInLeg(virtualReserves(...))` agree register for
register. Their status as of this audit:

- `test_diff_exactIn_fullMatchesLegs` — attempted once, **persisted zero files**. Not proven.
- `test_diff_exactOut_fullMatchesLegs` — **never attempted**. No proof directory exists.

So all six currently-PASSED `XYCConcentrate` properties are statements about the copy, and
nothing machine-checked connects them to the deployed instruction. Note also that the
differential is declared over narrowed types (`uint64,uint64,uint64,uint56,uint64`), so even
once proven it will close the boundary only on that sub-domain.

This does not make those six properties worthless — a faithful copy that has been read
carefully is decent evidence, and they did catch real behaviour. It makes them a *weaker
claim* than the tier-1 proofs, and they should never be reported as equivalent.

### `PeggedSwap` — the `seam*` surface

A copy of `PeggedSwap.sol:98-224` together with `PeggedSwapMath.sol:63-104`, with exactly one
edit: each of the four `Math.sqrt(z)` call sites becomes `_isqrt(z, w)`, which does not
compute a square root but *checks* a supplied witness.

This is a deliberate and well-motivated abstraction — `Math.sqrt` is inlined straight-line
code with seven data-dependent branches and no symbol for a lemma to attach to, so `_isqrt`
creates the seam a lemma can target. The residual assumption is narrow and explicit: that
OZ's `Math.sqrt` computes a correct integer square root.

**CORRECTION (re-measured from the proof store).** The claim previously made here — that
this surface "has never once been exercised" and that every `test_seam_*` run had stalled —
was **false**. Eight seam proof directories existed; two had PASSED:
`test_seam_bothBalancesZeroGuardFiresWhenBothZero` at 128 nodes, and
`test_seam_realisticPoolMatchesInstruction` at 4 nodes — the latter a *genuine differential*
comparing `seamExactOut` against the real instruction register-for-register, with an
explicit anti-vacuity guard. One goal had expanded to 166 nodes.

**The seam has since been DELETED.** `PeggedSwapHarness` is now a plain wrapper (120 lines,
no arithmetic, no `require`) and `PeggedSwapSpec` carries 31 properties, all stated against
the complete `_peggedSwapGrowPriceRange2D`. The two passing seam proofs were statements
about a transcription and were given up deliberately; the 33-property plain surface that
found the `:215` underflow is untouched. Tier 2 now contains only `XYCConcentrate`.

The tier-1 `PeggedSwap` entrypoints (`run`, `exactIn`, `exactOut`) are unaffected and call
the real instruction; the confirmed underflow bug was found through those, not through the
seam.

## Residual gaps that apply even to Tier 1

Naming these matters more than the tier table, because they are easy to forget:

- **Inlining context differs.** The instruction is `internal`, so it is inlined into the
  *harness* rather than into the VM dispatch loop. Compiler settings are identical to
  production — solc 0.8.30, optimizer on, 700 runs, `via_ir = true`, verified against
  `[profile.default]` — and the only deliberate difference is `evm_version = "cancun"`,
  pinned because a proof that does not name its hardfork does not identify what it verified.
  But `via_ir` inlining decisions depend on the surrounding function, so the emitted
  bytecode is not byte-identical to the production deployment. We prove the same source
  compiled by the same compiler in a different context.
- **The constructor never runs.** `run-constructor = false`, so any `immutable` or
  initialised state variable reads as zero. `setUp()` does run. This is a vacuity trap, not
  just a fidelity gap — see `AGENT-PROTOCOL.md`.
- **Reachability is not modelled.** Every proof states something about an instruction called
  with arbitrary registers. Whether the VM can actually *reach* those registers through a
  real program is a separate question that nothing here answers. A bug proven reachable at
  the instruction level may or may not be reachable end to end.

## What would close the gaps, in order of value

1. **Prove the two `XYCConcentrate` differentials.** This is the single highest-value
   unproven property in the repo: it converts six copy-proofs into real-code proofs. The
   blocker is `mul512`, which is a lemma problem, not a spec problem.
2. **Exercise the `PeggedSwap` seam once**, by restating over a fixed-layout `_args(...)`
   with symbolic fields instead of a symbolic-length `bytes`. Until it runs at all, the
   abstraction is unvalidated.
3. **Differential-test `MinRate`'s dispatch stub** against the real loop.

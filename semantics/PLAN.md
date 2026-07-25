# SwapVM formal semantics — plan

**Status: PLAN ONLY. No implementation has started.**

This directory is deliberately separate from the verification work in `test/kontrol/`.
Nothing here depends on that work and nothing there depends on this. They meet at exactly
one seam, described in Phase R.

## The problem this addresses

SwapVM executes *programs*: byte strings of `[opcode:1][argsLen:1][args]`, composed with the
SDK's `ProgramBuilder.build`, signed off-chain, never deployed. The unit of risk is therefore
the program, not a contract — and 1inch's own `docs/PROGRAMS.md` says so plainly:

> "Instruction ordering is security-critical. Reordering instructions can change pricing,
> settlement amounts, invalidation behavior, and external side effects."
>
> "Invariant requirements must hold for the full composed program: Symmetry, additivity
> profile, monotonicity, quote/swap consistency, balance sufficiency, and strategy liveness."
>
> "Thorough testing and audit are mandatory for every program before production use."

Per-program manual audit does not scale with a product whose premise is that anyone can
compose programs. And the six named invariants are properties of *composition*, which
instruction-level verification cannot express even in principle.

**We have already hit a case that proves the point.** The confirmed `MinRate` bug —
`AdjustMinRate` reads a register from before `runLoop`, so settlement can end below the floor
— is correct in isolation and wrong when sequenced after anything that modifies `amountIn`.

## Why K

The semantics is executable, so it can be differentially tested against the real VM using the
~94 invariant tests already in `test/invariants/`. Semantics drift becomes a failing test
rather than a silent lie. Refinement to bytecode is statable in the same framework, since
KEVM is a K semantics of EVM. Rocq would prove more comfortably but would leave the link to
the deployed bytecode informal, and this project's demonstrated failure mode is exactly that
kind of unchecked gap.

Cost, stated honestly: K simplification rules are **trusted axioms unless separately proven**,
and SMT still discharges side conditions. What changes is that SMT stops being the proof
method and becomes a subroutine, with reachability claims and circularity doing the work.

## Phases

### Phase 0 — skeleton and conformance harness

The harness comes FIRST. Without it we cannot tell a correct semantics from a plausible one,
and every later phase is worthless.

- `semantics/swapvm.md` — configuration cell (`program`, `pc`, swap registers, query) and the
  fetch/decode/dispatch loop mirroring `VM.sol:118-150`. No instruction rules yet.
- `semantics/conformance/` — run a program through both engines and diff the registers.
- **Acceptance:** a program of two trivial instructions produces identical registers under
  `krun` and under Foundry.

### Phase 1 — three instructions, one theorem (GO / NO-GO)

Target: the permissioned-swap program from `docs/PROGRAMS.md` §4 Example A.

    OnlyTakerTokenBalanceNonZero(gateToken) ; StaticBalances([bIn, bOut]) ; LimitSwap(tIn, tOut)

- One rule per instruction, over registers.
- **Theorem:** for ANY program whose first instruction is `OnlyTakerTokenBalanceNonZero(g)`,
  a taker holding zero `g` cannot reach a settled state — regardless of the rest of the
  program. Stated over a symbolic program tail, which is what makes it worth more than the
  scenario tests.
- **Acceptance:** theorem proved, AND conformance passes on the concrete instance.
- **This is the go/no-go.** Small enough to abandon cheaply. If the theorem will not close, or
  conformance disagrees, stop and reconsider before spending more.

### Phase 2 — a program family

Limit orders with invalidators (`docs/PROGRAMS.md` §1 Examples A and B).
- **Theorems:** no replay, no overfill, deterministic partial-fill accounting.
- These are already named in the doc's "Invariant Focus" list, so the obligations are given.

### Phase 3 — conditional flow

Best-route selection (§4 Example B; `test/RunLoop.t.sol:test_BestRouteSelector_XYC_vs_Pegged`).
- **Theorems:** termination, and that the selected branch is the better-output branch.
- Their doc flags branching as "hard to reason about and easy to misconfigure" — this is where
  scenario tests are weakest and proof is worth most.

### Phase R — refinement (parallel, lower priority)

Each K rule must denote its Solidity implementation. This is the `test/kontrol/` work,
repositioned: not "XYCSwap rounds in the maker's favour" but "this rule equals this bytecode."

**This is the one seam between the two halves of the repo, and it will rot if unmaintained.**
Mitigation: a table here mapping each K rule to the Kontrol proof discharging it, and the K
rule quoted in the corresponding spec's docstring.

## Non-goals

- Not replacing `test/kontrol/`.
- Not modifying anything under `src/`. The contracts are deployed on twelve chains.
- Not proving programs nobody runs. Targets are the eight reference programs from the
  catalogue, which makers copy.

## Known risks

1. **Semantics drift** — mitigated by Phase 0, which is why it is first.
2. **Trusted axioms** — same disease as `lemmas.k`, where 68 rules accumulated with one
   carrying real evidence and four dead for their entire life. Rule: no rule enters the
   semantics without a conformance test exercising it.
3. **No third-party program corpus.** SwapVM is new and programs are signed off-chain, so
   there is nothing deployed to audit. We verify reference programs *before* an ecosystem
   grows on them. This is a real weakness if the goal were auditing existing strategies.
4. **Version coupling.** The semantics is valid for one VM version. Living in-tree means it
   moves with the implementation automatically, which is the reason it is here and not in a
   neighbouring repo with a pinned submodule.

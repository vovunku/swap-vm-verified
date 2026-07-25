# Phase 2 — prove the pricing arithmetic

Design and tech doc, written before implementation.

Phase 1 proved an access-control property that needed no arithmetic. This phase proves
something about the **money**: that `LimitSwap` prices exactly, and that its rounding favours
the maker.

## Why this is the right next target

`LimitSwap.sol:49` carries the comment *"Floor division for tokenOut is desired behavior"*,
and `:52` *"Ceiling division for tokenIn is desired behavior"*. Those are **economic
decisions** — they decide who absorbs the sub-wei remainder on every fill — and nothing
currently checks them beyond a handful of concrete conformance cases. Mutation testing found
exactly this: changing exact-in from floor to ceiling survived the entire original test suite,
because the catalogue program's numbers divide evenly.

It is also the smallest interesting arithmetic in the repo: one multiply and one divide per
leg, no loops, no square roots, no `mulDiv`. If symbolic arithmetic is tractable at the K level
at all, it is tractable here — which makes this a clean test of `PLAN.md` D1 ("exact arithmetic
first").

## The theorems

All three quantify over `amountIn`/`amountOut` and both balances **symbolically**, with only
the guards the instruction itself enforces.

### T1 — exact-in is exactly the floor

> `amountOut * balanceIn <= amountIn * balanceOut`  (maker safety: never more than the rate)
> `(amountOut + 1) * balanceIn > amountIn * balanceOut`  (taker safety: not a wei less)

Together these pin `amountOut` to exactly `floor(amountIn * balanceOut / balanceIn)`. Either
alone is satisfiable by a degenerate implementation — the first by returning 0, the second by
returning something huge — so both are required. This is the two-sided-exactness discipline
that `AGENT-PROTOCOL.md` records as the fix for upper-bound-only properties.

### T2 — exact-out is exactly the ceiling

> `amountIn * balanceOut >= amountOut * balanceIn`  (maker safety)
> `(amountIn - 1) * balanceOut < amountOut * balanceIn`  (taker safety, when `amountIn > 0`)

### T3 — rounding favours the maker (the economic claim)

The reason T1 and T2 round in *opposite* directions is that both must favour the maker. Stated
directly: quoting exact-in at `A`, then exact-out at the resulting `amountOut`, never returns
less than `A`.

> `limitQuoteIn(limitQuoteOut(A, bIn, bOut), bIn, bOut) >= A`

This is a **composition** property — two pricing operations related to each other — and it is
the one a maker would actually care about. It is the stretch goal; T1/T2 are the commitment.

## Technique

Floor division is the whole difficulty. K's `/Int` is floor on non-negatives, and the
defining property is

```
B > 0  ⟹  (A /Int B) *Int B <=Int A  <  ((A /Int B) +Int 1) *Int B
```

If the backend does not supply this, T1 is not provable and the fix is a lemma stating it —
which belongs in `semantics/lemmas.k` alongside the bytes lemmas, recorded in `axioms.md` as
generic-integer rather than domain-specific. **Check whether it is needed before writing it**;
adding an unnecessary lemma is how `lemmas.k` reached 68 rules with one having evidence.

Per `PLAN.md` D2 the arithmetic already goes through `limitQuoteOut` / `limitQuoteIn`, so the
claims are stated about those symbols and are unaffected if the definitions later change.

## Scope guards

- **No new instructions.** Three is enough; adding more is Phase 3 work and would dilute the
  question this phase answers.
- **Overflow stays unmodelled**, and therefore the theorems are stated over unbounded `Int`.
  This is a **real gap** and must be declared: Solidity reverts `Panic(0x11)` where K computes.
  The honest reading of T1 is "given the products do not overflow". `PLAN.md` D3's abstraction
  trigger does not apply — this is a fidelity gap, not a tractability one.
- **`PLAN.md` D3 applies to tractability.** If T1 does not close within 30 minutes on an idle
  box with the frontier containing `limitQuoteOut`'s arithmetic, weaken `limitQuoteOut` to
  axioms and record the measurement.

## Acceptance

1. T1 proves, symbolic in all three inputs.
2. T2 proves.
3. **Negative control**: the same claim with the inequality reversed (or floor replaced by
   ceiling) must FAIL. Plus a **sensitivity witness** that must prove. Phase 1 established that
   a control failing for an incidental reason is worthless — the prefix must be concrete and
   the control must reach the arithmetic.
4. Conformance: at least one non-dividing case per leg, asserted on both engines. The existing
   `exactInFloorsNotCeils` (balances 3/2) is the model — it distinguishes floor from ceiling,
   which the catalogue program cannot.
5. Every lemma added is recorded in `axioms.md` with its status, and none is added without
   first checking it is needed.

## Risks

- **Symbolic division stalls.** The whole project's history is stalls on symbolic `DIV`. At the
  K level there is no bytecode plumbing, which is why D1 says try exact first — but this is the
  first real test of that bet.
- **A vacuous claim.** `amountOut * balanceIn <= amountIn * balanceOut` is trivially true if
  the prover can show `amountOut = 0` under the hypotheses. Guard with a witness and by
  checking every hypothesis is load-bearing, as in Phase 1.
- **Proving the definition rather than the instruction.** The claims must run the *program*
  through `#run`, not just evaluate `limitQuoteOut` in isolation. A claim about the function
  symbol alone would prove arithmetic, not behaviour.

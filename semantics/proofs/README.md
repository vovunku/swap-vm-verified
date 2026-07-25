# Proofs

Six files. **Two of them are supposed to FAIL.** That is the design, not a defect, and it is
not discoverable from the filenames — hence this file.

| File | Expected | What it establishes |
|---|---|---|
| `gate-spec.k` | **`#Top`** | **T0** — for any program starting `0x23 0x14 G` with an arbitrary symbolic tail, a taker holding zero `G` ends `Reverted("TakerTokenBalanceIsZero")` |
| `pricing-spec.k` | **`#Top`** | **T1** — exact-in is exactly `floor(amountIn * balanceOut / balanceIn)` |
| `pricing-exactout-spec.k` | **`#Top`** | **T2** — exact-out is exactly the ceiling |
| `negative-control.k` | **FAIL** | Same program as T0, balance **non-zero**, asserting the same revert |
| `pricing-negative-control.k` | **FAIL** | T1 with the maker-safety inequality reversed |
| `control-sensitivity.k` | **`#Top`** | The control's twin: same premises, correct conclusion |

Run one:

    docker exec kontrol bash -c "cd /home/user/sem && su user -c \
      'PATH=/usr/bin:/bin kprove --definition swapvm-haskell proofs/<file>.k'"

## Why the controls exist

**A proof that cannot fail proves nothing**, and this project has produced exactly that twice —
properties that passed because a constructor-set value read as zero, and upper bounds satisfied
by a function returning zero.

The worst failure is an **inconsistent rule set**: it proves everything and looks like total
success. Nothing else catches it. A negative control is a statement known to be false, asserted
to fail; if it ever proves, every result above it is void.

**A failing control is not automatically evidence.** The first one written here failed at
`<pc> 0`, before a single instruction executed, on a residual branch where no decode rule
applies to a symbolic first byte. A review found the decisive fact: a claim that is *true*
failed with a byte-identical residual. It would have kept "failing correctly" with every
instruction rule deleted.

Two rules came out of that:

1. **A control must have a concrete prefix.** With a symbolic first instruction the prover
   cannot decode, and the run dies before reaching anything the control is about.
2. **Every control needs a sensitivity twin** — identical premises, correct conclusion, which
   must *prove*. That is what shows `kprove` is discriminating on the conclusion rather than
   choking on the setup. `control-sensitivity.k` plays that role for `negative-control.k`;
   `pricing-spec.k` itself plays it for `pricing-negative-control.k`.

A review noted a sharper control is available for T1: change `<=Int` to `<Int` in the
maker-safety bound — one character. It is false exactly when `balanceIn` divides
`amountIn * balanceOut`, so it discriminates the rounding decision itself rather than the
direction of an inequality. Not yet added.

## What these theorems rest on

Every instruction rule is `TESTED`, never `PROVEN` — conformance agrees on the cases run, which
is evidence on those inputs, not proof. See `../axioms.md` for the ledger and
`../DEMO.md` §4 for what was deliberately not proved.

The semantics models **3 of the 52 named opcodes**. Unmodelled opcodes are silent no-ops in K
where production reverts `UnknownOpcode`, so a theorem must either fix the whole program
concretely (T1, T2) or be stated so unmodelled opcodes cannot affect the conclusion (T0 reverts
before its tail is ever decoded).

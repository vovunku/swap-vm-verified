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

---

# Audit — full-suite run, 2026-07-26

36 `.k` files: the six above plus **15 new spec/control pairs**. Verdicts below are `kprove`
exit codes, K v7.1.337, Haskell backend, in the `kontrol` container.

## F-0 — the 15 new opcode modules are not in the compiled definition

`lemmas.k` is `requires "swapvm.md"` / `module SWAPVM-BYTES-LEMMAS imports SWAPVM` and nothing
else. No `requires "opcodes/<x>.k"` and no `imports SWAPVM-<X>` exists anywhere in the repo,
though every `opcodes/*.md` documents the wiring it needs. The compiled `definition.kore`
contains exactly four modules and zero occurrences of `DeadlineReached`,
`WhitelistInvalidTaker`, or `InstructionRevert`.

Consequently, **as committed, all 15 new specs fail and all 15 new controls fail for a reason
that has nothing to do with what they assert**: 12 of the 30 files do not parse (they name
symbols such as `#deadlineExceeded`, `#balanceLtMin`, `#txOrigin` that live in modules nothing
imports), and the other 18 stall on the `[owise]` unknown-opcode no-op — every residual carries
`ListItem(#unknown(<opcode>, …))`.

This is the trap this file already documents, reproduced at scale. The as-committed run *is*
the experiment "delete every new instruction rule and see whether the controls still fail
correctly." They do. So no control's failure is evidence of anything.

## Verdict table

`as-merged` = repo as committed. `wired` = a scratch copy of `lemmas.k` with the 15 `requires`
and 15 `imports` added; **not the repo**, and not a substitute for the fix.
`113` = parse/compile error, `1` = not proved, `0` = proved.

| Pair | expect | as-merged | wired | time (wired) |
|---|---|---|---|---|
| `gate-spec` | prove | **0** | 0 | 6.4 s |
| `pricing-spec` | prove | **0** | 0 | 7.3 s |
| `pricing-exactout-spec` | prove | **0** | 0 | 7.6 s |
| `control-sensitivity` | prove | **0** | 0 | 6.4 s |
| `negative-control` | fail | **1** | 1 | 6.5 s |
| `pricing-negative-control` | fail | **1** | 1 | 7.7 s |
| `stop-spec` / `-control` | prove / fail | 1 / 1 | 0 / 1 | 5.5 / 5.3 s |
| `revert-spec` / `-control` | prove / fail | 1 / 1 | 0 / 1 | 6.2 / 6.0 s |
| `salt-spec` / `-control` | prove / fail | 1 / 1 | 0 / 1 | 6.1 / 6.0 s |
| `jump-spec` / `-control` | prove / fail | 1 / 1 | 0 / 1 | 6.0 / 6.1 s |
| `extruction-spec` / `-control` | prove / fail | 1 / 1 | 0 / 1 | 5.9 / 6.1 s |
| `privateorder-spec` / `-control` | prove / fail | 1 / 1 | 0 / 1 | 6.1 / 82.8 s |
| `jumpifdirection-spec` / `-control` | prove / fail | 1 / 1 | 0 / 1 | 6.2 / 6.1 s |
| `jumpiftokenin-spec` / `-control` | prove / fail | 1 / 1 | 0 / 1 | 6.3 / 6.2 s |
| `jumpiftokenout-spec` / `-control` | prove / fail | 1 / 1 | 0 / 1 | 6.4 / 6.5 s |
| `deadline-spec` / `-control` | prove / fail | **113 / 113** | 0 / 1 | 6.1 / 6.2 s |
| `gte-spec` / `-control` | prove / fail | **113 / 113** | 0 / 1 | 6.2 / 6.3 s |
| `supplyshare-spec` / `-control` | prove / fail | **113 / 113** | 0 / 1 | 6.1 / 6.2 s |
| `txorigin-spec` / `-control` | prove / fail | **113 / 113** | 0 / 1 | 6.5 / 57.6 s |
| `whitelistcoequal-spec` / `-control` | prove / fail | **113 / 113** | 0 / 1 | 6.5 / 6.7 s |
| `whitelistsequential-spec` / `-control` | prove / fail | **113 / 113** | 0 / 1 | 7.0 / 7.4 s |

**No control proved, in either run.** No evidence of an inconsistent rule set. The original six
are unchanged and still correct.

## Near-neighbour assessment (wired run)

All 15 new controls fail *at the conclusion*, after their instruction has executed — their
residuals carry the true value where the control asserted a false one. Two shapes:

* **Conclusion-flip (13 pairs)** — `stop`, `revert`, `salt`, `jump`, `extruction`, `deadline`,
  `gte`, `supplyshare`, `whitelistcoequal`, `whitelistsequential`, `jumpifdirection`,
  `jumpiftokenin`, `jumpiftokenout`. Identical premises, negated conclusion. The spec is its
  own sensitivity twin. Good controls. (The six jump-family controls also tighten `<=Int` to
  `<Int` — required to exclude the one value at which the false conclusion is accidentally
  true, not a weakening.)
* **Premise-flip (2 pairs)** — `privateorder` and `txorigin` keep the spec's conclusion and
  negate the *premise*, copying `negative-control.k`'s shape. **Neither copied the twin.**
  `negative-control.k` has `control-sensitivity.k`; there is no PASS-arm claim for 0x2b or
  0x26. Per rule 2 above these two pairs are incomplete.

As committed, **none of the 15 is a near neighbour** — see F-0.

## Non-vacuity

Concrete `krun` witnesses on the wired LLVM backend reach the asserted conclusion for
**10 of 15**: `stop` (pc 2), `salt` (pc 7; second claim pc 2), `revert`
(`Reverted("InstructionRevert")`), `jump` (pc 4), `jumpifdirection` (pc 9),
`jumpiftokenin` (pc 24), `jumpiftokenout` (pc 24), `extruction`
(`Reverted("ExtructionUnmodelled")`), `privateorder` (`Reverted("WhitelistInvalidTaker")`),
plus `gate-spec` (`Reverted("TakerTokenBalanceIsZero")`).

**Five have no witness, and cannot have one**: `deadline`, `gte`, `supplyshare`,
`whitelistcoequal`, `whitelistsequential`. Their premises are `[function, no-evaluators]`
predicates — `#deadlineExceeded`, `#balanceLtMin`, `#supplyShareSufficient`,
`#coequalWhitelistContains`, `#sequentialWhitelistJumps` — that are *the same symbols the rule
branches on*, with no rule relating them to any state. `krun` aborts on the unevaluatable
symbol. Each such spec is a one-rewrite restatement of its rule's guard, not an independent
property. A sixth, `txorigin`, has a satisfiable premise (take `<balances> .Map`) but neither
`krun` nor `kprove` can discharge it: `#balanceOf` does not reduce under a symbolic holder.

Sharpest instance — `#balanceLtMin(TOK, MIN)` takes only the token and the minimum, and opcode
`0x24`'s rules bind `<taker>` and `<balances>` and then never use them (kompile says so:
"Variable 'TAKER' defined but not used", `gte.k:116,117,134,135`). A scratch claim pinning the
taker's balance to 10^30 with `minAmount = 1` and asserting
`Reverted("TakerTokenBalanceIsLessThanRequired")` **PROVES**. As modelled, `0x24` does not read
the balance. `gte-spec.k` is not a statement about balances.

Related: `salt-spec.k` with its `<trace>` cell anonymised **proves against the as-committed
definition, which has no Salt rule at all**. Its only discrimination against the unknown-opcode
no-op is the trace entry.

## Rule defect found while auditing (`jumps.k:56`, `:63`)

`==Bool` / `=/=Bool` sit in the loosest priority block in `domains.md:1128-1130`, below
`andBool`. So

    requires lengthBytes(ARGS) ==Int 3 andBool (ARGS [ 0 ] =/=Int 0) ==Bool (TIN <Int TOUT)

parses as `(lengthBytes(ARGS) ==Int 3 andBool …) ==Bool (TIN <Int TOUT)` — the length check is
swallowed. For `lengthBytes(ARGS) =/= 3` the left side is `false`, so the jump arm fires
whenever `TIN >= TOUT`, defeating the `UNMODELLED-ARGS-LENGTH` guard that arm was written to
protect. Machine-checked: a scratch claim that a 4-byte-args `0x30` must revert
`UNMODELLED-ARGS-LENGTH` **fails**, with residual `<pc> 10`, `<status> Running` under
`false ==Bool TIN <Int TOUT`; adding two pairs of parentheses makes the same claim **prove**.
`jumpifdirection-spec`/`-control` return 0/1 either way, so the pair's verdict is not evidence
about this. `0x31`/`0x32` use `==Int` (tighter than `andBool`) and are unaffected; so are the
parenthesised `==Bool` conditions in `swapvm.md`'s `0x53` rules.

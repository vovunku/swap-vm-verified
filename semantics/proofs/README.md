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

---

# Re-audit after the merge from `origin/main` (commit `30ec9c7`, 33 files)

Every one of the 33 files was run twice: **as committed**, and against a **scratch patched
definition** with the 12 opcode modules wired into `lemmas.k` and `jumps.k:56,63`
parenthesised. A third definition — **wired but *un*parenthesised** — isolates the rule defect
from the wiring defect. All three were rebuilt from this tree; the previous audit's
`/home/user/audit/sem-*` were not reused.

## Verdict table

| Definition | PROVED | not proved | fails to parse |
|---|---|---|---|
| **as committed** | **4** | 20 | **9** |
| **patched** (wired + parenthesised) | **21** | 12 (all controls) | 0 |
| **wired, still unparenthesised** | **21** | 12 (all controls) | 0 |

* **Prove as committed (4):** `gate-spec`, `pricing-spec`, `pricing-exactout-spec`,
  `control-sensitivity`. These four use only rules that live in `swapvm.md` itself (`0x23`,
  `0x90`/`0x91`), so they are the only honest results in the tree. They do **not** prove for
  the wrong reason.
* **Fail to parse as committed (9):** `conformance-concrete`, `deadline-concrete`,
  `gte-concrete`, `supplyshare-concrete`, `txorigin-concrete`, `whitelistcoequal-concrete`,
  `whitelistsequential-concrete`, `txorigin-spec`, `txorigin-control`. The seven `*-concrete`
  files name their opcode module in an `imports`; the two `txorigin` files reference
  `#txOrigin()`. Neither exists in the compiled definition.
* **Not proved as committed (20):** every remaining spec *and* every remaining control.

## Findings 1–5, re-checked independently

| # | Prior finding | Verdict |
|---|---|---|
| 1 | Opcode modules in no compiled definition | **SURVIVES** — `lemmas.k` is untouched by the merge |
| 2 | `jumps.k:56,63` precedence defect (D-1/D-2) | **SURVIVES** — reproduced with the identical residual |
| 3 | Five specs unprovably vacuous (`no-evaluators` premises) | **FIXED for four, reintroduced in a new place** |
| 4 | `0x24` does not read the balance map | **FIXED** |
| 5 | `salt-spec` proves with no Salt rule | **SURVIVES** — and now confirmed exactly |

**F-1 — the wiring gap is untouched.** `semantics/lemmas.k` does not appear in the merge diff
at all. It is still `requires "swapvm.md"` / `imports SWAPVM` with no opcode `requires` or
`imports`, while all 12 opcode files carry a header instructing the integrator to add both. The
merge added seven files that *depend* on those modules, so the wiring gap got worse, not better:
before the merge the unwired modules produced silently-wrong proofs, now they also produce nine
hard parse errors.

`run-proofs.sh` runs **6 of the 33 files** — exactly the four that prove plus the two original
controls. On the as-committed tree it kompiles cleanly, matches all six expectations, prints
`all proofs match expectations`, and exits 0. **The harness is green on a tree where 29 of 33
files are dead.**

**F-2 — the rule defect is unchanged and still invisible to the suite.** `jumps.k` is not in
the merge diff. A scratch claim that a 4-byte-args `0x30` must revert `UNMODELLED-ARGS-LENGTH`
**fails** on the wired-but-unparenthesised definition with residual `<pc> 10`, `<status>
Running` — the previous audit's result verbatim — and **proves** once the two pairs of
parentheses are added.

The important new result is the sensitivity measurement: the wired-but-defective definition and
the wired-and-fixed definition give **byte-identical suite verdicts, 21 PROVED / 12 failed**.
The methodological trap is not confined to the `jumpifdirection` pair — **no file in the suite
detects this defect.** Adding the parentheses changes no reported verdict anywhere.

Worse for the new harness: `krun` on the *defective* definition returns the *correct* answer
(`Reverted("UNMODELLED-ARGS-LENGTH")`). The defect is a rule **overlap** — both the jump arm
and the revert arm apply — and the LLVM backend silently picks one by priority while `kprove`'s
all-path search sees both. **A concrete conformance harness structurally cannot catch D-1.**

**F-4 — `0x24` is genuinely fixed.** `gte.k` now binds `<balances> B` and `<taker> TAKER` and
branches on the real comparison `#balanceOf(B, TOK, TAKER) <Int MIN` / `>=Int MIN`. The
previous audit's falsifying claim — balance 10^30, `minAmount = 1`, asserting
`Reverted("TakerTokenBalanceIsLessThanRequired")` — now **fails**, with residual `<pc> 54`,
`<status> Running`, i.e. the PASS arm correctly fires. `krun` witnesses both arms
(balance 5 vs min 10 → revert; balance 10 vs min 10 → pass). This is a real repair.

**F-3 — the tautology was moved, not eliminated.** `#balanceLtMin`, `#deadlineExceeded`,
`#supplyShareSufficient`, `#coequalWhitelistContains` are gone; the rules now branch on real
comparisons. The `no-evaluators` symbols that remain — `#blockTimestamp()`, `#txOrigin()`,
`#totalSupply(_)` — are *environment* values, not the rule's branching predicate, and the specs
pin them by premise (`requires #blockTimestamp() ==Int 100`). That is a legitimate shape: the
premise fixes an opaque input, and the conclusion is about `<pc>`/`<status>`.

But the vacuity reappeared as a **choice of constants**, which no amount of predicate cleanup
catches:

* **`whitelistcoequal-concrete.k` has no discriminating power at all.** Its jump target is
  `Int2Bytes(2, 14, BE)` = 14 and its post-decode `<pc>` is `2 + 12` = 14. Scenario A
  (taker in list, jump taken) and Scenario B (taker absent, fall through) therefore assert the
  **same final state**, `<pc> 14, <status> Running`. Machine-checked: with **both `0x2c`
  behavioural rules deleted** and the `[owise]` trace entry suppressed, the file still
  **PROVES**. Scenario B's own comment says it "guards against an arm-selection bug where both
  arms produce the same outcome" — that is precisely the bug it contains.
* **`conformance-concrete.k` repeats it for `0x31` and `0x32`.** Jump target 24, post-decode
  `2 + 22` = 24. The JumpIfTokenIn TAKEN and NOT-TAKEN claims and the JumpIfTokenOut TAKEN claim
  all assert `<pc> 24`. Machine-checked: with the `0x31` and `0x32` rules **deleted**, all three
  claims still **PROVE**. The `0x30` pair in the same file is well-formed (9 vs 5) — the flaw is
  per-claim, not per-file.

`deadline-concrete`, `gte-concrete`, `supplyshare-concrete`, `whitelistsequential-concrete` and
`txorigin-concrete` do not have this flaw: each pairs a `Reverted(...)` arm against a `Running`
arm, so the conclusions genuinely differ.

**F-5 — confirmed exactly, and now isolated.** Against the as-committed definition, `salt-spec`,
`stop-spec` and `jump-spec` all reach the claimed `<pc>`/`<status>` through the unknown-opcode
`[owise]` no-op; the residual's only failing conjunct is the `ListItem(#unknown(...))` trace
entry. Removing that one trace append from the `[owise]` rule and re-running: **`salt-spec`
PROVES with no Salt rule in the definition** (`#Top`), while `stop-spec`, `jump-spec`,
`revert-spec`, `extruction-spec`, `privateorder-spec`, `jumpifdirection-spec`,
`jumpiftokenin-spec` and `jumpiftokenout-spec` all still fail. So the pathology is specific and
proven: Salt's rule (`#exec(2, _) => .K`) is *behaviourally identical* to the unmodelled-opcode
no-op, and `salt-spec` asserts nothing beyond it.

## Did any control prove?

**No.** All 12 controls failed under all three definitions. Every one failed after execution
completed (`<k>` reduced to `.K`) on the conclusion, not on a stuck setup. No inconsistency.

## Near-neighbour assessment

The merge deleted 10 spec/control files (5 specs and their 5 controls) and added 7 concrete
files, so **only 12 controls remain for 21 positive claims**; the five reworked opcodes
(`0x20`, `0x24`, `0x25`, `0x2c`, `0x2d`) now have *no control at all* — their
sensitivity argument rests entirely on the two-arm concrete pairs, which is why the
whitelistcoequal and `0x31`/`0x32` constant collisions matter so much.

Re-running the previous audit's test on the current file set: as committed, with every
instruction rule absent, **11 of the 12 controls still fail** (the 12th, `txorigin-control`,
does not parse). None of them discriminates. Under the patched definition the 12 do behave as
near neighbours — they fail on the conclusion while their twins prove — so the controls are
sound *once the definition is wired*. The defect is the definition, not the controls.

## Non-vacuity

Concrete `krun` witnesses on the patched LLVM backend reach the asserted state for
`gate-spec` (`Reverted("TakerTokenBalanceIsZero")`), `gte-concrete` **both arms**,
`jump-spec` (pc 4), `jumpifdirection-spec` (pc 5), `stop-spec` (pc 2), `salt-spec` (pc 7),
and `whitelistcoequal-concrete` both arms — though the last is exactly the point: both
witnesses land on `<pc> 14, Running`, so the witness confirms the claim is unfalsifiable
rather than confirming the opcode works.

**No witness is possible for `deadline-concrete`, `txorigin-concrete`,
`whitelistsequential-concrete`, or `supplyshare-concrete`**: the LLVM interpreter aborts on the
unevaluatable `#blockTimestamp()` / `#txOrigin()` / `#totalSupply(_)`. This is weaker than
finding 3 was — the premises are now satisfiable *in principle* and the claims are not
tautological — but there is still no executable witness, so their non-vacuity rests on
`kprove` reaching a `Reverted(...)`/`Running` split that differs between arms. For those four
that split is real, which is the best available evidence short of an environment model.

## What the merge introduced that is new

1. **Nine parse failures** where there were none — the seven `*-concrete` files plus
   `txorigin-spec`/`-control` now name modules that the compiled definition does not contain.
2. **`whitelistcoequal-concrete.k`**, whose two scenarios are indistinguishable, proven vacuous
   by deleting the rules it claims to verify.
3. **Three claims in `conformance-concrete.k`** (`0x31` ×2, `0x32`) with the same defect.
4. **A shrunken control population** — 5 controls deleted, 0 added; five opcodes lost their
   sensitivity twins, leaving 12 controls for 21 positive claims.
5. **`txorigin`** gained `txorigin-concrete.k` but kept its `-spec`/`-control` pair, so it is
   the one opcode carrying both styles; the brief's expectation that it was replaced is wrong.
6. The genuine repair of `0x24` (F-4) and the removal of four tautological branching predicates
   (F-3) — real progress, in the same merge.

## Reproduction

    # as committed
    kompile --backend haskell lemmas.k --main-module SWAPVM-BYTES-LEMMAS \
      --syntax-module SWAPVM-SYNTAX -o swapvm-haskell
    for f in proofs/*.k; do kprove --definition swapvm-haskell "$f"; echo "$f $?"; done

    # patched: add `requires "opcodes/<each>.k"` + `imports SWAPVM-<EACH>` to lemmas.k,
    # and parenthesise jumps.k:56,63 as `andBool ( (…) ==Bool (…) )`, then re-run.

Exit codes: `0` PROVED, `1` not proved, `113` failed to parse.

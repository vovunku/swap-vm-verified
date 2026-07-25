# LEMMA-CRAFT — writing K lemmas for Kontrol/KEVM

A working reference for the proof engineering in this repo. Everything here is grounded in
one of three sources, and each claim says which:

* **[src]** — read out of the installed toolchain in the `kontrol` container
  (`kontrol` 1.0.255, `kevm-pyk` 1.0.921). Paths below are container paths.
* **[obs]** — observed empirically by running Kontrol against *this* repo's compiled
  definition during the writing of this document.
* **[doc]** — RV / K Framework documentation, with the URL.

Read `test/kontrol/analysis/FINDINGS.md` and `PROOF-MAP.md` first; this file is the "how",
those are the "what".

Short paths used throughout:

```
$EVM = /home/user/.local/lib/python3.10/site-packages/kevm_pyk/kproj/evm-semantics
$KD  = /home/user/.local/lib/python3.10/site-packages/kontrol/kdist
$PYK = /home/user/.local/lib/python3.10/site-packages/pyk
```

---

## 0. The five things that will cost you the most time

Ordered by how much of a day each one eats. Every one of these is verified below.

**0.1 A `[simplification]` rule whose LHS or RHS mentions a *partial* symbol and that does
not carry `preserves-definedness` is never even attempted by the Booster.** Not "sometimes",
not "it falls back" — the Booster discards it *before matching*, per candidate term, with a
one-line log entry you will never see unless you ask for it. Partial symbols in KEVM include
`/Int`, `modInt`, `%Int`, `<<Int`, `>>Int`, `log2Int`, `^Int`. `chop`, `up/Int`, `bool2Word`
and `#asWord` are `total` and do **not** trigger this. **[obs]**

Two rules in our `lemmas.k` are dead for exactly this reason — `mul512-high-zero` and
`mul512-high-zero-nochop`, i.e. blocker #2 in `PROOF-MAP.md`. Verbatim from a real Booster
log, on a real node of `LimitSwapSpec.test_exactOut_roundsInFavourOfMaker`:

```
['booster','simplify',{'term':'dd48918'},{'simplification':'091456c4…'},'detail']
    SWAPVM-LEMMAS.mul512-high-zero-nochop
['booster','simplify',{'term':'dd48918'},{'simplification':'091456c4…'},'failure','continue']
    Uncertain about definedness of rule due to: non-total symbol Lbl_modInt_
```

Note the absence of any `match` context between the two lines — compare the rule immediately
above it in the same log, `EVM-INT-SIMPLIFICATION.asWord-eq-asWord`, which shows
`['…','match','failure','continue']`. The definedness gate runs *first*. §3.2.

**0.2 The `--lemmas` fast loop silently cannot carry `preserves-definedness` or `comm`.**
`kontrol prove --lemmas f.k:MOD` injects rules over the RPC `add-module` endpoint, and
pyk's `krule_to_kore` converter supports exactly six rule attributes:
`label`, `priority`, `simplification`, `symbolic`, `concrete`, `smt-lemma`. Anything else is
a hard `ValueError` before the server even starts. **[src+obs]**

```
ValueError: Do not know how to convert AttEntry to Kore:
            AttEntry(key=AttKey(name='preserves-definedness'), value='')
```
(`$PYK/konvert/_kast_to_kore.py:334-351`, `raise ValueError` in the `case _:` arm.)

Consequence, and it is nasty: **the fast loop gives false negatives for precisely the
division lemmas this project is built out of.** You strip `preserves-definedness` to make
the file load, the Booster then discards the rule for lack of it, and you conclude the shape
was wrong. It was not. §8.2 gives the workaround.

**0.3 Same-priority simplification rules are in an unspecified race, and Kontrol ships ~60
of its own division/comparison rules that compete with yours.** `--auxiliary-lemmas = true`
in `kontrol.toml` pulls in `KONTROL-AUX-LEMMAS`, which contains eight ungated
transfer rules of the form `A <=Int B /Int C => A *Int C <=Int B requires 0 <Int C`, all at
default priority 50. Six of our Section-4/5 rules have LHSs those rules also match. §3.4.

**0.4 Term shapes are decided by the Yul optimiser, not by Solidity.** Every prediction in
the current `lemmas.k` header that was checked against bytecode turned out right, and every
prediction made from source turned out wrong. §2 makes this a procedure.

**0.5 Nothing checks soundness.** Not the frontend, not the backend, not CI. A wrong lemma
turns every proof in the repo into a theorem about nothing, and it will still say PASSED.
§4.

---

## 1. Anatomy of a simplification rule

### 1.1 The shape

```k
    rule [some-label]:
      LHS => RHS
      requires C1 andBool C2
      ensures  E
      [simplification(40), concrete(N), preserves-definedness]
```

The soundness obligation is **equivalence, not implication** [doc,
`docs.runtimeverification.com/kontrol/guides/advancing-proofs/simplifications-guide.md`]:

> a simplification is **sound** if and only if `C1 ∧ … ∧ CN ⟹ (LHS ⟺ RHS)`, meaning that the
> LHS and the RHS of the simplification have to be **equivalent** under assumptions
> `C1`, …, `CN`, that is, that a simplification **must not lose information**. This is
> essential to keep in mind, especially since the K rewrite symbol `=>` can easily be
> misunderstood as implication in this context.

Their own counterexample: `rule A >=Int 42 => A >=Int 0 [simplification]` is **unsound**.
It looks like a harmless weakening; it destroys information the rest of the proof needed.

This is the reason the `=> true` idiom is safe: `LHS => true requires C` is equivalent iff
`C ⟹ LHS`, which is exactly the informal reading. `LHS => WEAKER` is not.

### 1.2 `[simplification]` vs `[priority(N)]`

`simplification` takes an optional integer; absent, it means **50** [doc, K user manual].
The manual is explicit that this is *advisory*:

> Backends _should_ attempt simplification rules in order of their _simplification
> priority_, but **are not required to do so; in fact, the backend is free to apply
> `simplification` rules at _any time_**. Because of this, users must ensure that
> simplification rules are sound regardless of their order of application. […] **It is an
> error to have the `priority` attribute on a `simplification` rule.**

So: priority is a *performance and normalisation* tool, never a soundness tool. Never write
a pair of rules where one is only sound because the other fires first.

Bands actually used in the shipped lemma files **[src]**:

| Priority | Used for | Example |
|---|---|---|
| 30 | commutation / argument ordering | `int-eq-comm-concrete`, `A \|Int B => B \|Int A [concrete(B)]`, all the `b2w-*` comparator rules |
| 40 | canonicalisation, associativity, "answer directly instead of branching" | `A +Int (B +Int C) => (A +Int B) +Int C`, `minint-lt-maxint-a`, `asWord-trim-leading-zeros` |
| 42 | structural rewrites that must beat 45 | `slot-updates.k`'s `bor-update-with-shift` |
| 45 | comparison normalisation | the whole `A +Int B <Int C => A <Int C -Int B` family |
| 50 | default: content lemmas | most of ours |
| 60 | last resort / expansion that would otherwise loop | `notBool-or`, `notBool-and`, `shift-to-div`, `{B #Equals B1 +Bytes B2}` decomposition |

Two concrete lessons from `int-simplification.k` **[src]**:

```k
    // Higher-priority: short-circuit to true directly when path condition already has 0 <=Int B.
    rule A:Int <=Int A:Int +Int B:Int => true requires 0 <=Int B [simplification(40)]
    rule A:Int <=Int A:Int +Int B:Int => 0 <=Int B              [simplification]
```

A 40-priority "decide it" rule in front of a 50-priority "reduce it" rule. That is the
idiom to copy when a stock rule keeps turning your goal into another goal.

```k
    // minInt <Int maxInt: priority 40 fires before the default-priority (50) expansion rules,
    // so Booster sees `true` directly rather than a disjunction requiring path-condition reasoning.
    rule [minint-lt-maxint-a]:
        minInt(A, _B) <Int maxInt(C, _D) => true requires A <Int C [simplification(40)]
```

Our `ceildiv-oz-raw` uses `simplification(40)` for the same reason and the comment says so.
Good. Our `shiftl-to-mul`/`shiftr-to-div` use 60 for the opposite reason (don't beat
`asWord-shr`). Also good.

### 1.3 `concrete` / `symbolic`

[doc, K user manual, "concrete and symbolic attributes"]:

> **A concrete pattern is a pattern which does not contain variables or unevaluated
> functions**, otherwise the pattern is symbolic.
> - If a simplification rule is marked `concrete`, then _all_ arguments must be concrete.
> - If marked `symbolic`, then _all_ arguments must be symbolic.
> - `concrete(<variables>)` / `symbolic(<variables>)` […] specify the exact arguments.

Three practical consequences.

**(a) "or unevaluated functions" is load-bearing.** `f(1,2)` before evaluation is *not*
concrete. This is why the Kontrol guide says concrete evaluation always runs first:

> Functions with all concrete parameters are **always evaluated before any other
> simplification is applied**. […] this means that the attribute `symbolic(A)` is redundant
> [in `mul-conc-left`]. […] when writing simplifications with a specific goal in mind, we
> have to ask ourselves: "What happens if some of the symbolic variables in my
> simplification were concrete?"

**(b) `concrete(X)` is how you make a commutation rule terminate.** The canonical
normalisation, from `int-simplification.k`:

```k
    rule A *Int B => B *Int A [simplification, symbolic(A), concrete(B)]
```
> if `B` is concrete then for the simplification to be applied `A` must be symbolic. Once
> the simplification is applied, `A` will end up on the RHS of the multiplication, which
> must be concrete if the simplification is to be applied again, producing a contradiction.

`rule X +Int Y => Y +Int X [simplification]` is the classic way to hang the simplifier.

**(c) Gating is why stock KEVM rules do not fire for us.** The comment at the head of
Section 1 of our `lemmas.k` is correct: KEVM's `*Int`-under-`<Int` transfer rules are

```k
    rule A *Int B <Int C => B <Int C /Int A
      requires 0 <Int A andBool 0 <=Int C andBool C modInt A ==Int 0
      [simplification(40), concrete(A, C), preserves-definedness]
```

`concrete(A, C)` — both the multiplier and the bound must be literals. SwapVM's are two
symbolic balances. That is a genuine gap and Section 1 correctly fills it.

The Booster's diagnostic when this bites, verbatim from our own log **[obs]**:
```
INT-SIMPLIFICATION-HASKELL.int-eq-comm-concrete
    Concreteness constraint violated:  Concrete variable "Eq#VarN"
$EVM/buf.md : (63,10)
    Concreteness constraint violated: term has variables
```

### 1.4 `preserves-definedness`

The single most consequential attribute, and it is **not documented in K's user manual at
all** — it exists only in `Att.scala`. What the manual documents is the obligation
[doc, K user manual, `simplification` attribute]:

> **NOTE**: The frontend and Haskell backend **do not check** that supplied simplification
> rules are sound, this is the developer's responsibility. In particular, rules with the
> simplification attribute must preserve definedness; that is, if the left-hand side refers
> to any partial function then:
> - the right-hand side must be `#Bottom` when the left-hand side is `#Bottom`, or
> - the rule must have an `ensures` clause that is `false` when the left-hand side is `#Bottom`, or
> - the rule must have a `requires` clause that is `false` when the left-hand side is `#Bottom`.
>
> These conditions are in order of decreasing preference […] **The most preferred option is
> to write total functions and avoid the entire issue.**

Kontrol's rule of thumb [doc, simplifications-guide]:

> This attribute should be used when **either the LHS or the RHS contains a partial
> function**, but we are certain that both the LHS and RHS are defined for all use cases.

**What actually breaks without it.** The Booster's abort conditions include
[doc, `haskell-backend/docs/2024-10-18-booster-description.md`]:

> - **a non-preserving-definedness rule, i.e. a rule which has partial symbols on the RHS
>   and no `preserves-definedness` attribute**

and [doc, `haskell-backend/booster/docs/booster.md`]:

> Definedness is a very important invariant for the booster […] **the booster often aborts
> when it cannot be sure if a rule/simplification preserves definedness** and is therefore
> unable to proceed in applying said rule/simplification safely.

**[obs] corrects the doc in two ways.** First, the check fires on partial symbols in the
**LHS** too, not only the RHS — `mul512-high-zero` has `modInt` on the LHS and `true` on the
RHS and is still rejected. Second, for a *simplification* the outcome is not a fallback to
kore-rpc; it is `[failure][continue]`, i.e. the rule is skipped and the next candidate is
tried. That is what makes it invisible: nothing aborts, nothing warns, the proof just
doesn't progress.

Rules from RV's own shipped files that are dead in the Booster for this reason, observed in
the same log **[obs]**:

```
$EVM/lemmas/lemmas.k : (52,10) (53,18) (54,18)  →  non-total symbol LblnewAddr
$EVM/lemmas/bitwise-simplification.k : (80,10)  →  non-total symbol Lbl_<<Int_
```

So this is not a beginner's mistake; RV ship it too. Assume nothing.

**The payoff of normalising onto a total symbol.** `up/Int` is declared
`[function, total, smtlib(upDivInt)]` (`$EVM/evm-types.md:76`). Because it is `total`, none
of our six `updiv-*` bound rules need `preserves-definedness` — and they are the ones that
actually get attempted. `SWAPVM-LEMMAS.updiv-gt-transfer` appears in the log as a live
candidate; `SWAPVM-LEMMAS.mul512-high-zero` appears as a rejected one. That is a direct,
measurable dividend of the "normalise onto an existing total symbol" decision, and it
generalises: **prefer a total symbol in your canonical form, and the definedness tax
disappears from every downstream lemma.**

### 1.5 `smt-lemma` — and when it hurts

[doc, K user manual, SMT Translation]:

> `smt-lemma` can be applied to a rule to encode it as a conditional equality when sending
> queries to Z3. A rule `rule LHS => RHS requires REQ` will be encoded as the conditional
> equality `(=> REQ (= (LHS RHS))`. **Every symbol present in the rule must have an
> `smt-hook(...)` or `smtlib(...)` attribute.**

(The Kontrol "Advancing Proofs" page calls this attribute `smt-lib`. There is no such
attribute. The production-level spellings are `smtlib` and `smt-hook`.)

Use it for **range facts about opaque symbols**, which is exactly what RV use it for:

```k
    rule [asWord-lb]: 0 <=Int #asWord( _ )     => true [simplification, smt-lemma]
    rule [asWord-ub]: #asWord( _ ) <Int pow256 => true [simplification, smt-lemma]
    rule [chop-upper-bound]: 0 <=Int chop(_V)  => true [simplification, smt-lemma]
    rule [b2w-lb]: 0 <=Int bool2Word(_)        => true [simplification, smt-lemma]
    rule [widthOpCode-ub]: #widthOpCode(_) <=Int 33 => true [simplification, smt-lemma]
```

`LEMMAS-HASKELL` even documents *why* the smtlib declaration matters:

> `smtlib(widthOpCode)` on the declaration lets `smt-lemma` encode these as
> universally-quantified bounds so the solver can discharge side conditions containing
> `#widthOpCode` without needing to evaluate it concretely.

**When it hurts.** Every `smt-lemma` becomes a universally quantified assertion in the Z3
context, on *every* query, for the rest of the proof.

1. **Nonlinear side conditions poison the fragment.** A lemma like
   `X *Int Y <=Int C => true requires X <=Int C /Int Y` as an `smt-lemma` hands Z3 a
   quantified nonlinear-integer axiom. QF_NIA plus quantifiers is undecidable in practice;
   Z3 will start returning `unknown` on queries that used to be instant, and the failures
   appear far away from the lemma. **Do not put `smt-lemma` on anything containing a product
   or quotient of two symbolic terms.** Every one of RV's `smt-lemma` rules is a linear
   range fact or a syntactic identity — that is not an accident.
2. **`/Int` and `modInt` are translated to Z3 as *total* functions.** From the Booster docs:
   > when we translate certain functions, such as the `mod` or `/` function, in kore, these
   > are partial functions undefined when the second argument is 0. However, **Z3 […] does
   > not understand partial functions and instead treats all functions as total**. This can
   > lead to subtle and hard to find bugs (see haskell-backend#3603).

   So an `smt-lemma` mentioning `/Int` can be *unsound at the SMT layer* even if it is sound
   in K, because Z3 will instantiate it at a zero divisor.
3. It makes the rule invisible to the rewriter's own diagnostics — you lose the
   `[simplification]` log trail for it.

Rule of thumb: **`smt-lemma` is for bounds on symbols the rewriter cannot see inside. Never
for arithmetic you want the rewriter to perform.** Our `lemmas.k` currently uses it nowhere;
that is the right default.

### 1.6 `comm`

`comm` on a *rule* is resolved by the K **frontend**, not the backend. `ResolveComm.java`:

> generate a duplicate simplification rule for symbols that are labeled as `comm`
> **remove this attribute from the rules because the Haskell Backend has a different meaning
> for it**

So `[simplification, comm]` on `X ==Int f(Y) => …` compiles to *two* axioms, the second with
the two arguments of the **top-most LHS symbol** swapped. Two constraints:

* The **production** must itself be `comm`, or you get
  `Used 'comm' attribute on simplification rule but <klabel> is not comm.` This works for
  `==Int`, `==K`, `#Equals`, `+Int`, `*Int`, `|Int`, `&Int`; it does not work for `<Int`.
* It only swaps the top symbol's two arguments. It will not produce
  `Y *Int X` from `X *Int Y` deep inside the LHS. That is why our `lemmas.k` has explicit
  `-comm` twins (`mul-bound-transfer-comm`, `not-word-to-sub-comm`, `mul-no-overflow-comm`)
  — those are *operand* commutations inside the LHS, which `comm` cannot generate. Correct
  as written.

`comm` is **not** available over `--lemmas` (§0.2), so a rule you are iterating on has to be
written out in both directions until you promote it into `lemmas.k`.

### 1.7 `total` and `no-evaluators` — production attributes, not rule attributes

Both live on `syntax` declarations and therefore **require a rebuild**; neither can be
introduced through `--lemmas`.

```k
    syntax Int ::= Int "up/Int" Int [function, total, smtlib(upDivInt)]
```

* `function` — evaluated by equations rather than matched structurally.
* `total` — the function is defined on all inputs. This is what exempts every `up/Int` rule
  from `preserves-definedness`, and what lets `#Ceil(up/Int(A,B))` reduce to `#Top`.
  Declaring `total` on something that is *not* total is an unsoundness with no diagnostic.
* `no-evaluators` — "this symbol has no defining equations". This is the attribute you want
  for a genuinely uninterpreted abstraction (§5). Note the difference from `up/Int`'s trick:
  `up/Int` *has* equations but they are all `[concrete]`, so it behaves uninterpreted on
  symbolic arguments while still computing on literals. For `isqrt` that is exactly the
  behaviour you want too — you *do* want `isqrt(4) == 2` — so `[function, total,
  smtlib(isqrt)]` with `[concrete]` equations beats `no-evaluators`.

`functional` is a legacy alias for `function, total`. Do not use it in new code.

---

## 2. Finding the term shape

> As always: dump the stuck node with `kontrol show --node` and write the rule against the
> term KEVM actually produces.  — `FINDINGS.md`

That is right, and it is only half the procedure. `kontrol show` tells you the shape *of the
node you already have*; when the proof is stuck *before* the interesting arithmetic, or when
you are writing lemmas ahead of the proof, you need the compiler's answer instead. Both
procedures follow.

### 2.1 Procedure A — read the node (when you already have one)

```bash
DOCK="docker exec -u user -w /home/user/swap-vm-verified -e HOME=/home/user \
      -e FOUNDRY_PROFILE=kontrol \
      -e PATH=/home/user/.local/bin:/home/user/.foundry/bin:/usr/bin:/bin kontrol"

# 1. Find the frontier.
$DOCK kontrol list | less                      # nodes / pending / stuck / vacuous per proof

# 2. Get the tree and locate the pending leaf.
$DOCK kontrol show 'XYCSwapSpec.test_exactOut_roundsInFavourOfMaker(uint256,uint256,uint256)' \
      --version 2 --pending --no-failure-information --minimize

# 3. Dump that node in full: <k> cell, wordStack, and — the part people skip — the
#    path condition.
$DOCK kontrol show '<Contract>.<sig>' --version N --node <ID> --no-failure-information
```

Node ids are **not stable**: they change as other agents advance the proof. Resolve the id
and dump it in the same minute, or read
`out/proofs/<test-id>/kcfg/nodes/<id>.json` directly.

**Reading a `<k>` cell.** Real output from step 2 above **[obs]**:

```
├─ 23 (split)
│   k: JUMPI 1501 bool2Word ( ( notBool KV0_balanceIn:Int ==Int 0 ) ) ~> #pc [ JUMPI ] ...
│   pc: 881
```

This is the whole lesson in one line. The Solidity was `if (balanceIn == 0) revert`. What
KEVM has is `bool2Word ( notBool ( KV0_balanceIn ==Int 0 ) )` — because solc emitted
`ISZERO; ISZERO`, and KEVM's `ISZERO` rule is `bool2Word(W ==Int 0)`. A lemma keyed on
`0 <Int KV0_balanceIn` cannot see this term. The `lemmas.k` Section 5 comment predicted
exactly this; here it is confirmed on a live node.

Useful `show` flags **[src]**: `--minimize` (default; `--no-minimize` shows every cell),
`--pending`, `--failing`, `--node-delta A,B` (diff two nodes — the fastest way to see what
an edge actually did), `--to-module` (emit the edges as a K module), `--use-hex-encoding`,
`--expand-config`, `--counterexample-information` (with `--failure-information`).

**Reading a path condition.** The bottom of a node dump is the constraint set. Real output,
`LimitSwapSpec.test_exactOut_roundsInFavourOfMaker`, node 56 **[obs]**:

```
#And ( #Not ( { KV0_balanceIn:Int #Equals 0 } )
#And ( #Not ( { KV1_balanceOut:Int #Equals 0 } )
#And ( { true #Equals 0 <=Int KV0_balanceIn:Int }
#And ( { true #Equals KV0_balanceIn:Int <Int 340282366920938463463374607431768211456 }
#And   { true #Equals KV1_balanceOut:Int <Int 1157920892373161954235709850086879078532699846656405640394575840079131296399
36 } ) ) ) )
```

Three things to take from it:

1. `vm.assume(balanceIn > 0)` did **not** arrive as `0 <Int KV0_balanceIn`. It arrived as
   `#Not({KV0_balanceIn #Equals 0})`. If your lemma's `requires` says `0 <Int B`, the
   Booster has to *derive* that, and step 2 of its `checkRequires` pipeline only filters
   conjuncts it finds **verbatim** — everything else goes to simplification and then Z3.
   Writing side conditions in the same syntactic form the path condition uses is a real
   speed and reliability win.
2. `2^128` and `2^256` appear as fully-expanded decimal literals. `pow256` and `maxUInt256`
   are `[macro]`s and are expanded at parse time, so a lemma written with `pow256` matches;
   one written with `2 ^Int 256` does **not** (that is an unevaluated `^Int` application).
   `evm-int-simplification.k` has a rule specifically to work around this,
   `asWord-buf-inversion-rangeUInt256`, whose comment says: *"avoids the
   `minInt(2^256, pow256)` evaluation that Booster cannot match against the path condition's
   `2 ^Int 256` tree form."*
3. Booster wants `requires` in **conjunctive normal form**, one fact per conjunct
   [doc, booster.md: *"Write your requires clauses in the conjunctive normal form!"*], and
   it de-duplicates conjunct-by-conjunct against the path condition. Long `andBool` chains of
   atomic facts (which is what our `lemmas.k` already does) are the right style. Nested
   `orBool` inside a `requires` is not.

### 2.2 Procedure B — read the bytecode (write lemmas before the proof gets there)

This is what produced the correct Section-5 and Section-6 shapes and it is repeatable.
The key discipline is **compile the probe with this repo's exact `[profile.kontrol]`
settings** — `solc 0.8.30`, `optimizer = true`, `optimizer_runs = 700`, `via_ir = true`,
`evm_version = cancun`. `via_ir` in particular changes everything: the Yul optimiser is what
turns `a - 1` into `add(a, not(0))` and `high == 0` into `eq(_2, _1)`.

```bash
# 1. Minimal probe: one function, the exact expression you care about, nothing else.
cat > /tmp/Probe.sol <<'EOF'
pragma solidity 0.8.30;
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
contract Probe {
    function ceil(uint256 a, uint256 b) external pure returns (uint256) {
        return Math.ceilDiv(a, b);
    }
}
EOF

# 2. Compile it with the proof profile and keep the IR.
FOUNDRY_PROFILE=kontrol forge build --extra-output-files irOptimized evm.assembly \
    --contracts /tmp --out /tmp/probe-out

# 3. Read the OPTIMISED Yul (this is the ground truth for the shape).
cat /tmp/probe-out/Probe.sol/Probe.iropt

# 4. Disassemble, to see the opcode sequence KEVM will actually step through.
cast disassemble $(jq -r .deployedBytecode.object /tmp/probe-out/Probe.sol/Probe.json)
```

Then translate opcodes to K terms using this table (`$EVM/evm.md`, `$EVM/word.md`):

| EVM | KEVM term |
|---|---|
| `ADD a b` | `chop(A +Int B)` (via `+Word`) |
| `SUB a b` | `chop(A -Int B)` |
| `MUL a b` | `chop(A *Int B)` |
| `DIV a b` | `A /Word B` → `A /Int B` when `B =/=Int 0`, `0` when `B ==Int 0` |
| `MOD a b` | `A %Word B` → `A modInt B` / `0` |
| `MULMOD a b m` | `(A *Int B) %Word M` → `(A *Int B) modInt M` — **no `chop`** (`evm.md:1216`) |
| `ISZERO a` | `bool2Word(A ==Int 0)` |
| `LT a b` / `GT a b` | `bool2Word(A <Int B)` / `bool2Word(B <Int A)` |
| `EQ a b` | `bool2Word(A ==Int B)` |
| `NOT a` | `A xorInt maxUInt256` (`evm-types.md`, `rule ~Word W => W xorInt maxUInt256`) |
| `OR` / `AND` / `XOR` | `A \|Int B` / `A &Int B` / `A xorInt B` |
| `SHL n a` / `SHR n a` | `A <<Word N` = `chop(A <<Int N)` / `A >>Int N` |
| `SIGNEXTEND` | `chop(… &Int …)` / `chop(… \|Int …)`, two `[concrete]` rules |

The four shapes this repo has been bitten by, with their compiled origin:

| Solidity | Yul | KEVM term |
|---|---|---|
| `a - 1` | `add(a, not(0))` | `chop(A +Int maxUInt256)` |
| `a > 0` (as `SafeCast.toUint`) | `iszero(iszero(a))` | `bool2Word(notBool (A ==Int 0))` |
| `type(uint256).max - x` | `not(x)` | `X xorInt maxUInt256` |
| `mul512 high == 0` | `eq(sub(mm,low), lt(mm,low))` | `chop(MM -Int chop(X*Y)) ==Int bool2Word(MM <Int chop(X*Y))` |

All four are recorded in `lemmas.k` already; the table is here so the *procedure* is
reusable, not just the four answers.

**Cross-check.** After writing the rule, confirm it compiled in and confirm the shape by
running the lemma through the Booster against a real node (§8). Compilation alone proves
nothing:

```bash
grep -c 'SWAPVM-LEMMAS.ceildiv-oz-raw' out/kompiled/definition.kore   # 2 = present
```

`out/kompiled/definition.kore` also carries a human-readable `// rule …` comment above each
axiom, which is the definitive statement of what your rule became after macro expansion:

```
// rule `_<=Int_`(`_/Int_`(A,B),A)=>#token("true","Bool")
//   requires `_andBool_`(`_<=Int_`(#token("0","Int"),A),`_<Int_`(#token("0","Int"),B))
//   [label(SWAPVM-LEMMAS.div-le-self), preserves-definedness, simplification("")]
```

Note `simplification("")` — empty argument means default priority 50.

---

## 3. Why a lemma does not fire — a diagnostic procedure

Do not guess. The Booster will tell you, per rule, per term, exactly where it gave up. Turn
the log on first, then read the table.

### 3.1 Turn the log on

```bash
$DOCK kontrol simplify-node '<Contract>.<sig>' <NODE> \
      --lemmas probe.k:PROBE \
      --haskell-log-dir /tmp/hlog \
      --haskell-log-entries Simplify,SimplifySuccess,Aborts
```

You get one `<request-id>.jsonl` per RPC in `/tmp/hlog` (~1.6 MB for a single
`simplify-node` on a small node **[obs]**). Analyse it with this script — it is the single
highest-value tool in this document:

```python
# lemma-log.py — classify what happened to every simplification candidate
import json, glob, collections, sys

labels, rows = {}, []
for fn in sorted(glob.glob(sys.argv[1] + '/*.jsonl')):
    for line in open(fn):
        try: d = json.loads(line)
        except Exception: continue
        ctx, msg = d['context'], d.get('message')
        h = next((x[k] for x in ctx if isinstance(x, dict)
                        for k in ('simplification','rewrite','function','equation') if k in x), None)
        strs = [x for x in ctx if isinstance(x, str)]
        if h and 'detail' in strs and isinstance(msg, str):
            labels[h] = msg                      # hash -> rule label or file:line
        rows.append((h, tuple(strs), msg))

applied   = collections.Counter()
nomatch   = collections.Counter()
rejected  = collections.Counter()
for h, strs, msg in rows:
    if not h: continue
    if strs[-2:] == ('match', 'success'):        applied[labels.get(h, h)] += 1
    elif 'match' in strs and 'failure' in strs:  nomatch[labels.get(h, h)] += 1
    elif strs[-2:] == ('failure', 'continue'):   rejected[(labels.get(h, h), str(msg)[:120])] += 1

print('APPLIED');            [print(f'{v:5d}  {k}') for k, v in applied.most_common(30)]
print('\nREJECTED (matched-or-considered, then discarded)')
for (l, m), v in rejected.most_common(30): print(f'{v:5d}  {l}\n       {m}')
print('\nLHS DID NOT MATCH (top 20)'); [print(f'{v:5d}  {k}') for k, v in nomatch.most_common(20)]
```

Context vocabulary you will see **[obs, doc/logging.md]**:

| Context tail | Meaning |
|---|---|
| `detail` | names the rule — label if it has one, else `file : (line, col)`. **Label your rules.** |
| `match, success` | LHS matched; rule applied |
| `match, failure, continue` | LHS did not match; try the next rule |
| `match, failure, break` | matching was *indeterminate* (a `remainder` is printed); simplification of this subterm stops here |
| `failure, continue` + `Uncertain about definedness of rule due to: non-total symbol X` | **missing `preserves-definedness`**. Rule skipped without even matching |
| `failure, continue` + `Concreteness constraint violated: …` | `concrete(…)`/`symbolic(…)` gating |
| `failure, continue` + `Condition simplified to #Bottom.` | side condition is *false* here |
| `constraint, …` | the same, but while simplifying the path condition rather than the term |
| `smt` | Z3 round-trip |
| `abort` (with a preceding `match` / `definedness` / `constraint`) | Booster gave up and fell back to kore-rpc |

The single most useful filter, if you drive `kore-rpc-booster` directly via
`--kore-rpc-command`, is `-c 'ceil>partial-symbols.'` — it prints, at load time, *every*
rule with partial symbols on the RHS and no `preserves-definedness`. That is a
whole-definition audit in one line.

### 3.2 Cause: missing `preserves-definedness`

**Symptom** `failure, continue` with `Uncertain about definedness of rule due to: non-total
symbol Lbl_modInt_` (or `Lbl_/Int_`, `Lbl_<<Int_`, `LblnewAddr`, `Lbllog2Int`).

**Test** Does the LHS *or* RHS mention `/Int`, `modInt`, `%Int`, `<<Int`, `>>Int`,
`log2Int`, `^Int`, or a project function not declared `total`? If yes and the attribute is
absent, this is your bug. No further investigation needed.

**Fix** Add `preserves-definedness` — after satisfying yourself that the rule really does
preserve definedness (the `requires` must rule out the zero divisor / negative shift).

**Trap** You cannot test this fix through `--lemmas` (§0.2). See §8.2.

### 3.3 Cause: shape mismatch

**Symptom** the rule never appears in the log at all, or appears only as
`match, failure, continue`.

**Test** `--lemmas` a copy of the rule with the `requires` deleted. If it still does not
appear as `match, success`, the LHS is wrong. If it now applies, the problem is the side
condition (§3.5).

**Fix** §2. In this codebase, the shape is wrong nine times out of ten because you wrote
Solidity-shaped arithmetic instead of Yul-shaped arithmetic.

**Trap** matching is *purely syntactic* [doc, rule-application]:
> the first rule requires a `0` **syntactically** in second position, whereas the second
> rule requires there a term that is **semantically equivalent** to `0`.

`chop(A +Int maxUInt256)` and `A -Int 1` are different terms even where they are provably
equal. That is exactly why `lemmas.k` carries both `ceildiv-oz-guarded` (chop form) and
`ceildiv-oz-guarded-flat` (subtraction form). Keeping both is correct practice, not
duplication.

### 3.4 Cause: another rule got there first

**Symptom** the rule appears as `match, failure, continue` even though the LHS looks right;
or a *different* rule appears as `match, success` on the same term hash immediately before.

**Test** In the analyser output, sort by term hash and look at what applied to that hash.
Alternatively grep `out/kompiled/definition.kore` for every axiom with your LHS's top
symbol:

```bash
grep -n '// rule .*_<=Int_.*_/Int_' out/kompiled/definition.kore
```

**[obs]** for `_<=Int_` with a `/Int` operand in this definition:

```
56224  KONTROL-AUX  A <=Int B /Int C  =>  A *Int C <=Int B          requires 0 <Int C
56268  SWAPVM       C <=Int A /Int B  =>  true                       (div-ge-transfer)
56668  SWAPVM       A /Int B <=Int A  =>  true                       (div-le-self)
56704  KONTROL-AUX  B /Int C <=Int A  =>  (A+1) *Int C >Int B        requires 0 <Int C
56716  INT-SIMP     (A *Int B) /Int C <=Int D => true
```

All at priority 50. `KONTROL-AUX-LEMMAS` is in the definition because
`kontrol.toml` sets `auxiliary-lemmas = true` (`kompile.py:37-44` then selects
`KONTROL-FULL`, since keccak lemmas default on). Those two aux rules are *ungated* — their
only side condition is `0 <Int C` — so they match almost everything our division lemmas
match.

Same-priority order is by position in the compiled definition, which is an artifact of
module topology. **Do not rely on it.** If you need to win, say so: `simplification(40)`.

**Fix** either (a) raise your rule to 40 so it decides the goal before the stock rule
rearranges it, or (b) delete your rule and let the stock rule fire — often the stock
rewrite *is* your side condition, in which case your rule was redundant. `div-ge-transfer`
is exactly this case: the aux rule turns `C <=Int A /Int B` into `C *Int B <=Int A`, which
is verbatim `div-ge-transfer`'s own `requires`. Same outcome, one fewer rule.

**Trap** the competitor may be one of *yours*. §3.7.

### 3.5 Cause: the side condition is not dischargeable

**Symptom** `failure, continue` with `Condition simplified to #Bottom.` (the condition is
*false*), or the rule silently not applying while Z3 time climbs.

**How the Booster checks `requires`** [doc, booster.md]:
> 1. substitute the rule's requires clause with the matching substitution
> 2. check if we already have any of the conjuncts **verbatim** in the pattern's path
>    condition (`PC`). If so, we filter them out as known truth
> 3. simplify every conjunct individually by applying equations
> 4. check again whether any of the, now simplified, conjuncts is present **verbatim**
> 5. if any clauses remain, check all conjuncts together with Z3 for validity given the PC.

**Test** Dump the node's path condition (§2.1) and ask, conjunct by conjunct, whether it is
there verbatim. If `requires 0 <Int B` and the PC has `#Not({B #Equals 0})` plus
`0 <=Int B`, steps 2 and 4 both miss and you are relying on step 5. That works, but it costs
an SMT call per attempt and it is where nonlinear conditions fail.

**Fix, in order of preference**
1. Restate the side condition in the form the path condition actually has.
2. Split a compound condition into atomic conjuncts (CNF).
3. Add a cheap bridging lemma. `int-simplification.k` ships one for this exact case:
   `rule 0 <Int X => true requires 0 <=Int X andBool notBool (X ==Int 0) [simplification(60)]`.
4. Weaken the side condition so it is linear. Our `sq-no-overflow` is the model:
   > Strictly weaker than `mul-no-overflow` in Section 1, but its side condition needs no
   > division, which is what lets it fire.

   `X <Int pow128` instead of `X <=Int maxUInt256 /Int Y`. A weaker lemma that fires beats a
   stronger one that does not.

**Trap: a side condition that rewrites into the rule's own LHS.** This is a real hazard
here and it is worth naming.

`mul-bound-transfer` is `X *Int Y <=Int C => true requires … X <=Int C /Int Y`.
`KONTROL-AUX-LEMMAS` contains, ungated at priority 50:

```k
    rule A <=Int B /Int C => A *Int C <=Int B requires 0 <Int C [simplification, preserves-definedness]
```

Step 3 above simplifies the conjunct `X <=Int C /Int Y` — and that aux rule turns it into
`X *Int Y <=Int C`, which is `mul-bound-transfer`'s own LHS. The simplifier can then try
`mul-bound-transfer` again, on the side condition of `mul-bound-transfer`. The Booster
bounds this with `--equation-max-recursion` (default 5) and `--equation-max-iterations`
(default 100) and emits an `EquationWarnings` soft-violation; the rule does not apply. The
same hazard applies to `mul-no-overflow`, `mul-no-overflow-comm`, and to RV's own
`X *Int Y <Int pow256 => true requires … Y <=Int maxUInt256 /Int X` in `lemmas.k`.

RV are aware of this class of bug — from `int-simplification.k`, verbatim:
> // Requires is purely concrete (both B and C are concrete), so no circular
> // self-application.

**To confirm it on a specific goal**: run with `-l EquationWarnings` (via
`--kore-rpc-command`) and look for recursion/iteration limit messages naming the rule; or
`--lemmas` a copy of the rule with the division moved out of the `requires`
(e.g. `requires X *Int Y <=Int C` restated as a *harness assumption* instead) and see it
apply. **Not yet confirmed empirically for this repo — see HANDOFF.**

### 3.6 Cause: `concrete` / `symbolic` gating

**Symptom** `Concreteness constraint violated: term has variables` /
`Concreteness constraint violated: Concrete variable "Eq#VarN"`.

**Test** read the attribute. Remember that an *unevaluated function application* counts as
symbolic, so `concrete(N)` will reject `N = 2 ^Int 24` if `^Int` has not been evaluated yet.

**Fix** relax the gate, or add a higher-priority rule that evaluates the operand first.
`shiftl-to-mul`/`shiftr-to-div` use `concrete(N)` correctly — the shift amount in
`unscaleValue` is the literal 24.

### 3.7 Cause: your own rules fight each other

**Symptom** oscillation, or a rule applying and then being undone.

**Test** in the analyser output, look for two rules with high `applied` counts on the same
term hash.

**Fix** pick one direction and make it the canonical form. `evm-int-simplification.k` has a
long comment about exactly this hazard being why they *refused* to add a rule:

> Note: there is intentionally no `asWord-eq-false` analogue of the `<Int`/`<=Int` rules
> above. Such a rule […] is not loop-safe: when both operands are `#asWord`, applying it
> rewrites the equality into its own `requires` with the two operands swapped […] so it
> re-matches and recurses without bound in the Kore simplifier. `<Int`/`<=Int` are
> antisymmetric, so their swapped requires is a different relation and does not re-match.

### 3.8 Cause: Booster vs. Haskell backend

The two engines do **not** apply the same rule set. The Booster skips rules it cannot
certify (§3.2); kore-rpc has slower but more complete definedness machinery. Booster falls
back to kore-rpc on `Branching,Stuck,Aborted` (`kore-rpc-booster --fallback-on`, that being
the default **[src]**).

**Symptom** the proof behaves differently at different points for no visible reason; or a
rule "works sometimes".

**Test** run the same node with `--no-use-booster`. If the behaviour changes, the Booster
skipped something.

**Fix** whatever the Booster skipped, fix it properly — do not run the whole proof on
kore-rpc, it is far slower. `--booster-only-simplify` (skip the Kore simplification pass
after Booster) is the opposite knob and is useful to isolate which engine did what.

### 3.9 Cause: the rule is not in the definition

**Symptom** the label never appears in the log, at all, even as `match, failure`.

**Test**
```bash
grep -c 'SWAPVM-LEMMAS.<label>' out/kompiled/definition.kore     # 2 if compiled in
```
`0` means the edit did not reach the build. `README.md` in `test/kontrol` already records
that a stale `lemmas.k` can survive a rebuild silently — the copy that matters is
`out/kompiled/requires/lemmas.k`:
```bash
diff lemmas.k out/kompiled/requires/lemmas.k && echo SAME
```

**Trap** after adding a lemma that kills a branch, **delete the stale `split` node**
[doc, debugging-failing-proofs]:
> When adding a new lemma to remove an unnecessary branch, be sure to **delete the `split`
> node from the KCFG** before continuing. Otherwise, both branches will still exist, but the
> unnecessary one will simplify to `#Bottom`.

`kontrol remove-node <test> <id>`, then re-run `prove` **without** `--reinit`.

---

## 4. Soundness discipline

### 4.1 What "sound" means operationally

For `LHS => RHS requires C`, you owe an argument for `C ⟹ (LHS ⟺ RHS)` over **K's integers**
— unbounded `Int`, with `/Int` **truncating toward zero**, not flooring. Our `lemmas.k`
Section 5 header already states this caveat and it is the right one to state:

> `up/Int` is defined via K's `/Int`, which truncates toward zero rather than flooring, so
> it coincides with ceiling division only on non-negative arguments. Every rule below carries
> an explicit non-negativity condition.

That is the single most common source of a *genuinely* unsound arithmetic lemma. Any rule
about `/Int`, `modInt` or `up/Int` that does not pin the sign of its arguments is suspect.

The second most common source is **partiality**: `A /Int 0` is `#Bottom`, not `0`. A rule
`A /Int B <=Int A => true requires 0 <=Int A` (note: no `0 <Int B`) is unsound, because at
`B = 0` the LHS is undefined and the RHS is `true`.

The third is **quantifier scope**: variables in a `requires` that do not occur in the LHS are
existentially chosen by the matcher and will bite you. K flags this (`unboundVariables`), so
in practice it does not happen; mentioned for completeness.

### 4.2 The three tiers a rule can be in

`lemmas.k` currently marks derivability inline with `DERIVABLE`. Make that a hard taxonomy,
because the tiers have different review requirements:

* **T1 — DERIVABLE (equational).** An identity of integer arithmetic, or an equational
  consequence of the EVM semantics. Reviewable by inspection. Examples:
  `dec-word-to-sub`, `manual-ceildiv-to-updiv`, `mul512-high-zero` (the two-case argument in
  its comment is genuinely complete), `sq-monotonic`.
* **T2 — DERIVABLE-BUT-HARD.** True and provable, but the proof is a real argument, not a
  one-liner. Should carry the argument in the comment *and* a regression test (§8.3).
  Example: `updiv-minimal` — minimality of ceiling division.
* **T3 — ASSUMED.** Not proven anywhere; a trust boundary. `isqrt`'s characterising axioms
  will be T3 until someone proves them against OZ `Math.sqrt`.

**Make T3 unmistakable in the file.** Structural recommendation, since a comment is not
enough:

1. Put **all** T3 rules in a separate module in a separate file, e.g.
   `lemmas-assumed.k` / `module SWAPVM-ASSUMED-LEMMAS`, which `SWAPVM-LEMMAS` imports.
2. Prefix every label: `assumed-isqrt-lower-bound`, not `isqrt-lower-bound`. Labels are what
   appear in the Booster log, so a reader of a trace sees the trust boundary too.
3. Put a machine-checkable census at the top of the file and a CI check on it:
   ```bash
   grep -c 'rule \[assumed-' lemmas-assumed.k   # must equal the number in the header
   grep -c 'rule \[assumed-' lemmas.k           # must be 0
   ```
4. Every proof report must list which `assumed-*` labels were reachable. The Booster log
   (§3.1) gives you this for free: grep `applied` for `assumed-`.

This is worth the ceremony because of §0.5: an assumed rule and a proven one are
indistinguishable to the tool, to the KCFG, and to `kontrol list`.

### 4.3 What makes a lemma unsound in practice

Ranked by how often it actually happens:

1. **Sign not pinned.** `/Int` truncates toward zero. `(-7) /Int 2 == -3`, not `-4`.
2. **Divisor not pinned nonzero**, making the LHS `#Bottom` where the RHS is defined.
3. **Weakening dressed as rewriting.** `A >=Int 42 => A >=Int 0`. Information loss is
   unsoundness for a simplification even though the implication holds.
4. **`chop` assumed away.** `chop(X) => X` needs `#rangeUInt(256, X)`; `chop(A +Int B) => A +Int B`
   is false on overflow. Our `dec-word-to-sub` is careful here (`0 <Int A andBool A <Int pow256`).
5. **A `total` declaration on a partial function.** Silent, global, and catastrophic.
6. **`smt-lemma` on nonlinear arithmetic**, or on anything mentioning `/Int`/`modInt`
   (Z3 totalises them — §1.5).
7. **Sound-only-if-another-rule-fires-first.** Forbidden by the "backend is free to apply
   simplification rules at any time" clause.

### 4.4 Cheap ways to raise confidence

* **Concrete instantiation.** Before trusting a rule, hand-evaluate it at the boundary:
  `A = 0`, `A = 1`, `B = 1`, `A = B`, `A = B - 1`, `A = pow256 - 1`. Most bad rules die at
  `A = 0` or `B = 1`.
* **Ask "what if my symbolic variable were concrete?"** — the Kontrol guide's own advice.
  A rule that is wrong for concrete inputs is wrong.
* **Prefer `=> true` with a strong `requires` over an equational rewrite.** `=> true` is
  information-preserving by construction if the `requires` implies the LHS: you can only
  fail to be *useful*, not fail to be *sound*.
* **Restate, don't invent.** Every rule you can express as "normalise onto a symbol KEVM
  already has" (`up/Int`) inherits RV's own soundness review for the eight rules that then
  apply. That is the highest-leverage soundness move available and this repo already made it
  once.

---

## 5. Uninterpreted functions and abstraction — the `isqrt` problem

### 5.1 Declaring one

```k
    syntax Int ::= isqrt ( Int ) [symbol(isqrt), function, total, smtlib(isqrt)]
 // ---------------------------------------------------------------------------
    rule isqrt(0) => 0                                          [concrete]
    rule isqrt(1) => 1                                          [concrete]
    rule isqrt(N) => …                                          [concrete]   // optional
```

Modelled on `up/Int` (`$EVM/evm-types.md:76-81`), and for the same reason: `total` frees
every downstream lemma from `preserves-definedness`; `smtlib(isqrt)` makes it an
uninterpreted function to Z3 so `smt-lemma` range facts can be attached; all-`[concrete]`
defining equations mean it computes on literals and stays opaque on symbols. `[no-evaluators]`
is the alternative if you want it opaque even on literals — you almost certainly don't.

Characterising axioms (all **T3 / assumed** until proven):

```k
    rule [assumed-isqrt-lb]:   isqrt(A) *Int isqrt(A) <=Int A => true            requires 0 <=Int A [simplification]
    rule [assumed-isqrt-ub]:   A <Int (isqrt(A) +Int 1) *Int (isqrt(A) +Int 1) => true requires 0 <=Int A [simplification]
    rule [assumed-isqrt-mono]: isqrt(A) <=Int isqrt(B) => true                   requires 0 <=Int A andBool A <=Int B [simplification]
    rule [assumed-isqrt-sq]:   isqrt(N *Int N) => N                              requires 0 <=Int N [simplification]
    rule [assumed-isqrt-rng-l]: 0 <=Int isqrt(_) => true [simplification, smt-lemma]
    rule [assumed-isqrt-rng-u]: isqrt(A) <=Int A  => true requires 1 <=Int A [simplification]
```

Note: only the two range facts get `smt-lemma`; the others are nonlinear and must stay out
of Z3 (§1.5).

`isqrt-sq` alone discharges `deadCode_PeggedSwapMathNoSolution` (FINDINGS §5).

### 5.2 The blocker: nothing produces the symbol

`Math.sqrt` is an `internal` library function; with `via_ir` it is **inlined** into
straight-line code — a 7-way branch on the MSB estimate followed by six unrolled Newton
steps. There is no `CALL`, no `DELEGATECALL`, no jump to a stable target. There is therefore
**no seam at the K level**: nothing in the `<k>` cell distinguishes "this DIV is Newton step
3 of a sqrt" from any other DIV.

Two hard consequences, both verified in the toolchain:

* **`--cse` cannot help.** Kontrol's CSE targets are computed by `find_function_calls`
  (`$KD/../solc_to_k.py:1102-1157`): it walks the Solidity AST for `FunctionCall` nodes
  whose `expression` is a `MemberAccess`, then computes
  `contract_type = typeString.split()[-1] if 'contract' in typeString else 'UnknownContractType'`
  and **drops** `UnknownContractType`. `Math` is a library, not a contract; `Math.sqrt(x)`
  never becomes a CSE target. **[src]**
* **`--lemmas` cannot declare the symbol.** `Foundry.load_lemmas`
  (`$KD/../foundry.py:654-668`) raises on any sentence that is not a `KRule`:
  ```python
  non_rule_sentences = [sent for sent in lemmas_module.sentences if not isinstance(sent, KRule)]
  if non_rule_sentences:
      raise ValueError(f'Supplied lemmas module contains non-Rule sentences: {non_rule_sentences}')
  ```
  A `syntax Int ::= isqrt(Int)` production is a `KProduction`. **A new symbol requires a
  rebuild, full stop.** **[src]**

### 5.3 The seams, ranked

**#1 — `kevm.freshUInt` + `vm.assume` at the call site, inside a harness.** *Available
today. No rebuild. No new symbol.*

Copy the enclosing function into the harness and replace `Math.sqrt(arg)` with a fresh
symbolic constrained by the characterisation:

```solidity
interface IKevmCheats { function freshUInt(uint8) external returns (uint256); }

IKevmCheats constant kevm =
    IKevmCheats(address(uint160(645326474426547203313410069153905908525362434349))); // 0x7109…D12D

function _isqrt(uint256 a) internal returns (uint256 s) {
    s = kevm.freshUInt(32);
    vm.assume(s * s <= a);
    vm.assume(a < (s + 1) * (s + 1));
}
```

The cheatcode is `[cheatcode.call.freshUInt]` in `$KD/cheatcodes.md:398-404`; it rewrites to
a fresh existential `?WORD` with `ensures 0 <=Int ?WORD andBool ?WORD <Int 2 ^Int (8 *Int W)`.
Selector `freshUInt(uint8)` = `625253732` (`cheatcodes.md:1942`), VM address
`0x7109709ECfa91a80626fF3989D68f67F5b1DD12D` (`$KD/foundry.md:54`). You do **not** need the
`kontrol-cheatcodes` library installed (this repo does not have it) — declaring the
interface yourself is enough, because the cheatcode is dispatched on selector at that
address.

Why this beats a plain harness parameter: PeggedSwap's four sqrt sites take **derived**
arguments (`Math.sqrt(u1 * ONE)` where `u1` is computed mid-function). A parameter cannot be
constrained relative to a value that does not exist at call entry; `freshUInt` can, because
you place it exactly where the call was.

Cost, and it is real:
* **No congruence.** Two `freshUInt`s on equal arguments are *different* symbols. If the
  same sqrt argument appears twice (the `test_diff_*` proofs), you must compute it once and
  reuse the variable. Structure the harness so each distinct argument has exactly one
  `_isqrt` call.
* **A transcription is a trust boundary.** Exactly the debt `FINDINGS.md` already records
  for `XYCConcentrateHarness`. Pair every property with a `test_diff_*` companion.

**#2 — harness scalar parameter + `vm.assume`.** *Available today. No rebuild.*
Simpler, ABI-visible, easier to review, and it composes with `custom:kontrol-precondition`
NatSpec (`solc_to_k.py:345-367`, `Precondition`) if you want the assumptions declared rather
than executed. Strictly worse than #1 when the sqrt argument is derived; strictly better when
it is an input, because there is no cheatcode call in the path and no extra branching.

**#3 — declare `isqrt` in `lemmas.k` + a `<k>`-cell interception rule on an oracle
address.** *Requires one rebuild.* Introduce a trivial `ISqrtOracle` contract with an
`external` `sqrt(uint256)`, have the harness call it, and add a **rewrite** rule (not a
simplification) that intercepts the call frame and returns `isqrt(ARG)` directly, in the
style of Kontrol's cheatcode rules. This is the only option that gives **true congruence**
and a symbol Z3 can quantify over.

Caveats: it is a `<k>`-cell rewrite rule, so it must be `[priority(40)]` and not
`[simplification]`; it must reproduce the exact call/return protocol; and the external call
is itself a fidelity change relative to the inlined production code, so you still owe a diff
proof. Net: more machinery than #1 for the same trust obligation, plus a rebuild. Only worth
it if congruence turns out to be the binding constraint.

**#4 — reuse an existing opaque symbol.** Technically possible (pick any `total`,
`smtlib`-declared function whose equations are all `[concrete]` and pretend it means isqrt)
and **do not do it**. Every stock lemma about that symbol becomes an unsoundness. Listed
only so nobody rediscovers it.

**#5 — `--cse` on an `external`/`public` wrapper.** Make `sqrt` an external function on a
deployed helper so `find_function_calls` picks it up. CSE will then try to *prove* a summary
of sqrt — which is the same 2^7-path problem you were escaping. The summary is inserted as a
high-priority rule and could in principle be admitted rather than proven, but Kontrol has no
"admit this subproof" surface today (see §7). Not practical.

**#6 — change the production code.** `FINDINGS.md` already floats this for `Power.pow`, and
it is equally the highest-leverage option here: a `sqrt` that is `external` on a library, or
a branchless fixed-iteration variant, changes the verification cost by orders of magnitude.
Out of scope for a lemma document, but it belongs on the list.

**Recommendation: #1 now, #3 only if the diff proofs turn out to need congruence.**

### 5.4 Making the abstraction honest

Whichever seam you pick, the assumed characterisation must be *tight* or the proof is
vacuous in the other direction — an over-constrained `s` can make a branch infeasible and a
property pass for the wrong reason. Two checks:

* **Anti-vacuity.** Assert a concrete witness through the abstracted path
  (`_isqrt(16) == 4` reachable, the success branch reachable). `FINDINGS.md`'s "anti-vacuity
  is part of writing a spec" applies double to an abstraction.
* **Both bounds, always.** `s*s <= a` alone admits `s = 0`; `a < (s+1)^2` alone admits
  huge `s`. Ship them as a pair, in one helper, never inline.

---

## 6. RV's own lemma idioms

The seven files in `$EVM/lemmas/` plus `$KD/kontrol_lemmas.md` are the best available style
guide. Six recurring patterns, with named examples.

### 6.1 Transfer — eliminate the division rather than reason under it

The dominant idiom. Move a partial/nonlinear operator to the other side of a comparison
where it becomes a product.

```k
// $KD/kontrol_lemmas.md, KONTROL-AUX-LEMMAS — eight of these, all with preserves-definedness
    rule A <=Int B /Int C =>         A  *Int C <=Int B requires 0 <Int C [simplification, preserves-definedness]
    rule A  <Int B /Int C => (A +Int 1) *Int C <=Int B requires 0 <Int C [simplification, preserves-definedness]
    rule B /Int C  <Int A =>         A  *Int C  >Int B requires 0 <Int C [simplification, preserves-definedness]
    rule B /Int C <=Int A => (A +Int 1) *Int C  >Int B requires 0 <Int C [simplification, preserves-definedness]
```

Note the `+Int 1` on the strict variants — that is the floor-division correction, and it is
the part people get wrong. `A < B/C ⟺ A+1 ≤ B/C ⟺ (A+1)·C ≤ B` for `C > 0`.

Our Section-4 rules are the `=> true` form of the same idea. Both forms are legitimate; the
`=> true` form is stronger (it decides the goal) but only fires when the side condition is
already in the path condition.

### 6.2 Normalisation to canonical form

Rewrite toward a single representative, with `concrete`/priority chosen so it terminates.

```k
// int-simplification.k — 30-band commutation
    rule A *Int B => B *Int A            [simplification, symbolic(A), concrete(B)]
    rule [int-eq-comm-concrete]: N:Int ==Int X:Int => X ==Int N [simplification(30), concrete(N), symbolic(X)]
// 40-band associativity, twelve rules of this shape
    rule (A +Int B) -Int C => A +Int (B -Int C) [concrete(B, C), symbolic(A), simplification(40)]
// 45-band comparison normalisation, forty rules
    rule A +Int B <=Int C => A <=Int C -Int B   [concrete(B, C), symbolic(A), simplification(45)]
```

Ours: `not-word-to-sub` (xor → subtraction), the six `ceildiv-*` rules (all forms →
`up/Int`), `shiftl-to-mul`/`shiftr-to-div` (shifts → arithmetic). Same discipline, and the
comments correctly justify the *direction* of each — which is the thing to review.

### 6.3 Range propagation

Assert bounds on symbols the rewriter cannot see inside. Almost always `smt-lemma`, almost
always linear.

```k
    rule [asWord-lb]: 0 <=Int #asWord( _ )     => true [simplification, smt-lemma]
    rule [chop-lower-bound]:   chop(_V) <Int pow256 => true [simplification, smt-lemma]
    rule [b2w-ub]: bool2Word(_) <=Int 1 => true [simplification, smt-lemma]
    rule 0 <=Int #lookup( _M:Map , _ ) => true [simplification, smt-lemma]
    rule 0 <=Int keccak( _ )           => true [simplification]
    rule 0 <=Int G up/Int I => true requires 0 <=Int G andBool 0 <Int I [simplification]
```

Every one is `0 <= x` or `x < bound`. None is nonlinear. Copy that.

### 6.4 Bound lemmas that decide rather than reduce

The `simplification(40)` "answer directly" pattern, plus its comment explaining why:

```k
    rule [minint-lt-maxint-a]:
        minInt(A, _B) <Int maxInt(C, _D) => true requires A <Int C [simplification(40)]
    rule A:Int <=Int A:Int +Int B:Int => true requires 0 <=Int B [simplification(40)]
```

and the `upInt-*` family in `evm-int-simplification.k`, which is the *reason* to normalise
into `up/Int`:

```k
    rule [upInt-refl-geq]: X <=Int ((X up/Int Y) *Int Y) => true                requires 0 <Int Y [simplification]
    rule [upInt-lt-true]:  ((X up/Int Y) *Int Y) <Int Z => true requires X +Int Y <=Int Z andBool 0 <Int Y [simplification]
    rule [upInt-refl-leq]: ((X up/Int Y) *Int Y) <=Int X => X modInt Y ==Int 0  requires 0 <Int Y [simplification, preserves-definedness]
    rule [upInt-ref-eq]:   X ==Int ((X up/Int Y) *Int Y) => X modInt Y ==Int 0  requires 0 <Int Y [simplification, comm, preserves-definedness]
```

`upInt-refl-geq` **is** `ceilDiv(a,b)*b >= a` — the lemma `FINDINGS.md` says two instructions
independently asked for. It already ships. That is the payoff of §6.6.

### 6.5 Contradiction / vacuity rules

Kill infeasible branches at the constraint level rather than the term level.

```k
// int-simplification.k
    rule A:Int <Int B:Int andBool C:Int <=Int A:Int => false requires B <=Int C [simplification, concrete(B, C)]
    rule A:Int <Int B:Int andBool B:Int <Int A:Int  => false [simplification]
    rule A +Int B <Int A => false requires 0 <=Int B [simplification]
// kontrol test-data cse-lemmas.k — ML level
    rule { B1:Bytes #Equals B2:Bytes } => #Bottom
      requires notBool ( lengthBytes(B1) ==Int lengthBytes(B2) ) [simplification]
```

Note the `#Equals`/`#Bottom` form: you can write simplifications over **matching-logic
predicates**, not just over terms. `int-simplification.k` mirrors eight of its `==Int` rules
into `{ _ #Equals _ }` form for exactly this reason. If a rule "should" fire but the goal is
a path constraint rather than a term, this is why.

### 6.6 Read before you write

The Kontrol guide's own advice, and it paid off here:

> `git grep -rin 'rule bool2Word'` […] Knowing the existing rules for any function is
> important since this means knowing how the function is treated by KEVM and thus by
> Kontrol.

Equivalent in this container:

```bash
docker exec -u user kontrol grep -rn 'up/Int' $EVM/lemmas/ $EVM/evm-types.md $KD/kontrol_lemmas.md
docker exec -u user kontrol grep -rn 'rule \[b2w' $EVM/lemmas/lemmas.k
```

`LEMMAS-WITHOUT-SLOT-UPDATES` alone has **23** `bool2Word` rules, including
`b2w-mul-le-l`/`b2w-mul-eq-l` which decompose exactly the
`bool2Word(P) *Int X <=Int A` shape that OZ's `ceilDiv` produces. Anyone writing a
`bool2Word` lemma for this repo should read those 23 first.

### 6.7 Two more habits worth stealing

* **Total helper functions with an `[owise]` sentinel**, so the helper never introduces
  partiality:
  ```k
      syntax Int ::= #getFirstOneBit(Int) [function, total]
      rule [gfo-succ]: #getFirstOneBit(X) => log2Int(X &Int ((maxUInt256 xorInt X) +Int 1))
        requires #rangeUInt(256, X) andBool X =/=Int 0 [preserves-definedness]
      rule [gfo-fail]: #getFirstOneBit(_) => -1 [owise]
  ```
* **Comment the rules you deliberately did *not* write**, and why. `int-simplification.k`'s
  disabled `eq-false-lt` (with the issue numbers and the 45→0 SMT-call measurement) and
  `evm-int-simplification.k`'s `asWord-eq-false` non-rule are both better documentation than
  most of what they did write.

---

## 7. Loop reasoning

**Honest answer: from Kontrol, there is no loop-invariant facility.** What exists:

**`--bmc-depth N`** — `'Enables bounded model checking. Specifies the maximum depth to
unroll all loops to.'` **[src]** This is unrolling, not invariants. It yields a *bounded*
result in general. It yields an *unconditional* result only when you can show the
`N+1`-th iteration is infeasible — which is exactly the `PiecewiseLinearScale` situation
recorded in `FINDINGS.md`: `argsLength` is a single byte, so at most 50 segments, so
`--bmc-depth 51` is complete provided you then **verify no reachable `bounded` leaves
remain** (`kontrol list` reports `bounded:` per proof).

**`[circularity]` and `[trusted]` are Claim-only attributes** in K's `Att.scala`. K
documents only `trusted`:
> You may add the `trusted` attribute to a given claim for the K prover to automatically add
> it to the list of proven **circularities**, instead of trying to discharge it separately.

Neither is reachable from a Solidity test. They belong to hand-written `kprove` specs, and
Kontrol never constructs a `KClaim` you can attach them to.

**The technique that actually works is a high-priority `<k>`-cell rewrite rule that jumps
the loop.** Kontrol's own integration test does this
(`kontrol/src/tests/integration/test-data/lemmas.k`, module `SUM-TO-N-INVARIANT`), and note
it is `[priority(40)]`, **not** `[simplification]`:

```k
    rule [foundry-sum-to-n-loop-invariant]:
      <kevm>
        <k> ((JUMPI 2423 CONDITION) => JUMP 2423) ~> #pc [ JUMPI ] ~> #execute ... </k>
        <mode> NORMAL </mode> <schedule> CANCUN </schedule>
        <ethereum><evm><callState>
          <program> PROGRAM </program>
          <jumpDests> JUMPDESTS </jumpDests>
          <wordStack>
            (S => (S +Int ((N *Int (N +Int 1)) divInt 2))) : 0 : (N => 0) : 459 : 2123244496 : .WordStack
          </wordStack>
          <pc> 2393 </pc>
          <gas> GAS_AMT => GAS_AMT -Int (N *Int 178) </gas>
          ...
        </callState></evm></ethereum>
      </kevm>
      requires 0 <Int N
       andBool #rangeUInt(256, S +Int ((N *Int (N +Int 1)) divInt 2))
       andBool CONDITION ==K bool2Word ( N ==Int 0 )
       andBool PROGRAM ==K #parseByteStack ( "0x6080..." )
       andBool JUMPDESTS ==K #computeValidJumpDests(PROGRAM)
      [priority(40)]
```

What this costs you, and why nobody does it casually:

* It is **bytecode-pinned**: `PROGRAM ==K #parseByteStack("0x6080…")` is the whole deployed
  runtime, verbatim. Any recompile silently stops the rule matching (and there is no
  diagnostic — it just goes back to unrolling).
* It pins the **`<pc>`, the exact `<wordStack>` layout including return addresses and the
  selector**, and the **`<gas>`** decrement. You have to derive all of it from a node dump.
* It is a **rewrite** rule, so it cannot be delivered through `--lemmas`, which only accepts
  simplification-shaped rules; it needs `--require` + `--module-import` + a rebuild.
* Its soundness is entirely on you — it *is* the loop invariant, asserted.

For `Power.pow` (up to 65 536 leaves for `DutchAuction`) this is the only in-tool option
short of changing the code. `FINDINGS.md` already reaches the right conclusion: prove the
**order properties** by hand-stated lemmas instead of trying to summarise the loop, and
consider a branchless fixed-trip-count `pow`.

**Adjacent, and worth trying first: `--cse` + node merging.** CSE summarises a *function*
(not a loop) into a high-priority rule, and `kontrol minimize-proof <proof> --merge`
collapses sibling branches. For `PiecewiseLinearScale`'s caterpillar KCFG this reduces node
count without touching the loop. It does not help `Power`, whose problem is branching, not
repetition. `--include-summary <test>` reuses an already-proven summary in another proof.
`--cse` and `--include-summary` are mutually exclusive (`prove.py:75-76`).

---

## 8. Testing a lemma

### 8.1 The fast loop: `simplify-node --lemmas`

**Verified working against this repo [obs].** No rebuild, no `--reinit`, one node.

```bash
cat > /tmp/probe.k <<'EOF'
module SWAPVM-PROBE
    imports KONTROL-MAIN

    rule [probe-div-le-self-40]:
      A /Int B <=Int A => true
      requires 0 <=Int A andBool 0 <Int B
      [simplification(40)]

endmodule
EOF
docker cp /tmp/probe.k kontrol:/home/user/swap-vm-verified/probe.k

$DOCK kontrol simplify-node 'LimitSwapSpec.test_exactOut_roundsInFavourOfMaker(uint256,uint256,uint256)' 56 \
      --lemmas probe.k:SWAPVM-PROBE
```

It prints the simplified node — configuration plus path condition. Add `--replace` to write
it back into the KCFG (don't, on a shared proof). `--lemmas` is also accepted by
`kontrol prove`, `kontrol show`, `kontrol step-node`, `kontrol get-model`, `kontrol
section-edge` (`foundry.py:1212,1304,1342,1392`).

Mechanics **[src]**: `Foundry.load_lemmas` parses the module, then
`KCFGExplore.cterm_symbolic.add_module(extra_module, name_as_id=True)` sends it over the
RPC `add-module` endpoint (`pyk/proof/reachability.py:781-782`, `pyk/kore/rpc.py:1200`). The
module is added to the *running server's* definition.

Empirical notes:
* No `requires "…"` line is needed. `imports KONTROL-MAIN` alone parsed and loaded.
* Rules only. Any `syntax`, `configuration`, `claim` → `ValueError: Supplied lemmas module
  contains non-Rule sentences`.
* **Attributes: `label`, `priority`, `simplification`, `symbolic`, `concrete`, `smt-lemma`
  only.** `preserves-definedness` and `comm` are hard errors (§0.2). `owise` is silently
  converted to `priority(200)`.
* Since the module goes into a *running* server, it cannot introduce new symbols — the
  signature is fixed at build time.

### 8.2 Working around the `preserves-definedness` gap

This is the one real hole in the fast loop, and it matters here because most of our lemmas
touch `/Int`.

**Diagnosis:** if your probe rule's LHS/RHS has a partial symbol, you are testing a rule the
Booster will discard. The log will say so explicitly. Do not conclude the shape is wrong.

**Three workarounds, in order:**

1. **Test the shape and the side condition separately from the definedness.** Split the rule
   into a partial-symbol-free skeleton that exercises the same matching problem. E.g. to
   test whether `chop(A +Int maxUInt256)` is really the term, probe with
   `rule chop(A +Int maxUInt256) => 999999 requires 0 <Int A andBool A <Int pow256
   [simplification(40)]` — `chop` is `total`, so this loads and applies, and the sentinel
   `999999` shows up in the dumped node if the shape was right. This isolates "is the shape
   right?" from "will the Booster accept the real rule?", which are the two questions you
   actually have.
2. **`--no-use-booster`.** kore-rpc does its own definedness reasoning and does not need the
   attribute. Much slower, but decisive for a single node.
3. **Promote to `lemmas.k` and rebuild** when you have a batch worth the rebuild cost.
   Batch them — a rebuild on a shared definition is expensive for everyone.

### 8.3 Confirming a rule *fired* rather than assuming it

Three levels of evidence, weakest to strongest:

1. **It compiled in.** `grep -c '<MODULE>.<label>' out/kompiled/definition.kore` → 2.
   Proves nothing about firing.
2. **The node changed.** `simplify-node` output differs with and without `--lemmas`, or
   `kontrol show --node-delta A,B`. Good, but does not tell you *which* rule did it.
3. **The Booster log names it.** `--haskell-log-dir` + the §3.1 analyser, looking for the
   label under `APPLIED`. This is the only direct evidence. **[obs]** on this repo, a single
   `simplify-node` produced 1334 `detail` (candidate) entries, 1278 `match/failure`, 54
   definedness/concreteness rejections and 6 `match/success` — so the log is dense but
   entirely mechanical to filter.

Do not accept "the proof passed" as evidence a specific lemma fired. It may have passed for
another reason, or vacuously.

### 8.4 A regression suite for lemmas

The KEVM idiom for this is `runLemma`/`doneLemma` claims
(`evm-semantics/tests/specs/functional/verification.k`):

```k
    claim [buf-shift]:
      <k> runLemma ( #buf ( 20, X <<Int 16 ) ) => doneLemma ( #buf ( 18, X ) +Bytes b"\x00\x00" ) ... </k>
      requires 0 <=Int X andBool X <Int 2 ^Int 144
```

**This is not available from Kontrol.** `grep -c runLemma out/kompiled/definition.kore` → 0
**[obs]**; `runLemma` is declared only in KEVM's functional test specs, not in
`KONTROL-MAIN`, and `--lemmas` cannot add the production. Even where it is available, RV
warn that it under-tests [doc, debugging-failing-proofs]:

> if your claim is in the form of `runLemma(A) => doneLemma(B)` and it passes, **it doesn't
> guarantee that `A` fully simplifies to `B`. Instead, it might simplify to an expression
> `B'` that implies `B`.**

So build the regression suite out of what Kontrol *does* have:

**Tier 1 — pinned nodes + probe file (no rebuild, seconds).**
Keep `test/kontrol/lemmas-regression/` containing, per lemma family:
* a **pinned node JSON**, copied out of `out/proofs/<id>/kcfg/nodes/<n>.json`, so node-id
  churn cannot break the test;
* a **probe module** exercising that family;
* an **expected marker** — either a sentinel RHS (§8.2 #1) or the rule label expected under
  `APPLIED` in the log.

A runner script then does `simplify-node --lemmas … --haskell-log-dir …` and asserts the
label appears. This catches the two failure modes that actually happen: a KEVM upgrade
changing a term shape, and a new rule shadowing an old one.

**Tier 2 — Solidity witness tests (needs a build, but only when specs change).**
For each lemma family, a tiny `prove_*` function whose *only* difficulty is the shape the
lemma targets — e.g. `prove_ceilDivShapeIsNormalised(uint256 a, uint256 b)` computing
`Math.ceilDiv(a,b)` and asserting `r * b >= a`. If the normalisation into `up/Int` works,
`upInt-refl-geq` closes it in a handful of nodes; if it regresses, the proof stalls. These
double as anti-vacuity checks because they have a real postcondition.

**Tier 3 — the soundness census.** A CI grep asserting (a) every rule in `lemmas.k` has a
label, (b) every rule whose LHS/RHS matches `/Int|modInt|<<Int|>>Int|log2Int|\^Int` also
matches `preserves-definedness`, (c) `assumed-` appears only in the assumed-lemmas file, and
(d) the count of `assumed-` rules equals the number declared in the file header. (b) alone
would have caught `mul512-high-zero` before it cost anyone a day.

---

# HANDOFF

## A. Decision tree — "my lemma did not fire"

Run the §3.1 log first. Everything below is a lookup, not an investigation.

```
0. Is the label in out/kompiled/definition.kore?           grep -c '<MOD>.<label>' …
   └─ no  → the edit never reached the build.
            diff lemmas.k out/kompiled/requires/lemmas.k     → §3.9

1. Does the label appear in the Booster log at all?
   └─ no  → the rule was never a candidate for any term you executed.
            Either the top symbol of your LHS never occurs (→ §2, wrong shape),
            or you are looking at the wrong node.

2. Does the log show  "Uncertain about definedness of rule due to: non-total symbol X"?
   └─ YES → MISSING preserves-definedness.  This is the #1 cause here.       → §3.2
            (partial symbols: /Int modInt %Int <<Int >>Int log2Int ^Int)
            NOTE: you cannot test the fix via --lemmas.                       → §8.2

3. Does the log show  "Concreteness constraint violated"?
   └─ YES → concrete()/symbolic() gating. Remember an unevaluated function
            application counts as symbolic.                                   → §3.6

4. Does the log show  "Condition simplified to #Bottom."?
   └─ YES → your requires is FALSE at this node. The lemma is inapplicable
            here (possibly correctly). Check the path condition.              → §3.5

5. Does the log show  match/failure/continue for your rule?
   └─ YES → LHS shape mismatch. Re-derive from optimised Yul, not Solidity.   → §2.2
            Sanity check: probe with the requires deleted.                    → §3.3

6. Does the log show  match/failure/break  ("Uncertain about match. Remainder: …")?
   └─ YES → indeterminate match; simplification of that subterm stopped.
            Usually two #asWord / two symbolic Bytes. Add a bridging lemma.

7. Rule matched, requires reached Z3, still nothing?
   └─ Look for another rule with match/success on the same term hash.
      Very likely KONTROL-AUX-LEMMAS at priority 50.                          → §3.4
      Fix: simplification(40), or delete yours because theirs is equivalent.

8. Nonlinear side condition and rising SMT time?
   └─ Weaken it until it is linear (sq-no-overflow is the model).             → §3.5
      Check for a self-referential requires loop (mul-bound-transfer).        → §3.5 trap

9. Behaves differently on different runs / "works sometimes"?
   └─ Re-run the node with --no-use-booster. If it changes, Booster skipped
      something → back to step 2.                                             → §3.8

10. Everything above clean, proof still stuck?
   └─ Stale split node in the KCFG. kontrol remove-node, then prove
      WITHOUT --reinit.                                                       → §3.9
```

## B. The `isqrt` seam — assessment

**Most practical seam: `kevm.freshUInt` + paired `vm.assume` bounds, at the call site,
inside a harness.** Available today, no rebuild, no new symbol, and it is the only
no-rebuild option that works when the sqrt argument is *derived* — which is the PeggedSwap
case (`Math.sqrt(u1 * ONE)` with `u1` computed mid-function) and therefore the case that
gates PeggedSwap Groups E/F.

Concretely:

```solidity
interface IKevmCheats { function freshUInt(uint8) external returns (uint256); }
IKevmCheats constant kevm =
    IKevmCheats(address(uint160(645326474426547203313410069153905908525362434349)));

function _isqrt(uint256 a) internal returns (uint256 s) {
    s = kevm.freshUInt(32);
    vm.assume(s * s <= a);
    vm.assume(a < (s + 1) * (s + 1));
}
```

Verified prerequisites: `[cheatcode.call.freshUInt]` at `$KD/cheatcodes.md:398-404` returns a
fresh existential with `0 <= ?WORD < 2^(8*W)`; selector `625253732`; VM address
`0x7109709ECfa91a80626fF3989D68f67F5b1DD12D`. The `kontrol-cheatcodes` library is *not*
installed in this repo and is *not* needed — declare the interface locally.

Ranking of the alternatives, with the reasons each is worse:

| # | Seam | Rebuild? | Verdict |
|---|---|---|---|
| 1 | `freshUInt` + assumed bounds at call site | no | **do this** |
| 2 | harness scalar param + assumed bounds | no | equivalent when the argument is an input; cannot express a derived argument |
| 3 | declared `isqrt` symbol + oracle-address `<k>` interception rule | **yes** | the only option giving true congruence; needs a `[priority(40)]` rewrite rule, cannot be delivered by `--lemmas`, and still owes a diff proof |
| 4 | reuse an existing opaque symbol | no | **never** — every stock lemma about that symbol becomes an unsoundness |
| 5 | `--cse` on an external `sqrt` wrapper | no | CSE would have to *prove* the summary; same 2^7 paths. And `Math.sqrt` is a library call, which `find_function_calls` (`solc_to_k.py:1130`) drops as `UnknownContractType`, so plain `--cse` cannot see it at all |
| 6 | change the production code | n/a | highest leverage, out of scope here |

Two things to get right regardless of seam:

* **Congruence.** `freshUInt` gives you a *fresh* symbol each call. Two calls on equal
  arguments are unrelated. Structure the harness so each distinct sqrt argument is computed
  once and the result reused — otherwise `test_diff_*` cannot close. If that turns out to be
  impossible, that is the trigger to escalate to seam #3, and the only one.
* **Both bounds together, in one helper.** `s*s <= a` alone admits `s = 0`; `a < (s+1)^2`
  alone admits absurd `s`. Ship as a pair and anti-vacuity-test the abstracted path.

The characterising axioms in §5.1 are all **T3 / assumed**. They belong in a separate
`lemmas-assumed.k` with `assumed-` label prefixes (§4.2), so that a Booster trace shows the
trust boundary being used.

## C. Findings against our `lemmas.k`

Ordered by consequence.

### C1. `mul512-high-zero` and `mul512-high-zero-nochop` are DEAD — missing `preserves-definedness` — **confirmed empirically**

Both LHSs contain `modInt`; both carry only `[simplification, comm]`. The Booster discards
them at the definedness gate, before matching. Observed verbatim on a live node of
`LimitSwapSpec.test_exactOut_roundsInFavourOfMaker`:

```
{'simplification':'091456c4…'},'detail'            SWAPVM-LEMMAS.mul512-high-zero-nochop
{'simplification':'091456c4…'},'failure','continue'
    Uncertain about definedness of rule due to: non-total symbol Lbl_modInt_
{'simplification':'1e97fafa…'},'detail'            SWAPVM-LEMMAS.mul512-high-zero
{'simplification':'1e97fafa…'},'failure','continue'
    Uncertain about definedness of rule due to: non-total symbol Lbl_modInt_
```

This is `PROOF-MAP.md` blocker #2, and the answer is **not** the `chop(… modInt …)` shape
question raised there. The shape is right (`evm.md:1216`: `MULMOD W0 W1 W2 => (W0 *Int W1)
%Word W2`, and `%Word` unfolds to a bare `modInt` for a nonzero concrete modulus — no
`chop`). The attribute is the bug.

**Fix:** add `preserves-definedness` to both. It is justified — the LHS's `modInt` divisor
is the literal `maxUInt256`, never zero, so the LHS is total on the rule's domain.

**Priority: highest single item in this document.** One attribute, on two rules, unblocks
the gate for every OZ `mulDiv` in the codebase.

### C2. `shiftr-to-div` is not a duplicate — it is a *fix*

`KONTROL-AUX-LEMMAS` ships
`rule [shift-to-div]: X >>Int N => X /Int (2 ^Int N) requires 0 <=Int X andBool 0 <=Int N
[simplification(60), concrete(N)]` — **without** `preserves-definedness`, with `>>Int` on
the LHS and `/Int` on the RHS. It is dead in the Booster for the same reason as C1. Our
`shiftr-to-div` is byte-identical except that it *has* the attribute, so it is the live one.
Keep it, and put a comment saying why (someone will "de-duplicate" it otherwise).

### C3. `mulmod-maxuint-collapse` is a true duplicate of a stock KEVM rule

```k
// ours
    rule [mulmod-maxuint-collapse]: (X *Int Y) modInt maxUInt256 => X *Int Y
      requires 0 <=Int X andBool 0 <=Int Y andBool X *Int Y <Int maxUInt256
      [simplification, preserves-definedness]
// int-simplification.k, INT-SIMPLIFICATION-COMMON
    rule A modInt B => A requires 0 <=Int A andBool A <Int B [simplification, preserves-definedness]
```

Instantiating the stock rule at `A := X *Int Y`, `B := maxUInt256` gives obligations
`0 <=Int X *Int Y` (discharged by `0 <=Int A *Int B => true requires 0<=A andBool 0<=B`, also
stock) and `X *Int Y <Int maxUInt256` — **identical** to ours, including the strictness. The
comment "KEVM's `A modInt B => A` needs the STRICT bound, which a harness assumption of the
usual form `X <= maxUInt256 / Y` does not supply" is true, but it is equally true of our own
rule. Delete it, or keep it and correct the comment to "specialisation for matching speed".

### C4. Six Section-4/5 rules compete with `KONTROL-AUX-LEMMAS` at the same priority

`auxiliary-lemmas = true` puts eight ungated division-transfer rules at priority 50 into the
definition. Our same-priority rules with an overlapping LHS:

| Ours | Competing aux rule | Assessment |
|---|---|---|
| `div-le-self` (`A /Int B <=Int A => true`) | `B /Int C <=Int A => (A+1)*C >Int B` | direct clash; whichever is earlier in `definition.kore` wins |
| `div-ge-transfer` (`C <=Int A /Int B => true`) | `A <=Int B /Int C => A *Int C <=Int B` (earlier in the file) | shadowed; but the aux rewrite **is** our `requires`, so same outcome — ours is redundant |
| `div-lt-transfer` (`A /Int B <Int C => true`) | `B /Int C <Int A => A *Int C >Int B` | direct clash, same-outcome argument applies |
| `div-monotonic` (`A /Int B <=Int C /Int B`) | both aux `<=Int` rules match | clash; the aux rewrite does **not** reproduce our conclusion here, so we should win |
| `div-le-updiv` (`A /Int B <=Int A up/Int B`) | `B /Int C <=Int A` matches with `A := A up/Int B` | clash |
| `updiv-*` family | none (`up/Int` ≠ `/Int`) | clean |

**Recommendation:** put `simplification(40)` on `div-monotonic`, `div-le-self` and
`div-le-updiv` (the three whose conclusion the aux rewrite does not reproduce), and consider
deleting `div-ge-transfer` and `div-lt-transfer` as redundant. Do **not** rely on
definition order — §1.2.

### C5. `mul-no-overflow` / `mul-no-overflow-comm` are largely subsumed by RV's `lemmas.k`

```k
// $EVM/lemmas/lemmas.k, LEMMAS-WITHOUT-SLOT-UPDATES
    rule X *Int Y <Int pow256 => true
      requires (0 <=Int X orBool 0 <=Int Y) andBool Y <=Int maxUInt256 /Int X
      [simplification]
```
Same conclusion, roles of `X`/`Y` swapped in the side condition. RV's version has a
*weaker* non-negativity requirement (a disjunction) and is live (no partial symbol in
LHS/RHS). Keep ours if the operand orientation matters, but the comment should say "covers
the orientation RV's rule does not", not "KEVM has nothing here".

### C6. Self-referential `requires` loop hazard — `mul-bound-transfer`, `mul-no-overflow` (hypothesis)

`mul-bound-transfer`'s `requires X <=Int C /Int Y` is rewritten by the ungated aux rule
`A <=Int B /Int C => A *Int C <=Int B` into `X *Int Y <=Int C` — the rule's own LHS. Bounded
by `--equation-max-recursion` (5) / `--equation-max-iterations` (100), so the visible symptom
is "the rule doesn't apply" plus an `EquationWarnings` soft violation. Same for
`mul-bound-transfer-comm`, `mul-no-overflow`, `mul-no-overflow-comm`, and RV's own rule in
C5. **Not confirmed empirically** — see §D. If confirmed, the fix is to restate the side
condition without a division (e.g. require the product bound directly and supply it from the
harness), which also removes the nonlinearity.

### C7. Rules that are correct as written, for the record

* `updiv-one` (`A up/Int 1 => A`) — **not** a duplicate. KEVM's `I1 up/Int 1 => I1` is
  `[concrete]` (`evm-types.md:80`) and never fires on a symbolic numerator. Correctly needed,
  correctly stated, and needs no `preserves-definedness` because `up/Int` is `total`.
* `dec-word-to-sub` — `chop` is `[function, total]` (`word.md:583`), so no attribute needed.
  Guard `0 <Int A andBool A <Int pow256` is exactly right.
* The whole `up/Int` normalisation strategy — validated. `up/Int` is
  `[function, total, smtlib(upDivInt)]` with all four defining equations `[concrete]`, so on
  symbolic operands it is a total, SMT-visible, uninterpreted function. `upInt-refl-geq`
  *is* `ceilDiv(a,b)*b >= a`, the lemma two spec passes independently asked for. The header
  comment's claim of eight activated rules is accurate (`upInt-lt-true`, `upInt-lt-false`,
  `upInt-refl-leq`, `upInt-refl-gt`, `upInt-refl-geq`, `upInt-ref-eq`, `upInt-refl-neq`, plus
  `0 <=Int G up/Int I` in `lemmas.k`).
* Keeping both `ceildiv-oz-guarded` (chop form) and `ceildiv-oz-guarded-flat` (subtraction
  form) — correct, because matching is purely syntactic.
* The `-comm` twins — correct, because K's `comm` attribute only swaps the top-level LHS
  symbol's two arguments and cannot generate operand commutations inside the LHS.
* Section 7 squares — no partial symbols, no attribute needed, and `sq-no-overflow`'s
  deliberate weakening (`X <Int pow128` instead of a division) is exactly the right
  engineering trade. Observed as a live candidate in the Booster log.

### C8. Corroborations of the hard-won lessons in the task brief

* `a > 0` → `bool2Word(notBool (A ==Int 0))`: **confirmed on a live node**
  (`JUMPI 1501 bool2Word ( ( notBool KV0_balanceIn:Int ==Int 0 ) )`, XYCSwap node 23).
* `type(uint256).max - x` → `X xorInt maxUInt256`: confirmed against `evm-types.md`
  (`rule ~Word W => W xorInt maxUInt256`), and `bitwise-simplification.k` indeed has
  `xorInt-ge-zero` / `xorInt-lt` / `xorInt-to-if` but nothing relating `xorInt` back to
  subtraction. `not-word-to-sub` fills a real gap.
* `mul512` branch condition never mentions `high`: consistent with `evm.md:1216`
  (`MULMOD => (W0 *Int W1) %Word W2`, no `chop`) and with `-Word`/`*Word` unfolding to
  `chop(…)`. The written shape is right; only the attribute is wrong (C1).
* "Nothing in the tooling flags an unsound lemma": confirmed, and it is worse than that —
  nothing flags a lemma the backend is silently *refusing to apply* either. §8.4 Tier 3 is
  the cheapest mitigation.

## D. Unresolved

1. **C6 is unconfirmed.** I did not manage to observe a recursion-limit / `EquationWarnings`
   event naming `mul-bound-transfer`. The `--haskell-log-entries` set I used
   (`Simplify,SimplifySuccess,Aborts`) does not include `EquationWarnings`; re-running with
   it, or driving `kore-rpc-booster` directly via `--kore-rpc-command` with
   `-l EquationWarnings`, should settle it in one node.
2. **Whether the aux division rules actually beat ours in practice (C4)** — I established
   that both are present at priority 50 and that their LHSs overlap, and I read the
   `definition.kore` ordering, but I did not observe a term where one shadowed the other.
   The `simplify-node` I ran did not reach a division-heavy goal. Repeat §3.1 on a node from
   `XYCSwapSpec.test_exactIn_roundsInFavourOfMaker` and sort the log by term hash.
3. **No `preserves-definedness` fix was validated end-to-end**, because validating it needs
   either a rebuild (forbidden) or `--no-use-booster` on a `mulDiv`-bearing node. I checked
   the rejection, not the acceptance. The rejection is unambiguous; the acceptance is a
   two-word edit; but someone should watch `mul512-high-zero` appear under `APPLIED` before
   declaring the blocker closed.
4. **Node ids churn under concurrent agents.** Two node dumps I started failed with
   `ValueError: Unknown node` because another proof run renumbered the KCFG between resolving
   the id and dumping it. For any reproducible artifact, copy
   `out/proofs/<id>/kcfg/nodes/<n>.json` first and work from the copy (this is why §8.4
   Tier 1 pins nodes).
5. **`--cse` was not exercised.** I established from source that it cannot see `Math.sqrt`,
   but I did not measure whether it helps the `mulDiv` path once C1 is fixed. Worth one
   experiment on `XYCConcentrateSpec`.
6. **`kontrol build`/`--rekompile` were not run**, per the constraint, so nothing in §5.1
   (the `isqrt` production) or §7 (a loop-invariant rewrite rule) has been compiled and
   tested. Both are read-from-source designs.

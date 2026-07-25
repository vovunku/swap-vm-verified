# SwapVM formal semantics — plan

**Status: PLAN ONLY. No implementation has started.**

Deliberately separate from the verification work in `test/kontrol/`. Nothing here depends on
that work and nothing there depends on this. They meet at exactly one seam, Phase R.

---

## 0. The deliverable for THIS pass, and what it is worth

**Goal: a demonstrated program-level theorem about a real catalogue program, with every
assumption declared.** Not a verified VM. Not a discharged trust base.

**Phase R — proving the K rules against the deployed bytecode — is OUT OF SCOPE for this
pass.** There is not time, and pretending otherwise would produce a worse result than
admitting it. Every instruction rule therefore starts `ADMITTED`, and every theorem says so.

What the demonstrator does establish, which nothing today does:

- A theorem quantified over an **infinite family of programs** — every program sharing a
  given prefix — where the existing `test/invariants/` suite can only sample.
- A property of **composition and ordering**, which is where 1inch say the risk lives and
  which instruction-level verification cannot express at all.
- A reusable machine: adding the next program is writing a claim, not rebuilding anything.

What it does **not** establish, and must never be reported as:

- That the deployed bytecode at `0x8fdd04dbf6111437b44bbca99c28882434e0958f` has this
  property. That needs Phase R. Without it, the claim is *"the program has this property
  given that each instruction behaves as its rule says"*.

Both halves of that sentence go in any writeup. The failure mode this project has already
demonstrated is reporting a weaker result as a stronger one: six properties were carried for
weeks as real-code proofs when they were about a hand-written transcription.

---

## 1. Why

SwapVM executes *programs*: byte strings of `[opcode:1][argsLen:1][args]`, composed with
`ProgramBuilder.build`, signed off-chain, never deployed. The unit of risk is the program,
not a contract. 1inch's own `docs/PROGRAMS.md` says so:

> "Instruction ordering is security-critical. Reordering instructions can change pricing,
> settlement amounts, invalidation behavior, and external side effects."
>
> "Invariant requirements must hold for the full composed program: Symmetry, additivity
> profile, monotonicity, quote/swap consistency, balance sufficiency, and strategy liveness."
>
> "Thorough testing and audit are mandatory for every program before production use."

Per-program manual audit does not scale with a product whose premise is that anyone can
compose programs. The six named invariants are properties of *composition*, which
instruction-level verification cannot express even in principle.

**The case that proves it is already confirmed.** The `MinRate` bug — `AdjustMinRate` reads a
register from before `runLoop`, so settlement can end below the floor — is correct in
isolation and wrong when sequenced after anything that modifies `amountIn`. Note it needs
**no arithmetic at all** to state or detect: it is about which register is read when.

## 2. Why K rather than Rocq

A K definition is executable, so it can be differentially tested against the real VM using the
~94 invariant tests already in `test/invariants/`. Semantics drift becomes a failing test
instead of a silent lie. Refinement to bytecode is statable in the same framework, since KEVM
is a K semantics of EVM.

Rocq proves more comfortably, but a hand-written Rocq model would have no mechanised link to
the bytecode at `0x8fdd04dbf6111437b44bbca99c28882434e0958f`. This project's demonstrated
failure mode is exactly that kind of unchecked gap: six "proven" properties turned out to be
about a hand-written transcription rather than the deployed code.

Cost, stated honestly: K simplification rules are **trusted axioms unless separately proven**,
and SMT still discharges side conditions. What changes is that SMT stops being the proof
method and becomes a subroutine.

---

## 3. Design decisions

### D1 — Exact arithmetic first, abstraction only on evidence

Instruction rules compute the real arithmetic, including rounding direction. We do **not**
start with uninterpreted quote functions.

Rationale: **the arithmetic has never been cleanly measured.** Every stall observed in
`test/kontrol/` was contaminated — ~1930 steps of ABI/STATICCALL/`Context` plumbing before the
first guard branch, a prove profile that made literally zero progress on branchy goals, four
`lemmas.k` rules that could never fire because a general rule shadowed them, and orphaned
boosters holding two cores for 90 minutes. At the K level none of that exists. Assuming the
arithmetic is intractable would be inferring from a contaminated measurement.

### D2 — Arithmetic goes through a NAMED FUNCTION SYMBOL, always

This is what makes D1 safe to reverse. Even with an exact definition, never inline arithmetic
into a dispatch rule:

```k
    rule <k> #exec(XYCSWAP, ARGS) => .K ... </k>
         <amountIn> AIN </amountIn>
         <balanceIn> BIN </balanceIn> <balanceOut> BOUT </balanceOut>
         <amountOut> _ => xycQuote(AIN, BIN, BOUT) </amountOut>

    rule xycQuote(AIN, BIN, BOUT) => (AIN *Int BOUT) /Int (BIN +Int AIN)     // the DEFINITION
      requires BIN >Int 0 andBool BOUT >Int 0
```

**Weakening is then deleting the second rule and adding axioms about `xycQuote`** — a local,
one-line change per instruction rather than a restructuring. Structure for the retreat before
needing it.

### D3 — Abstraction trigger, decided in advance

Weaken instruction *I* to axioms when: a program-level proof that does not mention *I*'s
arithmetic in its conclusion fails to close within **30 minutes** on an idle box, and the
frontier term contains *I*'s arithmetic.

Stated in advance so it is a measurement, not a mood. Record every firing in
`semantics/axioms.md` with the proof that forced it.

### D4 — External effects are abstract

Token transfers, signature checks, Aqua settlement: abstracted to a `<status>` cell and an
event trace. Modelling ERC-20 balloons the effort and none of the six invariants needs it.

### D5 — Reverts are modelled, reasons are opaque

"Strategy liveness" is one of the six, so we must distinguish reverted from settled. The
revert *reason* is an opaque token — enough to state "reverts with `MinRateFailed`" without
modelling error encoding.

---

## 4. Configuration

Mirrors `src/libs/VM.sol` and the `Context` struct.

```k
configuration
  <swapvm>
    <k> $PGM:Bytes ~> #run </k>
    <program> .Bytes </program>          // SDK byte string, may be symbolic
    <pc> 0 </pc>                         // ctx.vm.nextPC
    <swap>
      <balanceIn> 0 </balanceIn>   <balanceOut> 0 </balanceOut>
      <amountIn>  0 </amountIn>    <amountOut>  0 </amountOut>
      <netPulled> 0 </netPulled>
    </swap>
    <query>
      <isExactIn> true </isExactIn>
      <tokenIn> 0 </tokenIn> <tokenOut> 0 </tokenOut> <taker> 0 </taker>
    </query>
    <invalidators> .Map </invalidators>
    <status> Running </status>           // Running | Reverted(Token) | Settled
    <trace> .List </trace>               // abstracted external effects
  </swapvm>
```

Fetch/decode/dispatch mirrors `VM.sol:118-150` exactly: `opcode = shr(248, word)`,
`argsLength = and(shr(240, word), 0xff)`, `pc += 2 + argsLength`, and the `pcs > length`
bound check that reverts with `RunLoopExceedProgramLength`.

---

## 5. Phases

### Phase 0 — decode loop and conformance harness

**The harness comes first.** Without it we cannot distinguish a correct semantics from a
plausible one, and every later phase is worthless.

Deliverables:
- `semantics/swapvm.md` — configuration and fetch/decode/dispatch. **No instruction rules.**
- `semantics/conformance/` — run a program through both engines, diff final registers.

**Acceptance:** a two-instruction program yields identical `<swap>` registers under `krun` and
under a Foundry test driving the real VM. Plus: a malformed program (args running past the
end) reverts in both.

### Phase 1 — three instructions, one theorem — **GO / NO-GO**

Target: `docs/PROGRAMS.md` §4 Example A.

```
OnlyTakerTokenBalanceNonZero(gateToken) ; StaticBalances([bIn,bOut]) ; LimitSwap(tIn,tOut)
```

**Theorem:** for any program whose first instruction is `OnlyTakerTokenBalanceNonZero(g)`, a
taker holding zero `g` cannot reach `<status> Settled`, **regardless of the remaining program
bytes**. Stated over a symbolic tail — that is what makes it worth more than the scenario
tests, which can only sample.

**Acceptance:** theorem proved over a symbolic tail, AND conformance passes on the concrete
instance.

**This is the go/no-go.** If the theorem will not close, or conformance disagrees, stop and
reconsider. Small enough to abandon cheaply.

### Phase 2 — a program family

Limit orders with invalidators (`docs/PROGRAMS.md` §1 Examples A and B). Theorems: no replay,
no overfill, deterministic partial-fill accounting — all named in the doc's own "Invariant
Focus" list, so the obligations are given rather than invented.

### Phase 3 — conditional flow

Best-route selection (§4 Example B; `test/RunLoop.t.sol:test_BestRouteSelector_XYC_vs_Pegged`).
Theorems: termination, and that the selected branch is the better-output branch. Their doc
flags branching as "hard to reason about and easy to misconfigure" — where scenario tests are
weakest and proof is worth most.

### Phase R — refinement — **OUT OF SCOPE for this pass**

Each K rule must denote its Solidity implementation. This is the `test/kontrol/` work
repositioned: not "XYCSwap rounds in the maker's favour" but "this rule equals this bytecode".

**Not attempted now.** Recorded here so the debt is visible and so the demonstrator's claims
are stated at their true strength. See §0 and the trust model in §5a.

**This is the only seam between the two halves of the repo, and it will rot if unmaintained.**
Mitigation: a table in `semantics/axioms.md` mapping each rule or axiom to the Kontrol proof
discharging it, with `UNDISCHARGED` written out where nothing does. Note that `lemmas.k`'s
`mul-div-lt-factor` — `(A *Int B) /Int (C +Int A) <Int B` — is already exactly the
`cannotDrainPool` axiom.

---

## 5a. Trust model

Every instruction rule is a claim about the deployed bytecode. Conformance testing is
**evidence on concrete inputs, not proof over all inputs** — a green conformance suite means
well-tested, still admitted. Three states, tracked per instruction in `semantics/axioms.md`:

| State | Meaning |
|---|---|
| `ADMITTED` | Asserted. No proof, no conformance coverage. **All rules start here.** |
| `TESTED` | Conformance exercises it on concrete programs. Evidence, not proof. |
| `PROVEN` | A Kontrol proof discharges it against the real bytecode. Phase R only. |

**Every theorem records its dependency set — the instructions it touches — and inherits the
weakest state among them.** So the repo can mechanically produce "the permissioned-swap
theorem holds, modulo `LimitSwap` being `TESTED`" instead of relying on someone remembering.
A theorem's status improves automatically as its dependencies do.

This is a smaller and more honest trust base than the status quo, which is worth stating
plainly: `test/kontrol/` currently rests on **68 simplification rules** — one with real firing
evidence, four dead for their entire life, none tracked — and yields no program-level results
at all. Eighteen enumerable, individually dischargeable claims is a strict improvement, even
while every one of them is admitted.

**Negative control.** Keep a small set of statements known to be FALSE and assert they fail to
prove. If a known-false statement ever closes, the rule set is inconsistent and every result
above it is void. This is the only cheap check for the failure mode that looks like total
success, and this project has already met its cousin twice — properties that passed because a
constructor-set value read as zero, and upper bounds satisfied by a function returning zero.

## 6. Standing rules

1. **No rule enters the semantics without a conformance test exercising it.** `lemmas.k` is
   the cautionary tale: 68 rules accumulated, one with real firing evidence, four dead for
   their entire life because a general rule shadowed them at equal priority.
2. **Every axiom is listed in `semantics/axioms.md` with a discharge status.** Undischarged is
   acceptable; undocumented is not.
3. **Abstraction only via the D3 trigger**, with the forcing measurement recorded.
4. **Nothing under `src/` is modified.** The contracts are deployed on twelve chains; a source
   edit changes the metadata hash and therefore the deployed bytecode.

## 7. Non-goals

- Not replacing `test/kontrol/`.
- Not modelling ERC-20, signatures, or Aqua settlement concretely.
- Not proving programs nobody runs — targets are the eight reference programs from the
  catalogue, which makers copy.

## 8. Risks

1. **Semantics drift** — mitigated by Phase 0 being first, and by rule 1.
2. **Trusted axioms** — the `lemmas.k` disease. Mitigated by rules 1-3.
3. **Exact arithmetic proves intractable at K level** — mitigated by D2, which makes the
   retreat a one-line change, and D3, which decides in advance when to take it.
4. **No third-party program corpus.** SwapVM is new and programs are signed off-chain, so
   nothing is deployed to audit. We verify reference programs *before* an ecosystem grows on
   them. A real weakness if the goal were auditing existing strategies.
5. **Version coupling.** The semantics is valid for one VM version. Living in-tree means it
   moves with the implementation automatically — the reason it is here rather than in a
   neighbouring repo behind a pinned submodule.

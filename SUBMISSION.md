# ETHGlobal submission — description field

Copy the block below. ~2,200 characters.

---

SwapVM makes a trading strategy **data** rather than a contract: a maker ships a bytecode program and the VM runs it. That's what makes auditing the VM insufficient — an audit covers the interpreter, but every program written afterwards is new attack surface with no audit at all, and there will be far more programs than instructions.

We wanted SwapVM itself to be as secure as possible, and to leave future builders leverage to secure their own composite programs. So the project is two parts.

**1 — Specs and proofs for SwapVM's instructions.** 281 properties across 13 instruction suites, run with Kontrol against the compiled bytecode rather than a model of it: argument-bound guards, rounding direction, overflow reachability, dead-code claims.

This turned up real defects. **13 confirmed bugs, each with an executable `forge test` reproducer** — a fee adjuster that inverts against the taker above a parameter threshold and bricks entirely above another, a min-rate instruction that doesn't enforce its floor, a non-terminating loop reachable from short arguments, an unguarded division by zero, and several arithmetic panics in the pegged-swap and concentrated-liquidity curves. They're written up in `test/kontrol/analysis/BUGS.md` with an evidence level, a criticality, and a reachability assessment each, because "found by a prover" isn't the same as "exploitable on chain" and we don't conflate the two.

**2 — A formal semantics you can build on.** A handwritten K semantics of the SwapVM interpreter — the full decode loop plus 20 of 52 opcodes — so a *program*, not just an instruction, can carry a machine-checked theorem. A builder writes a claim about their own bytes and discharges it with `kprove`.

The leverage is concrete: our gate theorem is proved with **the rest of the program left symbolic**, so it already holds for programs nobody has written yet. Put the gate first and the theorem comes with it. `dustproof/` is a worked example — a dust sweeper whose order builder can emit only the one shape the theorems cover.

Every theorem ships with a negative control that **must fail**: a proof that cannot fail proves nothing, and an inconsistent rule set proves everything while looking like success.

Reproduce it in 30 seconds: `VERIFY.md`. Browse it: https://vovunku.github.io/swap-vm-verified/

---

# "How it's made" / technology field

~1,900 characters.

---

The whole project runs on one stack: **Kontrol → KEVM → K**.

For the instruction layer, specs are written as Solidity property tests and proved with Kontrol (pinned to 1.0.255). Kontrol compiles the contract, lifts the **deployed bytecode** into KEVM — the K semantics of the EVM — and symbolically executes it, discharging side conditions to an SMT solver. Proving against bytecode rather than source puts the compiler *inside* the trust boundary: what we prove is what actually gets deployed.

Most of the engineering was making that terminate. Symbolic execution over 256-bit words with `bytes calldata` slicing hits walls that have nothing to do with how hard the property is. We ended up tuning the Booster backend's equation limits and fallback behaviour, raising `max-depth` and SMT timeouts per suite, and building a lemma library for byte-level reasoning. One lesson worth passing on: a proof leaf that is *terminal but not the target* is a **refutation**, not a closed branch — an off-the-shelf status reader that miscounts those turns real counterexamples into a green wall, so we wrote our own.

That's how the bugs surfaced: as counterexamples with path conditions, which we then replayed as executable `forge test` reproducers before calling anything confirmed. They'll be reported to the project's maintainers.

The second layer is where the stack choice pays off. The SwapVM interpreter's formal semantics is written **directly in K** — the same language KEVM is written in. So the same prover and the same claim syntax cover both levels: "this instruction's bytecode is correct" and "this composite program is correct" differ in what they quantify over, not in how they're written or checked. A builder who can read one can write the other.

Both layers run their negative controls through the same harness, and the runner exits non-zero if a control ever passes.

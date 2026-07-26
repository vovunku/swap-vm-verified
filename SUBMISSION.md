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

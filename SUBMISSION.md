# ETHGlobal submission

Two fields. Copy each block as-is.

---

# Description

In SwapVM a trading strategy is data rather than a contract: the maker ships a bytecode
program and the VM runs it. This means auditing the VM is not enough. An audit covers the
interpreter, but says nothing about the programs written afterwards, and there will be many
more programs than instructions.

We wanted SwapVM itself to be as secure as possible, and to give future builders something
they can use to secure their own composite programs. The project has two parts.

The first is specs and proofs for SwapVM's instructions: 281 properties across 13 instruction
suites, proved with Kontrol against the compiled bytecode rather than a model of it.
Argument bounds, rounding direction, overflow reachability, dead-branch claims.

This found real defects. 13 are confirmed, each with an executable forge test: a fee adjuster
that inverts against the taker past one parameter threshold and stops working past another, a
min-rate instruction that does not enforce its floor, a non-terminating loop reachable from
short arguments, an unguarded division by zero, and several arithmetic panics in the
pegged-swap and concentrated-liquidity curves. Each is written up in
test/kontrol/analysis/BUGS.md with an evidence level, a criticality, and an assessment of
whether it is reachable in production, since a prover finding something is not the same as it
being exploitable. We are reporting these to the maintainers.

The second part is a formal semantics of the SwapVM interpreter, written by hand in K: the
full decode loop and 20 of the 52 opcodes. It lets a whole program carry a proof, not just a
single instruction. You state a claim about your own bytes and discharge it with kprove.

The useful property is that our gate theorem — if you do not hold the gate token you cannot
fill the order — is proved with the rest of the program left symbolic. Not a set of tails we
enumerated, an unknown tail. So it already covers programs nobody has written yet: put the
gate first and the theorem carries over. dustproof/ is a worked example, a dust sweeper whose
order builder can only emit the one shape our theorems cover.

Every theorem has a negative control beside it that must fail. A proof that cannot fail says
nothing, and an inconsistent rule set proves everything while looking like a clean result.

Reproducible in about 30 seconds, see VERIFY.md. Or browse it:
https://vovunku.github.io/swap-vm-verified/

---

# How it's made

One stack throughout: Kontrol on top of KEVM on top of K.

For the instruction proofs, specs are written as Solidity property tests and given to Kontrol
(pinned at 1.0.255). It compiles the contract, lifts the deployed bytecode into KEVM — the K
semantics of the EVM — and symbolically executes it, sending side conditions to an SMT
solver. Working on bytecode rather than source puts the compiler inside the trust boundary,
so what is proved is what actually gets deployed.

Most of the effort went into making proofs terminate. Symbolic execution over 256-bit words
with bytes calldata slicing hits limits unrelated to the difficulty of the property. We tuned
the Booster backend's equation limits and fallback behaviour, raised max-depth and SMT
timeouts per suite, and built a lemma library for byte-level reasoning.

One detail worth knowing: a proof leaf that is terminal but not the target is a refutation, a
counterexample. A status reader that counts it as a closed branch will report a clean pass
over real bugs. We wrote our own reader after hitting this.

That is also how the bugs surfaced — as counterexamples with path conditions. None were
called confirmed until replayed as forge tests that fail.

The reason for the stack is the second part. We wrote the SwapVM semantics directly in K, the
same language KEVM is written in, so both levels share a prover and a way of stating claims.
"This instruction's bytecode is correct" and "this composite program is correct" differ in
what they quantify over, not in how they are written or checked.

Both parts run their negative controls through the same script, which exits non-zero if a
control ever passes.

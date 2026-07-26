# ETHGlobal submission

Two fields. Copy each block as-is.

---

# Description

In SwapVM a trading strategy is data rather than a contract: the maker ships a bytecode
program and the VM runs it. So auditing the VM is not enough. An audit covers the
interpreter, not the programs people write afterwards, and there will be many more programs
than instructions.

We wanted SwapVM itself as secure as possible, and something future builders can use to
secure their own composite programs. Two parts.

First, specs and proofs for SwapVM's instructions — 281 properties across 13 suites, proved
with Kontrol against the compiled bytecode rather than a model of it. This turned up 13
confirmed bugs, each with an executable forge test, written up with an evidence level and an
assessment of whether it is reachable in production. We are reporting them to the
maintainers.

Second, a formal semantics of the SwapVM interpreter, written by hand in K. It lets a whole
program carry a proof, not just a single instruction: you state a claim about your own bytes
and discharge it with kprove.

The useful part is that our gate theorem — if you do not hold the gate token you cannot fill
the order — is proved with the rest of the program left symbolic. Not a set of tails we
enumerated, an unknown tail. So it already covers programs nobody has written yet: put the
gate first and the theorem carries over. dustproof/ is a worked example, a dust sweeper whose
order builder can only emit the one shape our theorems cover.

Every theorem ships with a negative control that must fail, because a proof that cannot fail
says nothing.

https://vovunku.github.io/swap-vm-verified/

---

# How it's made

One stack throughout: Kontrol on top of KEVM on top of K.

For the instruction proofs, specs are written as Solidity property tests and given to Kontrol.
It compiles the contract, lifts the deployed bytecode into KEVM — the K semantics of the EVM —
and symbolically executes it, sending side conditions to an SMT solver. Working on bytecode
rather than source means what is proved is what actually gets deployed.

Most of the effort went into making proofs terminate: tuning the Booster backend's equation
limits and fallback, raising depth and SMT timeouts, and building a lemma library for
byte-level reasoning. The bugs surfaced here, as counterexamples with path conditions. We did
not call any of them confirmed until we had replayed them as forge tests that fail.

The second part is why the stack matters. We wrote the SwapVM semantics directly in K, the
same language KEVM is written in, so both levels share a prover and a way of stating claims.
"This instruction's bytecode is correct" and "this composite program is correct" differ in
what they quantify over, not in how they are written or checked.

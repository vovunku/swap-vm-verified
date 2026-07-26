# ETHGlobal submission

Two fields, written plainly. Copy each block as-is.

---

# Description

In SwapVM a trading strategy is data, not a contract. The maker ships a bytecode program and
the VM runs it. That's great for makers, but it means auditing the VM isn't enough. An audit
covers the interpreter. It says nothing about the programs people write next, and there are
going to be a lot more programs than there are instructions.

We wanted two things: SwapVM itself as secure as we could make it, and something future
builders can use to secure the programs they write on top of it. So the project has two
halves.

The first half is specs and proofs for SwapVM's own instructions. 281 properties over 13
instruction suites, proved with Kontrol against the compiled bytecode rather than a model of
it. Argument bounds, rounding direction, overflow reachability, claims that some branch is
actually dead.

We found real bugs doing this. 13 of them are confirmed, each with a forge test you can run.
A fee adjuster that flips the adjustment against the taker once a parameter goes over a
threshold, and bricks completely over a higher one. A min-rate instruction that doesn't
actually enforce its floor. A loop that never terminates if you hand it short arguments. An
unguarded division by zero. A few arithmetic panics in the pegged-swap and concentrated
liquidity curves. They're all written up in test/kontrol/analysis/BUGS.md with an evidence
level, a criticality, and an honest note on whether we think it's reachable in production,
because a prover finding something isn't the same as it being exploitable and we didn't want
to blur that. These are going to the maintainers.

The second half is a formal semantics of the SwapVM interpreter, written by hand in K. The
full decode loop plus 20 of the 52 opcodes. The point is that a whole program can carry a
proof, not just a single instruction. You write a claim about your own bytes and run kprove
on it.

Here's the part we're happiest with. Our gate theorem — "if you don't hold the gate token you
can't fill this order" — is proved with the rest of the program left symbolic. Not a list of
tails we checked, an unknown tail. So it already covers programs nobody has written yet. Put
the gate first and you get the theorem for free. dustproof/ is a worked example: a dust
sweeper whose order builder can only emit the one program shape our theorems cover.

Every theorem has a negative control next to it that has to fail. A proof that can't fail
isn't telling you anything, and if the rule set is inconsistent it'll prove literally
everything while looking like a clean sweep. The controls are the only thing that catches
that.

You can reproduce the whole thing in about 30 seconds: see VERIFY.md. Or just look at it:
https://vovunku.github.io/swap-vm-verified/

---

# How it's made

One stack the whole way down: Kontrol, on top of KEVM, on top of K.

For the instruction proofs we write the specs as Solidity property tests and hand them to
Kontrol (pinned at 1.0.255). It compiles the contract, lifts the deployed bytecode into KEVM,
which is the K semantics of the EVM, and symbolically executes that, sending the side
conditions to an SMT solver. Working on bytecode instead of source means the compiler is
inside what we're trusting, which we prefer — you end up proving things about what actually
gets deployed.

Honestly, most of our time went into getting proofs to finish at all. Symbolic execution over
256-bit words with bytes calldata slicing runs into walls that have nothing to do with whether
the property is hard. We tuned the Booster backend's equation limits and its fallback
behaviour, raised max-depth and SMT timeouts per suite, and built up a lemma library for
byte-level reasoning.

One thing we'd tell anyone starting this: a proof leaf that's terminal but isn't the target is
a refutation. It's a counterexample. If your status reader counts it as a closed branch you
get a beautiful green wall covering real bugs. We got burned by this and wrote our own reader.

That's also how the bugs came out — as counterexamples with path conditions. We didn't call
any of them confirmed until we'd replayed them as forge tests that actually fail.

The reason the stack matters is the second half. We wrote the SwapVM semantics directly in K,
the same language KEVM is written in. So both levels use the same prover and the same way of
writing a claim. "This instruction's bytecode is correct" and "this composite program is
correct" differ in what they quantify over, not in how you write them down or how you check
them. If you can read one you can write the other.

Both halves run their negative controls through the same script, and it exits non-zero if a
control ever passes.

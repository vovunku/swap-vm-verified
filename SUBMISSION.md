# ETHGlobal submission — description field

Copy the block below into the "Description" field.

---

SwapVM turns a trading strategy into **data** rather than a contract: a maker ships a bytecode program, and the VM executes it. That design is what makes it powerful — and it's also what makes auditing the VM insufficient. An audit covers the interpreter. Every composite program written *after* that audit is fresh attack surface shipping with no audit at all, and there will be orders of magnitude more programs than there are instructions.

So we treated the security problem as two layers, and built for both.

**Layer 1 — proving the instructions.** Specifications and proofs for SwapVM's own instruction implementations, run with Kontrol (symbolic execution by Runtime Verification) against the *compiled bytecode*, not against a model of it. 281 properties across 13 instruction suites: argument-bound guards, rounding direction, overflow reachability, and dead-code claims. Every result carries the evidence tier that produced it, and the ones still open are labelled open rather than quietly counted as passing.

**Layer 2 — making programs provable.** A handwritten K semantics of the SwapVM interpreter: the full decode loop plus 20 of the 52 named opcodes. This is the piece meant to outlive the hackathon. It lets a *program* — not just an instruction — carry a machine-checked theorem, so a builder composing a new strategy can write a claim about their own bytes and discharge it with `kprove`.

**Why layer 2 gives leverage rather than just more proofs.** Our gate theorem (T0: "anyone not holding the gate token cannot fill this order") is proved with the rest of the program left *symbolic* — an unknown tail, not an enumeration of tails. It therefore already holds for programs nobody has written yet. Put the gate first, and the theorem comes with it instead of being re-earned per strategy. No test suite can cover that set.

**A worked example, not just a framework.** `dustproof/` is a dust-sweeping product built on Aqua/SwapVM: a user sweeps several dust balances into ETH in one transaction. Its order program is composed by a builder that can emit only the one shape our theorems cover (gate → deadline → constant-product swap → salt), and that shape carries D1 — a proof that the quote is exactly the constant-product curve, for any reserves and any trade size. The sweeper contract batches via OpenZeppelin's `Multicall`, so there is no loop and therefore no loop invariant to prove, and it refuses to execute any order hash not marked verified on chain.

**Everything ships with a negative control.** Each theorem has a deliberately false twin that *must fail*. This is not decoration: a proof that cannot fail proves nothing, and an inconsistent rule set proves *everything* while looking like total success. Our runner exits non-zero if a control ever passes — a louder failure than the real theorem merely not proving.

**We state the edges rather than bury them.** 20 of 52 opcodes are modelled; anything else no-ops in the model while the real VM reverts, and where the two disagree a theorem about the model says nothing about production. The layer-2 theorems are marked ADMITTED rather than PROVEN, because the instruction rules they rest on are conformance-tested against the real VM rather than derived from it. All of it is tiered in `axioms.md` and reproducible from `VERIFY.md` — four theorems and two negative controls in about 30 seconds.

**Demo:** a static page showing each verified program alongside the Solidity it dispatches to, the builder that produces its bytes, the K specification that constrains it, what `kprove` actually returned, and what the real VM actually did. Every proof result on it is a recording of a real run, labelled as a replay with its timestamp and command — never dressed up as live.

https://vovunku.github.io/swap-vm-verified/

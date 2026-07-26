# `0x02` Salt — formal semantics

Design doc for `semantics/opcodes/salt.k`. Companion to `swapvm.md` (decode loop),
`opcodes/stop.md` and `opcodes/revert.md` (sibling opcodes), and the Phase 1 instruction notes
(`PHASE1.md`).

## Source

`Controls.sol:72-73`:

```solidity
/// @dev This instruction does nothing and can be used for uniqueness order hash value.
function _salt(Context memory /* ctx */, bytes calldata /* args */) internal pure { }
```

Both parameters are unnamed (`/* ctx */`, `/* args */`) and the body is empty. The function is
`pure`. It reads no register, writes no register, does not touch `nextPC`, and never reverts. At
execution time it is the identity on machine state.

The NatSpec is the whole story: "does nothing ... can be used for uniqueness order hash value".
The args bytes are part of the program, and the program is hashed off-chain to form the order's
identity (what the maker signs). Two programs that differ only in their Salt args are therefore
two distinct orders, even though both execute identically on chain.

## What the K rule does

The decode rule (`swapvm.md:143-149`) consumes the `[opcode:1][argsLen:1]` header and advances
`<pc>` by `2 + argsLen` **before** `#exec` fires. Salt does not overwrite `<pc>` (unlike Jump
and Stop), so the advanced value is inherited — the same posture as Revert.

```k
rule <k> #exec ( 2 , _ ) => .K ... </k>
     <status> Running </status>
```

The continuation `#run` is left in `<k>`. On the next step the loop decodes the instruction at
the advanced `<pc>`. Salt is therefore **not a halt**: unlike Stop (which writes a sentinel
`<pc>` so the loop-exit rule fires) and Revert (which clears the continuation via `#revert`),
Salt lets execution proceed. This is the single most important fact about the rule for proof
shape — see "Composition" below.

Salt ignores its args entirely (both source parameters are unnamed and unread), so the rule's
`ARGS` cell is a wildcard.

## D4 — the off-chain order hash is abstracted away

The *entire* on-chain effect of Salt is "none". Its value to the system lives off-chain: the
args bytes are folded into the program hash that anchors the order's identity and the maker's
signature. Per `PLAN.md` D4 (external effects are abstract), the K model does not represent the
order hash, signature, or any off-chain identity concern — the configuration in `swapvm.md` has
no cell for them, and no instruction rule reads them.

This is the cleanest possible D4 instance: the thing being abstracted is *literally* the only
thing the instruction is for. The on-chain VM never observes the salt's contribution; the K
model therefore has nothing to do but pass through. Recording this here means a future reviewer
asking "why does the Salt rule do nothing — is something missing?" finds the answer in the
source's own NatSpec and in D4, rather than suspecting an omission.

## Integration

`salt.k` defines a **sibling module `SWAPVM-SALT`** that imports `SWAPVM`, rather than reopening
`module SWAPVM`. K v7 (the toolchain in this repo, v7.1.337) rejects reopening a module across
files with `Module SWAPVM differs from previous declaration`. Two lines must be added to
`semantics/lemmas.k`:

1. `requires "opcodes/salt.k"` at the top (alongside the existing `requires "swapvm.md"` and the
   other opcode `requires`), so K parses the file and `SWAPVM-SALT` is available to import.
2. `imports SWAPVM-SALT` inside `module SWAPVM-BYTES-LEMMAS` (alongside the existing
   `imports SWAPVM` and the other opcode imports), so the Salt rule is in scope for every spec
   that imports `SWAPVM-BYTES-LEMMAS` (which is all of them).

A single `requires` alone is **not** sufficient: K does not auto-import the modules of a required
file into the main module. (See `opcodes/stop.md` "Integration" for the same constraint.) This
file uses `requires "../swapvm.md"` — resolving relative to its own directory — so it kompiles
correctly when invoked as `kompile ... lemmas.k` from `semantics/` without an `-I` flag.

## Fidelity gaps (declared per `PLAN.md` D3, D5)

- **Off-chain effect unmodelled (by design, D4).** The salt's contribution to the order hash is
  the instruction's sole purpose and is deliberately out of scope: the configuration has no cell
  for order identity, and no on-chain behaviour depends on it. This is not a gap to close; it is
  the abstraction boundary stated explicitly. Recorded here so it is not mistaken for an
  oversight.
- **`ADMITTED`.** Per the trust model in `PLAN.md` §5a, every instruction rule starts `ADMITTED`.
  This one is not yet exercised by the conformance harness.
- **No `Reverted` branch.** Salt never reverts — the Solidity has no `require`, no `revert`, no
  bounds check of its own. The rule therefore has a single arm. A false `Reverted` arm is the
  subject of `proofs/salt-control.k`, which is supposed to fail.

## Composition

Salt is **unlike** the gate (`proofs/gate-spec.k`), Stop (`proofs/stop-spec.k`), and Revert
(`proofs/revert-spec.k`) theorems in one decisive respect: those instructions HALT, so an
arbitrary symbolic tail is never decoded and can be abstracted away. Salt does not halt — it
leaves `#run` in `<k>`, and the loop proceeds to decode the byte at the advanced `<pc>`.

Consequence for proof shape: a claim of the form `b"\x02\x05" +Bytes SALT +Bytes TAIL` over an
arbitrary symbolic `TAIL` cannot terminate cleanly. After Salt fires at `<pc>` 0→7, the next
`#run` step tries to decode `PGM[7]`, which is `TAIL[0]` — symbolic, so no decode rule reduces,
and the prover gets stuck with a byte-identical residual. This is precisely the failure mode that
sank the first `negative-control.k` (`proofs/README.md:27-34`): a claim that is true fails with a
residual indistinguishable from a false claim's, because the prover cannot decode a symbolic
first byte.

The honest analogue of "the tail is irrelevant" for Salt is therefore **"the salt bytes are
irrelevant"**: `SALT` is symbolic, the rule matches it with a wildcard, and the conclusion does
not depend on its contents. `proofs/salt-spec.k` states exactly that, with the program
terminating at the post-decode `<pc>` because the salt is the whole program (no arbitrary tail).
The negative control `proofs/salt-control.k` is the sensitivity twin.

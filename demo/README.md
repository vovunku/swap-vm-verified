# SwapVM — compose &amp; verify (demo)

A SwapVM order *is* a bytecode program. This shows the permissioned-swap example as the
blocks it is made of, lets you edit it or build your own, and then tells you what can
actually be *proved* about what you built.

```bash
python3 demo/gen_data.py        # regenerate data from the repo (already committed)
python3 demo/server.py          # http://localhost:8000
python3 demo/selftest.py        # check the demo still matches the repository
```

Standard library only. No dependencies, no build step, no network.

## What Verify does

Three tiers. **It never shows a bare green check** — every result names the tier that
produced it and the assumptions it rests on. That is the point, not decoration: this
repository documents proofs that PASSED while proving nothing, and a proof that FAILED for a
reason unrelated to the bug it was testing. A verifier that hides its assumptions ships false
assurance, which is worse than shipping none.

| tier | what it does | cost |
|---|---|---|
| **PROVED** | Matches your program against theorems already discharged by `kprove` | instant |
| **LINT** | Re-runs the argument bounds `build()` enforces and `parse()` does not | instant |
| **DECODE** | Walks the bytes exactly as `VM.sol:118-150` does, including the bound check | instant |

### Why PROVED can answer instantly for a program you just invented

**T0 was proved over a symbolic tail.** The claim is: *for any program beginning with the
gate instruction — with everything after it left completely unknown — a taker holding none of
the gate token ends reverted.* So it covers programs nobody has written yet, including
whatever you build here. No prover runs at demo time; the proving already happened.

Move the gate out of first position and Verify says the theorem no longer applies, because it
genuinely does not. That discrimination is the feature.

### Why LINT is the interesting tier

Seven instructions validate their arguments in a `build()` helper and **not** in `parse()`.
Program bytes are maker-assembled and `parse()` is the only thing that runs on chain, so
those `require`s never execute. The bounds are already written down; they are simply in the
wrong place. Lint re-runs them against your composed bytes.

## Trusting this demo

`selftest.py` guards the three ways it could quietly start lying:

1. the composer reproduces the example **byte-for-byte** (`ProgramBytes.t.sol` pins that
   layout against real SDK output);
2. the decoder agrees with the conformance table on every case decided at decode level —
   those expectations are checked against both `krun` and the real `ContextLib.runLoop`;
3. the opcode table and coverage numbers match the enum and `DEMO.md`.

Data files are **generated** from `src/libs/OpcodeList.sol` and
`semantics/conformance/run.sh` rather than hand-written, because `c0d0bf1` records a
hand-typed constant with a nibble in the wrong position that every existing test passed over.

Writing the decoder surfaced the same defect the K semantics already had: the run loop
advances `pc` *before* its bound check, so a truncated program reverts reporting the
**advanced** value. The conformance case `argsOverrun` expects `pc=66`; the first version of
this decoder said `pc=0`. Fixed, and now pinned by the self-test.

## Honest limits

- **3 of 52 opcodes** are modelled by the K semantics. Anything else is a no-op in the model
  while the real VM reverts `UnknownOpcode` — Verify says so rather than staying quiet.
- **Nothing here executes on a chain.** Decode is static; the instruction-level guards
  (recompute detection, zero-balance rejection) are not simulated.
- **The instruction rules are conformance-TESTED, not proven.** Every theorem holds *given
  each instruction behaves as its rule says*. See `semantics/axioms.md`.
- The block palette covers the three instructions the example uses, not all 52.

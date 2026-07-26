# `0x04` Extruction — formal semantics

Design doc for `semantics/opcodes/extruction.k`. Companion to `swapvm.md` (decode loop),
`opcodes/stop.md`, `opcodes/revert.md`, `opcodes/salt.md`, `opcodes/jump.md` (sibling
opcodes), and the Phase 1 instruction notes (`PHASE1.md`).

This is the hardest opcode modelled so far, because it delegates to **arbitrary external
code**. The design decision recorded here is the load-bearing one for this file.

## Source

`src/instructions/Extruction.sol:90-115`:

```solidity
/// @param args.target         | 20 bytes
/// @param args.extructionArgs | N bytes
function _extruction(Context memory ctx, bytes calldata args) internal {
    address target = address(bytes20(args));
    uint256 choppedLength;

    if (ctx.vm.isStaticContext) {
        (ctx.vm.nextPC, choppedLength, ctx.swap) = IStaticExtruction(target).extruction(
            ctx.vm.isStaticContext, ctx.vm.nextPC, ctx.query, ctx.swap, args.slice(20), ctx.takerArgs()
        );
    } else {
        (ctx.vm.nextPC, choppedLength, ctx.swap) = IExtruction(target).extruction(
            ctx.vm.isStaticContext, ctx.vm.nextPC, ctx.query, ctx.swap, args.slice(20), ctx.takerArgs()
        );
    }
    bytes calldata chopped = ctx.tryChopTakerArgs(choppedLength);
    require(chopped.length == choppedLength, ExtructionChoppedExceededLength(chopped, choppedLength));
}
```

The target is `address(bytes20(args))` — a maker-chosen address. The return triple
overwrites three pieces of VM state: `ctx.vm.nextPC` (the program counter), `choppedLength`
(a cursor that `tryChopTakerArgs` then consumes from the taker args), and the **entirety**
of `ctx.swap` — `balanceIn`, `balanceOut`, `amountIn`, `amountOut`, `netPulled`. There is
no way to compute any of these concretely without modelling the target, which is impossible
in general because the target is arbitrary code at an arbitrary address.

The Solidity then runs a sanity check on the returned `choppedLength`:
`require(chopped.length == choppedLength, ExtructionChoppedExceededLength(chopped, choppedLength))`.
This is the only piece of *caller-side* logic that a sound model could in principle express
about the post-call state — and even that requires the unmodellable `choppedLength` as
input.

## The abstraction boundary (PLAN.md D4)

PLAN.md D4:

> External effects are abstract. Token transfers, signature checks, Aqua settlement:
> abstracted to a `<status>` cell and an event trace. Modelling ERC-20 balloons the effort
> and none of the six invariants needs it.

Extruction is the **direct, in-your-face instance** of D4. Unlike an ERC-20 transfer, where
the abstraction boundary is "we represent a transfer as a trace event and do not model the
token's storage", here the abstraction boundary is "we cannot even *name* the next
configuration, because the call's return values overwrite core VM registers". There is no
honest K term to write into `<pc>` or `<swap>` that does not pretend to know what the target
returned.

This is exactly the situation `swapvm.md:301-324, 330-346` warns about: a soundness gap that
can hide behind a passing proof if the model silently no-ops. The discipline there is
**loud, not silent** — the unmodellable surface reverts with an explicit reason rather than
falling through to the `[owise]` no-op. This file follows that discipline.

## Strategy: (A) revert with explicit reason

Two strategies were on the table.

**(A) Revert with explicit reason.** Model `#exec(4, ARGS)` as `#revert("ExtructionUnmodelled")`
for canonical-or-longer args (`lengthBytes(ARGS) >=Int 20`), and
`#revert("UNMODELLED-ARGS-LENGTH")` for sub-canonical args. Any program containing an
Extruction then fails to prove anything except that it reverts.

**(B) Nondeterministic abstract effect + structural check.** Introduce fresh symbolic
variables for the call's return triple, write them into `<pc>` and `<swap>`, and model the
`ExtructionChoppedExceededLength` `require` as a side condition. This would let us state and
prove *structural* theorems ("if the external call respects the chop contract, execution
continues; otherwise it reverts with `ExtructionChoppedExceededLength`").

**Chosen: (A)**, the conservative match for how the rest of `swapvm.md` treats unmodellable
surface (the `UNMODELLED-ARGS-LENGTH` rules at 319-324 and the unknown-opcode admission at
330-346). The decisive reasons:

1. **Honest default.** The real VM's behaviour here depends on code we cannot see. Asserting
   "it reverts in the model" is a strictly weaker claim than asserting "it does anything
   specific", and it is the only strictly weaker claim that cannot misrepresent the deployed
   behaviour. A theorem that wants to ignore the tail (like the Phase 1 gate) still holds
   because `#revert` discards the continuation — exactly the property the gate relies on.

2. **Composition with the gate theorem.** The Phase 1 gate theorem (`proofs/gate-spec.k`)
   works because `#revert(MSG) ~> _ => .K` clears the continuation. Strategy (A) inherits
   the same composition for free: a program whose prefix is `gate ; Extruction ; ...` still
   reverts at the gate; a program whose prefix is `Extruction ; gate ; ...` reverts at the
   Extruction in the model (a strict over-approximation of failure — sound). Under strategy
   (B) we would carry the symbolic `<swap>` cell forward into the gate rule's balance
   consult, which would in turn force the gate premises to range over a strictly larger
   state space — a non-trivial change to a theorem that already closed.

3. **(B)'s risk of vacuity.** Per `proofs/README.md:30-43`, every premise in a proof must
   be load-bearing — a control that fails for the wrong reason tells you nothing. Strategy
   (B) requires a sensitivity twin *of its own* to be worth anything, because the symbolic
   cells make it easy to state a structural theorem that closes vacuously. The twin would
   have to be designed, proved, and maintained. The cost is not justified for Phase 1, where
   no theorem yet needs a positive claim about an Extruction-containing program.

The cost of (A) — that we cannot prove anything *positive* about a program that legitimately
uses Extruction — is real and is the **declared fidelity gap** below. It is a smaller cost
than the alternative (a model that pretends to know what the call returned), and it matches
the project's stated posture in PLAN.md §0: "Every instruction rule therefore starts
`ADMITTED`, and every theorem says so."

Strategy (B) is recorded in `semantics/OPCODE-BACKLOG.md` as future work.

## What the K rule does

The decode rule (`swapvm.md:143-149`) consumes the `[opcode:1][argsLen:1]` header and
advances `<pc>` by `2 + argsLen` before `#exec` fires. Extruction does not read `<pc>`
beyond that and produces `#revert`, which clears the continuation (`swapvm.md:154-156`) — so
the post-decode `<pc>` value is the final one. This is the same posture as Revert
(`opcodes/revert.k`): no `<pc>` write, the rule inherits the decode-advanced value.

```k
rule <k> #exec ( 4 , ARGS ) => #revert("ExtructionUnmodelled") ... </k>
     <status> Running </status>
  requires lengthBytes(ARGS) >=Int 20

rule <k> #exec ( 4 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
  requires lengthBytes(ARGS) <Int 20
```

`#revert("ExtructionUnmodelled") ~> _ => .K` (swapvm.md:154-156) then sets `<status>
Reverted("ExtructionUnmodelled")` and clears the continuation. The loop never resumes. A
program containing an Extruction therefore ends `Reverted("ExtructionUnmodelled")` in the
model — a sound over-approximation of the real VM, which may or may not revert depending on
the target.

## The canonical guard is `>=Int 20`, not `==Int 20`

The Solidity constrains nothing about `args.length`. `address(bytes20(args))` right-zero-pads
a short `args` and silently truncates a long one — there is no revert for any length. So:

- **`lengthBytes(ARGS) < 20`** — the unsafe pad-and-truncate case. A 19-byte args reads a
  *different* address than the maker's bytes literally encode (the high byte becomes 0).
  This is the same hazard documented at `swapvm.md:301-324` for opcodes `0x23` and `0x90`,
  and is reverted loudly with `"UNMODELLED-ARGS-LENGTH"` — the same reason, for the same
  reason: a proof touching such an Extruction should fail rather than succeed on a fiction.
- **`lengthBytes(ARGS) >= 20`** — the address read is faithful to the first 20 bytes of
  `args`. The remaining concern is no longer the address; it is that the external call
  itself is unmodellable. This arm reverts with the distinct reason `"ExtructionUnmodelled"`
  so a proof can distinguish "the args were malformed" from "the args were fine and the call
  is the unmodellable part".

`==Int 20` would be wrong here in a way it is *not* wrong for Jump (`opcodes/jump.k`):
Solidity's `address(bytes20(args))` does **not** constrain the input to 20 bytes the way
`uint16(bytes2(args))` constrains it to 2. For Extruction, an `args.length` of 21 or 100 is
legal on chain (only the first 20 are read as the target; the rest are passed to the
external contract as `extructionArgs`). Treating those lengths as unmodelled would silently
delete Extruction from any program whose args packing happens to include the
`extructionArgs` tail — exactly the silent-deletion failure mode `swapvm.md:307-316` warns
about.

## Static vs non-static

The Solidity selects `IStaticExtruction` (view) when `ctx.vm.isStaticContext` is true and
`IExtruction` otherwise. The interface choice constrains what the *target* may do — a
static-call cannot mutate state — but both interfaces return the **same shape** of triple
`(nextPC, choppedLength, swap)`. Since the K rule below models neither branch concretely (it
reverts unconditionally), the static/non-static distinction is not observable in the model.
Recording the elision here so it is not mistaken for an oversight.

Should strategy (B) ever be adopted, the static/non-static distinction would still be
uninteresting at the K level unless the model also tracks whether the surrounding execution
is a quote (read-only) or a swap (stateful) — which the current configuration does not
(`swapvm.md` has no `<isStaticContext>` cell). Adding one would be Phase 2+ work.

## Integration

`extruction.k` defines a **sibling module `SWAPVM-EXTRUCTION`** that imports `SWAPVM`,
rather than reopening `module SWAPVM`. K v7 (the toolchain in this repo, v7.1.337) rejects
reopening a module across files with `Module SWAPVM differs from previous declaration`; this
is the same constraint that shaped `stop.k`, `revert.k`, `salt.k`, and `jump.k`. Two lines
must be added to `semantics/lemmas.k`:

1. `requires "opcodes/extruction.k"` at the top (alongside the existing
   `requires "swapvm.md"` and the other opcode `requires`), so K parses the file and
   `SWAPVM-EXTRUCTION` is available to import.
2. `imports SWAPVM-EXTRUCTION` inside `module SWAPVM-BYTES-LEMMAS` (alongside the existing
   `imports SWAPVM` and the other opcode imports), so the Extruction rules are in scope for
   every spec that imports `SWAPVM-BYTES-LEMMAS` (which is all of them).

A single `requires` alone is **not** sufficient: K does not auto-import the modules of a
required file into the main module. (See `opcodes/jump.md` "Integration" and
`opcodes/stop.md` "Integration" for the same constraint.) This file uses
`requires "../swapvm.md"` — resolving relative to its own directory — so it kompiles
correctly when invoked as `kompile ... lemmas.k` from `semantics/` without an `-I` flag.

## Fidelity gaps (declared per `PLAN.md` D3, D4, D5)

These are the elisions a reviewer needs to see written out, not inferred. Recording them
here so they are not mistaken for oversights.

- **The external call is unmodelled (D4).** This is the headline gap. The real VM delegates
  to a maker-chosen contract whose return values overwrite `nextPC`, `choppedLength`, and
  the entire `<swap>` cell. The K model reverts unconditionally with
  `"ExtructionUnmodelled"`. **Consequence:** any theorem whose program contains an
  Extruction can only conclude that the program reverts in the model; it can say nothing
  about what the program does on chain if the target returns normally. This is the safe
  direction to be wrong in (sound over-approximation of failure), per `swapvm.md:314-316`.
- **`ExtructionChoppedExceededLength` is unmodelled.** The Solidity's
  `require(chopped.length == choppedLength, ...)` is caller-side logic that depends on the
  unmodellable `choppedLength`. It is therefore not expressible under strategy (A). Under
  strategy (B) it would be a side condition on the symbolic `choppedLength`; recorded as
  future work.
- **Sub-canonical args unmodelled.** Solidity right-pads short `args` and truncates long
  ones without reverting; the model reverts with `"UNMODELLED-ARGS-LENGTH"` for any
  `args.length < 20`. (Note: `>= 20` IS modelled — see "The canonical guard is `>=Int 20`"
  above. Only the sub-canonical case reverts as malformed.) This makes the gap loud rather
  than silent (`swapvm.md:314-316`), in the same safe direction chosen for opcodes `0x23`,
  `0x90`, and `0x03`.
- **Static vs non-static branch elided.** See "Static vs non-static" above. Not observable
  at the abstraction level of this model.
- **Quote payload opaque.** Like every other revert in this system (`PLAN.md` D5), the K
  reason is an opaque string token. The real VM carries no error payload for
  `"ExtructionUnmodelled"` (it is the model's invention, not a Solidity revert), and for
  `"UNMODELLED-ARGS-LENGTH"` it carries none either. The token is enough to state
  "reverts with `ExtructionUnmodelled`" without modelling ABI error encoding.
- **`ADMITTED`.** Per the trust model in `PLAN.md` §5a, every instruction rule starts
  `ADMITTED`. This one is not yet exercised by the conformance harness.

## Composition

Extruction HALTS in the model — `#revert` clears the continuation (`swapvm.md:154-156`) —
so it composes like Stop, Revert, and the Phase 1 gate, and *unlike* Salt and Jump (which
leave `#run` in `<k>` and let the loop proceed). The positive spec
`proofs/extruction-spec.k` therefore quantifies over an arbitrary symbolic `TAIL` exactly as
`gate-spec.k` and `revert-spec.k` do: `TAIL` is never decoded because the Extruction
instruction reverts before the loop resumes.

The negative control `proofs/extruction-control.k` asserts that the same program ends
`Running` — which is false in the model because Extruction reverts unconditionally. It must
fail. The sensitivity twin is `extruction-spec.k` itself: same premises, correct conclusion
(`Reverted("ExtructionUnmodelled")`), which must prove. Together they show `kprove` is
discriminating on the conclusion rather than choking on the setup, per
`proofs/README.md:30-43`.

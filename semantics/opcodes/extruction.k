requires "../swapvm.md"

// 0x04 Extruction — Extruction.sol:90-115.
//
// Adds the Extruction rule to the SWAPVM semantics. K v7 does not allow reopening
// `module SWAPVM` across files (it reports "Module SWAPVM differs from previous
// declaration"), so this file defines a sibling module SWAPVM-EXTRUCTION that imports
// SWAPVM and adds the rule. Integration is via `requires "opcodes/extruction.k"` plus
// `imports SWAPVM-EXTRUCTION` from the main module (semantics/lemmas.k) — see
// extruction.md "Integration".
//
// WHY THIS RULE REVERTS, NOT NO-OPS — the abstraction boundary (PLAN.md D4).
//
// The Solidity delegates to a maker-chosen external contract:
//
//   (ctx.vm.nextPC, choppedLength, ctx.swap) = I{Static,}Extruction(target).extruction(
//       ctx.vm.isStaticContext, ctx.vm.nextPC, ctx.query, ctx.swap,
//       args.slice(20), ctx.takerArgs());
//
// `target` is `address(bytes20(args))` — an arbitrary address the maker picks. The return
// triple overwrites three pieces of VM state: `<pc>` (via nextPC), the chop cursor (via
// choppedLength, which `tryChopTakerArgs` then consumes), and the ENTIRE `<swap>` cell
// (balanceIn, balanceOut, amountIn, amountOut, netPulled). Modelling this soundly would
// require modelling the target contract, which is impossible in general: the target is
// arbitrary code at an arbitrary address. This is exactly the abstraction-boundary case
// PLAN.md D4 names ("the abstraction boundary for external effects").
//
// Two strategies were considered (see extruction.md "Strategy" for the full trade-off):
//
//   (A) Revert with an explicit reason. Honest: any program containing an Extruction
//       fails to prove anything except that it reverts. Composes correctly with the gate
//       theorem because #revert discards the continuation.
//   (B) Nondeterministic abstract effect: fresh symbolic cells for the return triple, the
//       ExtructionChoppedExceededLength require modelled as a side condition. More
//       machinery and a real risk of vacuous proofs unless every premise is load-bearing.
//
// Chosen: (A), the conservative match for how swapvm.md:301-324 and 330-346 already treat
// unmodellable surface (loud revert, not silent no-op). (B) is recorded as future work in
// extruction.md.
//
// THE CANONICAL GUARD IS `>=Int 20`, NOT `==Int 20`.
//
// Solidity's `address(bytes20(args))` right-zero-pads short args and silently truncates
// long ones — there is NO revert for any length. The unsafe case is `< 20` (a short args
// silently reads a *different* address, the same pad-and-truncate hazard documented for
// opcodes 0x23/0x90/0x03 at swapvm.md:301-324). For `>= 20` the address read is faithful
// to the first 20 bytes of args — the issue is no longer the address, it is that the
// external call itself is unmodellable, which is why this arm reverts with the distinct
// reason "ExtructionUnmodelled". The `< 20` arm reverts with the same
// "UNMODELLED-ARGS-LENGTH" reason as the other pad-and-truncate hazards, so a proof
// touching such an Extruction fails rather than succeeds on a fiction.
//
// STATIC vs NON-STATIC BRANCH. The Solidity selects IStaticExtruction (view) when
// `isStaticContext` is true and IExtruction otherwise. The choice of interface constrains
// what the *target* may do, not what the caller observes: both branches return the same
// shape `(nextPC, choppedLength, swap)`. Since the rule below models neither branch
// concretely — it reverts unconditionally — the static/non-static distinction is not
// observable in the K model. Recording the elision here so it is not mistaken for an
// oversight; see extruction.md "Static vs non-static".

module SWAPVM-EXTRUCTION
  imports SWAPVM

  // Canonical-or-longer args (>= 20 bytes): the address read is faithful, but the external
  // call itself cannot be modelled (PLAN.md D4). Revert loudly with a reason distinct from
  // the pad-and-truncate hazard below. The `Running` side condition guards against
  // Extruction firing after a prior Revert, matching the loop rule's own guard
  // (swapvm.md:103) and the analogous guard on the Stop, Revert, Salt, and Jump rules.
  // The [owise] unknown-opcode rule (swapvm.md:349-351) is overridden by this more
  // specific rule regardless of which module each lives in: owise rules have lower
  // priority than concrete rules across the whole imported closure.
  rule <k> #exec ( 4 , ARGS ) => #revert("ExtructionUnmodelled") ... </k>
       <status> Running </status>
    requires lengthBytes(ARGS) >=Int 20

  // Sub-canonical args (< 20 bytes): Solidity right-zero-pads, so the target address is
  // silently different from what the maker's bytes literally encode — the same
  // pad-and-truncate soundness hazard documented at swapvm.md:301-324 for opcodes 0x23
  // and 0x90. Revert loudly here so a proof cannot silently succeed on an unmodelled
  // length. Mirrors the analogous rule for Jump in opcodes/jump.k.
  rule <k> #exec ( 4 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
    requires lengthBytes(ARGS) <Int 20
endmodule

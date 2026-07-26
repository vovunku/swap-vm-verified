requires "../swapvm.md"

// 0x00 Stop — Controls.sol:89-93.
//
// Adds the Stop rule to the SWAPVM semantics. K v7 does not allow reopening `module SWAPVM`
// across files (it reports "Module SWAPVM differs from previous declaration"), so this file
// defines a sibling module SWAPVM-STOP that imports SWAPVM and adds the rule. Integration is
// via `requires "opcodes/stop.k"` plus `imports SWAPVM-STOP` from the main module
// (semantics/lemmas.k) — see stop.md "Integration".
//
// The decode rule in swapvm.md has already consumed the [opcode:1][argsLen:1] header and
// advanced <pc> before #exec fires, exactly mirroring `pcs := add(pcs, 2); ... pcs :=
// add(pcs, argsLength)` in VM.sol:133-138. So this rule inherits the advanced <pc> and
// overwrites it.
//
// The Solidity sets ctx.vm.nextPC = type(uint256).max = 2^256 - 1, and runLoop's
// `while (pcs < length)` then falls through: execution ends with status Running — not
// Reverted, not Settled. The post-loop return (VM.sol:150) is modelled as the loop-exit
// rule (swapvm.md:100-105) clearing <k>.

module SWAPVM-STOP
  imports SWAPVM

  // NOTE: an earlier version of this rule wrote <pc> to a `#stopSentinel()` (= 2^256) and
  // relied on the loop-exit rule firing on the next step. That stalled the prover on
  // giant-constant arithmetic; see the comment on the rule below. The sentinel syntax is
  // retained for documentation but no longer used by the rule.

  // Stop ignores its args entirely (Controls.sol:90 declares the parameter and reads
  // nothing) and reads no registers. The `Running` side condition guards against Stop firing
  // after a prior Reverted, matching the loop rule's own guard (swapvm.md:103). The [owise]
  // unknown-opcode rule (swapvm.md:349-351) is overridden by this more specific rule
  // regardless of which module each lives in: owise rules have lower priority than concrete
  // rules across the whole imported closure.
  //
  // The rule clears the whole continuation (`~> _ => .K`), mirroring exactly what `#revert`
  // does (swapvm.md:154-156). Why: Solidity sets nextPC = type(uint256).max and lets runLoop's
  // `while (pcs < length)` fall through on the NEXT iteration. The obvious K analogue would
  // write a sentinel pc (2^256) and let the loop-exit rule (swapvm.md:100-105) fire next step
  // — but with a symbolic program length, that forces the prover to discharge every other
  // decode rule's side conditions against `2^256 +Int ...`, which explodes into 24+ unexplored
  // branches and stalls (observed). Clearing <k> directly is the observationally-equivalent
  // shortcut: the on-chain effect of "loop exits, status stays Running" is captured in one
  // step. <pc> is left at the post-decode value (2 for argsLen 0), exactly as the Revert twin
  // leaves it — see opcodes/revert.k and proofs/revert-spec.k:28. The Solidity max-pc value is
  // an implementation detail unobservable to any proof that doesn't pin the exact pc word,
  // and is documented in stop.md as a fidelity nuance rather than modelled literally.
  rule <k> #exec ( 0 , _ ) ~> _ => .K </k>
       <status> Running </status>
endmodule

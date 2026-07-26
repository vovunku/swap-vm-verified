requires "../swapvm.md"

// 0x01 Revert — Controls.sol:84-87.
//
// Adds the Revert rule to the SWAPVM semantics. K v7 does not allow reopening `module SWAPVM`
// across files (it reports "Module SWAPVM differs from previous declaration"), so this file
// defines a sibling module SWAPVM-REVERT that imports SWAPVM and adds the rule. Integration is
// via `requires "opcodes/revert.k"` plus `imports SWAPVM-REVERT` from the main module
// (semantics/lemmas.k) — see revert.md "Integration".
//
// The decode rule in swapvm.md has already consumed the [opcode:1][argsLen:1] header and
// advanced <pc> before #exec fires, exactly mirroring `pcs := add(pcs, 2); ... pcs :=
// add(pcs, argsLength)` in VM.sol:133-138. Revert does not read or write <pc> beyond that, so
// this rule inherits the advanced value and leaves it.
//
// The Solidity source is `revert InstructionRevert(args);` (Controls.sol:86) where
// `error InstructionRevert(bytes);` is declared at Controls.sol:65. Unlike the other reverts
// in this system (e.g. TakerTokenBalanceIsZero), the payload is the maker-supplied `args`
// bytes -- an opaque reason the maker chooses. Per PLAN.md D5 the reason in the K model is an
// opaque token; this rule collapses every distinct payload to the single token
// "InstructionRevert". The fidelity gap -- the real VM's revert data carries the args bytes,
// K's does not -- is recorded in revert.md "Fidelity gaps".

module SWAPVM-REVERT
  imports SWAPVM

  // Revert is unconditional. It reads no register, writes no register except <status>, and
  // ignores its args entirely (the args are carried as the error payload, not consulted).
  // #revert(MSG) ~> _ => .K (swapvm.md:154-156) clears the continuation and sets
  // <status> Reverted(MSG), so the loop never resumes.
  //
  // The `Running` side condition guards against Revert firing after a prior Revert, matching
  // the loop rule's own guard (swapvm.md:103) and the analogous guard on the Stop rule
  // (opcodes/stop.k). The [owise] unknown-opcode rule (swapvm.md:349-351) is overridden by
  // this more specific rule regardless of which module each lives in: owise rules have lower
  // priority than concrete rules across the whole imported closure.
  rule <k> #exec ( 1 , _ ) => #revert("InstructionRevert") ... </k>
       <status> Running </status>
endmodule

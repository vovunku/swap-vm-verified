requires "../swapvm.md"

// 0x02 Salt — Controls.sol:72-73.
//
// Adds the Salt rule to the SWAPVM semantics. K v7 does not allow reopening `module SWAPVM`
// across files (it reports "Module SWAPVM differs from previous declaration"), so this file
// defines a sibling module SWAPVM-SALT that imports SWAPVM and adds the rule. Integration is
// via `requires "opcodes/salt.k"` plus `imports SWAPVM-SALT` from the main module
// (semantics/lemmas.k) — see salt.md "Integration".
//
// The decode rule in swapvm.md has already consumed the [opcode:1][argsLen:1] header and
// advanced <pc> by `2 + argsLen` before #exec fires, exactly mirroring `pcs := add(pcs, 2);
// ... pcs := add(pcs, argsLength)` in VM.sol:133-138. Salt does not read or write <pc> beyond
// that, so this rule inherits the advanced value and leaves it — the same posture as Revert.
//
// The Solidity source is an empty function body: `function _salt(Context memory, bytes
// calldata) internal pure { }` (Controls.sol:72-73). It touches nothing at execution time. Its
// purpose is off-chain: the args bytes are folded into the order hash (the maker's signature
// covers them), so two orders that differ only in their salt args are distinct orders. That
// contribution to the order's identity is an abstraction-boundary concern (PLAN.md D4): the
// on-chain VM never observes the order hash, so the K model has nothing to represent for it.
// At execution time Salt is a pure no-op.

module SWAPVM-SALT
  imports SWAPVM

  // Salt ignores its args entirely (Controls.sol:73 declares both parameters unnamed and reads
  // neither) and reads no register, writes no register, and does not overwrite <pc>. The
  // continuation #run is left in <k>, so the loop proceeds to decode the next instruction —
  // Salt is NOT a halt, unlike Stop (which sets a sentinel pc) and Revert (which clears the
  // continuation). This is the decisive semantic difference for the spec shape: an arbitrary
  // symbolic tail CANNOT be abstracted away the way the gate/stop/revert theorems do, because
  // execution continues into it. See salt.md "Composition".
  //
  // The `Running` side condition guards against Salt firing after a prior Revert, matching the
  // loop rule's own guard (swapvm.md:103) and the analogous guard on the Stop and Revert rules.
  // The [owise] unknown-opcode rule (swapvm.md:349-351) is overridden by this more specific
  // rule regardless of which module each lives in: owise rules have lower priority than concrete
  // rules across the whole imported closure.
  rule <k> #exec ( 2 , _ ) => .K ... </k>
       <status> Running </status>
endmodule

requires "../swapvm.md"

// 0x03 Jump — Controls.sol:75-82.
//
// Adds the Jump rule to the SWAPVM semantics. K v7 does not allow reopening `module SWAPVM`
// across files (it reports "Module SWAPVM differs from previous declaration"), so this file
// defines a sibling module SWAPVM-JUMP that imports SWAPVM and adds the rule. Integration is
// via `requires "opcodes/jump.k"` plus `imports SWAPVM-JUMP` from the main module
// (semantics/lemmas.k) — see jump.md "Integration".
//
// The decode rule in swapvm.md (143-149) has already consumed the [opcode:1][argsLen:1] header
// and advanced <pc> by `2 + argsLen` BEFORE #exec fires, exactly mirroring `pcs := add(pcs, 2);
// ... pcs := add(pcs, argsLength)` in VM.sol:133-138. Jump OVERWRITES that already-advanced
// value: swapvm.md:138-140 explains this directly — it is the K analogue of `ctx.vm.nextPC =
// pcs; ... ; pcs = ctx.vm.nextPC` in the Solidity (the read-back after dispatch lets a Jump
// instruction override the advance). So the rule's `<pc> _ => ...` discards whatever the decode
// loop wrote. This is the single most important semantic fact about the rule, and the
// difference between a correct Jump and a no-op.
//
// The Solidity reads `uint16(bytes2(args))`, i.e. the first 2 bytes of `args` as a big-endian
// uint16, truncated to 16 bits. The model uses `Bytes2Int(substrBytes(ARGS, 0, 2), BE,
// Unsigned)` — on a 2-byte slice this yields exactly the value in [0, 65535] for any
// canonical-length ARGS, so the truncation is automatic and exact. No separate `modInt 65536`
// is needed for the modelled case.
//
// PAD-AND-TRUNCATE SOUNDNESS HAZARD (swapvm.md:301-324). The Solidity constrains nothing: a
// short `args` is right-zero-padded (so `b"\x03\x01\xab"` with argsLen 1 reads `\xab\x00` and
// jumps to `0xab00`, not `0xab`), and a long `args` is silently truncated to the first 2 bytes.
// There is NO revert for a wrong length. Modelling only the canonical-length case and letting
// the others fall through to the `[owise]` no-op (swapvm.md:349-351) would SILENTLY DELETE jumps
// from the model — the worst failure direction, sound but wrong. The mitigation follows the
// pattern at swapvm.md:319-324 for opcodes 0x23 and 0x90: non-canonical lengths revert loudly
// with `"UNMODELLED-ARGS-LENGTH"`, so a proof touching such a Jump fails rather than succeeds
// on a fiction.

module SWAPVM-JUMP
  imports SWAPVM

  // Canonical 2-byte Jump. Overwrites the decode-advanced <pc> with the big-endian uint16 read
  // from ARGS[0:2]. The `Running` side condition guards against Jump firing after a prior
  // Revert, matching the loop rule's own guard (swapvm.md:103) and the analogous guard on the
  // Stop, Revert, and Salt rules. The [owise] unknown-opcode rule (swapvm.md:349-351) is
  // overridden by this more specific rule regardless of which module each lives in: owise rules
  // have lower priority than concrete rules across the whole imported closure.
  rule <k> #exec ( 3 , ARGS ) => .K ... </k>
       <pc> _ => Bytes2Int(substrBytes(ARGS, 0, 2), BE, Unsigned) </pc>
       <status> Running </status>
    requires lengthBytes(ARGS) ==Int 2

  // Non-canonical args: Solidity right-pads short and truncates long without reverting, which is
  // a soundness hazard (swapvm.md:301-324). Revert loudly here so a proof cannot silently
  // succeed on an unmodelled length. Mirrors opcodes 0x23 / 0x90 in swapvm.md:319-324.
  rule <k> #exec ( 3 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
    requires lengthBytes(ARGS) =/=Int 2
endmodule

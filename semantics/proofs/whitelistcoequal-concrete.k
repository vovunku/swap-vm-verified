// Concrete-input conformance claims for the 0x2c (WhitelistCoequal) opcode.
//
// This file replaces the former `whitelistcoequal-spec.k` (a symbolic universal claim) and
// `whitelistcoequal-control.k` (its sensitivity twin). Both were TAUTOLOGICAL under the prior
// uninterpreted-predicate form: the spec asserted `#coequalWhitelistContains(ARGS, PACKED)` as
// a premise and the rule branched on the same predicate, so the proof established nothing
// about whether the underlying `while (i-- > 0)` loop matched Solidity, and krun could not
// reduce the predicate either — i.e. zero conformance evidence. See whitelists.md "What the
// K rules do" for the full rationale of the switch.
//
// The recursive `#coequalContains(LIST, PACKED)` function in `opcodes/whitelists.k` now models
// the Solidity loop directly:
//   sender = uint80(uint160(taker)) = TAKER modInt 2^80
//   list   = ARGS[2:]                                  // post-header slice
//   for each 10-byte entry e in list (high-index first):
//       if (sender == e) JUMP;
//   FALL THROUGH.
// On CONCRETE lists the recursion reduces to a concrete Bool via the bytes lemmas in
// semantics/lemmas.k (lines 16-67: `lengthBytes`, `substrBytes`, and the `Int2Bytes`/
// `Bytes2Int` round-trip), so the rule arm fires for the right reason. On SYMBOLIC lists
// neither rule's `requires` clause reduces, so the function is STUCK — no false symbolic
// claim is admitted. This is the same posture as gte-concrete.k: concrete claims are the
// conformance evidence; symbolic claims are honestly stuck rather than wrong.
//
// Each claim runs a FULLY CONCRETE program through `#run` and asserts the exact final `<pc>`
// and `<status>`. A concrete claim that proves under kprove is the operational equivalent of
// having `krun` the program: it establishes "this exact input reaches this exact state" under
// the K rules. The hand-derived expectations here are cross-checked against the Solidity side
// in `test/conformance/InstructionConformance.t.sol` (`test_conformance_whitelist_coequal_*`),
// which runs the SAME bytes through the REAL `_whitelistCoequal` body and REAL `runLoop`.
// Agreement between the two sides IS the conformance evidence — neither side alone suffices.
//
// PROGRAM CONSTRUCTION. Program = b"\x2c\x0c" +Bytes Int2Bytes(2, 14, BE) +Bytes
// Int2Bytes(10, ENTRY, BE) (14 bytes total). `b"\x2c\x0c"` is the [opcode:1][argsLen:1] header
// — opcode 0x2c = 44 decimal, argsLen 0x0c = 12 decimal (2-byte pc + 10-byte packed entry,
// N=1). The pc field is `Int2Bytes(2, 14, BE)` = uint16 BE of 14, so `args.parseWhitelistCoequalPC()`
// returns 14 — exactly the program length, so the JUMP lands past the end and the loop-exit
// rule (swapvm.md:100-105) fires on the next step. The packed entry is `Int2Bytes(10, ENTRY, BE)`
// so the function's `Bytes2Int(substrBytes(LIST, 0, 10), BE, Unsigned)` reduces to ENTRY via
// the round-trip lemma (lemmas.k:65) under the bound `0 <=Int ENTRY andBool ENTRY <Int 2^80`,
// which holds for both ENTRY=4660 (scenario A) and ENTRY=9999 (scenario B).
//
// taker 4660 = address(0x...1234). The packed taker is `4660 modInt 2^80 = 4660` (4660 < 2^80),
// matching the rule's `TAKER modInt (2 ^Int 80)` projection faithfully. Scenario A pins the
// entry to the taker's packed bits (JUMP); scenario B pins it elsewhere (FALL THROUGH). Both
// end at <pc> 14 = program length: scenario A because the jump target IS 14 (past end → loop
// exit), scenario B because the FALL-THROUGH arm inherits the decode-advanced pc
// (2 + argsLen = 2 + 12 = 14, also past end → loop exit).
module WHITELISTCOEQUAL-CONCRETE
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS
  imports SWAPVM-WHITELISTS

  // ---- Scenario A — JUMP. The single 10-byte packed entry is 4660, matching the taker's
  // low 80 bits (4660 mod 2^80 = 4660). The recursive `#coequalContains` reduces to `true`
  // after one unfold: Bytes2Int(Int2Bytes(10, 4660, BE), BE, Unsigned) ==Int 4660 → true.
  // The 0x2c JUMP arm fires, overwriting <pc> with Bytes2Int(substrBytes(ARGS, 0, 2), BE,
  // Unsigned) = 20. The loop then tries to decode at pc=20, hits the loop-exit rule
  // (swapvm.md:100-105) since 20 >= lengthBytes(PGM)=14, and halts with status Running.
  // DISCRIMINATION: jump target 20 != fall-through pc 14. Earlier the target was 14 ==
  // fall-through, so both scenarios asserted the same pc and a mutant deleting the JUMP arm
  // passed both — verified by deletion (whitelistcoequal-concrete still PROVED with both 0x2c
  // rules removed). With the target at 20, deleting the JUMP arm makes this claim fail
  // (fall-through lands at 14, not 20).
  claim <k> #run => .K </k>
        <program> b"\x2c\x0c" +Bytes Int2Bytes(2, 20, BE) +Bytes Int2Bytes(10, 4660, BE) </program>
        <pc> 0 => 20 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> 4660 </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>

  // ---- Scenario B — FALL THROUGH. The single 10-byte packed entry is 9999, which does NOT
  // match the taker's low 80 bits (4660). The recursive `#coequalContains` reduces to `false`
  // after one unfold: Bytes2Int(Int2Bytes(10, 9999, BE), BE, Unsigned) ==Int 4660 → false;
  // the recursive call on the empty tail hits the base case → false; `false orBool false` →
  // false. The 0x2c FALL-THROUGH arm fires (no <pc> overwrite), the loop inherits the
  // decode-advanced pc = 2 + 12 = 14, hits the loop-exit rule, and halts with status Running.
  // This is the boundary case (entry ≠ taker) which the JUMP arm must NOT take. Combined with
  // scenario A (pc 20) it discriminates the two arms: a mutant that always jumps fails B
  // (would give 20, not 14), a mutant that never jumps fails A (would give 14, not 20).
  claim <k> #run => .K </k>
        <program> b"\x2c\x0c" +Bytes Int2Bytes(2, 20, BE) +Bytes Int2Bytes(10, 9999, BE) </program>
        <pc> 0 => 14 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> 4660 </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>

endmodule

// Concrete-input conformance claims for the 0x2d (WhitelistSequential) opcode.
//
// This file replaces the former `whitelistsequential-spec.k` (a symbolic universal claim) and
// `whitelistsequential-control.k` (its sensitivity twin). Both were TAUTOLOGICAL under the
// prior uninterpreted-predicate form: the spec asserted `#sequentialWhitelistJumps(ARGS, PACKED)`
// as a premise and the rule branched on the same predicate, so the proof established nothing
// about whether the underlying time-aware `while (i < length)` loop matched Solidity, AND
// krun could not reduce the predicate either — i.e. zero conformance evidence. See
// whitelists.md "What the K rules do" for the full rationale of the switch.
//
// The recursive `#seqOutcome(LIST, TIMELEFT, PACKED)` function in `opcodes/whitelists.k` now
// models the Solidity loop directly:
//   sender = uint80(uint160(taker)) = TAKER modInt 2^80
//   start  = Bytes2Int(ARGS[2:7], BE, Unsigned)              // 5-byte start timestamp
//   list   = ARGS[7:]                                          // post-header slice
//   timeLeft = block.timestamp - start                        // preconditions: ts >= start
//   for each 12-byte entry (duration, allowedTaker) in list (low-index first):
//       if (sender == allowedTaker) JUMP;                     // addr at LIST[2:12]
//       if (timeLeft < duration)   REVERT;                    // dur at LIST[0:2]
//       timeLeft -= duration;
//   FALL THROUGH.
// On CONCRETE lists + a CONCRETE timestamp the recursion reduces to a concrete outcome tag
// (#WL_JUMP / #WL_REVERT / #WL_FALLTHROUGH) via the bytes lemmas in semantics/lemmas.k
// (lines 16-67: `lengthBytes`, `substrBytes`, and the `Int2Bytes`/`Bytes2Int` round-trip), so
// the rule arm fires for the right reason. On SYMBOLIC lists neither rule's `requires` clause
// reduces, so the function is STUCK — no false symbolic claim is admitted. This is the same
// posture as gte-concrete.k and whitelistcoequal-concrete.k: concrete claims are the
// conformance evidence; symbolic claims are honestly stuck rather than wrong.
//
// Each claim runs a FULLY CONCRETE program through `#run` and asserts the exact final `<pc>`
// and `<status>`. A concrete claim that proves under kprove is the operational equivalent of
// having `krun` the program: it establishes "this exact input reaches this exact state" under
// the K rules. The hand-derived expectations here are cross-checked against the Solidity side
// in `test/conformance/InstructionConformance.t.sol`
// (`test_conformance_whitelist_sequential_*`), which runs the SAME bytes through the REAL
// `_whitelistSequential` body and REAL `runLoop`. Agreement between the two sides IS the
// conformance evidence — neither side alone suffices.
//
// PROGRAM CONSTRUCTION. Program = b"\x2d\x13" +Bytes Int2Bytes(2, 21, BE) +Bytes
// Int2Bytes(5, 0, BE) +Bytes Int2Bytes(2, 1000, BE) +Bytes Int2Bytes(10, ENTRY, BE)
// (21 bytes total). `b"\x2d\x13"` is the [opcode:1][argsLen:1] header — opcode 0x2d = 45
// decimal, argsLen 0x13 = 19 decimal (2-byte pc + 5-byte start + (2-byte dur + 10-byte entry)
// for N=1). The pc field is `Int2Bytes(2, 21, BE)` = uint16 BE of 21, so the JUMP arm lands
// at pc=21, which is EXACTLY the program length (21 bytes), so the loop-exit rule
// (swapvm.md:100-105) fires on the next step. The start field is `Int2Bytes(5, 0, BE)` =
// 40-bit BE of 0, so `ts >=Int 0` for any non-negative timestamp premise. The duration field
// is `Int2Bytes(2, 1000, BE)` = uint16 BE of 1000. The packed entry is
// `Int2Bytes(10, ENTRY, BE)` so the function's `Bytes2Int(substrBytes(LIST, 2, 12), BE,
// Unsigned)` reduces to ENTRY via the round-trip lemma (lemmas.k:65) under the bound
// `0 <=Int ENTRY andBool ENTRY <Int 2^80`, which holds for both ENTRY=4660 (scenario A) and
// ENTRY=9999 (scenario B).
//
// TIMESTAMP PREMISE. `#blockTimestamp()` is `[function, no-evaluators]` (opcodes/whitelists.k)
// — its value is fixed-but-unknown, so each claim pins it via the premise
// `requires #blockTimestamp() ==Int 10`. This is what makes the `#seqOutcome` recursion
// reduce: with timestamp=10 and start=0, `timeLeft = 10 - 0 = 10`, a concrete Int; the
// `timeLeft <Int duration` check then reduces to `10 <Int 1000` → true. On the Solidity side
// this premise corresponds to `vm.warp(10)` in the conformance test
// (InstructionConformance.t.sol), which sets `block.timestamp` to 10.
//
// taker 4660 = address(0x...1234). The packed taker is `4660 modInt 2^80 = 4660` (4660 <
// 2^80), matching the rule's `TAKER modInt (2 ^Int 80)` projection faithfully. Scenario A
// pins the entry to the taker's packed bits (JUMP before the duration check fires); scenario
// B pins it elsewhere (REVERT via `timeLeft(10) < duration(1000)`). Both end at <pc> 21 =
// program length: scenario A because the jump target IS 21 (past end → loop exit), scenario B
// because the REVERT arm inherits the decode-advanced pc (2 + argsLen = 2 + 19 = 21, also
// past end → the halt rule fires after `<k>` is cleared).
module WHITELISTSEQUENTIAL-CONCRETE
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS
  imports SWAPVM-WHITELISTS

  // ---- Scenario A — JUMP. The single 10-byte packed entry is 4660, matching the taker's
  // low 80 bits (4660 mod 2^80 = 4660). With timestamp=10 and start=0, timeLeft=10. The
  // recursion unfolds once: address Bytes2Int(substrBytes(LIST, 2, 12), BE, Unsigned) ==Int
  // 4660 → #WL_JUMP (the JUMP rule fires before the duration check is consulted). The 0x2d
  // JUMP arm overwrites <pc> with Bytes2Int(substrBytes(ARGS, 0, 2), BE, Unsigned) = 21. The
  // loop then tries to decode at pc=21, hits the loop-exit rule (swapvm.md:100-105) since
  // 21 >= lengthBytes(PGM)=21, and halts with status Running. Mirror of jump-spec.k's
  // "jump lands past end" shape, the 0x23 PASS composition shape, and the 0x2c JUMP scenario
  // in whitelistcoequal-concrete.k.
  //
  // KEY FIDELITY POINT: this scenario exercises the Solidity rule that the address match is
  // checked BEFORE the duration check (Whitelist.sol:158-163). With timeLeft=10 < duration=
  // 1000, an INVERTED order would REVERT instead of JUMP. The proof of this claim establishes
  // that the K model preserves the Solidity order — a non-trivial property of the recursion.
  claim <k> #run => .K </k>
        <program> b"\x2d\x13" +Bytes Int2Bytes(2, 21, BE) +Bytes Int2Bytes(5, 0, BE) +Bytes Int2Bytes(2, 1000, BE) +Bytes Int2Bytes(10, 4660, BE) </program>
        <pc> 0 => 21 </pc>
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
    requires #blockTimestamp() ==Int 10

  // ---- Scenario B — IN-WINDOW REVERT. The single 10-byte packed entry is 9999, which does
  // NOT match the taker's low 80 bits (4660). With timestamp=10 and start=0, timeLeft=10.
  // The recursion unfolds once: address Bytes2Int(substrBytes(LIST, 2, 12), BE, Unsigned)
  // ==Int 9999 =/=Int 4660 → the JUMP rule does NOT fire. The REVERT rule is then consulted:
  // timeLeft(10) <Int duration(1000) → true → #WL_REVERT. The 0x2d IN-WINDOW REVERT arm
  // fires `#revert("WhitelistAllowedTimeViolation")`, which clears <k> and sets
  // <status> Reverted("WhitelistAllowedTimeViolation"). pc ends at post-decode 21. Mirror of
  // the 0x23 REVERT composition shape (gate-spec.k) and the gte-concrete.k REVERT scenario.
  //
  // KEY FIDELITY POINT: this scenario exercises the Solidity in-window revert
  // (Whitelist.sol:163: `if (timeLeft < duration) revert WhitelistAllowedTimeViolation();`).
  // The premise `timeLeft(10) < duration(1000)` is what fires the revert — exactly mirroring
  // the source. A model that inverted the comparison or dropped the time arithmetic would
  // not select this arm.
  claim <k> #run => .K </k>
        <program> b"\x2d\x13" +Bytes Int2Bytes(2, 21, BE) +Bytes Int2Bytes(5, 0, BE) +Bytes Int2Bytes(2, 1000, BE) +Bytes Int2Bytes(10, 9999, BE) </program>
        <pc> 0 => 21 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> 4660 </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("WhitelistAllowedTimeViolation") </status>
        <trace> _ </trace>
    requires #blockTimestamp() ==Int 10

endmodule

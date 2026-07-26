// Concrete-input conformance claims.
//
// Each claim runs a FULLY CONCRETE program through `#run` and asserts the exact final `<pc>` and
// `<status>`. A concrete claim that proves under kprove is the operational equivalent of having
// `krun` the program: it establishes "this exact input reaches this exact state" under the K
// rules. (krun proper hangs on revert-producing cases in this environment for both the stock
// `swapvm-llvm` build and any build importing the opcode modules; concrete kprove claims bypass
// that tooling bug and use the working Haskell backend.)
//
// The hand-derived expectations here are cross-checked against the Solidity side in
// `test/conformance/InstructionConformance.t.sol` (`test_conformance_<opcode>_concrete`), which
// runs the SAME bytes through the REAL instruction bodies and REAL `runLoop`. Agreement between
// the two sides IS the conformance evidence -- neither side alone suffices.
//
// Arg payloads are built with `Int2Bytes(N, V, BE)` so the byte widths are exact by construction
// (hand-typing multi-byte literals miscounted on the first attempt -- a JumpIfTokenIn claim
// declared argsLen 22 but supplied a 23-byte body, tripping RunLoopExceedProgramLength instead of
// the rule under test).
//
// Scope: only the direct-form opcodes whose rules reduce without uninterpreted symbols
// (Salt, Revert, Jump, JumpIfDirection, JumpIfTokenIn, JumpIfTokenOut, PrivateOrder).
// The opcodes whose conditions are uninterpreted predicates/functions (Deadline, Gte,
// SupplyShare, TxOrigin, both Whitelists) cannot be concretely executed by kprove either -- a
// concrete claim would still need a premise to fix the uninterpreted value, so it would no
// longer be "fully concrete". Those are conformance-untestable in the current modelling; see the
// final report. Stop is also deferred: its K rule leaves pc at the post-decode value while
// Solidity sets nextPC = type(uint256).max, a documented fidelity gap that a conformance case on
// the pc field would surface as a mismatch -- fixing it is a separate modelling decision.
module CONFORMANCE-CONCRETE
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS
  imports SWAPVM-REVERT
  imports SWAPVM-SALT
  imports SWAPVM-JUMP
  imports SWAPVM-JUMPS
  imports SWAPVM-PRIVATEORDER

  // ---- Salt (0x02): no-op. Decode advances pc 0 -> 2. Loop exits (2 >= 2). Solidity: same.
  claim <k> #run => .K </k>
        <program> b"\x02\x00" </program>
        <pc> 0 => 2 </pc>
        <status> Running </status>

  // ---- Revert (0x01): unconditional revert. pc ends at post-decode 2.
  claim <k> #run => .K </k>
        <program> b"\x01\x00" </program>
        <pc> 0 => 2 </pc>
        <status> Running => Reverted("InstructionRevert") </status>

  // ---- Jump (0x03): args = 2-byte uint16 = 0x0005 = 5. Overwrites pc to 5.
  // Program is 4 bytes; pc 5 >= 4, loop exits.
  claim <k> #run => .K </k>
        <program> b"\x03\x02\x00\x05" </program>
        <pc> 0 => 5 </pc>
        <status> Running </status>

  // ---- JumpIfDirection (0x30), branch TAKEN. args=0x01 (dir=true) + 0x0009 (pc=9).
  // tokenIn=1 < tokenOut=2 => swapDir=true; expectedDir==swapDir => jump to 9. Program 5 bytes.
  // Jump target 9 != fall-through pc 5, so deleting the jump arm would make this claim fail
  // (fall-through lands at 5, not 9) — the claim discriminates the arm.
  claim <k> #run => .K </k>
        <program> b"\x30\x03\x01\x00\x09" </program>
        <pc> 0 => 9 </pc>
        <tokenIn> 1 </tokenIn> <tokenOut> 2 </tokenOut>
        <status> Running </status>

  // ---- JumpIfDirection (0x30), branch NOT TAKEN. tokenIn=2 > tokenOut=1 => swapDir=false.
  // expectedDir(true) != swapDir(false) => fall through. pc = 2+3 = 5.
  claim <k> #run => .K </k>
        <program> b"\x30\x03\x01\x00\x09" </program>
        <pc> 0 => 5 </pc>
        <tokenIn> 2 </tokenIn> <tokenOut> 1 </tokenOut>
        <status> Running </status>

  // ---- JumpIfTokenIn (0x31), branch TAKEN. args = 20-byte token (=1) + 2-byte pc (=30).
  // Built via Int2Bytes so widths are exact. tokenIn=1 == arg => jump to 30. Program is 24
  // bytes; jump target 30 != fall-through pc 24 (and 30 >= 24 so the loop exits). Earlier the
  // target was 24 == fall-through, so a mutant deleting the jump arm passed both claims.
  claim <k> #run => .K </k>
        <program> b"\x31\x16" +Bytes Int2Bytes(20, 1, BE) +Bytes Int2Bytes(2, 30, BE) </program>
        <pc> 0 => 30 </pc>
        <tokenIn> 1 </tokenIn>
        <status> Running </status>

  // ---- JumpIfTokenIn (0x31), branch NOT TAKEN. arg token=5 != tokenIn=1. Fall through, pc=24.
  claim <k> #run => .K </k>
        <program> b"\x31\x16" +Bytes Int2Bytes(20, 5, BE) +Bytes Int2Bytes(2, 30, BE) </program>
        <pc> 0 => 24 </pc>
        <tokenIn> 1 </tokenIn>
        <status> Running </status>

  // ---- JumpIfTokenOut (0x32), branch TAKEN. arg token=7 == tokenOut=7 => jump to 30.
  // Jump target 30 != fall-through pc 24. (A not-taken case is added below so BOTH arms are
  // exercised; previously only the taken case existed, so the fall-through arm had no coverage.)
  claim <k> #run => .K </k>
        <program> b"\x32\x16" +Bytes Int2Bytes(20, 7, BE) +Bytes Int2Bytes(2, 30, BE) </program>
        <pc> 0 => 30 </pc>
        <tokenOut> 7 </tokenOut>
        <status> Running </status>

  // ---- JumpIfTokenOut (0x32), branch NOT TAKEN. arg token=9 != tokenOut=7 => fall through,
  // pc = 2+22 = 24. Paired with the taken case above: a mutant that swaps or deletes either
  // arm now fails exactly one of the two claims (taken wants pc 30, not-taken wants pc 24).
  claim <k> #run => .K </k>
        <program> b"\x32\x16" +Bytes Int2Bytes(20, 9, BE) +Bytes Int2Bytes(2, 30, BE) </program>
        <pc> 0 => 24 </pc>
        <tokenOut> 7 </tokenOut>
        <status> Running </status>

  // ---- PrivateOrder (0x2b), taker MATCHES. arg = packed taker low 80 bits = 0x1234.
  // taker=4660=0x1234; 0x1234 modInt 2^80 = 0x1234 = arg => gate passes. pc = 2+10 = 12.
  claim <k> #run => .K </k>
        <program> b"\x2b\x0a" +Bytes Int2Bytes(10, 4660, BE) </program>
        <pc> 0 => 12 </pc>
        <taker> 4660 </taker>
        <status> Running </status>

  // ---- PrivateOrder (0x2b), taker does NOT match. arg=0x5678, taker=0x1234 => revert.
  claim <k> #run => .K </k>
        <program> b"\x2b\x0a" +Bytes Int2Bytes(10, 22136, BE) </program>
        <pc> 0 => 12 </pc>
        <taker> 4660 </taker>
        <status> Running => Reverted("WhitelistInvalidTaker") </status>

endmodule

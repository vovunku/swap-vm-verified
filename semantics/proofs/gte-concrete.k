// Concrete-input conformance claims for the 0x24 (Gte) opcode.
//
// This file replaces the former `gte-spec.k` (a symbolic universal claim) and `gte-control.k`
// (its sensitivity twin). Both were TAUTOLOGICAL under the prior predicate-form rule: the spec
// assumed `#balanceLtMin(TOK, MIN)` as a premise and the rule branched on the same predicate, so
// the proof established nothing about whether the underlying `<` / `>=` definition matched
// Solidity, and krun could not reduce the predicate either — i.e. zero conformance evidence.
// See gte.md "Direct form, concrete conformance" for the full rationale of the switch.
//
// The direct two-arm rule in `opcodes/gte.k` branches on the REAL comparison
//   #balanceOf(B, TOK, TAKER) <Int MIN     (REVERT)
//   #balanceOf(B, TOK, TAKER) >=Int MIN    (PASS)
// mirroring the gate's `>Int 0` / `<=Int 0` shape (swapvm.md:182-193) but compared to MIN. A
// symbolic universal claim over arbitrary TOK/MIN/TAKER does NOT prove in this form (the K
// Haskell backend does not propagate an inequality premise on an uninterpreted-vs-symbolic
// comparison into a refutation of the opposite arm — opcodes/deadline.md:125-156). CONCRETE
// claims, however, are unaffected: with balance and MIN both concrete Ints, the SMT solver
// decides `<Int` / `>=Int` directly and arm selection is immediate. So the two scenarios here
// ARE the conformance evidence — they verify the actual comparison against Solidity for fixed
// inputs, which the predicate-form symbolic proof could never do.
//
// Each claim runs a FULLY CONCRETE program through `#run` and asserts the exact final `<pc>` and
// `<status>`. A concrete claim that proves under kprove is the operational equivalent of having
// `krun` the program: it establishes "this exact input reaches this exact state" under the K
// rules. The hand-derived expectations here are cross-checked against the Solidity side in
// `test/conformance/InstructionConformance.t.sol` (`test_conformance_gte_*`), which runs the
// SAME bytes through the REAL `_onlyTakerTokenBalanceGte` body and REAL `runLoop`. Agreement
// between the two sides IS the conformance evidence — neither side alone suffices.
//
// PROGRAM CONSTRUCTION. Program = b"\x24\x34" +Bytes Int2Bytes(20, 1, BE) +Bytes
// Int2Bytes(32, MIN, BE) (54 bytes total). `b"\x24\x34"` is the [opcode:1][argsLen:1] header —
// opcode 0x24 = 36 decimal, argsLen 0x34 = 52 decimal (20-byte token + 32-byte minAmount).
// After the decode loop fires <pc> = 2 + 52 = 54. NOTE on the opcode byte: it is `\x24`
// (= 36 decimal), NOT `\x36` — the rule keys on the DECIMAL opcode `#exec ( 36 , ARGS )` and
// the program byte is the hex literal 0x24 = 36 decimal (0x24 is the unusual case where the hex
// and decimal readings diverge by 12, easy to mistype). Arg payloads are built via
// `Int2Bytes(N, V, BE)` so the byte widths are exact by construction — hand-typing multi-byte
// literals miscounted on the first attempt for other opcodes (see conformance-concrete.k
// header). Token value 1 is a PLACEHOLDER: the Solidity side patches the deployed
// `GateTokenMock` address into the program at runtime, so `bytes20(1)` here only verifies the
// byte plumbing end-to-end. Taker 4660 = address(0x...1234) on the Solidity side.
module GTE-CONCRETE
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS
  imports SWAPVM-GTE

  // ---- Scenario A — REVERT. Taker 4660 holds 5 of token 1; minAmount is 10. Balance 5 < 10,
  // rule's REVERT arm fires, `#revert("TakerTokenBalanceIsLessThanRequired")` clears the
  // continuation and sets `<status> Reverted("TakerTokenBalanceIsLessThanRequired")`. pc ends
  // at post-decode 54. Mirror of the 0x23 REVERT composition shape (gate-spec.k).
  claim <k> #run => .K </k>
        <program> b"\x24\x34" +Bytes Int2Bytes(20, 1, BE) +Bytes Int2Bytes(32, 10, BE) </program>
        <pc> 0 => 54 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> 4660 </taker>
        <balances> bal(1, 4660) |-> 5 </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("TakerTokenBalanceIsLessThanRequired") </status>
        <trace> _ </trace>

  // ---- Scenario B — PASS. Taker 4660 holds 10 of token 1; minAmount is 10. Balance 10 >= 10,
  // rule's PASS arm fires, opcode is a no-op at the register level (#run stays in <k>, loop
  // decodes the next instruction, which does not exist, so loop exits). pc ends at post-decode
  // 54 and status stays Running. Mirror of the 0x23 PASS composition shape. This is the
  // boundary case (balance == minAmount) which the REVERT arm must NOT take — covering it here
  // guards against an off-by-one in the `>=Int` / `<Int` split.
  claim <k> #run => .K </k>
        <program> b"\x24\x34" +Bytes Int2Bytes(20, 1, BE) +Bytes Int2Bytes(32, 10, BE) </program>
        <pc> 0 => 54 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> 4660 </taker>
        <balances> bal(1, 4660) |-> 10 </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>

endmodule

// Concrete-input conformance claims for the 0x20 (Deadline) opcode.
//
// This file replaces the former `deadline-spec.k` (a symbolic universal claim) and
// `deadline-control.k` (its sensitivity twin). Both were TAUTOLOGICAL under the prior
// predicate-form rule: the spec assumed `#deadlineExceeded(DL)` as a premise and the rule
// branched on the same predicate, so the proof established nothing about whether the underlying
// `>` / `<=` matched Solidity, and krun could not reduce the predicate either — i.e. zero
// conformance evidence. See deadline.md "Direct form, concrete conformance" for the full
// rationale of the switch.
//
// The direct two-arm rule in `opcodes/deadline.k` branches on the REAL comparison
//   #blockTimestamp() >Int DL     (REVERT)
//   #blockTimestamp() <=Int DL    (PASS)
// mirroring the Solidity `block.timestamp > deadline` / `<= deadline` split exactly. A symbolic
// universal claim over arbitrary DL does NOT prove in this form (the K Haskell backend does not
// propagate an inequality premise on an uninterpreted-vs-symbolic comparison into a refutation
// of the opposite arm — opcodes/deadline.md:125-156). CONCRETE claims, however, are unaffected:
// with `#blockTimestamp()` fixed by a premise and DL a concrete Int, the SMT solver decides
// `>Int` / `<=Int` directly and arm selection is immediate. So the two scenarios here ARE the
// conformance evidence — they verify the actual comparison against Solidity for fixed inputs,
// which the predicate-form symbolic proof could never do.
//
// Each claim runs a FULLY CONCRETE program through `#run` and asserts the exact final `<pc>` and
// `<status>`. A concrete claim that proves under kprove is the operational equivalent of having
// `krun` the program: it establishes "this exact input reaches this exact state" under the K
// rules. The hand-derived expectations here are cross-checked against the Solidity side in
// `test/conformance/InstructionConformance.t.sol` (`test_conformance_deadline_*`), which runs
// the SAME bytes through the REAL `_deadline` body and REAL `runLoop` — using `vm.warp(timestamp)`
// to set `block.timestamp` for the run. Agreement between the two sides IS the conformance
// evidence — neither side alone suffices.
//
// PROGRAM CONSTRUCTION. Program = b"\x20\x05" +Bytes Int2Bytes(5, DL, BE) (7 bytes total).
// `b"\x20\x05"` is the [opcode:1][argsLen:1] header — opcode 0x20 = 32 decimal, argsLen 0x05 = 5
// decimal (the uint40 deadline). After the decode loop fires <pc> = 2 + 5 = 7. NOTE on the
// opcode byte: it is `\x20` (= 32 decimal), NOT `\x14` (= 20 decimal) — the rule keys on the
// DECIMAL opcode `#exec ( 32 , ARGS )` and the program byte is the hex literal 0x20 = 32. The
// arg payload is built via `Int2Bytes(5, DL, BE)` so the byte width is exact by construction.
module DEADLINE-CONCRETE
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS
  imports SWAPVM-DEADLINE

  // ---- Scenario A — REVERT. block.timestamp 100 > deadline 50: the rule's REVERT arm fires,
  // `#revert("DeadlineReached")` clears the continuation and sets `<status>
  // Reverted("DeadlineReached")`. pc ends at post-decode 7. The premise
  // `#blockTimestamp() ==Int 100` fixes the uninterpreted timestamp so the SMT solver decides
  // `100 >Int 50` directly (true) and refutes the PASS arm `100 <=Int 50` immediately.
  // Mirror of the gate / gte REVERT composition shape.
  claim <k> #run => .K </k>
        <program> b"\x20\x05" +Bytes Int2Bytes(5, 50, BE) </program>
        <pc> 0 => 7 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("DeadlineReached") </status>
        <trace> _ </trace>
    requires #blockTimestamp() ==Int 100

  // ---- Scenario B — PASS. block.timestamp 50 <= deadline 100: the rule's PASS arm fires, the
  // opcode is a no-op at the register level (#run stays in <k>, loop decodes the next
  // instruction, which does not exist, so the loop-exit rule at swapvm.md:100-105 fires). pc
  // ends at post-decode 7 and status stays Running. The premise `#blockTimestamp() ==Int 50`
  // fixes the uninterpreted timestamp so the SMT solver decides `50 >Int 100` (false, refuting
  // the REVERT arm) and `50 <=Int 100` (true, selecting the PASS arm). Mirror of the gte PASS
  // composition shape. This is the boundary case (timestamp < deadline) which the REVERT arm
  // must NOT take — covering it here guards against an off-by-one in the `>Int` / `<=Int` split.
  claim <k> #run => .K </k>
        <program> b"\x20\x05" +Bytes Int2Bytes(5, 100, BE) </program>
        <pc> 0 => 7 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>
    requires #blockTimestamp() ==Int 50

endmodule

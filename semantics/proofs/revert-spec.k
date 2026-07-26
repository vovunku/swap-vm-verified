module REVERT-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // Revert halts before any tail executes.
  //
  // For ANY program that begins with Revert (opcode 0x01, argsLen 0x00) followed by an
  // arbitrary symbolic TAIL, execution ends in Reverted("InstructionRevert"). TAIL is never
  // decoded: the Revert rule (opcodes/revert.k) produces #revert("InstructionRevert"), and
  // #revert(MSG) ~> _ => .K (swapvm.md:154-156) clears the continuation so the loop never
  // resumes.
  //
  // Shape mirrors gate-spec.k and stop-spec.k: an early-halting instruction makes the tail
  // irrelevant. The outcome is Reverted, like the gate; the difference is that Revert is
  // unconditional -- there is no balance side condition, so no extra premise beyond the
  // generic lengthBytes(TAIL) >=Int 0.
  //
  // The `lengthBytes(TAIL) >=Int 0` side condition is NOT decorative -- do not delete. Once
  // `lengthBytes(b"\x01\x00" +Bytes TAIL)` rewrites to `2 +Int lengthBytes(TAIL)`, no axiom
  // forces `lengthBytes` non-negative, so without it the prover can take the termination
  // branch at <pc> 0 and the claim gets stuck. Same reason as gate-spec.k:27-32 and
  // stop-spec.k:16-19.
  //
  // Sensitivity twin: revert-control.k -- same premises, conclusion Running instead of
  // Reverted -- must FAIL. Together they show kprove is discriminating on the conclusion.
  claim <k> #run => .K </k>
        <program> b"\x01\x00" +Bytes TAIL </program>
        <pc> 0 => 2 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("InstructionRevert") </status>
        <trace> _ </trace>
    requires lengthBytes(TAIL) >=Int 0

endmodule

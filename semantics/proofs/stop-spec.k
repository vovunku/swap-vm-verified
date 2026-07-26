module STOP-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // T3 -- Stop halts before any tail executes.
  //
  // For ANY program that begins with Stop (opcode 0x00, argsLen 0x00) followed by an
  // arbitrary symbolic TAIL, execution ends in Running with <k> cleared. TAIL is never
  // decoded: the Stop rule clears the continuation (mirroring #revert at swapvm.md:154-156),
  // so the loop never resumes and the tail cannot affect the conclusion.
  //
  // <pc> ends at the post-decode value (2), exactly like the Revert twin
  // (proofs/revert-spec.k:28). The Solidity sets nextPC = type(uint256).max, but that value is
  // an implementation detail of the loop-exit mechanism; what a proof can observe is that the
  // loop halted with Running status. See opcodes/stop.k for why modelling the literal max
  // stalls the prover on giant-constant arithmetic.
  //
  // Shape mirrors gate-spec.k: an early-halting instruction makes the tail irrelevant. The
  // outcome is Running, not Reverted, because Stop is the unconditional-success halt.
  //
  // The `lengthBytes(TAIL) >=Int 0` side condition is NOT decorative -- do not delete. Once
  // `lengthBytes(b"\x00\x00" +Bytes TAIL)` rewrites to `2 +Int lengthBytes(TAIL)`, no axiom
  // forces `lengthBytes` non-negative, so without it the prover can take the termination
  // branch at <pc> 0 and the claim gets stuck. Same reason as gate-spec.k:27-32.
  claim <k> #run => .K </k>
        <program> b"\x00\x00" +Bytes TAIL </program>
        <pc> 0 => 2 </pc>
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
    requires lengthBytes(TAIL) >=Int 0

endmodule

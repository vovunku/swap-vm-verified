module STOP-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // DELIBERATELY FALSE. Must fail.
  //
  // Identical program to stop-spec.k -- Stop with a symbolic tail -- but the conclusion is
  // Reverted("...") instead of Running. Stop is the unconditional-SUCCESS halt
  // (Controls.sol:89-93); it never reverts. So this claim cannot close, and kprove must
  // report not-proved with a counterexample ending in <status> Running at <pc> 2.
  //
  // WHY THIS SHAPE. Mirrors negative-control.k: the program prefix is concrete (so the
  // prover can actually decode opcode 0x00), the rule fires for real, and the failure is on
  // the conclusion -- not on a stuck decode. If this control ever PROVES, the rule set is
  // inconsistent and stop-spec.k above is void (proofs/README.md:20-28).
  //
  // The sensitivity twin is stop-spec.k itself: same premises, correct conclusion, must
  // prove. Together they show kprove is discriminating on the conclusion rather than
  // choking on the setup.
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
        <status> Running => Reverted("StopIsNotSuccess") </status>
        <trace> _ </trace>
    requires lengthBytes(TAIL) >=Int 0

endmodule

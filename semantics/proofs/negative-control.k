module NEGATIVE-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // DELIBERATELY FALSE. Must fail.
  //
  // Identical to gate-spec.k except the taker's balance is NON-ZERO, so the gate passes and
  // execution completes Running instead of reverting.
  //
  // WHY THIS SHAPE. The first version of this control dropped the gate prefix and asserted
  // that an ARBITRARY program reverts. It did fail -- but for the wrong reason, and it was
  // therefore worthless. It died at <pc> 0 before a single instruction executed, on a
  // residual branch where no decode rule applies to a fully symbolic first byte. A review
  // established the decisive fact: a claim that is TRUE (mere termination over an arbitrary
  // program) fails with a byte-identical residual. So the old control would have kept
  // "failing correctly" even if every instruction rule were deleted or made contradictory.
  //
  // The lesson generalises: a negative control with a SYMBOLIC PREFIX cannot discriminate,
  // because the prover cannot decode the first instruction. The prefix must be concrete.
  //
  // This version reaches #exec, consults #balanceOf, and fails with a real computed
  // counterexample -- <pc> 22, <status> Running.
  claim <k> #run => .K </k>
        <program> b"\x23\x14" +Bytes Int2Bytes(20, G, BE) </program>
        <pc> 0 => 22 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> TAKER </taker>
        <balances> BALS </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("TakerTokenBalanceIsZero") </status>
        <trace> _ </trace>
    requires 0 <=Int G andBool G <Int (2 ^Int 160)
     andBool #balanceOf(BALS, G, TAKER) >Int 0

endmodule

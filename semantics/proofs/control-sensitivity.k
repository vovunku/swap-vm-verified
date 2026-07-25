module CONTROL-SENSITIVITY
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // MUST PROVE. The twin of negative-control.k: identical premises, only the conclusion
  // differs -- Running instead of Reverted.
  //
  // This is what makes the negative control meaningful. A control that FAILS tells you
  // nothing unless the same setup with the RIGHT conclusion SUCCEEDS; otherwise the failure
  // may be incidental -- a syntax error, a missing lemma, a stuck configuration. Together the
  // pair shows kprove is discriminating on the conclusion and not merely choking on the setup.
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
        <status> Running </status>
        <trace> _ </trace>
    requires 0 <=Int G andBool G <Int (2 ^Int 160)
     andBool #balanceOf(BALS, G, TAKER) >Int 0

endmodule

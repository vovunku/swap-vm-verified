module NEGATIVE-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // DELIBERATELY FALSE. This claim drops the gate prefix and asserts that an ARBITRARY
  // program reverts with TakerTokenBalanceIsZero. It does not: the empty program terminates
  // with status Running, and so do many others.
  //
  // kprove MUST FAIL on this. If it ever succeeds, the rule set is inconsistent and every
  // result proved above it is void -- an inconsistent theory proves everything and looks
  // exactly like total success.
  claim <k> #run => .K </k>
        <program> TAIL </program>
        <pc> 0 => ?_ </pc>
        <balanceIn> 0 </balanceIn> <balanceOut> 0 </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> TAKER </taker>
        <balances> BALS </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("TakerTokenBalanceIsZero") </status>
        <trace> _ </trace>
    requires #balanceOf(BALS, 0, TAKER) ==Int 0
     andBool lengthBytes(TAIL) >=Int 0

endmodule

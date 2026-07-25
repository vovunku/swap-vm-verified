module GATE-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // Phase 1 go/no-go.
  //
  // For ANY program that begins with OnlyTakerTokenBalanceNonZero(G) -- with TAIL an
  // arbitrary, symbolic byte string -- a taker holding zero balance of G ends reverted.
  //
  // TAIL is never decoded: #revert discards the continuation, so its contents cannot affect
  // the conclusion and the proof must not case-split on it.
  claim <k> #run => .K </k>
        <program> b"\x23\x14" +Bytes Int2Bytes(20, G, BE) +Bytes TAIL </program>
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
     andBool #balanceOf(BALS, G, TAKER) ==Int 0
     // NOT decorative -- do not delete. It excludes no Bytes value semantically, but the
     // backend needs it: once `lengthBytes(B1 +Bytes B2)` rewrites the program length to
     // `22 +Int lengthBytes(TAIL)`, there is no axiom making `lengthBytes` non-negative, so
     // without this the prover takes the `PC >= length` termination branch and the proof
     // gets stuck at <pc> 0. Verified by deleting it.
     andBool lengthBytes(TAIL) >=Int 0

endmodule

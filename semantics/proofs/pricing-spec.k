module PRICING-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // T1 -- exact-in prices at EXACTLY the floor of the maker's rate.
  //
  // Runs the whole 3-instruction program, not just the arithmetic: the claim is about what
  // the VM does, not about what limitQuoteOut computes in isolation.
  //
  // Both bounds are required. The upper alone is satisfied by returning 0; the lower alone by
  // returning something huge. Together they pin amountOut to floor(AIN * BOUT / BIN).
  claim <k> #run => .K </k>
        <program> b"\x23\x14" +Bytes Int2Bytes(20, G, BE)
          +Bytes b"\x90\x40" +Bytes Int2Bytes(32, BA, BE) +Bytes Int2Bytes(32, BB, BE)
          +Bytes b"\x53\x01\x01" </program>
        <pc> 0 => 91 </pc>
        <balanceIn> 0 => BA </balanceIn> <balanceOut> 0 => BB </balanceOut>
        <amountIn> AIN </amountIn>
        <amountOut> 0 => ?AOUT:Int </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> true </isExactIn>
        <tokenIn> TIN </tokenIn> <tokenOut> TOUT </tokenOut>
        <taker> TAKER </taker>
        <balances> BALS </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>
    requires 0 <=Int G andBool G <Int (2 ^Int 160)
     andBool #balanceOf(BALS, G, TAKER) >Int 0        // gate passes
     andBool TIN <Int TOUT                            // matches direction byte 0x01
     andBool 0 <Int BA andBool BA <Int (2 ^Int 256)   // maker's reserves, non-zero
     andBool 0 <Int BB andBool BB <Int (2 ^Int 256)
     andBool 0 <=Int AIN andBool AIN <Int (2 ^Int 256)
    ensures ?AOUT *Int BA <=Int AIN *Int BB
    andBool ( ?AOUT +Int 1 ) *Int BA >Int AIN *Int BB

endmodule

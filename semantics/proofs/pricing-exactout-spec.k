// STATUS: WRITTEN, NOT YET VERIFIED. The container was busy with review agents when this
// was committed. It must be run before anything cites it, and axioms.md does not list it.
module PRICING-EXACTOUT-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // T2 -- exact-out prices at EXACTLY the ceiling of the maker's rate.
  //
  // Mirror of T1 on the other leg. The two round in OPPOSITE directions and that is
  // deliberate: both must favour the maker. LimitSwap.sol:52 documents the ceiling as
  // intended, and like the floor it was unconstrained by anything but concrete cases.
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
        <amountIn> 0 => ?AIN:Int </amountIn>
        <amountOut> AOUT </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> false </isExactIn>
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
     andBool 0 <Int AOUT andBool AOUT <Int (2 ^Int 256)
    ensures ?AIN *Int BB >=Int AOUT *Int BA
    andBool ( ?AIN -Int 1 ) *Int BB <Int AOUT *Int BA

endmodule

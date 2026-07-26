// Negative control for the 0x24 (Gte) opcode — a deliberately-FALSE claim.
//
// Restores the must-fail control deleted when gte-spec/control were replaced by gte-concrete
// (review §7). gte-concrete.k scenario A: taker 4660 holds 5 of token 1, minAmount 10, so
// `5 <Int 10` reverts "TakerTokenBalanceIsLessThanRequired" on both engines. This claim
// asserts the SAME input ends Running. kprove must FAIL. Sensitivity twin: gte-concrete.k
// scenario A (correct conclusion) proves.
module GTE-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS
  imports SWAPVM-GTE

  claim <k> #run => .K </k>
        <program> b"\x24\x34" +Bytes Int2Bytes(20, 1, BE) +Bytes Int2Bytes(32, 10, BE) </program>
        <pc> 0 => 54 </pc>
        <taker> 4660 </taker>
        <balances> bal(1, 4660) |-> 5 </balances>
        <status> Running </status>
endmodule

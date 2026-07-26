// Negative control for the 0x25 (SupplyShare) opcode — a deliberately-FALSE claim.
//
// Restores the must-fail control deleted when supplyshare-spec/control were replaced by
// supplyshare-concrete (review §7). supplyshare-concrete.k scenario A: totalSupply == 0, so
// the conjunction `totalSupply > 0 && ...` fails on its first conjunct and reverts
// "TakerTokenBalanceSupplyShareIsLessThanRequired" on both engines. This claim asserts the
// SAME input ends Running. kprove must FAIL. Sensitivity twin: supplyshare-concrete.k
// scenario A (correct conclusion) proves.
module SUPPLYSHARE-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS
  imports SWAPVM-SUPPLYSHARE

  claim <k> #run => .K </k>
        <program> b"\x25\x1c" +Bytes Int2Bytes(20, 1, BE) +Bytes Int2Bytes(8, 0, BE) </program>
        <pc> 0 => 30 </pc>
        <taker> 4660 </taker>
        <balances> bal(1, 4660) |-> 5 </balances>
        <status> Running </status>
    requires #totalSupply(1) ==Int 0
endmodule

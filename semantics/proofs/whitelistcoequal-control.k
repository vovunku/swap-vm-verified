// Negative control for the 0x2c (WhitelistCoequal) opcode — a deliberately-FALSE claim.
//
// Restores the must-fail control deleted when whitelistcoequal-spec/control were replaced by
// whitelistcoequal-concrete (review §7). whitelistcoequal-concrete.k scenario A: the packed
// entry 4660 matches the taker's low 80 bits, so the JUMP arm fires and pc becomes 20 on
// both engines. This claim asserts the SAME input ends at the FALL-THROUGH pc 14 — i.e. that
// the match did not jump. kprove must FAIL. Sensitivity twin: whitelistcoequal-concrete.k
// scenario A (pc => 20) proves.
//
// NOTE on discrimination: the jump target was chosen as 20 (!= fall-through 14) precisely so
// this control discriminates the arm. With the earlier target == 14, this claim would have
// the SAME pc as a successful jump and could not fail — the defect review §3 machine-checked.
module WHITELISTCOEQUAL-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS
  imports SWAPVM-WHITELISTS

  claim <k> #run => .K </k>
        <program> b"\x2c\x0c" +Bytes Int2Bytes(2, 20, BE) +Bytes Int2Bytes(10, 4660, BE) </program>
        <pc> 0 => 14 </pc>
        <taker> 4660 </taker>
        <status> Running </status>
endmodule

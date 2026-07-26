// Negative control for the 0x2d (WhitelistSequential) opcode — a deliberately-FALSE claim.
//
// Restores the must-fail control deleted when whitelistsequential-spec/control were replaced
// by whitelistsequential-concrete (review §7). whitelistsequential-concrete.k scenario A:
// ts 10, start 0, the packed entry 4660 matches the taker's low 80 bits, so the JUMP arm
// fires and pc becomes 30 on both engines. This claim asserts the SAME input ends at pc 21
// (i.e. did not jump). kprove must FAIL. Sensitivity twin: whitelistsequential-concrete.k
// scenario A (pc => 30) proves.
//
// NOTE on discrimination: the jump target was chosen as 30 (!= fall-through 21) precisely so
// this control discriminates the arm — the defect review §3 machine-checked.
module WHITELISTSEQUENTIAL-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS
  imports SWAPVM-WHITELISTS

  claim <k> #run => .K </k>
        <program> b"\x2d\x13" +Bytes Int2Bytes(2, 30, BE) +Bytes Int2Bytes(5, 0, BE) +Bytes Int2Bytes(2, 1000, BE) +Bytes Int2Bytes(10, 4660, BE) </program>
        <pc> 0 => 21 </pc>
        <taker> 4660 </taker>
        <status> Running </status>
    requires #blockTimestamp() ==Int 10
endmodule

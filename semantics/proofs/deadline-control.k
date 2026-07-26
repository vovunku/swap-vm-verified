// Negative control for the 0x20 (Deadline) opcode — a deliberately-FALSE claim.
//
// Restores the must-fail control deleted when deadline-spec/control were replaced by
// deadline-concrete (proofs/README.md §"Why the controls exist", review §7). A proof that
// cannot fail proves nothing, and an inconsistent rule set proves everything while looking
// like total success — the control is the only artefact that fails when the rule set stops
// meaning what you think it means.
//
// This claim is deadline-concrete.k scenario A with the conclusion FLIPPED: timestamp 100 >
// deadline 50 reverts "DeadlineReached" on both engines, but the claim asserts it ends
// Running. kprove must FAIL. If it ever proves, the Deadline rule set is inconsistent and
// every result above it is void. (Contrast deadline-concrete.k, the sensitivity twin that
// asserts the correct conclusion and proves.)
module DEADLINE-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS
  imports SWAPVM-DEADLINE

  claim <k> #run => .K </k>
        <program> b"\x20\x05" +Bytes Int2Bytes(5, 50, BE) </program>
        <pc> 0 => 7 </pc>
        <status> Running </status>
    requires #blockTimestamp() ==Int 100
endmodule

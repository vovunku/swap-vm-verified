module JUMPIFDIRECTION-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // DELIBERATELY FALSE. Must fail.
  //
  // Same program and premises as jumpifdirection-spec.k -- a 5-byte JumpIfDirection with
  // ARGS[0] = 0x01 and target TGT in (5, 65535], with TIN <Int TOUT so the branch is taken --
  // but the conclusion pins <pc> to 5 (the post-decode value, `2 + argsLen`) instead of TGT.
  // This asserts that the jump arm of opcodes/jumps.k did NOT overwrite <pc>, i.e. that
  // JumpIfDirection behaves like Salt on its taken branch.
  //
  // The jump arm of opcodes/jumps.k DOES overwrite <pc> when its condition holds (mirroring
  // `pcs = ctx.vm.nextPC` in VM.sol; swapvm.md:138-140). So this claim is false on every model
  // satisfying the rule: in the resulting configuration <pc> equals TGT (any value in
  // (5, 65535]) and never equals 5 (since TGT = 5 is excluded by the strict `5 <Int TGT`
  // premise, mirroring jump-control.k's `4 <Int TGT`).
  //
  // WHY THIS SHAPE. Mirrors jump-control.k, negative-control.k, stop-control.k, revert-control.k,
  // salt-control.k: the program prefix is concrete (so the prover can actually decode opcode
  // 0x30), the rule fires for real, and the failure is on the conclusion -- not on a stuck
  // decode. If this control ever PROVES, the rule set is inconsistent (e.g. the JumpIfDirection
  // jump arm lost its `<pc> _ => ...` overwrite) and jumpifdirection-spec.k above is void
  // (proofs/README.md:20-28).
  //
  // The sensitivity twin is jumpifdirection-spec.k itself: same premises, correct conclusion,
  // must prove. Together they show kprove is discriminating on the conclusion rather than
  // choking on the setup.
  claim <k> #run => .K </k>
        <program> b"\x30\x03" +Bytes b"\x01" +Bytes Int2Bytes(2, TGT, BE) </program>
        <pc> 0 => 5 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> TIN </tokenIn> <tokenOut> TOUT </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>
    requires 5 <Int TGT andBool TGT <Int 65536
     andBool TIN <Int TOUT

endmodule

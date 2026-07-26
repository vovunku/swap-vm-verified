module JUMPIFTOKENIN-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // DELIBERATELY FALSE. Must fail.
  //
  // Same program and premises as jumpiftokenin-spec.k -- a 24-byte JumpIfTokenIn with token TOK
  // pinned into <tokenIn> (so the branch is taken) and target TGT in (24, 65535] -- but the
  // conclusion pins <pc> to 24 (the post-decode value, `2 + argsLen`) instead of TGT. This
  // asserts that the jump arm of opcodes/jumps.k did NOT overwrite <pc>, i.e. that
  // JumpIfTokenIn behaves like Salt on its taken branch.
  //
  // The jump arm of opcodes/jumps.k DOES overwrite <pc> when its condition holds (mirroring
  // `pcs = ctx.vm.nextPC` in VM.sol; swapvm.md:138-140). So this claim is false on every model
  // satisfying the rule: in the resulting configuration <pc> equals TGT (any value in
  // (24, 65535]) and never equals 24 (since TGT = 24 is excluded by the strict `24 <Int TGT`
  // premise, mirroring jump-control.k's `4 <Int TGT`).
  //
  // WHY THIS SHAPE. Mirrors jump-control.k, jumpifdirection-control.k, negative-control.k,
  // stop-control.k, revert-control.k, salt-control.k: the program prefix is concrete (so the
  // prover can actually decode opcode 0x31), the rule fires for real, and the failure is on the
  // conclusion -- not on a stuck decode. If this control ever PROVES, the rule set is
  // inconsistent and jumpiftokenin-spec.k above is void (proofs/README.md:20-28).
  //
  // The sensitivity twin is jumpiftokenin-spec.k itself: same premises, correct conclusion,
  // must prove.
  claim <k> #run => .K </k>
        <program> b"\x31\x16" +Bytes Int2Bytes(20, TOK, BE) +Bytes Int2Bytes(2, TGT, BE) </program>
        <pc> 0 => 24 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> TOK </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>
    requires 24 <Int TGT andBool TGT <Int 65536
     andBool 0 <=Int TOK andBool TOK <Int (2 ^Int 160)

endmodule

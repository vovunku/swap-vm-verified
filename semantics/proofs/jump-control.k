module JUMP-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // DELIBERATELY FALSE. Must fail.
  //
  // Same program as jump-spec.k -- a 4-byte Jump to TGT in [4, 65535] -- but the conclusion
  // pins <pc> to 4 (the post-decode value, `2 + argsLen`) instead of TGT (the value the Jump
  // rule overwrites). This asserts that the Jump rule did NOT fire / did not overwrite <pc> --
  // i.e. that Jump behaves like Salt or Revert, inheriting the decode-advanced pc.
  //
  // The Jump rule (opcodes/jump.k) DOES overwrite <pc> (mirroring `pcs = ctx.vm.nextPC` in
  // VM.sol; swapvm.md:138-140). So this claim is false on every model satisfying the rule: in
  // the resulting configuration <pc> equals TGT (any value in [4, 65535]) and never equals 4
  // (since TGT = 4 would require the loop to decode the Jump instruction's own bytes, which is
  // outside this claim's premise `4 <Int TGT`).
  //
  // WHY THIS SHAPE. Mirrors negative-control.k, stop-control.k, revert-control.k, and
  // salt-control.k: the program prefix is concrete (so the prover can actually decode opcode
  // 0x03), the rule fires for real, and the failure is on the conclusion -- not on a stuck
  // decode. If this control ever PROVES, the rule set is inconsistent (e.g. the Jump rule lost
  // its `<pc> _ => ...` overwrite) and jump-spec.k above is void (proofs/README.md:20-28).
  //
  // The sensitivity twin is jump-spec.k itself: same premises, correct conclusion, must prove.
  // Together they show kprove is discriminating on the conclusion rather than choking on the
  // setup.
  //
  // ENV CAVEAT. Like salt-control.k, this control's non-zero exit is the meaningful signal only
  // when kprove is healthy on the sibling positive claim. In this sandbox kprove has been
  // observed to die with "Haskell Backend execution failed" when TMPDIR is not /tmp; the task
  // brief's "Critical environment facts" #2 directs setting TMPDIR=/tmp, which the run harness
  // does. Under that fix the control's failure here is a real counterexample, not incidental.
  claim <k> #run => .K </k>
        <program> b"\x03\x02" +Bytes Int2Bytes(2, TGT, BE) </program>
        <pc> 0 => 4 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>
    requires 4 <Int TGT andBool TGT <Int 65536

endmodule

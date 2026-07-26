module EXTRUCTION-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // DELIBERATELY FALSE. Must fail.
  //
  // Identical program to extruction-spec.k — Extruction (opcode 0x04, argsLen 0x14,
  // 20-byte target TGT in [0, 2^160)) followed by a symbolic TAIL — but the conclusion
  // is Running instead of Reverted("ExtructionUnmodelled"). The K rule
  // (opcodes/extruction.k) reverts unconditionally on canonical args (length >= 20) because
  // the external call is an unmodelled abstraction boundary (PLAN.md D4). So this claim
  // cannot close, and kprove must report not-proved with a counterexample ending in
  // <status> Reverted("ExtructionUnmodelled") at <pc> 22.
  //
  // WHY THIS SHAPE. Mirrors negative-control.k, stop-control.k, revert-control.k,
  // salt-control.k, and jump-control.k: the program prefix is concrete (so the prover can
  // actually decode opcode 0x04), the rule fires for real, and the failure is on the
  // conclusion — not on a stuck decode. If this control ever PROVES, the rule set is
  // inconsistent (e.g. the Extruction rule lost its `=> #revert(...)` rewrite) and
  // extruction-spec.k above is void (proofs/README.md:20-28).
  //
  // The sensitivity twin is extruction-spec.k itself: same premises, correct conclusion,
  // must prove. Together they show kprove is discriminating on the conclusion rather than
  // choking on the setup.
  //
  // ENV CAVEAT. Like jump-control.k and salt-control.k, this control's non-zero exit is the
  // meaningful signal only when kprove is healthy on the sibling positive claim. In this
  // sandbox kprove has been observed to die with "Haskell Backend execution failed" when
  // TMPDIR is not /tmp; the task brief's "Critical environment facts" #2 directs setting
  // TMPDIR=/tmp, which the run harness does. Under that fix the control's failure here is a
  // real counterexample, not incidental.
  claim <k> #run => .K </k>
        <program> b"\x04\x14" +Bytes Int2Bytes(20, TGT, BE) +Bytes TAIL </program>
        <pc> 0 => 22 </pc>
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
    requires 0 <=Int TGT andBool TGT <Int (2 ^Int 160)
     andBool lengthBytes(TAIL) >=Int 0

endmodule

module DEADLINE-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // DELIBERATELY FALSE. Must fail.
  //
  // Same program and same premise as deadline-spec.k — opcode 0x20 argsLen 5, deadline DL in
  // [0, 2^40), `#deadlineExceeded(DL)` — but the conclusion asserts the WRONG post-state: that
  // execution ends in `Running`. The premise selects the REVERT arm of the Deadline rule
  // (opcodes/deadline.k), which sets <status> `Reverted("DeadlineReached")` and clears <k>. So
  // this claim is false on every model satisfying the rule: in the resulting configuration
  // <status> is `Reverted("DeadlineReached")`, never `Running`.
  //
  // WHY THIS SHAPE. Mirrors negative-control.k, stop-control.k, revert-control.k, salt-control.k,
  // and jump-control.k: the program prefix is concrete (so the prover can actually decode opcode
  // 0x20), the rule fires for real, and the failure is on the conclusion — not on a stuck
  // decode. If this control ever PROVES, the rule set is inconsistent (e.g. the Deadline REVERT
  // arm lost its `#deadlineExceeded` guard, or both arms produce the same outcome) and
  // deadline-spec.k above is void (proofs/README.md:20-28).
  //
  // The sensitivity twin is deadline-spec.k itself: same premises, correct conclusion, must
  // prove. Together they show kprove is discriminating on the conclusion rather than choking on
  // the setup.
  //
  // ENV CAVEAT. Like jump-control.k and salt-control.k, this control's non-zero exit is the
  // meaningful signal only when kprove is healthy on the sibling positive claim. In this sandbox
  // kprove has been observed to die with "Haskell Backend execution failed" when TMPDIR is not
  // /tmp; the brief's "Critical environment facts" directs setting TMPDIR=/tmp, which the run
  // harness does. Under that fix the control's failure here is a real counterexample, not
  // incidental.
  claim <k> #run => .K </k>
        <program> b"\x20\x05" +Bytes Int2Bytes(5, DL, BE) +Bytes TAIL </program>
        <pc> 0 => 7 </pc>
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
    requires 0 <=Int DL andBool DL <Int (2 ^Int 40)
     andBool #deadlineExceeded(DL)
     andBool lengthBytes(TAIL) >=Int 0

endmodule

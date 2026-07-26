module GTE-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // DELIBERATELY FALSE. Must fail.
  //
  // Same program and same premise as gte-spec.k — opcode 0x24 argsLen 0x34 (52), token TOK in
  // [0, 2^160), minAmount MIN in [0, 2^256), `#balanceLtMin(TOK, MIN)` — but the conclusion
  // asserts the WRONG post-state: that execution ends in `Running`. The premise selects the
  // REVERT arm of the Gte rule (opcodes/gte.k), which sets <status>
  // `Reverted("TakerTokenBalanceIsLessThanRequired")` and clears <k>. So this claim is false on
  // every model satisfying the rule: in the resulting configuration <status> is
  // `Reverted("TakerTokenBalanceIsLessThanRequired")`, never `Running`.
  //
  // WHY THIS SHAPE. Mirrors negative-control.k, stop-control.k, revert-control.k, salt-control.k,
  // jump-control.k, and deadline-control.k: the program prefix is concrete (so the prover can
  // actually decode opcode 0x24), the rule fires for real, and the failure is on the conclusion
  // — not on a stuck decode. If this control ever PROVES, the rule set is inconsistent (e.g. the
  // Gte REVERT arm lost its `#balanceLtMin` guard, or both arms produce the same outcome) and
  // gte-spec.k above is void (proofs/README.md:20-28).
  //
  // The sensitivity twin is gte-spec.k itself: same premises, correct conclusion, must prove.
  // Together they show kprove is discriminating on the conclusion rather than choking on the
  // setup.
  //
  // ENV CAVEAT. Like deadline-control.k, this control's non-zero exit is the meaningful signal
  // only when kprove is healthy on the sibling positive claim. In this sandbox kprove has been
  // observed to die with "Haskell Backend execution failed" when TMPDIR is not /tmp; the brief's
  // "Critical environment facts" directs setting TMPDIR=/tmp, which the run harness does. Under
  // that fix the control's failure here is a real counterexample, not incidental.
  claim <k> #run => .K </k>
        <program> b"\x24\x34" +Bytes Int2Bytes(20, TOK, BE) +Bytes Int2Bytes(32, MIN, BE) +Bytes TAIL </program>
        <pc> 0 => 54 </pc>
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
    requires 0 <=Int TOK andBool TOK <Int (2 ^Int 160)
     andBool 0 <=Int MIN andBool MIN <Int (2 ^Int 256)
     andBool #balanceLtMin(TOK, MIN)
     andBool lengthBytes(TAIL) >=Int 0

endmodule

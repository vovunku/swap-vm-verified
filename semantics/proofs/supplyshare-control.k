module SUPPLYSHARE-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // DELIBERATELY FALSE. Must fail.
  //
  // Same program and same premise as supplyshare-spec.k — opcode 0x25 argsLen 0x1c (28),
  // token TOK in [0, 2^160), minShareE18 MIN in [0, 2^64),
  // `notBool #supplyShareSufficient(#balanceOf(BALS, TOK, TAKER), #totalSupply(TOK), MIN)`
  // — but the conclusion asserts the WRONG post-state: that execution ends in `Running`.
  // The premise selects the REVERT arm of the SupplyShare rule (opcodes/supplyshare.k),
  // which sets <status> `Reverted("TakerTokenBalanceSupplyShareIsLessThanRequired")` and
  // clears <k>. So this claim is false on every model satisfying the rule: in the resulting
  // configuration <status> is `Reverted("TakerTokenBalanceSupplyShareIsLessThanRequired")`,
  // never `Running`.
  //
  // WHY THIS SHAPE. Mirrors negative-control.k, stop-control.k, revert-control.k,
  // salt-control.k, jump-control.k, deadline-control.k, and gte-control.k: the program
  // prefix is concrete (so the prover can actually decode opcode 0x25), the rule fires for
  // real, and the failure is on the conclusion — not on a stuck decode. If this control
  // ever PROVES, the rule set is inconsistent (e.g. the SupplyShare REVERT arm lost its
  // `notBool #supplyShareSufficient(...)` guard, or both arms produce the same outcome) and
  // supplyshare-spec.k above is void (proofs/README.md:20-28).
  //
  // The sensitivity twin is supplyshare-spec.k itself: same premises, correct conclusion,
  // must prove. Together they show kprove is discriminating on the conclusion rather than
  // choking on the setup.
  //
  // ENV CAVEAT. Like deadline-control.k and gte-control.k, this control's non-zero exit is
  // the meaningful signal only when kprove is healthy on the sibling positive claim. In
  // this sandbox kprove has been observed to die with "Haskell Backend execution failed"
  // when TMPDIR is not /tmp; the brief's "Critical environment facts" directs setting
  // TMPDIR=/tmp, which the run harness does. Under that fix the control's failure here is a
  // real counterexample, not incidental.
  claim <k> #run => .K </k>
        <program> b"\x25\x1c" +Bytes Int2Bytes(20, TOK, BE) +Bytes Int2Bytes(8, MIN, BE) +Bytes TAIL </program>
        <pc> 0 => 30 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> TAKER </taker>
        <balances> BALS </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>
    requires 0 <=Int TOK andBool TOK <Int (2 ^Int 160)
     andBool 0 <=Int MIN andBool MIN <Int (2 ^Int 64)
     andBool notBool #supplyShareSufficient(#balanceOf(BALS, TOK, TAKER), #totalSupply(TOK), MIN)
     andBool lengthBytes(TAIL) >=Int 0

endmodule

module TXORIGIN-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // DELIBERATELY FALSE. Must fail.
  //
  // Same program and same shape as txorigin-spec.k — opcode 0x26 argsLen 20, token TOK in
  // [0, 2^160), arbitrary symbolic TAIL — but the premise fixes tx.origin's balance of
  // TOK to be STRICTLY POSITIVE (`#balanceOf(BALS, TOK, #txOrigin()) >Int 0`), which
  // selects the PASS arm of the 0x26 rule (opcodes/txorigin.k). The PASS arm leaves #run
  // in <k> and the loop proceeds to decode the symbolic TAIL; the conclusion asserts the
  // WRONG post-state (`Reverted("TxOriginTokenBalanceIsZero")`). The premise selects the
  // PASS arm, which does not halt and does not revert, so this claim is false on every
  // model satisfying the rule: in the resulting configuration <status> stays `Running`
  // and execution continues into TAIL, never reaching the claimed Reverted state.
  //
  // WHY THIS SHAPE. Mirrors negative-control.k (the 0x23 twin), deadline-control.k,
  // gte-control.k, and supplyshare-control.k: the program prefix is concrete (so the
  // prover can actually decode opcode 0x26), the rule fires for real, and the failure is
  // on the conclusion — not on a stuck decode. If this control ever PROVES, the rule set
  // is inconsistent (e.g. the 0x26 PASS arm lost its `>Int 0` guard, or both arms produce
  // the same outcome) and txorigin-spec.k above is void (proofs/README.md:20-28).
  //
  // The sensitivity twin is txorigin-spec.k itself: same premises, correct conclusion,
  // must prove. Together they show kprove is discriminating on the conclusion rather than
  // choking on the setup.
  //
  // NOTE on the conclusion. Per the convention established in negative-control.k, this
  // control asserts the SAME Reverted conclusion as the positive claim (not `Running`),
  // so that its failure is unambiguously attributable to the arm selected by the premise
  // rather than to a different post-state assertion. The diagnostic is: the positive
  // claim's premise (`==Int 0`) selects REVERT and the claim proves; this control's
  // premise (`>Int 0`) selects PASS, the rule does not revert, and the Reverted
  // conclusion is never reached.
  //
  // ENV CAVEAT. Like deadline-control.k and the other sibling controls, this control's
  // non-zero exit is the meaningful signal only when kprove is healthy on the sibling
  // positive claim. In this sandbox kprove has been observed to die with "Haskell Backend
  // execution failed" when TMPDIR is not /tmp; the brief's "Critical environment facts"
  // directs setting TMPDIR=/tmp, which the run harness does. Under that fix the control's
  // failure here is a real counterexample, not incidental.
  claim <k> #run => .K </k>
        <program> b"\x26\x14" +Bytes Int2Bytes(20, TOK, BE) +Bytes TAIL </program>
        <pc> 0 => 22 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> BALS </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("TxOriginTokenBalanceIsZero") </status>
        <trace> _ </trace>
    requires 0 <=Int TOK andBool TOK <Int (2 ^Int 160)
     andBool #balanceOf(BALS, TOK, #txOrigin()) >Int 0
     andBool lengthBytes(TAIL) >=Int 0

endmodule

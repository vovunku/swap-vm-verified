module PRIVATEORDER-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // DELIBERATELY FALSE. Must fail.
  //
  // Same program and same shape as privateorder-spec.k — opcode 0x2b argsLen 10, packed
  // taker PACKED in [0, 2^80), arbitrary symbolic TAIL — but the premise fixes the
  // taker's low 80 bits to EQUAL PACKED (`(TAKER modInt 2^80) ==Int PACKED`), which
  // selects the PASS arm of the 0x2b rule (opcodes/privateorder.k). The PASS arm leaves
  // #run in <k> and the loop proceeds to decode the symbolic TAIL; the conclusion
  // asserts the WRONG post-state (`Reverted("WhitelistInvalidTaker")`). The premise
  // selects the PASS arm, which does not halt and does not revert, so this claim is
  // false on every model satisfying the rule: in the resulting configuration <status>
  // stays `Running` and execution continues into TAIL, never reaching the claimed
  // Reverted state.
  //
  // WHY THIS SHAPE. Mirrors negative-control.k (the 0x23 twin), txorigin-control.k
  // (the 0x26 twin), deadline-control.k, gte-control.k, and supplyshare-control.k: the
  // program prefix is concrete (so the prover can actually decode opcode 0x2b), the
  // rule fires for real, and the failure is on the conclusion — not on a stuck decode.
  // If this control ever PROVES, the rule set is inconsistent (e.g. the 0x2b PASS arm
  // lost its `==Int` guard, or both arms produce the same outcome) and
  // privateorder-spec.k above is void (proofs/README.md:20-28).
  //
  // The sensitivity twin is privateorder-spec.k itself: same program, the OPPOSITE
  // premise (`=/=Int`), correct conclusion, must prove. Together they show kprove is
  // discriminating on the arm selected by the premise rather than choking on the setup.
  //
  // NOTE on the conclusion. Per the convention established in negative-control.k and
  // followed by txorigin-control.k, this control asserts the SAME Reverted conclusion
  // as the positive claim (not `Running`), so that its failure is unambiguously
  // attributable to the arm selected by the premise rather than to a different
  // post-state assertion. The diagnostic is: the positive claim's premise (`=/=Int`)
  // selects REVERT and the claim proves; this control's premise (`==Int`) selects PASS,
  // the rule does not revert, and the Reverted conclusion is never reached.
  //
  // FIDELITY NOTE. The premise ranges over the taker's low 80 bits (`TAKER modInt 2^80`),
  // matching the rule's projection. TAKER itself is the full 160-bit address in the
  // <taker> cell; only its low 80 bits are consulted, faithfully mirroring
  // `uint80(uint160(taker))`. See opcodes/privateorder.md "The 80-bit packing".
  claim <k> #run => .K </k>
        <program> b"\x2b\x0a" +Bytes Int2Bytes(10, PACKED, BE) +Bytes TAIL </program>
        <pc> 0 => 12 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> TAKER </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("WhitelistInvalidTaker") </status>
        <trace> _ </trace>
    requires 0 <=Int PACKED andBool PACKED <Int (2 ^Int 80)
     andBool (TAKER modInt (2 ^Int 80)) ==Int PACKED
     andBool lengthBytes(TAIL) >=Int 0

endmodule

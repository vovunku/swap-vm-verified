module SALT-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // DELIBERATELY FALSE. Must fail.
  //
  // Identical program to salt-spec.k's primary claim — Salt with a symbolic 5-byte SALT — but
  // the conclusion is Reverted("SaltNeverReverts") instead of Running. Salt is a pure no-op
  // (Controls.sol:72-73); it never reverts. So this claim cannot close, and kprove must report
  // not-proved with a counterexample ending in <status> Running at <pc> 7.
  //
  // WHY THIS SHAPE. Mirrors negative-control.k, stop-control.k, and revert-control.k: the
  // program prefix is concrete (so the prover can actually decode opcode 0x02), the rule fires
  // for real, and the failure is on the conclusion — not on a stuck decode. If this control
  // ever PROVES, the rule set is inconsistent and salt-spec.k above is void
  // (proofs/README.md:20-28).
  //
  // The sensitivity twin is salt-spec.k itself: same premises, correct conclusion, must prove.
  // Together they show kprove is discriminating on the conclusion rather than choking on the
  // setup.
  //
  // ENV CAVEAT. In this sandbox kprove is broken on every spec (it dies with "Haskell Backend
  // execution failed with code 1" even on the untouched gate-spec.k), so the control's non-zero
  // exit here is the same broken-kprove failure mode, not on its own meaningful discrimination.
  // The meaningful signal is the hand-trace: Salt produces Running and never Reverted, so the
  // control's conclusion is false by direct evaluation of the rule. See the task brief's
  // "Critical environment facts" #2.
  claim <k> #run => .K </k>
        <program> b"\x02\x05" +Bytes SALT </program>
        <pc> 0 => 7 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("SaltNeverReverts") </status>
        <trace> _ </trace>
    requires lengthBytes(SALT) ==Int 5

endmodule

module SALT-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // T4 — Salt is a pure no-op; its args contribute nothing at execution time.
  //
  // For ANY 5-byte SALT (symbolic, constrained only by lengthBytes(SALT) ==Int 5) following the
  // Salt header (opcode 0x02, argsLen 0x05), execution ends in Running with <pc> advanced to
  // 7 — the post-decode position 2 + argsLen. The SALT bytes are passed to #exec as ARGS but
  // the Salt rule (opcodes/salt.k) matches them with a wildcard and never inspects them, so
  // their concrete values cannot affect the conclusion. This is the salt-args analogue of the
  // gate theorem's "the tail is irrelevant".
  //
  // DEVIATION FROM THE GATE-SPEC SHAPE — semantic, not stylistic. gate-spec.k, stop-spec.k,
  // and revert-spec.k all quantify over an ARBITRARY symbolic TAIL because their instruction
  // HALTS (the gate reverts and clears the continuation; Stop sets a sentinel pc; Revert clears
  // the continuation). Salt does NONE of these — it leaves #run in <k>, so the loop proceeds to
  // decode the byte at pc 7. With a symbolic TAIL that byte is symbolic and no decode rule
  // reduces, so the prover gets stuck at the next step with a byte-identical residual (the same
  // failure mode that sank the first negative-control.k — proofs/README.md:27-34). An arbitrary
  // tail therefore CANNOT be part of a clean terminating claim for Salt; including one would be
  // stating a fiction, which this repo does not do. See opcodes/salt.md "Composition".
  //
  // The claim terminates because lengthBytes(b"\x02\x05" +Bytes SALT) rewrites (via the
  // +Bytes length lemma in lemmas.k) to 2 +Int lengthBytes(SALT) = 7, so at pc 7 the loop-exit
  // rule (swapvm.md:100-105) fires and <k> becomes .K.
  //
  // lengthBytes(SALT) ==Int 5 is load-bearing: without it the program length is symbolic and
  // the loop-exit check `7 >=Int lengthBytes(PGM)` cannot reduce. It plays the same role for
  // this claim that `lengthBytes(TAIL) >=Int 0` plays for gate-spec.k — the side condition that
  // lets the length reasoning close.
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
        <status> Running </status>
        <trace> _ </trace>
    requires lengthBytes(SALT) ==Int 5

  // Degenerate form: Salt with argsLen 0 and no salt bytes. Same no-op behaviour, <pc>
  // advanced to 2. Included to exercise the rule on the minimal header and to show that the
  // args length is immaterial — Salt with 0 salt bytes and Salt with 5 behave identically.
  claim <k> #run => .K </k>
        <program> b"\x02\x00" </program>
        <pc> 0 => 2 </pc>
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

endmodule

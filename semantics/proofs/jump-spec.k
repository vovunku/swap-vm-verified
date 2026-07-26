module JUMP-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // Jump overwrites the decode-advanced <pc>.
  //
  // For a program consisting ONLY of a Jump (opcode 0x03, argsLen 0x02, 2-byte target TGT in
  // [0, 65535]), execution ends in Running with <pc> == TGT -- NOT 4, the post-decode value
  // (2 + argsLen). This is the decisive test: the Jump rule (opcodes/jump.k) must OVERWRITE
  // the <pc> that the decode loop already advanced by `2 + argsLen`, mirroring
  // `pcs = ctx.vm.nextPC` after dispatch in VM.sol. swapvm.md:138-140 states this directly.
  //
  // PROOF SHAPE -- WHY THE PROGRAM IS EXACTLY 4 BYTES, WITH NO TAIL.
  //
  // gate-spec.k, stop-spec.k, and revert-spec.k all quantify over an ARBITRARY symbolic TAIL
  // because their instruction HALTS (revert clears the continuation; Stop sets a sentinel pc).
  // Jump does not halt -- it leaves #run in <k>, so the loop proceeds to decode the byte at the
  // jumped-to <pc>. With an arbitrary tail whose first byte is symbolic, no decode rule reduces
  // and the prover gets stuck on a residual indistinguishable from a false claim's -- the same
  // failure mode that sank the first negative-control.k (proofs/README.md:27-34).
  //
  // The honest shape is to constrain the program so that the JUMP ITSELF lands past the end,
  // which makes the loop-exit rule (swapvm.md:100-105) fire on the next step without decoding
  // any further instruction. The minimal such program is exactly the 4-byte Jump:
  // `b"\x03\x02" +Bytes Int2Bytes(2, TGT, BE)` has length 4, and after the jump <pc> = TGT.
  // The premise `TGT >=Int 4` (implicit because TGT lands inside [0, 65535] and we need
  // TGT >= lengthBytes(PGM) = 4 to trigger the loop-exit) makes the loop-exit rule fire on
  // the next step: <k> becomes .K, <status> stays Running. So the proof closes cleanly.
  //
  // TGT < 4 would land the jump inside the Jump instruction's own header -- a real corner case
  // (the real VM would then re-decode the bytes at that position, possibly infinitely). The
  // claim deliberately scopes to TGT in [4, 65535], so the jump lands past the end and the
  // program terminates. The behaviour for TGT in [0, 3] is real but out of scope for this
  // theorem and is left to the conformance harness.
  //
  // The `lengthBytes(TAIL) >=Int 0` analogue is the bound `0 <=Int TGT` -- load-bearing: without
  // it the prover cannot establish the loop-exit side condition `TGT >=Int lengthBytes(PGM)`
  // because lengthBytes(PGM) rewrites to 4 and the SMT solver needs the upper and lower bound
  // on TGT to discharge `TGT >=Int 4`.
  claim <k> #run => .K </k>
        <program> b"\x03\x02" +Bytes Int2Bytes(2, TGT, BE) </program>
        <pc> 0 => TGT </pc>
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
    requires 4 <=Int TGT andBool TGT <Int 65536

endmodule

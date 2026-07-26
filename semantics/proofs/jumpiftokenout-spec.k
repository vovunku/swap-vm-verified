module JUMPIFTOKENOUT-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // 0x32 JumpIfTokenOut overwrites the decode-advanced <pc> when its condition holds.
  //
  // Structurally identical to jumpiftokenin-spec.k, reading <tokenOut> instead of <tokenIn>.
  //
  // For a program consisting ONLY of a JumpIfTokenOut (opcode 0x32, argsLen 0x16, 20-byte token
  // TOK, 2-byte target TGT in [0, 65535]), when Bytes2Int(ARGS[0:20], BE, Unsigned) == tokenOut
  // -- which with ARGS = Int2Bytes(20, TOK, BE) +Bytes Int2Bytes(2, TGT, BE) reduces (via the
  // Bytes2Int/Int2Bytes round-trip lemma in lemmas.k) to TOK == tokenOut -- execution ends in
  // Running with <pc> == TGT, NOT 24 (the post-decode value, 2 + argsLen). Conditional twin of
  // proofs/jump-spec.k.
  //
  // PROOF SHAPE — program is exactly 24 bytes, no tail. Same logic as jump-spec.k,
  // jumpifdirection-spec.k, jumpiftokenin-spec.k: the instruction does not halt on its taken
  // branch, so TGT must land at or past the program end (length 24) to fire the loop-exit rule
  // (swapvm.md:100-105) cleanly. The minimal program is
  // `b"\x32\x16" +Bytes Int2Bytes(20, TOK, BE) +Bytes Int2Bytes(2, TGT, BE)`.
  //
  // TGT in [24, 65535] is the scope.
  claim <k> #run => .K </k>
        <program> b"\x32\x16" +Bytes Int2Bytes(20, TOK, BE) +Bytes Int2Bytes(2, TGT, BE) </program>
        <pc> 0 => TGT </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> TOK </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>
    requires 24 <=Int TGT andBool TGT <Int 65536
     andBool 0 <=Int TOK andBool TOK <Int (2 ^Int 160)

endmodule

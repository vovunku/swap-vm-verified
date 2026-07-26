module JUMPIFTOKENIN-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // 0x31 JumpIfTokenIn overwrites the decode-advanced <pc> when its condition holds.
  //
  // For a program consisting ONLY of a JumpIfTokenIn (opcode 0x31, argsLen 0x16, 20-byte token
  // TOK, 2-byte target TGT in [0, 65535]), when the token-equality condition holds -- i.e.
  // when Bytes2Int(ARGS[0:20], BE, Unsigned) == tokenIn, which with ARGS = Int2Bytes(20, TOK, BE)
  // +Bytes Int2Bytes(2, TGT, BE) reduces (via the Bytes2Int/Int2Bytes round-trip lemma in
  // lemmas.k) to TOK == tokenIn -- execution ends in Running with <pc> == TGT, NOT 24 (the
  // post-decode value, 2 + argsLen). This is the conditional twin of proofs/jump-spec.k.
  //
  // PROOF SHAPE — why the program is exactly 24 bytes, with no tail. Same logic as jump-spec.k
  // and jumpifdirection-spec.k: JumpIfTokenIn does not halt on its taken branch, so the loop
  // proceeds to decode the byte at the jumped-to <pc>. With an arbitrary tail the prover gets
  // stuck. The honest shape is to constrain TGT so the jump lands at or past the end of the
  // program (length 24), which makes the loop-exit rule (swapvm.md:100-105) fire on the next
  // step. The minimal such program is
  // `b"\x31\x16" +Bytes Int2Bytes(20, TOK, BE) +Bytes Int2Bytes(2, TGT, BE)` (length 24).
  //
  // The `<tokenIn> TOK </tokenIn>` cell pin plus the premise `0 <=Int TOK andBool TOK <Int
  // (2 ^Int 160)` makes the jump arm fire: the arm's side condition is
  // `TIN ==Int Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned)`, which the round-trip lemma
  // reduces to `TIN ==Int TOK` — satisfied by the cell pin — exactly when TOK is in the 160-bit
  // unsigned range.
  //
  // TGT in [24, 65535] is the scope (mirrors jump-spec.k's [4, 65535] and
  // jumpifdirection-spec.k's [5, 65535]).
  claim <k> #run => .K </k>
        <program> b"\x31\x16" +Bytes Int2Bytes(20, TOK, BE) +Bytes Int2Bytes(2, TGT, BE) </program>
        <pc> 0 => TGT </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> TOK </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>
    requires 24 <=Int TGT andBool TGT <Int 65536
     andBool 0 <=Int TOK andBool TOK <Int (2 ^Int 160)

endmodule

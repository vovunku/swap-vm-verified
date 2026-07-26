module JUMPIFDIRECTION-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // 0x30 JumpIfDirection overwrites the decode-advanced <pc> when its condition holds.
  //
  // For a program consisting ONLY of a JumpIfDirection (opcode 0x30, argsLen 0x03, 1-byte
  // direction = 0x01, 2-byte target TGT in [0, 65535]), when the swapDirection condition holds
  // -- i.e. when (ARGS[0] =/=Int 0) == (TIN <Int TOUT), which with ARGS[0] = 0x01 reduces to
  // TIN <Int TOUT -- execution ends in Running with <pc> == TGT, NOT 5 (the post-decode value,
  // 2 + argsLen). This is the conditional twin of proofs/jump-spec.k: the jump arm of
  // opcodes/jumps.k must OVERWRITE the <pc> that the decode loop already advanced by `2 +
  // argsLen`, exactly as opcodes/jump.k does for the unconditional Jump.
  //
  // PROOF SHAPE — why the program is exactly 5 bytes, with no tail. Same logic as jump-spec.k:
  // JumpIfDirection does not halt — on the taken branch it leaves #run in <k>, so the loop
  // proceeds to decode the byte at the jumped-to <pc>. With an arbitrary tail whose first byte
  // is symbolic, no decode rule reduces and the prover gets stuck. The honest shape is to
  // constrain TGT so the jump lands at or past the end of the program (length 5), which makes
  // the loop-exit rule (swapvm.md:100-105) fire on the next step. The minimal such program is
  // `b"\x30\x03" +Bytes b"\x01" +Bytes Int2Bytes(2, TGT, BE)` (length 5), and after the jump
  // <pc> = TGT >= 5 = lengthBytes(PGM), so the loop-exit rule fires.
  //
  // TGT in [5, 65535] is the scope (mirrors jump-spec.k's [4, 65535]). TGT < 5 would land the
  // jump inside the instruction's own bytes -- a real corner case, out of scope here.
  //
  // The premise `TIN <Int TOUT` makes the jump arm fire: with ARGS[0] = 0x01, the condition
  // `(ARGS[0] =/=Int 0) ==Bool (TIN <Int TOUT)` reduces to `true ==Bool (TIN <Int TOUT)`, which
  // holds iff TIN <Int TOUT.
  claim <k> #run => .K </k>
        <program> b"\x30\x03" +Bytes b"\x01" +Bytes Int2Bytes(2, TGT, BE) </program>
        <pc> 0 => TGT </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> TIN </tokenIn> <tokenOut> TOUT </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>
    requires 5 <=Int TGT andBool TGT <Int 65536
     andBool TIN <Int TOUT

endmodule

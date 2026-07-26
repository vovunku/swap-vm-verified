module EXTRUCTION-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // T-extruction — Extruction reverts in the model with "ExtructionUnmodelled".
  //
  // The real VM's _extruction (Extruction.sol:90-115) delegates to a maker-chosen external
  // contract whose return values overwrite <pc>, the chop cursor, and the entire <swap>
  // cell. That external call is an abstraction boundary (PLAN.md D4) and cannot be modelled
  // soundly without modelling arbitrary code. The K rule (opcodes/extruction.k) therefore
  // reverts loudly with "ExtructionUnmodelled" for canonical-or-longer args (>= 20 bytes),
  // following the same loud-not-silent discipline as swapvm.md:301-324, 330-346. See
  // opcodes/extruction.md "Strategy" for the (A)-vs-(B) decision.
  //
  // For ANY program that begins with Extruction (opcode 0x04, argsLen 0x14, 20-byte target
  // TGT in [0, 2^160)) followed by an arbitrary symbolic TAIL, execution ends reverted with
  // reason "ExtructionUnmodelled". TAIL is never decoded: #revert discards the continuation
  // (swapvm.md:154-156), so its contents cannot affect the conclusion and the proof must
  // not case-split on it.
  //
  // PROOF SHAPE — same as gate-spec.k, stop-spec.k, and revert-spec.k. Those three also
  // quantify over an arbitrary symbolic TAIL because their instruction HALTS (the gate
  // reverts; Stop sets a sentinel pc; Revert clears the continuation). Extruction shares
  // that shape: #revert clears the continuation, so an arbitrary tail cannot affect the
  // conclusion and including one is honest, not a fiction.
  //
  // The `lengthBytes(TAIL) >=Int 0` side condition is NOT decorative — do not delete. Once
  // `lengthBytes(b"\x04\x14" +Bytes Int2Bytes(20, TGT, BE) +Bytes TAIL)` rewrites (via the
  // +Bytes length lemma in lemmas.k) to `22 +Int lengthBytes(TAIL)`, no axiom forces
  // `lengthBytes` non-negative, so without it the prover can take the termination branch at
  // <pc> 0 and the claim gets stuck. Same reason as gate-spec.k:27-32, revert-spec.k:18-22,
  // and stop-spec.k:16-19.
  //
  // The 2^160 bound on TGT mirrors gate-spec.k:25 — Int2Bytes(20, TGT, BE) is exactly
  // 20 bytes precisely when 0 <= TGT < 2^160, which the round-trip lemma in lemmas.k
  // relies on. Without the bound the args length is not provably 20 and the canonical-guard
  // arm of the Extruction rule does not reduce.
  //
  // Sensitivity twin: extruction-control.k — same premises, conclusion Running instead of
  // Reverted — must FAIL. Together they show kprove is discriminating on the conclusion.
  claim <k> #run => .K </k>
        <program> b"\x04\x14" +Bytes Int2Bytes(20, TGT, BE) +Bytes TAIL </program>
        <pc> 0 => 22 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("ExtructionUnmodelled") </status>
        <trace> _ </trace>
    requires 0 <=Int TGT andBool TGT <Int (2 ^Int 160)
     andBool lengthBytes(TAIL) >=Int 0

endmodule

module GTE-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // Phase 1 sibling of gate-spec.k and deadline-spec.k. For ANY program that begins with
  // OnlyTakerTokenBalanceGte(TOK, MIN) — with TAIL an arbitrary, symbolic byte string — a
  // taker whose balance of TOK is strictly less than MIN ends reverted with
  // "TakerTokenBalanceIsLessThanRequired".
  //
  // TAIL is never decoded: #revert discards the continuation (swapvm.md:154-156), so its
  // contents cannot affect the conclusion and the proof must not case-split on it. Same shape
  // as gate-spec.k, revert-spec.k, stop-spec.k, and deadline-spec.k.
  //
  // b"\x24\x34" is the [opcode:1][argsLen:1] header — opcode 0x24 = 36 decimal, argsLen 0x34 =
  // 52 decimal (20-byte token + 32-byte minAmount). After the decode loop fires <pc> = 2 + 52
  // = 54. The token and minAmount values are constructed via Int2Bytes with explicit widths so
  // the round-trip lemma in lemmas.k:64-67 rewrites
  //   Bytes2Int(Int2Bytes(20, TOK, BE), BE, Unsigned) => TOK
  //   Bytes2Int(Int2Bytes(32, MIN, BE), BE, Unsigned) => MIN
  // exactly, under the premises `0 <=Int TOK <Int 2^160` (the lemma's bound with N = 20) and
  // `0 <=Int MIN <Int 2^256` (the lemma's bound with N = 32). The 0 <=Int MIN lower bound alone
  // would also suffice for non-negativity, but the upper bound is included because minAmount is
  // a uint256 and the lemma needs `V <Int 2 ^Int (8 *Int N)` for N = 32 to fire.
  //
  // ARM SELECTION — why the premise is `#balanceLtMin(TOK, MIN)` and not
  // `#balanceOf(BALS, TOK, TAKER) <Int MIN`. The Gte rule (opcodes/gte.k) has two canonical
  // arms that split on whether the taker's balance of TOK is less than MIN. The natural
  // Solidity-faithful condition is `#balanceOf(...) <Int MIN` vs `#balanceOf(...) >=Int MIN`,
  // and a spec premise `#balanceOf(...) <Int MIN` OUGHT to select the REVERT arm by
  // contradicting the PASS arm. Empirically it does not: the K Haskell backend does not
  // propagate an inequality premise on an uninterpreted-vs-symbolic comparison into a
  // refutation of the opposite arm (opcodes/deadline.md:125-156), so the PASS arm is also
  // explored; the PASS arm does not halt, the loop runs into a symbolic TAIL, and the
  // all-path claim stalls. The gate rule avoids this because its arms compare `#balanceOf(...)`
  // to a CONSTANT (0), not a symbolic value, and constant reasoning IS propagated. The fix —
  // recorded in opcodes/gte.k and gte.md "Arm selection" — is to abstract the comparison
  // itself into a Bool predicate `#balanceLtMin(TOK, MIN)` (conceptually
  // `#balanceOf(BALS, TOK, TAKER) <Int MIN`) and branch on THAT. A premise `#balanceLtMin(TOK,
  // MIN)` (implicitly `==Bool true`) then selects the REVERT arm exactly as
  // `#balanceOf(...) ==Int 0` selects the gate's REVERT arm and `#deadlineExceeded(DL)`
  // selects Deadline's REVERT arm.
  //
  // The `lengthBytes(TAIL) >=Int 0` side condition is NOT decorative — do not delete. Once
  // `lengthBytes(b"\x24\x34" +Bytes Int2Bytes(20, TOK, BE) +Bytes Int2Bytes(32, MIN, BE)
  // +Bytes TAIL)` rewrites to `54 +Int lengthBytes(TAIL)`, no axiom forces `lengthBytes`
  // non-negative, so without this premise the prover can take the `PC >= length` termination
  // branch at <pc> 0 and the claim gets stuck. Same reason as gate-spec.k:27-32,
  // revert-spec.k:18-22, stop-spec.k:21-24, and deadline-spec.k:37-41.
  //
  // NOTE on the opcode byte: it is `\x24` (= 36 decimal), NOT `\x24` reading as 24 decimal.
  // The rule keys on the DECIMAL opcode `#exec ( 36 , ARGS )` and the program byte is the hex
  // literal 0x24 = 36 decimal. (0x24 is the unusual case where the hex and decimal readings
  // diverge by 12, easy to mistype as `\x36`.)
  //
  // Sensitivity twin: gte-control.k — same premises, conclusion `Running` instead of
  // `Reverted("TakerTokenBalanceIsLessThanRequired")` — must FAIL. Together they show kprove
  // is discriminating on the conclusion rather than choking on the setup.
  claim <k> #run => .K </k>
        <program> b"\x24\x34" +Bytes Int2Bytes(20, TOK, BE) +Bytes Int2Bytes(32, MIN, BE) +Bytes TAIL </program>
        <pc> 0 => 54 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> TAKER </taker>
        <balances> BALS </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("TakerTokenBalanceIsLessThanRequired") </status>
        <trace> _ </trace>
    requires 0 <=Int TOK andBool TOK <Int (2 ^Int 160)
     andBool 0 <=Int MIN andBool MIN <Int (2 ^Int 256)
     andBool #balanceLtMin(TOK, MIN)
     andBool lengthBytes(TAIL) >=Int 0

endmodule

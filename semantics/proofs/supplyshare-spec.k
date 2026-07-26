module SUPPLYSHARE-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // Phase 1 sibling of gate-spec.k, deadline-spec.k, and gte-spec.k. For ANY program that
  // begins with OnlyTakerTokenSupplyShareGte(TOK, MIN) — with TAIL an arbitrary, symbolic
  // byte string — a taker whose (balance, totalSupply, minShareE18) triple FAILS the share
  // conjunction ends reverted with "TakerTokenBalanceSupplyShareIsLessThanRequired".
  //
  // TAIL is never decoded: #revert discards the continuation (swapvm.md:154-156), so its
  // contents cannot affect the conclusion and the proof must not case-split on it. Same
  // shape as gate-spec.k, revert-spec.k, stop-spec.k, deadline-spec.k, and gte-spec.k.
  //
  // b"\x25\x1c" is the [opcode:1][argsLen:1] header — opcode 0x25 = 37 decimal, argsLen
  // 0x1c = 28 decimal (20-byte token + 8-byte minShareE18). After the decode loop fires
  // <pc> = 2 + 28 = 30. The token and minShareE18 values are constructed via Int2Bytes
  // with explicit widths so the round-trip lemma in lemmas.k:64-67 rewrites
  //   Bytes2Int(Int2Bytes(20, TOK, BE), BE, Unsigned) => TOK
  //   Bytes2Int(Int2Bytes( 8, MIN, BE), BE, Unsigned) => MIN
  // exactly, under the premises `0 <=Int TOK <Int 2^160` (the lemma's bound with N = 20)
  // and `0 <=Int MIN <Int 2^64` (the lemma's bound with N = 8, matching the uint64 read).
  //
  // ARM SELECTION — why the premise is `notBool #supplyShareSufficient(...)` and not the
  // direct arithmetic. The SupplyShare rule (opcodes/supplyshare.k) has two canonical arms
  // that split on whether the share conjunction holds. The natural Solidity-faithful
  // condition is `totalSupply > 0 && balance * 1e18 >= minShare * totalSupply` vs its
  // negation, and a spec premise encoding the negation OUGHT to select the REVERT arm by
  // contradicting the PASS arm. Empirically it does not: the K Haskell backend does not
  // propagate an inequality premise on an uninterpreted-vs-symbolic comparison into a
  // refutation of the opposite arm (opcodes/deadline.md:125-156, opcodes/gte.md "Arm
  // selection"; confirmed twice this round by the Deadline and Gte subagents), so the PASS
  // arm is also explored; the PASS arm does not halt, the loop runs into a symbolic TAIL,
  // and the all-path claim stalls. The gate rule avoids this because its arms compare
  // `#balanceOf(...)` to a CONSTANT (0), not a symbolic value, and constant reasoning IS
  // propagated. The fix — recorded in opcodes/supplyshare.k and supplyshare.md "Arm
  // selection" — is to abstract the ENTIRE conjunction into a Bool predicate
  // `#supplyShareSufficient(BAL, TS, MIN)` (conceptually
  // `TS >Int 0 && BAL *Int 1e18 >=Int MIN *Int TS`) and branch on THAT. A premise
  // `notBool #supplyShareSufficient(BAL, TS, MIN)` (implicitly `==Bool true`) then selects
  // the REVERT arm exactly as `#balanceLtMin(TOK, MIN)` selects Gte's REVERT arm and
  // `#deadlineExceeded(DL)` selects Deadline's REVERT arm.
  //
  // Note the premise embeds `#balanceOf(BALS, TOK, TAKER)` and `#totalSupply(TOK)`
  // directly — they appear inside the predicate. The rule's side condition (after the
  // round-trip lemma fires) has the SAME shape, so cell unification (B=BALS, TAKER=TAKER)
  // plus Int rewrite makes the premise and the side condition syntactically identical.
  //
  // The `lengthBytes(TAIL) >=Int 0` side condition is NOT decorative — do not delete. Once
  // `lengthBytes(b"\x25\x1c" +Bytes Int2Bytes(20, TOK, BE) +Bytes Int2Bytes(8, MIN, BE)
  // +Bytes TAIL)` rewrites to `30 +Int lengthBytes(TAIL)`, no axiom forces `lengthBytes`
  // non-negative, so without this premise the prover can take the `PC >= length`
  // termination branch at <pc> 0 and the claim gets stuck. Same reason as gate-spec.k:27-32,
  // revert-spec.k:18-22, stop-spec.k:21-24, deadline-spec.k:37-41, and gte-spec.k:43-48.
  //
  // NOTE on the opcode byte: it is `\x25` (= 37 decimal), NOT `\x37` (= 55 decimal). The
  // rule keys on the DECIMAL opcode `#exec ( 37 , ARGS )` and the program byte is the hex
  // literal 0x25 = 37 decimal. Easy to mistype as `\x37` (which would land on an
  // unmodelled opcode and fall through to `[owise]`).
  //
  // Sensitivity twin: supplyshare-control.k — same premises, conclusion `Running` instead
  // of `Reverted("TakerTokenBalanceSupplyShareIsLessThanRequired")` — must FAIL. Together
  // they show kprove is discriminating on the conclusion rather than choking on the setup.
  claim <k> #run => .K </k>
        <program> b"\x25\x1c" +Bytes Int2Bytes(20, TOK, BE) +Bytes Int2Bytes(8, MIN, BE) +Bytes TAIL </program>
        <pc> 0 => 30 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> TAKER </taker>
        <balances> BALS </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("TakerTokenBalanceSupplyShareIsLessThanRequired") </status>
        <trace> _ </trace>
    requires 0 <=Int TOK andBool TOK <Int (2 ^Int 160)
     andBool 0 <=Int MIN andBool MIN <Int (2 ^Int 64)
     andBool notBool #supplyShareSufficient(#balanceOf(BALS, TOK, TAKER), #totalSupply(TOK), MIN)
     andBool lengthBytes(TAIL) >=Int 0

endmodule

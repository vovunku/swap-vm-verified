module TXORIGIN-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // Phase 1 sibling of gate-spec.k. For ANY program that begins with
  // OnlyTxOriginTokenBalanceNonZero(G) — with TAIL an arbitrary, symbolic byte string — a
  // tx.origin holding zero balance of G ends reverted with "TxOriginTokenBalanceIsZero".
  //
  // This is the tx.origin twin of gate-spec.k (the 0x23 claim): same shape, same
  // premise family, the only structural difference is that the balance consulted is
  // `#balanceOf(BALS, G, #txOrigin())` (uninterpreted environment EOA, opcodes/txorigin.k)
  // rather than `#balanceOf(BALS, G, TAKER)` (the <taker> cell). The opcode 0x26 rule
  // (opcodes/txorigin.k) is byte-for-byte identical to the 0x23 rule (swapvm.md:182-193)
  // modulo that one argument.
  //
  // TAIL is never decoded: #revert discards the continuation (swapvm.md:154-156), so its
  // contents cannot affect the conclusion and the proof must not case-split on it. Same
  // shape as gate-spec.k, deadline-spec.k, and stop-spec.k.
  //
  // b"\x26\x14" is the [opcode:1][argsLen:1] header — opcode 0x26 = 38 decimal, argsLen
  // 0x14 = 20 decimal (the uint160 token). After the decode loop fires <pc> = 2 + 20 = 22.
  // The token value itself is constructed via `Int2Bytes(20, TOK, BE)` so the round-trip
  // lemma in lemmas.k:64-67 rewrites `Bytes2Int(Int2Bytes(20, TOK, BE), BE, Unsigned) =>
  // TOK` exactly, under the premise `0 <=Int TOK andBool TOK <Int 2^160` (which is the
  // lemma's required bound `0 <=Int V andBool V <Int 2 ^Int (8 *Int N)` with N = 20).
  //
  // ARM SELECTION — why the premise is `#balanceOf(BALS, TOK, #txOrigin()) ==Int 0` and
  // not a Bool predicate. The 0x26 rule (opcodes/txorigin.k) splits on
  //   #balanceOf(B, TOKEN, #txOrigin()) >Int 0     (PASS)
  //   #balanceOf(B, TOKEN, #txOrigin()) <=Int 0    (REVERT)
  // i.e. it compares an uninterpreted function application to a CONSTANT (0). This is the
  // same form as the 0x23 gate (swapvm.md:182-193), which proves in the direct two-arm
  // form because constant reasoning IS propagated into arm refutation. The
  // Deadline/Gte/SupplyShare arm-selection limitation (which forces those opcodes into a
  // Bool-predicate form) ONLY affects inequalities against SYMBOLIC values; it does not
  // apply here. So a premise `#balanceOf(BALS, TOK, #txOrigin()) ==Int 0` selects the
  // REVERT arm directly — exactly as `#balanceOf(BALS, G, TAKER) ==Int 0` selects the
  // gate's REVERT arm in gate-spec.k.
  //
  // The `lengthBytes(TAIL) >=Int 0` side condition is NOT decorative — do not delete.
  // Once `lengthBytes(b"\x26\x14" +Bytes Int2Bytes(20, TOK, BE) +Bytes TAIL)` rewrites to
  // `22 +Int lengthBytes(TAIL)`, no axiom forces `lengthBytes` non-negative, so without
  // this premise the prover can take the `PC >= length` termination branch at <pc> 0 and
  // the claim gets stuck. Same reason as gate-spec.k:27-32, deadline-spec.k:37-41,
  // revert-spec.k, and stop-spec.k.
  //
  // Sensitivity twin: txorigin-control.k — same program and premises, conclusion
  // `Running` instead of `Reverted("TxOriginTokenBalanceIsZero")` — must FAIL. Together
  // they show kprove is discriminating on the conclusion rather than choking on the
  // setup.
  claim <k> #run => .K </k>
        <program> b"\x26\x14" +Bytes Int2Bytes(20, TOK, BE) +Bytes TAIL </program>
        <pc> 0 => 22 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> BALS </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("TxOriginTokenBalanceIsZero") </status>
        <trace> _ </trace>
    requires 0 <=Int TOK andBool TOK <Int (2 ^Int 160)
     andBool #balanceOf(BALS, TOK, #txOrigin()) ==Int 0
     // NOT decorative -- do not delete. It excludes no Bytes value semantically, but the
     // backend needs it: once `lengthBytes(B1 +Bytes B2)` rewrites the program length to
     // `22 +Int lengthBytes(TAIL)`, there is no axiom making `lengthBytes` non-negative,
     // so without this the prover takes the `PC >= length` termination branch and the
     // proof gets stuck at <pc> 0. Verified by deleting it in gate-spec.k.
     andBool lengthBytes(TAIL) >=Int 0

endmodule

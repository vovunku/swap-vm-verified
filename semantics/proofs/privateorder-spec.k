module PRIVATEORDER-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // 0x2b PrivateOrder — Whitelist.sol:103-110. Positive claim, REVERT direction.
  //
  // For ANY program that begins with PrivateOrder(PACKED) — with TAIL an arbitrary,
  // symbolic byte string — a taker whose low 80 bits do NOT equal PACKED ends reverted
  // with "WhitelistInvalidTaker".
  //
  // This is the 0x2b twin of gate-spec.k (the 0x23 claim): same shape, same premise
  // family, the structural difference is that the gate's predicate is an EXTERNAL read
  // (`#balanceOf(BALS, G, TAKER) ==Int 0`) compared to zero, while this opcode's
  // predicate is a PURE equality between two decoded values
  // (`(TAKER modInt 2^80) =/=Int PACKED`). Both select the REVERT arm directly because
  // the comparison is decidable — `0x23` compares to a constant 0, `0x2b` compares two
  // terms for equality. The 0x2b rule (opcodes/privateorder.k) is the equality twin of
  // the 0x23 rule (swapvm.md:182-193).
  //
  // TAIL is never decoded: #revert discards the continuation (swapvm.md:154-156), so its
  // contents cannot affect the conclusion and the proof must not case-split on it. Same
  // shape as gate-spec.k, txorigin-spec.k, deadline-spec.k, and stop-spec.k.
  //
  // b"\x2b\x0a" is the [opcode:1][argsLen:1] header — opcode 0x2b = 43 decimal, argsLen
  // 0x0a = 10 decimal (the 10-byte packed uint80 allowedTaker). After the decode loop
  // fires <pc> = 2 + 10 = 12. The packed value itself is constructed via
  // `Int2Bytes(10, PACKED, BE)` so the round-trip lemma in lemmas.k:64-67 rewrites
  // `Bytes2Int(Int2Bytes(10, PACKED, BE), BE, Unsigned) => PACKED` exactly, under the
  // premise `0 <=Int PACKED andBool PACKED <Int 2^80` (which is the lemma's required
  // bound `0 <=Int V andBool V <Int 2 ^Int (8 *Int N)` with N = 10).
  //
  // ARM SELECTION — why the premise is `(TAKER modInt 2^80) =/=Int PACKED` and not a
  // Bool predicate. The 0x2b rule (opcodes/privateorder.k) splits on
  //   (TAKER modInt (2 ^Int 80)) ==Int  Bytes2Int(ARGS, BE, Unsigned)   (PASS)
  //   (TAKER modInt (2 ^Int 80)) =/=Int Bytes2Int(ARGS, BE, Unsigned)   (REVERT)
  // After the round-trip lemma rewrites `Bytes2Int(Int2Bytes(10, PACKED, BE), ...) =>
  // PACKED`, both side conditions mention the same two terms
  // (`TAKER modInt (2 ^Int 80)` and `PACKED`) and split on equality. Equality between
  // two terms is decidable in the K Haskell backend (SMT-discharged), so the premise
  // `(TAKER modInt 2^80) =/=Int PACKED` refutes the PASS arm and selects the REVERT arm
  // directly — exactly as `#balanceOf(...) ==Int 0` selects the 0x23 REVERT arm. The
  // Deadline/Gte/SupplyShare arm-selection limitation (which forces those opcodes into a
  // Bool-predicate form) ONLY affects inequalities against SYMBOLIC values; it does not
  // apply to ==/=/=.
  //
  // The `lengthBytes(TAIL) >=Int 0` side condition is NOT decorative — do not delete.
  // Once `lengthBytes(b"\x2b\x0a" +Bytes Int2Bytes(10, PACKED, BE) +Bytes TAIL)`
  // rewrites to `12 +Int lengthBytes(TAIL)`, no axiom forces `lengthBytes`
  // non-negative, so without this premise the prover can take the `PC >= length`
  // termination branch at <pc> 0 and the claim gets stuck. Same reason as
  // gate-spec.k:27-32, txorigin-spec.k:40-45, deadline-spec.k:37-41, revert-spec.k,
  // and stop-spec.k.
  //
  // Sensitivity twin: privateorder-control.k — same program and SAME Reverted
  // conclusion, premise `(TAKER modInt 2^80) ==Int PACKED` (PASS arm selected) — must
  // FAIL. Together they show kprove is discriminating on the arm selected by the
  // premise rather than choking on the setup.
  //
  // FIDELITY NOTE. The premise ranges over the taker's FULL value TAKER (a 160-bit
  // address in the <taker> cell) but only its low 80 bits are compared — `modInt 2^80`
  // discards the high 80 bits, faithfully mirroring `uint80(uint160(taker))`
  // (Whitelist.sol:106, 83-84). Two takers sharing their low 10 bytes are
  // indistinguishable to this opcode and to this proof. See opcodes/privateorder.md
  // "The 80-bit packing" and Whitelist.sol:88-95 for the collision-resistance trade-off.
  claim <k> #run => .K </k>
        <program> b"\x2b\x0a" +Bytes Int2Bytes(10, PACKED, BE) +Bytes TAIL </program>
        <pc> 0 => 12 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> TAKER </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("WhitelistInvalidTaker") </status>
        <trace> _ </trace>
    requires 0 <=Int PACKED andBool PACKED <Int (2 ^Int 80)
     andBool (TAKER modInt (2 ^Int 80)) =/=Int PACKED
     // NOT decorative -- do not delete. It excludes no Bytes value semantically, but the
     // backend needs it: once `lengthBytes(B1 +Bytes B2)` rewrites the program length to
     // `12 +Int lengthBytes(TAIL)`, there is no axiom making `lengthBytes` non-negative,
     // so without this the prover takes the `PC >= length` termination branch and the
     // proof gets stuck at <pc> 0. Verified by deleting it in gate-spec.k.
     andBool lengthBytes(TAIL) >=Int 0

endmodule

module WHITELISTSEQUENTIAL-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // DELIBERATELY FALSE. Must fail.
  //
  // Same program as whitelistsequential-spec.k — opcode 0x2d argsLen 0x13 (19), TGT in
  // [21, 65535], START in [0, 2^40), DUR in [0, 2^16), PACKED in [0, 2^80), a single
  // (duration, address) entry matching the taker's low 80 bits — but the conclusion pins
  // <pc> to 21 (the post-decode value, `2 + argsLen`) instead of TGT (the value the JUMP arm
  // overwrites). This asserts that the 0x2d rule did NOT fire / did not overwrite <pc> —
  // i.e. that WhitelistSequential behaves like Salt or Revert, inheriting the decode-
  // advanced pc.
  //
  // The 0x2d JUMP arm (opcodes/whitelists.k) DOES overwrite <pc> when
  // `#sequentialWhitelistJumps(...)` holds (mirroring `pcs = ctx.vm.nextPC` in VM.sol;
  // swapvm.md:138-140). The premise of this control selects exactly that arm:
  // `#sequentialWhitelistJumps(...)` holds AND `(TAKER modInt 2^80) ==Int PACKED` (so the
  // entry matches the taker). So this claim is false on every model satisfying the rule: in
  // the resulting configuration <pc> equals TGT (any value in [21, 65535]) and never equals
  // 21 (since TGT = 21 is excluded by the premise `21 <Int TGT`, mirroring jump-control.k's
  // `4 <Int TGT` and whitelistcoequal-control.k's `14 <Int TGT`).
  //
  // WHY THIS SHAPE. Mirrors jump-control.k and whitelistcoequal-control.k (the JUMP-arm
  // twins), and negative-control.k, stop-control.k, revert-control.k, salt-control.k,
  // deadline-control.k, gte-control.k, supplyshare-control.k, txorigin-control.k, and
  // privateorder-control.k: the program prefix is concrete (so the prover can actually
  // decode opcode 0x2d), the rule fires for real, and the failure is on the conclusion —
  // not on a stuck decode. If this control ever PROVES, the rule set is inconsistent (e.g.
  // the 0x2d JUMP arm lost its `<pc> _ => ...` overwrite, or two arms produce the same
  // outcome) and whitelistsequential-spec.k above is void (proofs/README.md:20-28).
  //
  // The sensitivity twin is whitelistsequential-spec.k itself: same premises, correct
  // conclusion (<pc> => TGT), must prove. Together they show kprove is discriminating on
  // the conclusion rather than choking on the setup.
  //
  // FIDELITY NOTE. The premise ranges over the taker's low 80 bits (`TAKER modInt 2^80`),
  // matching the rule's projection. TAKER itself is the full 160-bit address in the <taker>
  // cell; only its low 80 bits are consulted, faithfully mirroring `uint80(uint160(taker))`.
  // See opcodes/privateorder.md "The 80-bit packing" and Whitelist.sol:88-95.
  claim <k> #run => .K </k>
        <program> b"\x2d\x13" +Bytes Int2Bytes(2, TGT, BE) +Bytes Int2Bytes(5, START, BE) +Bytes Int2Bytes(2, DUR, BE) +Bytes Int2Bytes(10, PACKED, BE) </program>
        <pc> 0 => 21 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> TAKER </taker>
        <balances> _ </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>
    requires 21 <Int TGT andBool TGT <Int 65536
     andBool 0 <=Int START andBool START <Int (2 ^Int 40)
     andBool 0 <=Int DUR andBool DUR <Int (2 ^Int 16)
     andBool 0 <=Int PACKED andBool PACKED <Int (2 ^Int 80)
     andBool (TAKER modInt (2 ^Int 80)) ==Int PACKED
     andBool #sequentialWhitelistJumps( Int2Bytes(2, TGT, BE) +Bytes Int2Bytes(5, START, BE) +Bytes Int2Bytes(2, DUR, BE) +Bytes Int2Bytes(10, PACKED, BE)
                                      , TAKER modInt (2 ^Int 80)
                                      )
     // MUTUAL-EXCLUSIVITY GUARD — same as whitelistsequential-spec.k. The control selects
     // the JUMP arm via #sequentialWhitelistJumps; without negating #sequentialWhitelistReverts
     // the prover would stall on the REVERT arm rather than failing cleanly on the <pc>
     // conclusion. The control's failure must be attributable to the wrong <pc> assertion,
     // not to a stall — see proofs/README.md:20-28.
     andBool notBool #sequentialWhitelistReverts( Int2Bytes(2, TGT, BE) +Bytes Int2Bytes(5, START, BE) +Bytes Int2Bytes(2, DUR, BE) +Bytes Int2Bytes(10, PACKED, BE)
                                               , TAKER modInt (2 ^Int 80)
                                               )

endmodule

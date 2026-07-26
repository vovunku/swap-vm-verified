module WHITELISTCOEQUAL-CONTROL
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // DELIBERATELY FALSE. Must fail.
  //
  // Same program as whitelistcoequal-spec.k — opcode 0x2c argsLen 0x0c (12), TGT in
  // [14, 65535], PACKED in [0, 2^80), a single 10-byte packed entry matching the taker's
  // low 80 bits — but the conclusion pins <pc> to 14 (the post-decode value, `2 + argsLen`)
  // instead of TGT (the value the JUMP arm overwrites). This asserts that the 0x2c rule did
  // NOT fire / did not overwrite <pc> — i.e. that WhitelistCoequal behaves like Salt or
  // Revert, inheriting the decode-advanced pc.
  //
  // The 0x2c JUMP arm (opcodes/whitelists.k) DOES overwrite <pc> when
  // `#coequalWhitelistContains(...)` holds (mirroring `pcs = ctx.vm.nextPC` in VM.sol;
  // swapvm.md:138-140). The premise of this control selects exactly that arm:
  // `#coequalWhitelistContains(...)` holds AND `(TAKER modInt 2^80) ==Int PACKED` (so the
  // entry matches the taker). So this claim is false on every model satisfying the rule: in
  // the resulting configuration <pc> equals TGT (any value in [14, 65535]) and never equals
  // 14 (since TGT = 14 is excluded by the premise `14 <Int TGT`, mirroring jump-control.k's
  // `4 <Int TGT`).
  //
  // WHY THIS SHAPE. Mirrors jump-control.k (the 0x03 twin), negative-control.k, stop-control.k,
  // revert-control.k, salt-control.k, deadline-control.k, gte-control.k, supplyshare-control.k,
  // txorigin-control.k, and privateorder-control.k: the program prefix is concrete (so the
  // prover can actually decode opcode 0x2c), the rule fires for real, and the failure is on
  // the conclusion — not on a stuck decode. If this control ever PROVES, the rule set is
  // inconsistent (e.g. the 0x2c JUMP arm lost its `<pc> _ => ...` overwrite, or both arms
  // produce the same outcome) and whitelistcoequal-spec.k above is void (proofs/README.md:20-28).
  //
  // The sensitivity twin is whitelistcoequal-spec.k itself: same premises, correct conclusion
  // (<pc> => TGT), must prove. Together they show kprove is discriminating on the conclusion
  // rather than choking on the setup.
  //
  // FIDELITY NOTE. The premise ranges over the taker's low 80 bits (`TAKER modInt 2^80`),
  // matching the rule's projection. TAKER itself is the full 160-bit address in the <taker>
  // cell; only its low 80 bits are consulted, faithfully mirroring `uint80(uint160(taker))`.
  // See opcodes/privateorder.md "The 80-bit packing" and Whitelist.sol:88-95.
  claim <k> #run => .K </k>
        <program> b"\x2c\x0c" +Bytes Int2Bytes(2, TGT, BE) +Bytes Int2Bytes(10, PACKED, BE) </program>
        <pc> 0 => 14 </pc>
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
    requires 14 <Int TGT andBool TGT <Int 65536
     andBool 0 <=Int PACKED andBool PACKED <Int (2 ^Int 80)
     andBool (TAKER modInt (2 ^Int 80)) ==Int PACKED
     andBool #coequalWhitelistContains( Int2Bytes(2, TGT, BE) +Bytes Int2Bytes(10, PACKED, BE)
                                      , TAKER modInt (2 ^Int 80)
                                      )

endmodule

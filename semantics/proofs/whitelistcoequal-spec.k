module WHITELISTCOEQUAL-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // 0x2c WhitelistCoequal — Whitelist.sol:112-129. Positive claim, JUMP direction.
  //
  // For a program consisting ONLY of a WhitelistCoequal whose single 10-byte packed entry
  // matches the taker's low 80 bits — args layout [pc:2][entry:10], total 12 bytes, opcode
  // 0x2c = 44 decimal, argsLen 0x0c = 12 — a taker in the list ends Running with <pc> == TGT,
  // the uint16 read from ARGS[0:2], NOT 14 (the post-decode value, 2 + 12). This is the
  // decisive JUMP test: the 0x2c JUMP arm (opcodes/whitelists.k) must OVERWRITE the <pc> that
  // the decode loop already advanced, mirroring `pcs = ctx.vm.nextPC` after dispatch in
  // VM.sol (swapvm.md:138-140). Twin of jump-spec.k, adapted to the WhitelistCoequal shape.
  //
  // PROOF SHAPE — WHY THE PROGRAM IS EXACTLY 14 BYTES, WITH NO TAIL. Same reason as
  // jump-spec.k:14-39. The 0x2c JUMP arm leaves #run in <k>, so the loop proceeds to decode
  // the byte at the jumped-to <pc>. With an arbitrary tail whose first byte is symbolic, no
  // decode rule reduces and the prover gets stuck on a residual indistinguishable from a
  // false claim's — the same failure mode that sank the first negative-control.k
  // (proofs/README.md:27-34). The honest shape is to constrain the program so that the JUMP
  // ITSELF lands past the end, which makes the loop-exit rule (swapvm.md:100-105) fire on
  // the next step without decoding any further instruction. The minimal such program is
  // exactly the 14-byte WhitelistCoequal with one entry: `b"\x2c\x0c" +Bytes
  // Int2Bytes(2, TGT, BE) +Bytes Int2Bytes(10, PACKED, BE)` has length 14, and after the
  // jump <pc> = TGT. The premise `TGT >=Int 14` makes the loop-exit rule fire on the next
  // step: <k> becomes .K, <status> stays Running. So the proof closes cleanly.
  //
  // b"\x2c\x0c" is the [opcode:1][argsLen:1] header — opcode 0x2c = 44 decimal, argsLen
  // 0x0c = 12 decimal (2-byte pc + 10-byte packed entry, N=1). After the decode loop fires
  // <pc> = 2 + 12 = 14. The packed entry is constructed via `Int2Bytes(10, PACKED, BE)` so
  // the predicate's second argument `(TAKER modInt (2 ^Int 80))` is compared against a
  // taker whose low 80 bits equal PACKED exactly, under the premise
  // `(TAKER modInt (2 ^Int 80)) ==Int PACKED`. The predicate `#coequalWhitelistContains`
  // itself is uninterpreted — the spec asserts it holds for this args+taker pair, which
  // selects the JUMP arm directly.
  //
  // NOTE on the predicate's first argument. The premise passes
  // `Int2Bytes(2, TGT, BE) +Bytes Int2Bytes(10, PACKED, BE)` — the 12-byte ARGS payload
  // AFTER the [opcode:1][argsLen:1] header, NOT the whole program. The decode rule
  // (swapvm.md:143-149) slices ARGS out of the program with `substrBytes(PGM, PC+2, ...)`
  // before #exec fires, so the rule's side condition is `#coequalWhitelistContains(ARGS, ...)`
  // where ARGS is exactly this 12-byte payload. Including the b"\x2c\x0c" header in the
  // premise (an early draft did) breaks unification — ARGS never equals the whole program
  // — and the proof stalls with both arms explorable. This matches how the Solidity names
  // `args` (the post-header payload) in `args.slice(2)` at Whitelist.sol:118.
  //
  // ARM SELECTION — why the premise is `#coequalWhitelistContains(ARGS, TAKER modInt 2^80)`
  // and not the literal byte-level loop. The 0x2c rule (opcodes/whitelists.k) has two
  // canonical arms that split on whether the taker's packed bits are in the list. The
  // Solidity-faithful condition is the result of `while (i-- > 0)` over `args.slice(2)`'s
  // 10-byte entries — but this loop is INTRACTABLE for K to model: the list length
  // `lengthBytes(ARGS) -Int 2` divided by 10 is symbolic, the entries themselves are
  // arbitrary bytes, and unfolding the loop is not decidable. Per PLAN.md D4 (cross-ref
  // opcodes/extruction.md "The abstraction boundary (PLAN.md D4)"), the honest direction is
  // to abstract the loop's outcome as the uninterpreted Bool predicate
  // `#coequalWhitelistContains(ARGS, PACKED)`. A spec premise
  // `#coequalWhitelistContains(ARGS, TAKER modInt 2^80)` (implicitly `==Bool true`) selects
  // the JUMP arm exactly as `#deadlineExceeded(DL)` selects Deadline's REVERT arm and
  // `#balanceLtMin(TOK, MIN)` selects Gte's REVERT arm. The byte-level list parse and the
  // loop iteration are NOT modelled; this is the declared fidelity gap.
  //
  // The `0 <=Int TGT` lower bound is load-bearing in the same way jump-spec.k's is: the SMT
  // solver needs both bounds on TGT to discharge `TGT >=Int 14` against the loop-exit side
  // condition `TGT >=Int lengthBytes(PGM)` once lengthBytes(PGM) rewrites to 14.
  //
  // Sensitivity twin: whitelistcoequal-control.k — same program and SAME Running-with-<pc>=TGT
  // conclusion, premise `notBool #coequalWhitelistContains(...)` (FALL-THROUGH arm selected) —
  // must FAIL. Together they show kprove is discriminating on the arm selected by the
  // premise rather than choking on the setup.
  //
  // FIDELITY NOTE. The premise ranges over the taker's low 80 bits (`TAKER modInt 2^80`),
  // matching the rule's projection. TAKER itself is the full 160-bit address in the <taker>
  // cell; only its low 80 bits are consulted, faithfully mirroring `uint80(uint160(taker))`
  // (Whitelist.sol:117, 83-84). Two takers sharing their low 10 bytes are indistinguishable
  // to this opcode and to this proof. See opcodes/privateorder.md "The 80-bit packing".
  claim <k> #run => .K </k>
        <program> b"\x2c\x0c" +Bytes Int2Bytes(2, TGT, BE) +Bytes Int2Bytes(10, PACKED, BE) </program>
        <pc> 0 => TGT </pc>
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
    requires 14 <=Int TGT andBool TGT <Int 65536
     andBool 0 <=Int PACKED andBool PACKED <Int (2 ^Int 80)
     andBool (TAKER modInt (2 ^Int 80)) ==Int PACKED
     andBool #coequalWhitelistContains( Int2Bytes(2, TGT, BE) +Bytes Int2Bytes(10, PACKED, BE)
                                      , TAKER modInt (2 ^Int 80)
                                      )

endmodule

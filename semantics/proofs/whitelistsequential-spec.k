module WHITELISTSEQUENTIAL-SPEC
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS

  // 0x2d WhitelistSequential — Whitelist.sol:131-167. Positive claim, JUMP direction.
  //
  // For a program consisting ONLY of a WhitelistSequential whose single (duration,address)
  // entry matches the taker's low 80 bits at the current block timestamp — args layout
  // [pc:2][start:5][duration:2][entry:10], total 19 bytes, opcode 0x2d = 45 decimal,
  // argsLen 0x13 = 19 — a taker in the list ends Running with <pc> == TGT, the uint16 read
  // from ARGS[0:2], NOT 21 (the post-decode value, 2 + 19). This is the decisive JUMP test:
  // the 0x2d JUMP arm (opcodes/whitelists.k) must OVERWRITE the <pc> that the decode loop
  // already advanced, mirroring `pcs = ctx.vm.nextPC` after dispatch in VM.sol
  // (swapvm.md:138-140). Twin of jump-spec.k and whitelistcoequal-spec.k, adapted to the
  // WhitelistSequential three-outcome shape and selecting the JUMP arm.
  //
  // PROOF SHAPE — WHY THE PROGRAM IS EXACTLY 21 BYTES, WITH NO TAIL. Same reason as
  // whitelistcoequal-spec.k and jump-spec.k:14-39. The 0x2d JUMP arm leaves #run in <k>, so
  // the loop proceeds to decode the byte at the jumped-to <pc>. With an arbitrary tail whose
  // first byte is symbolic, no decode rule reduces and the prover gets stuck on a residual
  // indistinguishable from a false claim's (proofs/README.md:27-34). The honest shape is to
  // constrain the program so that the JUMP ITSELF lands past the end, which makes the
  // loop-exit rule (swapvm.md:100-105) fire on the next step without decoding further. The
  // minimal such program is exactly the 21-byte WhitelistSequential with one entry:
  // `b"\x2d\x13" +Bytes Int2Bytes(2, TGT, BE) +Bytes Int2Bytes(5, START, BE)
  //  +Bytes Int2Bytes(2, DUR, BE) +Bytes Int2Bytes(10, PACKED, BE)` has length 21, and
  // after the jump <pc> = TGT. The premise `TGT >=Int 21` makes the loop-exit rule fire on
  // the next step: <k> becomes .K, <status> stays Running. So the proof closes cleanly.
  //
  // b"\x2d\x13" is the [opcode:1][argsLen:1] header — opcode 0x2d = 45 decimal, argsLen
  // 0x13 = 19 decimal (2-byte pc + 5-byte start + (2-byte dur + 10-byte entry) for N=1).
  // The packed entry is constructed via `Int2Bytes(10, PACKED, BE)` so that
  // `(TAKER modInt 2^80) ==Int PACKED` matches the taker's low 80 bits, exactly as in
  // whitelistcoequal-spec.k. The START and DUR values are concretely bound but their
  // arithmetic against `block.timestamp` is INSIDE the predicate — not modelled directly.
  //
  // ARM SELECTION — why the premise is `#sequentialWhitelistJumps(ARGS, TAKER modInt 2^80)`
  // and not the literal byte-level loop. The 0x2d rule (opcodes/whitelists.k) has THREE
  // canonical arms — JUMP, REVERT, FALL THROUGH — that split on the joint outcome of the
  // loop, the timestamp-vs-start comparison, and the per-entry time-window arithmetic. This
  // is even harder to model literally than 0x2c: in addition to the variable-length byte
  // array loop, there is per-entry `timeLeft < duration` and `timeLeft -= duration`
  // arithmetic against an abstract `block.timestamp`, and the JUMP/REVERT outcome depends on
  // the INTERLEAVING of address matches and window expirations across the list. Per PLAN.md
  // D4 (cross-ref opcodes/extruction.md "The abstraction boundary (PLAN.md D4)"), the honest
  // direction is to abstract the joint outcome as two uninterpreted Bool predicates:
  //   - `#sequentialWhitelistJumps(ARGS, PACKED)` — true iff the JUMP arm fires.
  //   - `#sequentialWhitelistReverts(ARGS, PACKED)` — true iff the REVERT arm fires.
  // FALL THROUGH is the negation of both. A spec premise
  // `#sequentialWhitelistJumps(ARGS, TAKER modInt 2^80)` selects the JUMP arm directly. The
  // byte-level parse, the start-vs-timestamp comparison, the duration arithmetic, and the
  // in-window revert are ALL inside the predicates — NOT modelled.
  //
  // MUTUAL EXCLUSIVITY. By Solidity control flow, #sequentialWhitelistJumps and
  // #sequentialWhitelistReverts can never both hold (a JUMP returns before any REVERT can
  // fire). This fact is NOT enforced by K — the two predicates are independent uninterpreted
  // symbols. This spec selects the JUMP arm by its premise and trusts the exclusivity
  // itself; the soundness of doing so is the declared fidelity gap in opcodes/whitelists.md.
  //
  // The `0 <=Int TGT` lower bound is load-bearing for the same reason as in jump-spec.k and
  // whitelistcoequal-spec.k: the SMT solver needs both bounds on TGT to discharge
  // `TGT >=Int 21` against the loop-exit side condition once lengthBytes(PGM) rewrites to 21.
  //
  // Sensitivity twin: whitelistsequential-control.k — same program and SAME Running-with-
  // <pc>=TGT conclusion, premise `notBool #sequentialWhitelistJumps(...)` (FALL-THROUGH arm
  // selected) — must FAIL. Together they show kprove is discriminating on the arm selected
  // by the premise rather than choking on the setup.
  //
  // FIDELITY NOTE. The premise ranges over the taker's low 80 bits (`TAKER modInt 2^80`),
  // matching the rule's projection. TAKER itself is the full 160-bit address in the <taker>
  // cell; only its low 80 bits are consulted, faithfully mirroring `uint80(uint160(taker))`
  // (Whitelist.sol:142, 83-84). Two takers sharing their low 10 bytes are indistinguishable
  // to this opcode and to this proof. See opcodes/privateorder.md "The 80-bit packing".
  claim <k> #run => .K </k>
        <program> b"\x2d\x13" +Bytes Int2Bytes(2, TGT, BE) +Bytes Int2Bytes(5, START, BE) +Bytes Int2Bytes(2, DUR, BE) +Bytes Int2Bytes(10, PACKED, BE) </program>
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
    requires 21 <=Int TGT andBool TGT <Int 65536
     andBool 0 <=Int START andBool START <Int (2 ^Int 40)
     andBool 0 <=Int DUR andBool DUR <Int (2 ^Int 16)
     andBool 0 <=Int PACKED andBool PACKED <Int (2 ^Int 80)
     andBool (TAKER modInt (2 ^Int 80)) ==Int PACKED
     andBool #sequentialWhitelistJumps( Int2Bytes(2, TGT, BE) +Bytes Int2Bytes(5, START, BE) +Bytes Int2Bytes(2, DUR, BE) +Bytes Int2Bytes(10, PACKED, BE)
                                      , TAKER modInt (2 ^Int 80)
                                      )
     // MUTUAL-EXCLUSIVITY GUARD. The 0x2d rule has three canonical arms that split on
     // #sequentialWhitelistJumps / #sequentialWhitelistReverts / neither. By Solidity control
     // flow the JUMP and REVERT outcomes can never both hold (a JUMP returns before any REVERT
     // can fire). K does NOT know this: the two predicates are independent uninterpreted
     // symbols, and without this negation the prover explores the REVERT arm (whose side
     // condition #sequentialWhitelistReverts(...) is consistent with the spec's premises) and
     // the all-path claim stalls with <status> Reverted("WhitelistAllowedTimeViolation"). The
     // explicit `notBool #sequentialWhitelistReverts(...)` lets the prover exclude that arm
     // by direct Bool contradiction, the same way the FALL-THROUGH arm of the rule does. See
     // whitelists.md "Fidelity gaps" — the mutual exclusivity is asserted by the spec, not
     // enforced by K.
     andBool notBool #sequentialWhitelistReverts( Int2Bytes(2, TGT, BE) +Bytes Int2Bytes(5, START, BE) +Bytes Int2Bytes(2, DUR, BE) +Bytes Int2Bytes(10, PACKED, BE)
                                               , TAKER modInt (2 ^Int 80)
                                               )

endmodule

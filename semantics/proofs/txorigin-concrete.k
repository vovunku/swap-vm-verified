// Concrete-input conformance claims for the 0x26 (TxOrigin) opcode.
//
// This file is the concrete twin of `txorigin-spec.k` (the symbolic go/no-go claim that
// holds for any TAIL). It runs TWO fully-concrete fixed-byte programs through `#run`,
// pins `#txOrigin()` to a concrete value via a premise, and asserts the exact final
// `<pc>` and `<status>`. A concrete claim that proves under kprove is the operational
// equivalent of having `krun` the program: it establishes "this exact input reaches this
// exact state" under the K rules. The hand-derived expectations here are cross-checked
// against the Solidity side in `test/conformance/InstructionConformance.t.sol`
// (`test_conformance_txOrigin_*`), which runs the SAME bytes through the REAL
// `_onlyTxOriginTokenBalanceNonZero` body and REAL `runLoop`. Agreement between the two
// sides IS the conformance evidence — neither side alone suffices.
//
// This is the tx.origin twin of the 0x23 concrete-claim family: same program shape
// (opcode 0x26 + argsLen 0x14 + 20-byte token), same two scenarios (REVERT on zero
// balance, PASS on positive balance), same pc post-decode value (2 + 20 = 22). The ONLY
// structural difference is that the balance consulted is
// `#balanceOf(BALS, TOK, #txOrigin())` (uninterpreted environment EOA,
// opcodes/txorigin.k) rather than `#balanceOf(BALS, TOK, TAKER)` (the <taker> cell).
//
// ARM SELECTION — why `requires #txOrigin() ==Int 771` is enough. The 0x26 rule
// (opcodes/txorigin.k) splits on
//   #balanceOf(B, TOKEN, #txOrigin()) >Int 0     (PASS)
//   #balanceOf(B, TOKEN, #txOrigin()) <=Int 0    (REVERT)
// i.e. it compares the balance to a CONSTANT (0). The `#txOrigin()` symbol is the only
// uninterpreted piece inside `#balanceOf`, and fixing it via a concrete premise makes the
// whole `#balanceOf` application reduce to a concrete int via the defining rule
// (swapvm.md:171-174): {B [ bal(TOKEN, 771) ] orDefault 0}:>Int. Once that is concrete,
// the `>Int 0` / `<=Int 0` split decides immediately, exactly as it does for the 0x23
// concrete claims where TAKER is concretised by the <taker> cell read. The tx.origin
// VALUE itself (771) is environment, supplied on the Solidity side by `vm.txOrigin =
// 0x...0303`; this K premise is the matching abstraction-boundary pin. See
// `conformance-concrete.k` for the established pattern.
//
// PROGRAM CONSTRUCTION. Program = b"\x26\x14" +Bytes Int2Bytes(20, 1, BE) (22 bytes
// total). The arg payload is built via `Int2Bytes(N, V, BE)` so the byte width is exact
// by construction — hand-typing multi-byte literals miscounted on the first attempt for
// other opcodes (see conformance-concrete.k header). Token value 1 is a PLACEHOLDER: the
// Solidity side patches the deployed `GateTokenMock` address into the program at runtime,
// so `bytes20(1)` here only verifies the byte plumbing end-to-end. Scenario A uses
// `<balances> .Map </balances>` — the `#balanceOf` `[owise]` rule (swapvm.md:174) returns
// 0 for the missing `bal(1, 771)` key, selecting the REVERT arm. Scenario B uses
// `<balances> bal(1, 771) |-> 5 </balances>` so `#balanceOf = 5 >Int 0`, selecting the
// PASS arm.
module TXORIGIN-CONCRETE
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS
  imports SWAPVM-TXORIGIN

  // ---- Scenario A — REVERT. tx.origin (=771) holds none of token (=1). Balance is 0 by
  // the `#balanceOf` `[owise]` rule on the empty `.Map`. Rule's REVERT arm fires,
  // `#revert("TxOriginTokenBalanceIsZero")` clears the continuation and sets
  // `<status> Reverted("TxOriginTokenBalanceIsZero")`. pc ends at post-decode 22.
  claim <k> #run => .K </k>
        <program> b"\x26\x14" +Bytes Int2Bytes(20, 1, BE) </program>
        <pc> 0 => 22 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> .Map </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("TxOriginTokenBalanceIsZero") </status>
        <trace> _ </trace>
    requires #txOrigin() ==Int 771

  // ---- Scenario B — PASS. tx.origin (=771) holds 5 of token (=1). Balance is 5 > 0,
  // rule's PASS arm fires, opcode is a no-op at the register level (#run stays in <k>,
  // loop decodes the next instruction, which does not exist, so loop exits). pc ends at
  // post-decode 22 and status stays Running. Mirror of the 0x23 PASS composition shape.
  claim <k> #run => .K </k>
        <program> b"\x26\x14" +Bytes Int2Bytes(20, 1, BE) </program>
        <pc> 0 => 22 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> _ </taker>
        <balances> bal(1, 771) |-> 5 </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>
    requires #txOrigin() ==Int 771

endmodule

// Concrete-input conformance claims for the 0x25 (SupplyShare) opcode.
//
// This file replaces the former `supplyshare-spec.k` (a symbolic universal claim) and
// `supplyshare-control.k` (its sensitivity twin). Both were TAUTOLOGICAL under the prior
// predicate-form rule: the spec assumed `notBool #supplyShareSufficient(...)` as a premise
// and the rule branched on the same predicate, so the proof established nothing about
// whether the underlying conjunction `totalSupply > 0 && balance * 1e18 >= minShare *
// totalSupply` matched Solidity, and krun could not reduce the predicate either — i.e.
// zero conformance evidence. See supplyshare.md "Direct form, concrete conformance" for
// the full rationale of the switch. Same trade the Gte subagent made for the same reasons
// (proofs/gte-concrete.k header, opcodes/gte.md "Direct form, concrete conformance").
//
// The direct two-arm rule in `opcodes/supplyshare.k` branches on the REAL conjunction
//   totalSupply >Int 0  AND  balance *Int 1e18 >=Int minShare *Int totalSupply   (PASS)
//   NOT( ... )                                                                 (REVERT)
// A symbolic universal claim over arbitrary TOK/MIN/TAKER does NOT prove in this form
// (the K Haskell backend does not propagate an inequality premise on an
// uninterpreted-vs-symbolic comparison into a refutation of the opposite arm —
// opcodes/deadline.md:125-156, opcodes/gte.md "Arm selection"). CONCRETE claims,
// however, are unaffected: with `#balanceOf`, `#totalSupply`, and MIN all reduced to
// concrete Ints — the first via the defining rule on a concrete `<balances>` cell, the
// second via a spec premise, the third via a concrete `Int2Bytes(8, MIN, BE)` payload —
// the whole conjunction becomes a concrete arithmetic fact the SMT solver decides
// immediately, exactly as for the Gte concrete claims (proofs/gte-concrete.k). The 1e18
// multiplications are concrete; SMT handles them directly. So the two scenarios here ARE
// the conformance evidence — they verify the actual arithmetic against Solidity for fixed
// inputs, which the predicate-form symbolic proof could never do.
//
// Each claim runs a FULLY CONCRETE program through `#run` and asserts the exact final
// `<pc>` and `<status>`. A concrete claim that proves under kprove is the operational
// equivalent of having `krun` the program: it establishes "this exact input reaches this
// exact state" under the K rules. The hand-derived expectations here are cross-checked
// against the Solidity side in `test/conformance/InstructionConformance.t.sol`
// (`test_conformance_supplyShare_*`), which runs the SAME bytes through the REAL
// `_onlyTakerTokenSupplyShareGte` body and REAL `runLoop`. Agreement between the two
// sides IS the conformance evidence — neither side alone suffices.
//
// PROGRAM CONSTRUCTION. Program = b"\x25\x1c" +Bytes Int2Bytes(20, 1, BE) +Bytes
// Int2Bytes(8, MIN, BE) (30 bytes total). `b"\x25\x1c"` is the [opcode:1][argsLen:1]
// header — opcode 0x25 = 37 decimal, argsLen 0x1c = 28 decimal (20-byte token + 8-byte
// minShareE18). After the decode loop fires <pc> = 2 + 28 = 30. Arg payloads are built
// via `Int2Bytes(N, V, BE)` so the byte widths are exact by construction — hand-typing
// multi-byte literals miscounted on the first attempt for other opcodes (see
// conformance-concrete.k header). Token value 1 is a PLACEHOLDER: the Solidity side
// patches the deployed mock token address into the program at runtime, so `bytes20(1)`
// here only verifies the byte plumbing end-to-end. Taker 4660 = address(0x...1234) on the
// Solidity side, matching the Gte concrete claims so the same mock fixture shape applies.
//
// MOCK TOKEN GAP (Solidity side — NOT this file's scope, flagged for the integrator per
// the brief). `Controls.sol:174-175` consults BOTH `IERC20(token).balanceOf(taker)` AND
// `IERC20(token).totalSupply()`. The current Solidity conformance fixture
// `GateTokenMock` (test/conformance/InstructionConformance.t.sol:16-22) exposes ONLY
// `balanceOf`; it has no `totalSupply`. To run the Solidity mirror of these two K claims
// the integrator must extend `GateTokenMock` to expose `totalSupply` (e.g. add a
// `uint256 public totalSupply;` field with a `setTotalSupply(uint256)` setter that also
// implements the ERC-20 `totalSupply()` selector, or rename the mock and inherit a
// minimal ERC-20). `bytes20(1)` is a placeholder the integrator patches to the deployed
// mock's address at runtime, exactly as for the Gte claims. `bytes8(1e18)` is
// `bytes8(uint64(1e18))` — Solidity-side uint64 cast mirrors the K-side `Int2Bytes(8,
// MIN, BE)` round-trip with the lemma's `0 <=Int MIN <Int 2^64` bound.
module SUPPLYSHARE-CONCRETE
  imports SWAPVM
  imports SWAPVM-BYTES-LEMMAS
  imports SWAPVM-SUPPLYSHARE

  // ---- Scenario A — REVERT (totalSupply == 0). Taker 4660 of token 1 with
  // minShareE18 = 0. The Solidity conjunction `totalSupply > 0 && ...` fails on its FIRST
  // conjunct (totalSupply is 0), so the require reverts regardless of the balance. The
  // rule's REVERT arm fires via `notBool (TOTALSUPPLY >Int 0 andBool ...)`, which holds
  // as soon as `TOTALSUPPLY ==Int 0`. `#revert("TakerTokenBalanceSupplyShareIsLessThanRequired")`
  // clears the continuation and sets `<status>` accordingly. pc ends at post-decode 30.
  // This is the SIMPLEST revert path (the second conjunct need not be evaluated; the
  // `<balances>` cell is irrelevant here so it is left as the empty `.Map`). Mirror of the
  // 0x24 REVERT composition shape (gte-concrete.k scenario A).
  claim <k> #run => .K </k>
        <program> b"\x25\x1c" +Bytes Int2Bytes(20, 1, BE) +Bytes Int2Bytes(8, 0, BE) </program>
        <pc> 0 => 30 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> 4660 </taker>
        <balances> .Map </balances>
        <invalidators> _ </invalidators>
        <status> Running => Reverted("TakerTokenBalanceSupplyShareIsLessThanRequired") </status>
        <trace> _ </trace>
    requires #totalSupply(1) ==Int 0

  // ---- Scenario B — PASS. Taker 4660 holds 1000 of token 1; totalSupply is 1000;
  // minShareE18 is 1e18 (i.e. 100% of supply). The conjunction holds:
  //   totalSupply > 0                                              -- 1000 > 0   ✓
  //   balance * 1e18 >= minShare * totalSupply                     -- 1000 * 1e18
  //                                                                  >= 1e18 * 1000
  //                                                                  == 1000e18
  //                                                                  >= 1000e18   ✓
  // The rule's PASS arm fires, opcode is a no-op at the register level (#run stays in
  // <k>, loop decodes the next instruction, which does not exist, so loop exits). pc ends
  // at post-decode 30 and status stays Running. Mirror of the 0x24 PASS composition shape
  // (gte-concrete.k scenario B). This is the boundary case (balance scaled by 1e18 EQUALS
  // minShare scaled by totalSupply) which the REVERT arm must NOT take — covering it here
  // guards against an off-by-one in the `>=Int` / `<Int` split, exactly as the Gte
  // boundary claim does.
  claim <k> #run => .K </k>
        <program> b"\x25\x1c" +Bytes Int2Bytes(20, 1, BE) +Bytes Int2Bytes(8, 1000000000000000000, BE) </program>
        <pc> 0 => 30 </pc>
        <balanceIn> _ </balanceIn> <balanceOut> _ </balanceOut>
        <amountIn> _ </amountIn> <amountOut> _ </amountOut>
        <netPulled> _ </netPulled>
        <isExactIn> _ </isExactIn>
        <tokenIn> _ </tokenIn> <tokenOut> _ </tokenOut>
        <taker> 4660 </taker>
        <balances> bal(1, 4660) |-> 1000 </balances>
        <invalidators> _ </invalidators>
        <status> Running </status>
        <trace> _ </trace>
    requires #totalSupply(1) ==Int 1000

endmodule

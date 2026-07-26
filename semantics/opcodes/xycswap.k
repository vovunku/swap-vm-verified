requires "../swapvm.md"

// 0x50 XYCSwap — XYCSwap.sol:_xycSwapXD.
//
// Adds the rule to the SWAPVM semantics. K v7 does not allow reopening `module SWAPVM`
// across files, so this file defines a sibling module SWAPVM-XYCSWAP that imports SWAPVM and
// adds the rules. Integration is via `requires "opcodes/xycswap.k"` plus
// `imports SWAPVM-XYCSWAP` from the aggregated module (semantics/_lemmas-all.k) — see
// xycswap.md "Integration".
//
// This is the constant-product pricer (the "xy = constant" curve, x*y=k without fees). It is
// a DIRECT structural sibling of `0x53` LimitSwap (swapvm.md:221-298): same handler shape
// (`bytes calldata /* args */` — args IGNORED, so no `UNMODELLED-ARGS-LENGTH` arm, same as
// LimitSwap), same two Solidity reverts (`RequiresBothBalancesNonZero`,
// `RecomputeDetected`), same single-assignment guard, same two-direction split on
// `<isExactIn>`, floor on exact-in / ceiling on exact-out. The ONLY difference is the curve:
// LimitSwap is a flat rate (`amountOut = amountIn * balanceOut / balanceIn`); XYCSwap is the
// constant-product curve (`amountOut = amountIn * balanceOut / (balanceIn + amountIn)`),
// where the denominator grows with `amountIn` — the price slips as the fill grows. The
// ceiling arm's divisor is `balanceOut - amountOut` (not LimitSwap's `balanceOut`), which is
// the exact-out dual of that slip.
//
// ARITHMETIC GOES THROUGH A NAMED FUNCTION SYMBOL. This is the opcode PLAN.md §D2 uses to
// PRESCRIBE the pattern:
//
//     rule <k> #exec(XYCSWAP, ARGS) => .K ... </k>
//          <amountOut> _ => xycQuote(AIN, BIN, BOUT) </amountOut>
//     rule xycQuote(AIN, BIN, BOUT) => (AIN *Int BOUT) /Int (BIN +Int AIN)   // the DEFINITION
//
// Weakening to axioms is then deleting the defining rule and adding axioms about the symbol
// — a one-line change per instruction rather than a restructuring (PLAN.md D2/D3). The exact-
// in symbol is `xycQuoteOut`; the exact-out symbol is `xycQuoteIn`. The ceiling reuses the
// `#ceilDiv` helper LimitSwap defines in swapvm.md:237-245 (`a == 0 ? 0 : (a-1)/b + 1`,
// mirroring OpenZeppelin's `Math.ceilDiv`), so no new rounding machinery is needed.
//
// The decode rule in swapvm.md (143-149) has already consumed the [opcode:1][argsLen:1]
// header and advanced <pc> by `2 + argsLen` BEFORE #exec fires, exactly mirroring
// `pcs := add(pcs, 2); ... pcs := add(pcs, argsLength)` in VM.sol:133-138. XYCSwap neither
// reads nor writes <pc> beyond that (no `setNextPC` call), so the rules inherit the
// already-advanced value and leave it — the same posture as LimitSwap, the gates, and the
// invalidator opcodes. It is a pure register-writing instruction: it writes exactly one of
// `<amountOut>` (exact-in) or `<amountIn>` (exact-out), once, and leaves `#run` in `<k>`.
//
// ROUNDING. Exact-in floors (`/Int` rounds toward zero, and all operands are non-negative,
// so it is the floor): the sub-quotient remainder goes to the maker — the SAME rounding
// direction LimitSwap documents as intentional (axioms.md "T1 PROVED"). Exact-out ceilings
// via `#ceilDiv`, the dual: the taker must pay in just enough to cover the requested output,
// rounded up. Both round toward the maker's advantage, matching XYCSwap.sol exactly.
//
// OVERFLOW / DIV-BY-ZERO — known divergence, documented. `amountIn * balanceOut` (exact-in)
// and `amountOut * balanceIn` (exact-out) are Solidity 0.8 checked `uint256` multiplication:
// they revert `Panic(0x11)` on wraparound. The model uses unbounded `*Int` / `/Int`, so it
// COMPUTES where the EVM reverts. This is the SAME caveat T1 carries for LimitSwap
// (axioms.md): "K and the EVM differ iff amountIn * balanceOut >= 2^256". The exact-out
// subtraction `balanceOut - amountOut` underflows in the EVM when `amountOut > balanceOut`
// (Panic 0x11) and `Math.ceilDiv(_, 0)` reverts when `amountOut == balanceOut` (Panic 0x12).
// The model's `xycQuoteIn` defining rule requires `BOUT >Int AOUT`, so in that region the
// symbol stays unreduced (the proof stalls) — the SAFE failure direction (a claim on a
// fictionsucceeds cannot close). Neither region is reachable for a well-formed partial fill,
// where `amountOut < balanceOut` by construction. Read the theorems as "given the products do
// not overflow and `amountOut < balanceOut`".
//
// D-1 PRECEDENCE HAZARD (axioms.md "DEFECT D-1"). The rules below chain only `>Int` / `<=Int`
// / `==Int` / `=/=Int` with `andBool` / `orBool` — NO `==Bool` / `=/=Bool`, which are the
// operators that bind looser than `andBool` and caused D-1. So the hazard does not apply
// here. (LimitSwap's guard did use `==Bool` and had to be parenthesised; XYCSwap has no
// direction byte and so no such comparison.)

module SWAPVM-XYCSWAP
  imports SWAPVM

  // The constant-product quote, exact-in: amountOut = (amountIn * balanceOut) / (balanceIn +
  // amountIn), floored. Definitional rule with the well-formedness guard (both reserves
  // positive, mirroring the Solidity first-line require). The denominator `BIN +Int AIN` is
  // strictly positive under `BIN >Int 0`, so no division-by-zero. This is the rule PLAN.md D2
  // prescribes verbatim (modulo the symbol name). `[function]` (not `total`): it is undefined
  // outside the guard, which is the intended partiality — a spec that calls it on bad inputs
  // stalls rather than fabricating a value.
  syntax Int ::= xycQuoteOut ( Int , Int , Int ) [function]
  rule xycQuoteOut(AIN, BIN, BOUT) => (AIN *Int BOUT) /Int (BIN +Int AIN)
    requires BIN >Int 0 andBool BOUT >Int 0

  // The constant-product quote, exact-out: amountIn = ceilDiv(amountOut * balanceIn,
  // balanceOut - amountOut), ceiling. The divisor `BOUT -Int AOUT` must be strictly positive
  // (i.e. `BOUT >Int AOUT`): this is the well-formedness condition for a partial fill — the
  // taker cannot withdraw the entire output reserve (that would require infinite amountIn).
  // Reuses `#ceilDiv` from swapvm.md:237-245 (LimitSwap's helper). Below the guard the symbol
  // is unreduced (see header "OVERFLOW / DIV-BY-ZERO"); the #exec rule still fires and writes
  // the symbol, so a claim in that region stalls rather than silently no-op-ing.
  syntax Int ::= xycQuoteIn ( Int , Int , Int ) [function]
  rule xycQuoteIn(AOUT, BIN, BOUT) => #ceilDiv(AOUT *Int BIN, BOUT -Int AOUT)
    requires BOUT >Int AOUT

  // ---- Guard 1: both balances strictly positive. K twin of
  //   require(ctx.swap.balanceIn > 0 && ctx.swap.balanceOut > 0, XYCSwapRequiresBothBalancesNonZero(...))
  // (XYCSwap.sol). Fires first regardless of direction; the pricing rules below all require
  // BIN >Int 0 andBool BOUT >Int 0, so this arm is disjoint from them. `#revert` clears <k>.
  rule <k> #exec ( 80 , _ ) => #revert("XYCSwapRequiresBothBalancesNonZero") ... </k>
       <balanceIn> BIN </balanceIn> <balanceOut> BOUT </balanceOut>
       <status> Running </status>
    requires BIN <=Int 0 orBool BOUT <=Int 0

  // ---- Exact-in branch ----

  // Guard 2 (exact-in): single-assignment. K twin of
  //   require(ctx.swap.amountOut == 0, XYCSwapRecomputeDetected()).
  // Disjoint from the exact-in pricing rule on AOUT (=/=Int 0 vs ==Int 0). The `isExactIn`
  // cell pattern makes this arm disjoint from the exact-out arms.
  rule <k> #exec ( 80 , _ ) => #revert("XYCSwapRecomputeDetected") ... </k>
       <isExactIn> true </isExactIn>
       <amountOut> AOUT </amountOut>
       <balanceIn> BIN </balanceIn> <balanceOut> BOUT </balanceOut>
       <status> Running </status>
    requires BIN >Int 0 andBool BOUT >Int 0 andBool AOUT =/=Int 0

  // Pricing (exact-in). Writes `<amountOut>` once with the floored constant-product quote,
  // leaving `<amountIn>` untouched and `#run` in <k>. Mirrors swapvm.md:266-273 (the
  // LimitSwap exact-in pricing rule) with `xycQuoteOut` in place of `limitQuoteOut`. The
  // `AOUT ==Int 0` premise is the single-assignment guard; combined with the balance guard it
  // is disjoint from the two reverts above.
  rule <k> #exec ( 80 , _ ) => .K ... </k>
       <isExactIn> true </isExactIn>
       <amountIn> AIN </amountIn>
       <amountOut> AOUT => xycQuoteOut(AIN, BIN, BOUT) </amountOut>
       <balanceIn> BIN </balanceIn> <balanceOut> BOUT </balanceOut>
       <status> Running </status>
    requires BIN >Int 0 andBool BOUT >Int 0 andBool AOUT ==Int 0

  // ---- Exact-out branch ----

  // Guard 2 (exact-out): single-assignment. K twin of
  //   require(ctx.swap.amountIn == 0, XYCSwapRecomputeDetected()).
  // Disjoint from the exact-out pricing rule on AIN.
  rule <k> #exec ( 80 , _ ) => #revert("XYCSwapRecomputeDetected") ... </k>
       <isExactIn> false </isExactIn>
       <amountIn> AIN </amountIn>
       <balanceIn> BIN </balanceIn> <balanceOut> BOUT </balanceOut>
       <status> Running </status>
    requires BIN >Int 0 andBool BOUT >Int 0 andBool AIN =/=Int 0

  // Pricing (exact-out). Writes `<amountIn>` once with the ceiling constant-product quote.
  // Mirrors swapvm.md:283-290 (the LimitSwap exact-out pricing rule) with `xycQuoteIn` in
  // place of `limitQuoteIn`. The divisor `balanceOut - amountOut` lives inside `xycQuoteIn`;
  // when `BOUT <=Int AOUT` the defining rule does not fire and the symbol stays unreduced
  // (see header "OVERFLOW / DIV-BY-ZERO") — the safe direction.
  rule <k> #exec ( 80 , _ ) => .K ... </k>
       <isExactIn> false </isExactIn>
       <amountIn> AIN => xycQuoteIn(AOUT, BIN, BOUT) </amountIn>
       <amountOut> AOUT </amountOut>
       <balanceIn> BIN </balanceIn> <balanceOut> BOUT </balanceOut>
       <status> Running </status>
    requires BIN >Int 0 andBool BOUT >Int 0 andBool AIN ==Int 0
endmodule

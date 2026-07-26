requires "../swapvm.md"

// 0x25 OnlyTakerTokenSupplyShareGte — Controls.sol:168-178.
//
// Adds the SupplyShare rule to the SWAPVM semantics. K v7 does not allow reopening
// `module SWAPVM` across files (it reports "Module SWAPVM differs from previous
// declaration"), so this file defines a sibling module SWAPVM-SUPPLYSHARE that imports
// SWAPVM and adds the rules. Integration is via `requires "opcodes/supplyshare.k"` plus
// `imports SWAPVM-SUPPLYSHARE` from the main module (semantics/lemmas.k) — see
// supplyshare.md "Integration".
//
// The decode rule in swapvm.md has already consumed the [opcode:1][argsLen:1] header and
// advanced <pc> by `2 + argsLen` before #exec fires, exactly mirroring `pcs := add(pcs,
// 2); ... pcs := add(pcs, argsLength)` in VM.sol:133-138. SupplyShare neither reads nor
// writes <pc> beyond that (no `setNextPC` call), so both arms of this rule inherit the
// already-advanced value and leave it — the same posture as Revert (opcodes/revert.k),
// Salt (opcodes/salt.k), Deadline (opcodes/deadline.k), and Gte (opcodes/gte.k). The
// opcode is a pure conditional halt: it either reverts (clearing <k>) or is a no-op
// pass-through (leaves #run in <k>).
//
// RELATIONSHIP TO 0x24 (Gte). Gte (opcodes/gte.k, Controls.sol:158-166) reverts iff the
// taker's absolute balance of a token is strictly less than a maker-supplied uint256
// `minAmount`. SupplyShare is the relative variant: it reverts iff the taker's SHARE of
// the token's total supply is strictly less than a maker-supplied share, expressed as a
// uint64 `minShareE18` in parts-per-1e18 (i.e. the require is
// `balance * 1e18 >= minShareE18 * totalSupply`). Both read the 20-byte token via
// `#balanceOf` (swapvm.md:171-174); SupplyShare adds a SECOND external read —
// `totalSupply` — which Gte does not need.
//
// ARG DECODING. The Solidity source reads:
//     address token       = address(bytes20(args));
//     uint64 minShareE18  = uint64(bytes8(args.slice(20)));
// `address(bytes20(args))` right-zero-pads a short args and truncates a long one to 20
// bytes; `bytes8(args.slice(20))` does the same at offset 20 to 8 bytes. Under the
// canonical `lengthBytes(ARGS) ==Int 28` side condition the model uses
//   - `Bytes2Int(substrBytes(ARGS,  0, 20), BE, Unsigned)` for the token, exactly the
//     20-byte big-endian read;
//   - `Bytes2Int(substrBytes(ARGS, 20, 28), BE, Unsigned)` for minShareE18, exactly the
//     8-byte big-endian read at offset 20.
// The round-trip lemma in lemmas.k:64-67 rewrites each to the symbolic Int the spec
// supplies, under the standard width bounds (`0 <=Int TOK <Int 2^160` with N = 20 and
// `0 <=Int MIN <Int 2^64` with N = 8).
//
// PAD-AND-TRUNCATE SOUNDNESS HAZARD (swapvm.md:301-324). The Solidity constrains nothing
// about `args.length`. A short `args` is right-zero-padded at BOTH read sites (so e.g. an
// argsLen of 10 reads a 20-byte token whose last 10 bytes are zero, then an 8-byte
// minShare that is all zero); a long `args` is silently truncated (so e.g. an argsLen of
// 100 reads only the first 20 bytes as the token and bytes [20:28] as minShare). Neither
// case reverts on chain. If the model only handled the canonical 28-byte case and let the
// rest fall through to the `[owise]` no-op (swapvm.md:349-351), every such SupplyShare
// would be SILENTLY DELETED from the model while staying live in production — the worst
// failure direction, sound but wrong. The mitigation follows the pattern at
// swapvm.md:319-324 for opcodes 0x23 and 0x90 and the twins in opcodes/jump.k:50-54,
// opcodes/deadline.k:121-126, and opcodes/gte.k:142-148: non-canonical lengths revert
// loudly with `"UNMODELLED-ARGS-LENGTH"`, so a proof touching such a SupplyShare fails
// rather than succeeds on a fiction.
//
// EXTERNAL READS — two of them. The Solidity consults the chain twice:
//   1. `IERC20(token).balanceOf(ctx.query.taker)` — already modelled via `#balanceOf`
//      (swapvm.md:171-174), the existing D4 abstraction boundary for ERC-20 state.
//   2. `IERC20(token).totalSupply()` — NOT modelled anywhere in swapvm.md. Per PLAN.md D4
//      this is an external ERC-20 read at the abstraction boundary, so it is modelled
//      here as a local uninterpreted function `#totalSupply(Int)` (see below). The brief
//      forbids editing swapvm.md (six sibling subagents depend on it being untouched);
//      this local declaration achieves the abstraction without that coordination cost.
//
// ARM SELECTION — why `#supplyShareSufficient(BALANCE, TOTALSUPPLY, MIN)` and not the
// direct two-arm arithmetic form. The Solidity require is a CONJUNCTION of two
// inequalities:
//     totalSupply > 0
//     balance * 1e18 >= minShareE18 * totalSupply
// Both compare values derived from uninterpreted functions (`#balanceOf`, `#totalSupply`)
// to SYMBOLIC values (`minShareE18`, and `0` for the first conjunct — though the second
// conjunct also has `minShareE18 * totalSupply`, a product of symbolic and uninterpreted).
// The diagnostic established by the Deadline subagent (opcodes/deadline.md:125-156) and
// re-confirmed by the Gte subagent (opcodes/gte.md "Arm selection") is that the K Haskell
// backend does NOT propagate an inequality premise on an uninterpreted-vs-symbolic
// comparison into a refutation of the opposite arm of a two-arm rule. The gate
// (swapvm.md:182-193) avoids this only because its arms compare `#balanceOf(...)` to a
// CONSTANT (0), and constant reasoning IS propagated. Any direct two-arm form here —
// `requires ... >=Int ... *Int ... andBool ... >Int 0` (PASS) vs the negation (REVERT) —
// has EXACTLY the failure mode the diagnostic isolates: a spec premise
// `notBool (#balanceOf(...) *Int 1e18 >=Int MIN *Int #totalSupply(...))` would not refute
// the PASS arm, the PASS arm would not halt, the loop would run into the symbolic TAIL,
// and the all-path claim would stall.
//
// The fix — same shape Deadline (opcodes/deadline.k:84-119) and Gte (opcodes/gte.k:103-148)
// adopted — is to abstract the ENTIRE conjunction into a single Bool predicate
//
//     syntax Bool ::= #supplyShareSufficient ( Int , Int , Int ) [function, no-evaluators]
//
// conceptually `#supplyShareSufficient(BALANCE, TOTALSUPPLY, MINSHAREE18)`
//          == (TOTALSUPPLY >Int 0)
//          andBool (BALANCE *Int 1e18 >=Int MINSHAREE18 *Int TOTALSUPPLY).
//
// The RULE branches on this Bool (REVERT arm requires `notBool #supplyShareSufficient(...)`,
// PASS arm requires `#supplyShareSufficient(...)`) — same shape as the working `0x23`
// gate, which branches on `#balanceOf(...) >Int 0`, a comparison to a constant, and the
// Deadline/Gte predicates. A spec premise `notBool #supplyShareSufficient(...)` (implicitly
// `==Bool true`) then selects the REVERT arm exactly as `#balanceLtMin(TOK, MIN)` selects
// Gte's REVERT arm and `#deadlineExceeded(DL)` selects Deadline's REVERT arm. The brief's
// "CRITICAL lesson" directed going straight to the predicate form rather than attempting
// the direct two-arm arithmetic form first; this file honours that.
//
// The three symbols (`#balanceOf`, `#totalSupply`, `#supplyShareSufficient`) are kept as
// independent uninterpreted terms (no simplification rule equating the predicate with its
// arithmetic expansion) so the arm-selection condition stays a single atomic Bool the SMT
// solver can decide on. See supplyshare.md "Arm selection" for the cross-reference and
// "Fidelity gaps" for what the abstraction costs.

module SWAPVM-SUPPLYSHARE
  imports SWAPVM

  // The token's total supply, as an uninterpreted total function of the token address.
  // This is the PLAN.md D4 abstraction boundary for the external `IERC20(token).totalSupply()`
  // read in Controls.sol:172, per the task brief. No defining rule: its value is
  // fixed-but-unknown, constrained only by spec premises. `[function, no-evaluators]` marks
  // it as a total function symbol and prevents the simplifier from inventing a reduction.
  // The rule below does NOT branch on this symbol directly — see `#supplyShareSufficient`
  // for why, and the file header for the full diagnostic.
  syntax Int ::= #totalSupply ( Int ) [function, no-evaluators]

  // A Bool predicate abstracting the Solidity require's full conjunction
  //   totalSupply > 0  &&  balance * 1e18 >= minShareE18 * totalSupply
  // (Controls.sol:175). The RULE branches on this rather than on the arithmetic directly,
  // because the K Haskell backend cannot exclude an arm of a two-arm rule whose side
  // condition compares an uninterpreted function (`#balanceOf`, `#totalSupply`) to a
  // SYMBOLIC value (`MIN`, and the symbolic product `MIN *Int #totalSupply(...)`) — see
  // file header and supplyshare.md "Arm selection", cross-referencing
  // opcodes/deadline.md:125-156 and opcodes/gte.md. A spec premise
  // `notBool #supplyShareSufficient(BAL, TS, MIN)` (implicitly `==Bool true`) selects the
  // REVERT arm; `#supplyShareSufficient(BAL, TS, MIN)` would select the PASS arm.
  // Conceptually
  //   #supplyShareSufficient(BAL, TS, MIN)
  //     == (TS >Int 0) andBool (BAL *Int 1000000000000000000 >=Int MIN *Int TS)
  // but the two are kept as independent uninterpreted symbols (no simplification rule
  // equating them) so the arm-selection condition stays decidable for the SMT solver.
  syntax Bool ::= #supplyShareSufficient ( Int , Int , Int ) [function, no-evaluators]

  // Canonical 28-byte SupplyShare, REVERT arm. Solidity:
  //   require(totalSupply > 0 && balance * 1e18 >= minShareE18 * totalSupply,
  //           TakerTokenBalanceSupplyShareIsLessThanRequired(...));
  // reverts iff the conjunction FAILS — i.e. iff `totalSupply == 0` OR
  // `balance * 1e18 < minShareE18 * totalSupply`. `#revert(MSG) ~> _ => .K`
  // (swapvm.md:154-156) clears the continuation and sets <status> Reverted(MSG), so the
  // loop never resumes and an arbitrary symbolic tail in the program cannot affect the
  // conclusion. The `Running` side condition guards against SupplyShare firing after a
  // prior Revert, matching the loop rule's own guard (swapvm.md:103) and the analogous
  // guards on Stop, Revert, Jump, Salt, Deadline, and Gte. The [owise] unknown-opcode
  // rule (swapvm.md:349-351) is overridden by this more specific rule regardless of which
  // module each lives in: owise rules have lower priority than concrete rules across the
  // whole imported closure.
  rule <k> #exec ( 37 , ARGS ) => #revert("TakerTokenBalanceSupplyShareIsLessThanRequired") ... </k>
       <query> ... <taker> TAKER </taker> ... </query>
       <balances> B </balances>
       <status> Running </status>
    requires lengthBytes(ARGS) ==Int 28
     andBool notBool #supplyShareSufficient(
               #balanceOf(B, Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned), TAKER),
               #totalSupply(Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned)),
               Bytes2Int(substrBytes(ARGS, 20, 28), BE, Unsigned) )

  // Canonical 28-byte SupplyShare, PASS arm. The conjunction holds — `totalSupply > 0`
  // AND `balance * 1e18 >= minShareE18 * totalSupply` — the require passes, and
  // `_onlyTakerTokenSupplyShareGte` returns normally. The opcode is a no-op at the
  // register level — reads no register, writes no register, no `setNextPC` — so the
  // continuation #run is left in <k> and the loop proceeds to decode the next instruction.
  // Like Salt (opcodes/salt.k), Deadline (opcodes/deadline.k), and Gte (opcodes/gte.k),
  // SupplyShare is NOT a halt on this arm: an arbitrary symbolic tail in the program WILL
  // be decoded after SupplyShare passes. The composition shape for positive claims
  // therefore mirrors gate-spec.k / deadline-spec.k / gte-spec.k on the REVERT arm (HALT,
  // tail unconsumed) and would mirror salt-spec.k / jump-spec.k on the PASS arm (no halt,
  // must terminate concretely); the minimum positive claim here covers the REVERT arm only.
  rule <k> #exec ( 37 , ARGS ) => .K ... </k>
       <query> ... <taker> TAKER </taker> ... </query>
       <balances> B </balances>
       <status> Running </status>
    requires lengthBytes(ARGS) ==Int 28
     andBool #supplyShareSufficient(
               #balanceOf(B, Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned), TAKER),
               #totalSupply(Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned)),
               Bytes2Int(substrBytes(ARGS, 20, 28), BE, Unsigned) )

  // Non-canonical args: Solidity right-pads short and truncates long without reverting,
  // which is a soundness hazard (swapvm.md:301-324). Revert loudly here so a proof cannot
  // silently succeed on an unmodelled length. Mirrors opcodes 0x23 / 0x90 in
  // swapvm.md:319-324 and the twins in opcodes/jump.k:50-54, opcodes/deadline.k:121-126,
  // and opcodes/gte.k:142-148.
  rule <k> #exec ( 37 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
       <status> Running </status>
    requires lengthBytes(ARGS) =/=Int 28
endmodule

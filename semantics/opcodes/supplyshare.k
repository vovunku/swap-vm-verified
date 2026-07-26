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
// DIRECT TWO-ARM FORM — why the rule branches on the REAL arithmetic and not on an
// abstracted Bool predicate. The Solidity require is a CONJUNCTION of two inequalities:
//     totalSupply > 0
//     balance * 1e18 >= minShareE18 * totalSupply
// An earlier revision of this file abstracted that conjunction into a single Bool
// predicate `#supplyShareSufficient(BAL, TS, MIN)` (conceptually
// `TS >Int 0 && BAL *Int 1e18 >=Int MIN *Int TS`) and the rule branched on the predicate.
// That revision is now judged WRONG for the SAME two reasons the Gte subagent documented
// (opcodes/gte.k header, opcodes/gte.md "Direct form, concrete conformance"):
//
//   1. The SYMBOLIC universal claim was TAUTOLOGICAL. `supplyshare-spec.k` assumed
//      `notBool #supplyShareSufficient(...)` as a premise, and the rule's REVERT arm
//      fired on the same predicate — so the "proof" assumed the predicate and then
//      concluded under the predicate, establishing NOTHING about whether the underlying
//      `<` / `>=` definition matched Solidity. A wrong definition (e.g. `<=Int` vs
//      `<Int`, or comparing the wrong token, or missing the `totalSupply > 0` conjunct)
//      would have passed identically. This is the worst kind of false confidence: green
//      CI, no content.
//   2. `krun` could not reduce the predicate either. With `[function, no-evaluators]` and
//      no simplification rule equating the predicate to its underlying conjunction (the
//      simplification rule was deliberately omitted because it would re-introduce the
//      arm-selection issue — see below), a concrete `krun` on a SupplyShare program would
//      leave `#supplyShareSufficient(BAL, TS, MIN)` as a residual symbol. So the predicate
//      form had NO conformance evidence of any kind: not from kprove (the proof was
//      tautological) and not from krun (the predicate does not reduce).
//
// The DIRECT form restores MEANING to the comparison: the rule now says what the Solidity
// says, and a wrong definition would be caught by any claim that exercises it.
//
// ARM-SELECTION LIMITATION — symbolic vs concrete claims. The K Haskell backend (v7.1.337,
// the toolchain in this repo) does NOT propagate an inequality premise on an
// uninterpreted-vs-symbolic comparison into a refutation of the opposite arm of a
// two-arm rule (diagnostic in opcodes/deadline.md:125-156; re-confirmed for the Gte
// opcode — see opcodes/gte.md "Arm selection"). Here BOTH conjuncts involve uninterpreted
// functions compared to (or multiplied by) symbolic values:
//
//   - `#totalSupply(...) >Int 0` — uninterpreted-vs-constant, which the gate (`0x23`) shows
//     DOES propagate;
//   - `#balanceOf(...) *Int 1e18 >=Int MIN *Int #totalSupply(...)` — uninterpreted-vs-
//     symbolic on BOTH sides, which does NOT propagate.
//
// Consequently a SYMBOLIC universal claim over arbitrary TOK/MIN/TAKER does NOT prove in
// this direct form: the PASS arm is also explored, it does not halt, the loop runs into a
// symbolic TAIL, and the all-path claim stalls. That trade is accepted (see below). The
// conformance burden is carried by the TWO CONCRETE claims in
// `proofs/supplyshare-concrete.k`: with `#balanceOf`, `#totalSupply`, and `MIN` all
// reduced to concrete Ints — the first via the defining rule on a concrete `<balances>`
// cell, the second via a spec premise, the third via a concrete `Int2Bytes(8, MIN, BE)`
// payload — the entire conjunction becomes a concrete arithmetic fact the SMT solver
// decides immediately, exactly as for the Gte concrete claims (proofs/gte-concrete.k).
//
// The trade is asymmetric and correct: concrete conformance is REAL verification, the
// tautological symbolic claim was not. Should the K backend grow the missing SMT
// propagation, the symbolic universal claim can be reinstated on top of the direct form.
//
// ARITHMETIC OVERFLOW — NOT MODELLED (same class as T1 / LimitSwap, axioms.md).
// `Controls.sol:171-178` has NO `unchecked` block, so under Solidity 0.8.30 both
// `balance * 1e18` and `minShareE18 * totalSupply` are checked multiplications that revert
// `Panic(0x11)` on wraparound. The model uses arbitrary-precision `*Int`
// (supplyshare.k:154,176), so it COMPUTES where the chain reverts — the PERMISSIVE
// direction. Distinguishing input: `balanceOf(taker) = 2^200`, `totalSupply = 1`,
// `minShareE18 = 0` → Solidity reverts (`2^200 * 1e18 ≈ 1.6e78 > 2^256`); the K PASS arm
// fires → `<status> Running`. This is exactly the caveat that travels with T1 in axioms.md
// ("K and the EVM differ iff amountIn * balanceOut >= 2^256"). Read the theorems as "given
// the products do not overflow". Recorded here as a known limitation, not modelled.

module SWAPVM-SUPPLYSHARE
  imports SWAPVM

  // The token's total supply, as an uninterpreted total function of the token address.
  // This is the PLAN.md D4 abstraction boundary for the external `IERC20(token).totalSupply()`
  // read in Controls.sol:172, per the task brief. No defining rule: its value is
  // fixed-but-unknown, constrained only by spec premises (a concrete claim pins it via a
  // premise like `requires #totalSupply(1) ==Int 1000`). `[function, no-evaluators]` marks
  // it as a total function symbol and prevents the simplifier from inventing a reduction.
  syntax Int ::= #totalSupply ( Int ) [function, no-evaluators]

  // Canonical 28-byte SupplyShare, REVERT arm. Solidity:
  //   require(totalSupply > 0 && balance * 1e18 >= minShareE18 * totalSupply,
  //           TakerTokenBalanceSupplyShareIsLessThanRequired(...));
  // reverts iff the conjunction FAILS — i.e. iff `totalSupply == 0` OR
  // `balance * 1e18 < minShareE18 * totalSupply`. The negation is written out IN FULL
  // (no predicate abstraction) so the rule's side condition is the literal negation of the
  // PASS arm's side condition. `1e18 = 1000000000000000000`. `#revert(MSG) ~> _ => .K`
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
     andBool notBool ( #totalSupply(Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned)) >Int 0
                       andBool #balanceOf(B, Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned), TAKER) *Int 1000000000000000000
                               >=Int Bytes2Int(substrBytes(ARGS, 20, 28), BE, Unsigned)
                                 *Int #totalSupply(Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned)) )

  // Canonical 28-byte SupplyShare, PASS arm. The conjunction holds — `totalSupply > 0`
  // AND `balance * 1e18 >= minShareE18 * totalSupply` — the require passes, and
  // `_onlyTakerTokenSupplyShareGte` returns normally. The opcode is a no-op at the
  // register level — reads no register, writes no register, no `setNextPC` — so the
  // continuation #run is left in <k> and the loop proceeds to decode the next instruction.
  // Like Salt (opcodes/salt.k), Deadline (opcodes/deadline.k), and Gte (opcodes/gte.k),
  // SupplyShare is NOT a halt on this arm: an arbitrary symbolic tail in the program WILL
  // be decoded after SupplyShare passes. The composition shape for positive claims
  // therefore mirrors gate-spec.k / deadline-spec.k / gte-concrete.k on the REVERT arm
  // (HALT, tail unconsumed) and would mirror salt-spec.k / jump-spec.k / gte-concrete.k
  // on the PASS arm (no halt, must terminate concretely); both arms are exercised in
  // proofs/supplyshare-concrete.k.
  rule <k> #exec ( 37 , ARGS ) => .K ... </k>
       <query> ... <taker> TAKER </taker> ... </query>
       <balances> B </balances>
       <status> Running </status>
    requires lengthBytes(ARGS) ==Int 28
     andBool #totalSupply(Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned)) >Int 0
     andBool #balanceOf(B, Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned), TAKER) *Int 1000000000000000000
             >=Int Bytes2Int(substrBytes(ARGS, 20, 28), BE, Unsigned)
               *Int #totalSupply(Bytes2Int(substrBytes(ARGS, 0, 20), BE, Unsigned))

  // Non-canonical args: Solidity right-pads short and truncates long without reverting,
  // which is a soundness hazard (swapvm.md:301-324). Revert loudly here so a proof cannot
  // silently succeed on an unmodelled length. Mirrors opcodes 0x23 / 0x90 in
  // swapvm.md:319-324 and the twins in opcodes/jump.k:50-54, opcodes/deadline.k:121-126,
  // and opcodes/gte.k:142-148.
  rule <k> #exec ( 37 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
       <status> Running </status>
    requires lengthBytes(ARGS) =/=Int 28
endmodule

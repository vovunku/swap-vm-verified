requires "kontrol.md"

// SwapVM shared lemma library.
//
// Nearly every SwapVM pricing instruction reduces to the same arithmetic skeleton: a
// 256-bit `mulDiv`, flooring on the amountOut leg and ceiling on the amountIn leg. For
// example XYCSwap and LimitSwap differ only in the denominator:
//
//   XYCSwap    amountOut = amountIn * balanceOut / (balanceIn + amountIn)
//              amountIn  = ceilDiv(amountOut * balanceIn, balanceOut - amountOut)
//   LimitSwap  amountOut = amountIn * balanceOut / balanceIn
//              amountIn  = ceilDiv(amountOut * balanceIn, balanceOut)
//
// The lemmas needed to discharge one are therefore largely the lemmas needed to
// discharge all of them, which is why this library is shared rather than per-instruction.
//
// Conventions for contributors:
//   * Every rule carries a `[simplification]` attribute and a unique label, so that
//     `grep <label> out/kompiled/definition.kore` can confirm it was actually compiled in.
//   * Add `preserves-definedness` only when the rule cannot introduce a partial term
//     (e.g. it does not create a division whose divisor might be zero).
//   * State the soundness argument in a comment. A silently unsound lemma makes every
//     proof in the repo meaningless, and nothing in the tooling will flag it.
//   * Append new rules to the relevant section rather than editing existing ones, so
//     concurrent work merges cleanly.
//
// Before trusting any proof after editing this file, see test/kontrol/README.md — a
// stale copy of this file can survive `kontrol build --rekompile` silently.

module SWAPVM-LEMMAS
    imports KONTROL-BASE

// ---------------------------------------------------------------------------
// Section 1: multiplication overflow guards
// ---------------------------------------------------------------------------
//
// Solidity 0.8 guards `a * b` with the check `(a * b) / a == b`, which KEVM's
// `chop-no-overflow-mul-eq` rules rewrite into the obligation `X *Int Y <Int pow256`.
// Harnesses establish that bound by assuming `X <= type(uint256).max / Y`, but
// discharging the implication needs a product and a division of two symbolic operands.
// Z3 handles such non-linear goals poorly, and KEVM's own transfer rules for `*Int`
// under `<Int`/`<=Int` are gated on `concrete(A, C)`, so none of them fire when both
// operands are symbolic — which is exactly the SwapVM case.
//
// Soundness: for Y > 0, X <= floor(C / Y) implies X *Int Y <= floor(C / Y) *Int Y <= C.

    rule [mul-bound-transfer]:
      X *Int Y <=Int C => true
      requires 0 <=Int X
       andBool 0 <Int Y
       andBool X <=Int C /Int Y
      [simplification, preserves-definedness]

    rule [mul-bound-transfer-comm]:
      Y *Int X <=Int C => true
      requires 0 <=Int X
       andBool 0 <Int Y
       andBool X <=Int C /Int Y
      [simplification, preserves-definedness]

// `pow256` variants: `X <= maxUInt256 / Y` bounds the product by maxUInt256, which is
// strictly below pow256.

    rule [mul-no-overflow]:
      X *Int Y <Int pow256 => true
      requires 0 <=Int X
       andBool 0 <Int Y
       andBool X <=Int maxUInt256 /Int Y
      [simplification, preserves-definedness]

    rule [mul-no-overflow-comm]:
      Y *Int X <Int pow256 => true
      requires 0 <=Int X
       andBool 0 <Int Y
       andBool X <=Int maxUInt256 /Int Y
      [simplification, preserves-definedness]

// ---------------------------------------------------------------------------
// Section 2: addition overflow guards
// ---------------------------------------------------------------------------
//
// For `balanceIn + amountIn` style denominators and `totalX += delta` accumulators
// guarded by an assumption of the form `X <= type(uint256).max - Y`.

    rule [add-no-overflow]:
      X +Int Y <Int pow256 => true
      requires 0 <=Int X
       andBool 0 <=Int Y
       andBool X <=Int maxUInt256 -Int Y
      [simplification]

    rule [add-no-overflow-le]:
      X +Int Y <=Int maxUInt256 => true
      requires 0 <=Int X
       andBool 0 <=Int Y
       andBool X <=Int maxUInt256 -Int Y
      [simplification]

// ---------------------------------------------------------------------------
// Section 3: bitwise-complement normalisation
// ---------------------------------------------------------------------------
//
// `type(uint256).max - x` does not survive compilation as a subtraction. solc recognises
// that `maxUInt256 - x == ~x` for uint256 and emits a `NOT`, which KEVM rewrites to
// `x xorInt maxUInt256` (evm-semantics/evm-types.md:179, `rule ~Word W => W xorInt maxUInt256`).
//
// The consequence is that an overflow guard written as `vm.assume(a <= type(uint256).max - b)`
// arrives in the path condition as
//
//     KV_a <=Int KV_b xorInt maxUInt256
//
// — observed directly on a stuck node via `kontrol show --node`. The `add-no-overflow`
// rules above are stated over `maxUInt256 -Int Y` and so never fire against it. KEVM's
// bitwise-simplification module has rules for `0 <=Int X xorInt Y` and `X xorInt Y <Int Z`
// but none that relates the complement back to subtraction, so the goal simply sits there.
//
// Normalising in this direction (rather than restating every arithmetic lemma in xor form)
// keeps the rest of this file stated in ordinary arithmetic.
//
// Soundness: for a 256-bit unsigned X, flipping every bit yields maxUInt256 - X. The
// `#rangeUInt(256, X)` guard is what makes that identity hold.

    rule [not-word-to-sub]:
      X xorInt maxUInt256 => maxUInt256 -Int X
      requires #rangeUInt(256, X)
      [simplification]

    rule [not-word-to-sub-comm]:
      maxUInt256 xorInt X => maxUInt256 -Int X
      requires #rangeUInt(256, X)
      [simplification]

// ---------------------------------------------------------------------------
// Section 4: floor division bounds
// ---------------------------------------------------------------------------
//
// Used to prove the "cannot drain the maker" and rounding-direction properties.
// KEVM's int-simplification covers `(A *Int B) /Int A => B` and friends, but not these
// bounds with a symbolic divisor.

// Soundness: floor(A / B) * B <= A for B > 0, by definition of floor division.
    rule [div-mul-le]:
      (A /Int B) *Int B <=Int A => true
      requires 0 <=Int A
       andBool 0 <Int B
      [simplification, preserves-definedness]

// Soundness: for B >= 1 and A >= 0, floor(A / B) <= A.
    rule [div-le-self]:
      A /Int B <=Int A => true
      requires 0 <=Int A
       andBool 0 <Int B
      [simplification, preserves-definedness]

// Soundness: floor division is monotone in its numerator for a fixed positive divisor.
    rule [div-monotonic]:
      A /Int B <=Int C /Int B => true
      requires 0 <=Int A
       andBool A <=Int C
       andBool 0 <Int B
      [simplification, preserves-definedness]

// Soundness: if A < B then floor(A / B) = 0, for B > 0 and A >= 0.
    rule [div-lt-is-zero]:
      A /Int B => 0
      requires 0 <=Int A
       andBool A <Int B
      [simplification, preserves-definedness]

// ---------------------------------------------------------------------------
// Section 5: ceiling division  ->  KEVM's `up/Int`
// ---------------------------------------------------------------------------
//
// Every ceiling division is normalised onto KEVM's existing `up/Int` symbol rather than a
// new one. `up/Int` is declared `[function, total, smtlib(upDivInt)]` (evm-types.md:76) and
// all four of its defining rules carry `[concrete]` (:78-81), so on symbolic operands it
// does not unfold and behaves as a total, SMT-visible uninterpreted function. Normalising
// into it activates rules KEVM already ships -- notably `upInt-refl-geq`, which IS
// `ceilDiv(a,b)*b >= a`, and `upInt-lt-true`, which gives the tight upper bound -- and gives
// congruence between syntactically equal ceilDivs.
//
// TERM SHAPES BELOW WERE DERIVED FROM COMPILED BYTECODE, not from the Solidity source, by
// compiling a probe under this repo's exact `[profile.kontrol]` settings and reading the
// optimised Yul and disassembly. Two shapes matter and neither is the textbook form:
//
//   * `a - 1` is emitted as `add(a, not(0))`, so KEVM sees `chop(A +Int maxUInt256)` and
//     NEVER a subtraction.
//   * `SafeCast.toUint(a > 0)` is emitted as `ISZERO; ISZERO`, so KEVM sees
//     `bool2Word(notBool (A ==Int 0))` and NEVER `bool2Word(0 <Int A)`.
//
// KEVM ships no rule bridging either gap, which is why this section exists. This is the
// same class of trap as `not-word-to-sub` in Section 3, in mirror image.
//
// Soundness of the normalisation rules, for 0 <= A < 2^256 and B > 0: when A == 0 the guard
// is 0, the product is 0, and `0 up/Int B == 0`; when A > 0, `chop(A + maxUInt256) == A - 1`
// so `(A-1)/B + 1 == ceil(A/B)`. DERIVABLE -- an equational consequence of the semantics.
//
// One caveat to record: `up/Int` is defined via K's `/Int`, which truncates toward zero
// rather than flooring, so it coincides with ceiling division only on non-negative
// arguments. Every rule below carries an explicit non-negativity condition. EVM words are
// always non-negative, so this costs nothing, but it must be stated.

// solc emits `a - 1` as `add(a, not(0))`. KEVM's `chop-resolve` cannot discharge the result
// because `#rangeUInt(256, A +Int maxUInt256)` holds only for A == 0.
// Soundness: for 1 <= A < 2^256, (A + 2^256 - 1) mod 2^256 == A - 1. DERIVABLE.
    rule [dec-word-to-sub]:
      chop ( A +Int maxUInt256 ) => A -Int 1
      requires 0 <Int A andBool A <Int pow256
      [simplification]

// The OZ `Math.ceilDiv` compiled form, at priority 40 so it is tried before stock KEVM
// normalisations rearrange the term.
    rule [ceildiv-oz-raw]:
      chop ( bool2Word ( notBool ( A ==Int 0 ) )
             *Int chop ( ( chop ( A +Int maxUInt256 ) /Int B ) +Int 1 ) )
        => A up/Int B
      requires #rangeUInt(256, A) andBool 0 <Int B
      [simplification(40), preserves-definedness]

    rule [ceildiv-oz-flat]:
      chop ( bool2Word ( notBool ( A ==Int 0 ) )
             *Int ( ( chop ( A +Int maxUInt256 ) /Int B ) +Int 1 ) )
        => A up/Int B
      requires #rangeUInt(256, A) andBool 0 <Int B
      [simplification, preserves-definedness]

// When the path condition already gives A > 0, KEVM collapses the guard to 1 and removes
// the multiplication, so the shapes above cannot match. These cover what is left.
    rule [ceildiv-oz-guarded]:
      chop ( ( chop ( A +Int maxUInt256 ) /Int B ) +Int 1 ) => A up/Int B
      requires 0 <Int A andBool A <Int pow256 andBool 0 <Int B
      [simplification, preserves-definedness]

    rule [ceildiv-oz-guarded-flat]:
      ( ( A -Int 1 ) /Int B ) +Int 1 => A up/Int B
      requires 0 <Int A andBool 0 <Int B
      [simplification, preserves-definedness]

// PiecewiseLinearScale.sol:64 does NOT call Math.ceilDiv -- it hand-rolls
// `((value << 24) + scale) / (scale + 1)`, the classic `(A + D - 1)/D`. Without this it
// never reaches `up/Int` and none of the KEVM rules apply.
// Soundness: ceil(A/D) == floor((A + D - 1)/D) for A >= 0, D > 0. DERIVABLE.
    rule [manual-ceildiv-to-updiv]:
      ( A +Int B ) /Int ( B +Int 1 ) => A up/Int ( B +Int 1 )
      requires 0 <=Int A andBool 0 <=Int B
      [simplification, preserves-definedness]

// `Math.mulDiv(..., Rounding.Ceil)` reduces to floor + [remainder != 0] once Section 6 has
// taken the fast path. Soundness: floor(A/D) + [A mod D != 0] == ceil(A/D). DERIVABLE.
    rule [floor-plus-rem-to-updiv]:
      ( A /Int D ) +Int bool2Word ( notBool ( ( A modInt D ) ==Int 0 ) ) => A up/Int D
      requires 0 <=Int A andBool 0 <Int D
      [simplification, preserves-definedness]

// Bounds on `up/Int` that KEVM does not have. The workhorses eliminate the division
// entirely rather than reasoning underneath it.
// Soundness: for B > 0, ceil(A/B) <= C  <=>  A <= C*B, and dually. DERIVABLE.
    rule [updiv-le-transfer]:
      A up/Int B <=Int C => true
      requires 0 <=Int A andBool 0 <Int B andBool A <=Int C *Int B
      [simplification]

    rule [updiv-gt-transfer]:
      C <Int A up/Int B => true
      requires 0 <=Int A andBool 0 <=Int C andBool 0 <Int B andBool C *Int B <Int A
      [simplification]

// Minimality -- ceil(A/B) is the least k with k*B >= A. DERIVABLE.
// The companion `((A up/Int B) *Int B) <Int A +Int B` is already covered by KEVM's
// `upInt-lt-true` with Z := A +Int B; do not restate it.
    rule [updiv-minimal]:
      ( ( A up/Int B ) -Int 1 ) *Int B <Int A => true
      requires 0 <Int A andBool 0 <Int B
      [simplification]

    rule [updiv-monotonic]:
      A1 up/Int B <=Int A2 up/Int B => true
      requires 0 <=Int A1 andBool A1 <=Int A2 andBool 0 <Int B
      [simplification]

    rule [updiv-le-self]:
      A up/Int B <=Int A => true
      requires 0 <=Int A andBool 0 <Int B
      [simplification]

// KEVM's `I1 up/Int 1 => I1` is [concrete] and never fires on a symbolic numerator.
    rule [updiv-one]:
      A up/Int 1 => A
      [simplification]

    rule [div-le-updiv]:
      A /Int B <=Int A up/Int B => true
      requires 0 <=Int A andBool 0 <Int B
      [simplification, preserves-definedness]

// Floor-division transfer rules, needed to finish the round-trip goals once the shifts
// become divisions. Soundness: for A >= 0, B > 0, floor(A/B) < C <=> A < C*B, etc.
// DERIVABLE.
// Priority 40: these race rules of the same shape in KONTROL-AUX-LEMMAS at the default 50.
    rule [div-lt-transfer]:
      A /Int B <Int C => true
      requires 0 <=Int A andBool 0 <Int B andBool A <Int C *Int B
      [simplification(40), preserves-definedness]

    rule [div-ge-transfer]:
      C <=Int A /Int B => true
      requires 0 <=Int A andBool 0 <Int B andBool C *Int B <=Int A
      [simplification(40), preserves-definedness]

// Pins a quotient from a two-sided window -- the shape the unscaleValue round trip needs.
// The remainder of a floor division is below the divisor. Needed by two-sided exactness
// properties written as `A - (A/B)*B < B` rather than `A < (A/B + 1)*B`, which is the form
// that avoids forming a product the instruction never evaluated.
// Soundness: A -Int (A /Int B) *Int B is A modInt B, which lies in [0, B) for B > 0.
// DERIVABLE. Validated over 400k random samples including full-width uint256 values.
    rule [div-remainder-lt]:
      A -Int ( ( A /Int B ) *Int B ) <Int B => true
      requires 0 <=Int A
       andBool 0 <Int B
      [simplification, preserves-definedness]

    rule [div-eq-from-window]:
      ( A /Int B ) ==Int C => true
      requires 0 <=Int A andBool 0 <Int B
       andBool C *Int B <=Int A
       andBool A <Int ( C +Int 1 ) *Int B
      [simplification(40), comm, preserves-definedness]

// Bridge shifts to arithmetic. Priority 60 so KEVM's `asWord-shr` (default 50) still wins
// on byte-level goals -- do not raise it.
//
// NOTE: `shiftl-to-mul` below effectively NEVER FIRES. KEVM's bytes-simplification.k:95
// rewrites `X <<Int Y` into byte form at default priority, which beats 60. Section 8's
// `asword-buf29-zeros-*` rules are what actually handle a left shift here. Retained because
// the right-shift half does fire.
//
// NOT a duplicate of Kontrol's aux `shift-to-div`, despite looking like one. That version
// lacks `preserves-definedness` and is therefore discarded by the Booster before matching
// (same failure mode as the mul512 rules in Section 6). Ours is the live one. Do not
// "de-duplicate" it away.
    rule [shiftl-to-mul]:
      X <<Int N => X *Int ( 2 ^Int N )
      requires 0 <=Int X andBool 0 <=Int N
      [simplification(60), concrete(N), preserves-definedness]

    rule [shiftr-to-div]:
      X >>Int N => X /Int ( 2 ^Int N )
      requires 0 <=Int X andBool 0 <=Int N
      [simplification(60), concrete(N), preserves-definedness]

// ---------------------------------------------------------------------------
// Section 6: 512-bit multiplication collapse
// ---------------------------------------------------------------------------
//
// The gate for every OZ `Math.mulDiv`. mulDiv runs `Math.mul512` and branches on whether
// the high limb is zero; if KEVM cannot decide that branch, every mulDiv forks into the
// 512-bit path with its six-step Newton modular inverse, which is not realistically
// provable.
//
// TERM SHAPE: `high == 0` never appears. mul512 computes
//   mm := mulmod(a, b, not(0)); low := mul(a, b); _1 := lt(mm, low); _2 := sub(mm, low)
//   high := sub(_2, _1)
// and the Yul optimiser rewrites `high == 0` into `eq(_2, _1)` -- `high` is computed
// separately because the slow path still needs it, and does not occur in the branch
// condition. A lemma keyed on `HIGH ==Int 0` can never fire.
//
// Soundness: let P = X*Y >= 0 with P < 2^256, so chop(P) = P, and M = P mod (2^256 - 1).
// If P <= 2^256 - 2 then M = P, so both sides are 0. If P == 2^256 - 1 then M = 0, so both
// sides are 1. An elementary two-case argument that does NOT rely on the correctness of the
// CRT reconstruction. DERIVABLE.
//
// Once this fires the fast path returns `low / denominator` = `(X *Int Y) /Int D`, the
// textbook form the Section 4 division lemmas already handle. No mulDiv summary needed.
//
// !! `preserves-definedness` IS LOAD-BEARING ON BOTH RULES BELOW. !!
// `modInt` is a partial symbol, so without the attribute the Booster discards the rule
// BEFORE attempting to match it, logging
//     'failure','continue'  Uncertain about definedness of rule due to:
//                           non-total symbol Lbl_modInt_
// The rule is then dead: it never fires, and nothing in the build or the proof output says
// so. Both rules shipped without it and were dead until a Booster log was inspected
// directly. Do not remove it. See LEMMA-CRAFT.md for how to read those logs.
//
// This also means the `--lemmas` fast loop CANNOT test these: pyk's Kore converter accepts
// only six rule attributes and hard-errors on `preserves-definedness`, so a fast-loop run
// gives a false negative for every division lemma in this file. Test them via a rebuild.

    rule [mul512-high-zero]:
      chop ( ( ( X *Int Y ) modInt maxUInt256 ) -Int chop ( X *Int Y ) )
        ==Int bool2Word ( ( ( X *Int Y ) modInt maxUInt256 ) <Int chop ( X *Int Y ) )
      => true
      requires 0 <=Int X andBool 0 <=Int Y andBool X *Int Y <Int pow256
      [simplification, comm, preserves-definedness]

    rule [mul512-high-zero-nochop]:
      chop ( ( ( X *Int Y ) modInt maxUInt256 ) -Int ( X *Int Y ) )
        ==Int bool2Word ( ( ( X *Int Y ) modInt maxUInt256 ) <Int ( X *Int Y ) )
      => true
      requires 0 <=Int X andBool 0 <=Int Y andBool X *Int Y <Int pow256
      [simplification, comm, preserves-definedness]

// REMOVED: `mulmod-maxuint-collapse` duplicated KEVM's stock `A modInt B => A`, including
// the strictness the comment claimed was missing. Restating a stock rule adds a matching
// candidate for no gain and risks racing the original.

// ---------------------------------------------------------------------------
// Section 7: symbolic squares
// ---------------------------------------------------------------------------
//
// DERIVABLE -- ordinary integer arithmetic, no assumption about any library function.
// Z3 stalls on these because both operands are symbolic, and KEVM's own `*Int` transfer
// rules are gated on `concrete(A, C)` so they never fire here.

    rule [sq-monotonic]:
      X *Int X <=Int Y *Int Y => true
      requires 0 <=Int X andBool X <=Int Y
      [simplification]

    rule [sq-monotonic-strict]:
      X *Int X <Int Y *Int Y => true
      requires 0 <=Int X andBool X <Int Y
      [simplification]

// Strictly weaker than `mul-no-overflow` in Section 1, but its side condition needs no
// division, which is what lets it fire.
    rule [sq-no-overflow]:
      X *Int X <Int pow256 => true
      requires 0 <=Int X andBool X <Int pow128
      [simplification]

// ---------------------------------------------------------------------------
// Section 8: compiled-form normalisations (evidence-backed)
// ---------------------------------------------------------------------------
//
// Each rule here has direct before/after evidence from a real proof: the KCFG changed
// shape, or a failing proof closed, when it was added. They all exist because solc or KEVM
// presents a term in a form no stock rule matches.

// `value << 24` never becomes a multiplication. KEVM's bytes-simplification.k:95 rewrites
// `X <<Int Y` into `#asWord(#buf(32 - Y/8, X) +Bytes #buf(Y/8, 0))` at DEFAULT priority,
// which beats Section 5's `shiftl-to-mul` at priority 60 -- so that rule never fires and the
// shift stays in byte form. KEVM then knows only `< pow256`, too weak for the *checked*
// addition on the next line: the prover splits on `pow256 <=Int #asWord(...) +Int scale` and
// takes a spurious branch to a real EVMC_REVERT leaf.
//
// Evidence: adding this flipped `PiecewiseLinearScaleSpec.test_value_unscaleThenScaleIsIdentity`
// from FAILING to PASSED. Before, the KCFG split at node 39 with a reverting child; after,
// node 39 re-executed with no split and no overflow constraint in the path condition.
//
// Soundness: for X < 2^232 the 29-byte buffer holds X exactly and the three zero bytes are a
// shift by 24. DERIVABLE.
    rule [asword-buf29-zeros-lit]:
      #asWord ( #buf ( 29 , X ) +Bytes b"\x00\x00\x00" ) => X *Int 16777216
      requires 0 <=Int X andBool X <Int pow232
      [simplification, preserves-definedness]

    rule [asword-buf29-zeros-buf]:
      #asWord ( #buf ( 29 , X ) +Bytes #buf ( 3 , 0 ) ) => X *Int 16777216
      requires 0 <=Int X andBool X <Int pow232
      [simplification, preserves-definedness]

// A harness entry point returning `uint256` leaves the value as
// `#asWord(#range(#padToWidth(32, #asByteStack(U)), 0, 32))`. KEVM's own
// `#padToWidth(32, #asByteStack(V)) => #buf(32, V)` is guarded on `#rangeUInt(256, V)`, and
// when V is an `up/Int` term KEVM cannot establish that bound -- `up/Int` is uninterpreted on
// symbolic operands. Every downstream lemma then has to match the byte form instead of U.
// DERIVABLE.
    rule [abi-return-roundtrip-range]:
      #asWord ( #range ( #padToWidth ( 32 , #asByteStack ( X ) ) , 0 , 32 ) ) => X
      requires #rangeUInt(256, X)
      [simplification]

    rule [abi-return-roundtrip]:
      #asWord ( #padToWidth ( 32 , #asByteStack ( X ) ) ) => X
      requires #rangeUInt(256, X)
      [simplification]

// These two are what let the stock `#padToWidth` rule fire on an `up/Int` result.
    rule [updiv-lt-pow256]:
      A up/Int B <Int pow256 => true
      requires 0 <=Int A andBool A <Int pow256 andBool 0 <Int B
      [simplification]

    rule [updiv-nonneg]:
      0 <=Int A up/Int B => true
      requires 0 <=Int A andBool 0 <Int B
      [simplification]

// solc emits `or(iszero(a), eq(...))` as a bitwise `|Int` on two `bool2Word`s, and
// bitwise-simplification.k has no rule relating that to `orBool`, so it reaches the JUMPI
// SMT-opaque. Sound because `bool2Word` ranges over {0,1}. DERIVABLE.
    rule [bool2word-or]:
      bool2Word ( P:Bool ) |Int bool2Word ( Q:Bool ) => bool2Word ( P orBool Q )
      [simplification]

    rule [bool2word-and]:
      bool2Word ( P:Bool ) &Int bool2Word ( Q:Bool ) => bool2Word ( P andBool Q )
      [simplification]

// `if (++num == max)` is emitted as `DUP3 DUP3 SUB ... JUMPI`, never `EQ`, so KEVM sees
// `chop(NUM -Int MAX) ==Int 0`. KEVM's `chop-add-r-pos`, `chop-add-r-neg` and
// `chop-zero-sub` are all `[concrete(Y)]` and none matches a symbolic subtraction. Same
// class of trap as `not-word-to-sub` in Section 3. DERIVABLE.
    rule [chop-sub-eq-zero-l]:
      chop ( A -Int B ) ==Int 0 => A ==Int B
      requires #rangeUInt(256, A) andBool #rangeUInt(256, B)
      [simplification]

    rule [chop-sub-eq-zero-r]:
      0 ==Int chop ( A -Int B ) => A ==Int B
      requires #rangeUInt(256, A) andBool #rangeUInt(256, B)
      [simplification]

endmodule

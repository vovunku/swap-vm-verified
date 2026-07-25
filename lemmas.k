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

// `pow128`-bounded product: when both factors are known to fit in 128 bits, their
// product fits in 256 bits. Specs in this repo routinely bound inputs with
// `vm.assume(_ < 2 ** 128)` so that subsequent products are representable
// without further overflow reasoning (see e.g. LimitSwapSpec and
// XYCSwapSpec constant-product proofs). The two rules above do not fire in
// that case because their side condition is `X <= maxUInt256 /Int Y`, which is
// a *different* shape than `<Int pow128` and Z3 will not relate them without
// help.
//
// Soundness: for integers, 0 <= X < 2^128 and 0 <= Y < 2^128 imply
// X * Y < 2^128 * 2^128 = 2^256 = pow256. Both bounds are strict on the upper
// end so the result is strictly below pow256, matching Solidity 0.8's overflow
// predicate.

    rule [mul-no-overflow-pow128]:
      X *Int Y <Int pow256 => true
      requires 0 <=Int X
       andBool 0 <=Int Y
       andBool X <Int pow128
       andBool Y <Int pow128
      [simplification, preserves-definedness]

    rule [mul-no-overflow-pow128-comm]:
      Y *Int X <Int pow256 => true
      requires 0 <=Int X
       andBool 0 <=Int Y
       andBool X <Int pow128
       andBool Y <Int pow128
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
// Section 3: floor division bounds
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
// Section 4: ceiling division bounds
// ---------------------------------------------------------------------------
//
// OpenZeppelin `Math.ceilDiv(a, b)` for `b > 0` expands (after Solidity 0.8
// compilation and KEVM chopping) to `a > 0 ? (a - 1) / b + 1 : 0`. On the
// non-zero branch this is the term `((A -Int 1) /Int B) +Int 1`, which is what
// these rules match. They are the ceiling counterparts of `div-mul-le` and are
// needed by every `exactOut` rounding-direction property (LimitSwap, XYCSwap).
//
// All three rules assume the non-zero branch of ceilDiv, i.e. `0 < A`. The
// `a == 0` branch yields `0` and is discharged by int-simplification directly,
// so no lemma is needed there.

// Soundness: for A > 0 and B > 0, let q = floor((A - 1) / B). Then
// q * B <= (A - 1) by `div-mul-le`, so (q + 1) * B = q * B + B <= A - 1 + B.
// Since B >= 1, A - 1 + B >= A, hence (q + 1) * B >= A.
    rule [ceil-div-mul-ge]:
      ( ( ( A:Int -Int 1 ) /Int B:Int ) +Int 1 ) *Int B:Int >=Int A:Int => true
      requires 0 <Int A:Int
       andBool 0 <Int B:Int
      [simplification, preserves-definedness]

// Soundness: for A > 0 and B > 0, let q = floor((A - 1) / B). By definition of
// floor, q > (A - 1) / B - 1, i.e. q >= (A - 1) / B - (B - 1) / B > (A - B) / B,
// so q * B > A - B, i.e. q * B >= A - B + 1 (since both are integers).
// Hence (q + 1) * B = q * B + B >= A - B + 1 + B = A + 1 > A, i.e.
// (q + 1) * B - A < B. (Equivalently: ceilDiv(A, B) * B is in [A, A + B - 1].)
    rule [ceil-div-mul-tight]:
      ( ( ( A:Int -Int 1 ) /Int B:Int ) +Int 1 ) *Int B:Int -Int A:Int <Int B:Int => true
      requires 0 <Int A:Int
       andBool 0 <Int B:Int
      [simplification, preserves-definedness]

// Soundness: ceilDiv(A, B) >= floor(A / B) for A > 0, B > 0, since the ceiling
// is at least the floor. With q = floor((A-1)/B), q + 1 >= floor(A/B) because
// either A = k*B (q = k - 1, ceilDiv = k = floor(A/B)) or A = k*B + r with
// 0 < r < B (q = k, ceilDiv = k + 1 > floor(A/B) = k).
    rule [ceil-div-ge-div]:
      ( ( ( A:Int -Int 1 ) /Int B:Int ) +Int 1 ) >=Int ( A:Int /Int B:Int ) => true
      requires 0 <Int A:Int
       andBool 0 <Int B:Int
      [simplification, preserves-definedness]

// ---------------------------------------------------------------------------
// Section 4: bounded multiplication overflow (128 x 64)
// ---------------------------------------------------------------------------
//
// SwapVM specs commonly bound amounts to 128 bits (`vm.assume(X < 2**128)`) while rates
// are uint64, so every product `X * rate` is bounded by 2^192. Solidity 0.8 emits an
// overflow check (`X * Y < pow256`) for each multiplication, and without a rule that
// matches the *bounded* form, the SMT solver re-derives `2^128 * 2^64 = 2^192 < 2^256`
// for every node — the dominant cost on the MinRate proofs.
//
// The general `mul-no-overflow` rule in section 1 requires `X <= maxUInt256 / Y`, which
// does NOT match the bounded form `X < pow128` / `Y < pow64` without an extra chain of
// division/monotonicity reasoning. This specialised pair closes that gap directly.
//
// Soundness: for non-negative X < 2^128 and Y < 2^64, X * Y < 2^128 * 2^64 = 2^192 < 2^256.

    rule [mul-no-overflow-128x64]:
      X *Int Y <Int pow256 => true
      requires 0 <=Int X
       andBool 0 <=Int Y
       andBool X <Int pow128
       andBool Y <Int pow64
      [simplification, preserves-definedness]

    rule [mul-no-overflow-128x64-comm]:
      Y *Int X <Int pow256 => true
      requires 0 <=Int X
       andBool 0 <=Int Y
       andBool X <Int pow128
       andBool Y <Int pow64
      [simplification, preserves-definedness]

// ---------------------------------------------------------------------------
// Section 5: ceiling division bounds
// ---------------------------------------------------------------------------
//
// OpenZeppelin's `Math.ceilDiv(a, b)` compiles (for a > 0, b > 0) to `(a - 1) / b + 1`.
// SwapVM uses it on the exact-out leg of `_adjustMinRate1D`: the smallest input that
// satisfies the floor. The "adjusted rate satisfies the floor" property needs the
// *upper* bound `ceil(A/B) * B >= A`, the mirror image of `div-mul-le`.
//
// Soundness: ceilDiv(A, B) * B >= A for A > 0, B > 0.
//   ceilDiv(A, B) = floor((A-1)/B) + 1, so
//   ceilDiv(A,B) * B = floor((A-1)/B)*B + B.
//   Let Q = floor((A-1)/B). By definition of floor, Q*B <= A-1 < (Q+1)*B.
//   Then (Q+1)*B = Q*B + B > A-1, so (Q+1)*B >= A (integers).  ∎

    rule [ceil-div-mul-ge]:
      (((A -Int 1) /Int B) +Int 1) *Int B >=Int A => true
      requires 0 <Int A
       andBool 0 <Int B
      [simplification, preserves-definedness]

    rule [ceil-div-mul-ge-comm]:
      B *Int (((A -Int 1) /Int B) +Int 1) >=Int A => true
      requires 0 <Int A
       andBool 0 <Int B
      [simplification, preserves-definedness]

endmodule

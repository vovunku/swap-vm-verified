// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test, stdError } from "forge-std/Test.sol";

import { PowerHarness } from "./harnesses/PowerHarness.sol";

/// @notice Kontrol specification for `Power.pow` (`src/libs/Power.sol`), the fixed-point
///         exponentiation used by `DutchAuction` (`:85`, `:95`) and `TWAPSwap` (`:152`).
///
/// @dev **Reference semantics** (`src/libs/Power.sol:13-23`). Nothing is `unchecked`, so
///      every `*` panics with `Panic(0x11)` on overflow and every `/` panics with
///      `Panic(0x12)` on a zero divisor:
///
///        function pow(uint256 base, uint256 exponent, uint256 precision)
///            returns (uint256 result)
///        {
///            result = precision;
///            while (exponent > 0) {
///                if (exponent & 1 == 1) { result = (result * base) / precision; }
///                base = (base * base) / precision;
///                exponent >>= 1;
///            }
///        }
///
///      Read `precision` as the fixed-point unit `p`: `base` denotes the rational `B/p` and
///      the result denotes `(B/p)^E`, scaled back by `p`. `DutchAuction` uses `p == 1e18`.
///
///      **Termination is not in question.** `exponent >>= 1` runs unconditionally, so the
///      trip count is exactly `bitlength(exponent)` — at most 256 always, and at most 16 for
///      `DutchAuction`, whose exponent is `elapsed <= duration` and whose `duration` is a
///      `uint16` (`DutchAuctionArgsBuilder.build`, `:23`). `README.md`'s claim that this is
///      "a `while` loop with a symbolic trip count" that "needs `--bmc-depth`, which yields
///      only a bounded result" is wrong on the second half: `--bmc-depth 257` is
///      unconditional, and `--bmc-depth 17` is unconditional for `DutchAuction`.
///
///      **The cost is path count, not trip count.** The branch on `exponent & 1` has two
///      *continuing* arms — unlike `PiecewiseLinearScale`, whose extra branches all terminate
///      the loop and leave a caterpillar KCFG. Leaves therefore grow as `2^bitlength(E)`:
///      65 536 for a 16-bit exponent, `2^256` for `TWAPSwap`. BMC is nominally the right tool
///      and practically hopeless. See `analysis/FINDINGS.md`.
///
///      **So this file specifies order properties, not the closed form.** Each is provable by
///      induction on `bitlength(E)` from monotonicity of `floor` alone, with no exponential
///      anywhere. The closed form is not available in the first place: once the floors are
///      present, the exact-arithmetic invariant `(r/p)·(b/p)^e = (B/p)^E` survives only as the
///      inequality `pow(B,E,p) <= p·(B/p)^E`, and a matching lower bound is a numerical
///      analysis result rather than a rewriting exercise.
///
///      Every symbolic-exponent property below is therefore stated for the honest full
///      `uint256` domain **and** repeated with a `uint8` exponent where a tractable
///      restriction exists. The `uint8` forms cap the loop at 8 iterations and 256 leaves,
///      which `--bmc-depth 9` can actually close; they are additions, not replacements. The
///      concrete-exponent families (`test_unroll_*`, `test_witness_*`) are the cheapest
///      surface in the file: a literal `E` makes the loop condition and every `exponent & 1`
///      concrete, so KEVM unrolls to a **single path** while `base` and `precision` stay fully
///      symbolic.
///
///      **Three findings this file records, none of them previously written down.**
///
///      1. *The trailing square is dead work that can panic on an answer that fits.* The loop
///         squares `base` after consuming the final set bit, so `pow(2**128, 1, p)` reverts
///         with `Panic(0x11)` for every `p`, even though the answer is just `B`. solc's own
///         `**` iterates while `exponent > 1` and does not have this. See `test_squaring_*`.
///      2. *`precision == 0` does not always give `Panic(0x12)`.* `FINDINGS.md` bug 3 states
///         it flatly. It holds for every odd exponent and for every even exponent with
///         `base <= type(uint128).max`, but at `base = 2**128, exponent = 2` the trailing
///         square overflows *before* the division is reached and the panic is `0x11`. See
///         `test_precisionZero_*`.
///      3. *`FINDINGS.md` bug 3 has a concrete, in-range witness.* `pow(0.99e18, 4097, 1e18)`
///         is exactly `0`, and `4097 <= type(uint16).max`, so a `DutchAuction` with
///         `decayFactor = 0.99e18` and `duration >= 4097` reaches a zero `decay` — which
///         `DutchAuction.sol:97` then divides by. `pow(0.5e18, 60, 1e18)` is zero after only
///         60 seconds. See `test_witness_decayReachesZero*`.
///
///      **Domain narrowing is confined to one bound and always paired.** Where a property
///      needs the arithmetic to be total it assumes `precision <= type(uint128).max`, which
///      is exactly the condition making `p * p` fit in 256 bits — `(2**128 - 1)^2 < 2**256`
///      while `(2**128)^2 == 2**256`. It is a real restriction and it is stated in the
///      parameter type rather than hidden in a `vm.assume`. Every narrowed property has an
///      unnarrowed `try`/`catch` twin covering the whole `uint256` domain, so nothing is
///      assumed away. `1e18 < 2**128` by 38 orders of magnitude, so both production callers
///      sit comfortably inside.
///
///      **`try`/`catch` rather than an overflow assumption**, per `test/kontrol/README.md`:
///      bounding a product away needs a *symbolic* `DIV` in the path condition, which KEVM
///      models with a divide-by-zero guard and which has already stalled proofs in this repo.
///      The `try` form also quantifies over strictly more inputs than the assumption form.
///      Anti-vacuity is handled by pairing every `try`/`catch` property with a total or
///      concrete witness that provably reaches the `try` body with a non-degenerate value.
contract PowerSpec is Test {
    PowerHarness internal harness;

    /// @dev `DutchAuction`'s fixed-point unit (`DutchAuction.sol:86`, `:96`) and `TWAPSwap`'s
    ///      (`TWAPSwap.sol:152`).
    uint256 internal constant ONE = 1e18;

    /// @dev A representative decay factor from the instruction's own docstring
    ///      (`DutchAuction.sol:62`): 1% decay per second. `DutchAuctionArgsBuilder.build`
    ///      requires `decayFactor < 1e18` (`:28`), so this is a legal argument.
    uint256 internal constant DECAY_99 = 0.99e18;

    /// @dev The largest precision for which `p * p` still fits in 256 bits.
    ///      `(2**128 - 1)^2 = 2**256 - 2**129 + 1 < 2**256`, and `(2**128)^2 = 2**256` does
    ///      not. This boundary is exact and is pinned by `test_total_boundaryIsExact`.
    uint256 internal constant MAX_TOTAL_PRECISION = type(uint128).max;

    function setUp() public {
        harness = new PowerHarness();
    }

    // =======================================================================
    // Base cases — the three fixed points, no induction needed
    // =======================================================================

    /// @notice `pow(B, 0, p) == p` for every `B` and every `p`, including `p == 0`.
    /// @dev The loop is not entered, so `result` is still the initial `precision`. Total:
    ///      there is no reachable revert on this path at all, which is why it is stated
    ///      without `try`/`catch` over the full domain. Under Kontrol this is a single path
    ///      with no branch on `exponent & 1`, so it is the cheapest property in the file and
    ///      the right one to run first when validating the harness shape.
    function test_base_zeroExponentReturnsPrecision(uint256 base, uint256 precision) public view {
        assertEq(harness.pow(base, 0, precision), precision, "an empty product must be the fixed-point one");
    }

    /// @notice `pow(p, E, p) == p` — the fixed-point `1.0` is a fixed point of the map.
    /// @dev `B == p` denotes the rational `1`, and `1^E == 1`. Mechanically: `result` starts
    ///      at `p` and every step maps it to `(p * p) / p == p`, while `base` is likewise
    ///      preserved, so both registers are invariant and no floor ever loses anything.
    ///
    ///      DOMAIN NARROWING: `precision` is a `uint128`, i.e. `p <= 2**128 - 1`. That is not
    ///      cosmetic — at `p == 2**128` the very first `base * base` is exactly `2**256` and
    ///      the call panics, so `pow(2**128, E, 2**128)` genuinely is not `2**128`. The
    ///      unnarrowed statement is `test_base_precisionIsAFixedPointFullDomain` below, and
    ///      the boundary is pinned by `test_total_boundaryIsExact`.
    ///
    ///      `precision != 0` is required because `pow(0, E, 0)` divides by zero for `E > 0`;
    ///      that case is specified in full by the `test_precisionZero_*` group.
    function test_base_precisionIsAFixedPoint(uint128 precision, uint256 exponent) public view {
        vm.assume(precision != 0);

        assertEq(harness.pow(precision, exponent, precision), precision, "1.0 must be a fixed point of pow");
    }

    /// @notice The same claim over every `uint256` precision, with the panicking inputs
    ///         discharged by the `catch` rather than assumed away.
    /// @dev The pair (this plus the narrowed form above) is the pattern used throughout the
    ///      file: the `try` form is the true theorem and the narrowed form is the
    ///      non-vacuity certificate that the `try` body is reachable with a live value.
    function test_base_precisionIsAFixedPointFullDomain(uint256 precision, uint256 exponent) public view {
        try harness.pow(precision, exponent, precision) returns (uint256 result) {
            assertEq(result, precision, "1.0 must be a fixed point of pow wherever pow is defined");
        } catch { /* p * p overflowed, or p == 0 with E > 0: nothing to claim */ }
    }

    /// @notice `pow(0, E, p) == 0` for every `E > 0` and every `p > 0`.
    /// @dev `base` is zero at entry and `(0 * 0) / p == 0` keeps it there, so the first set
    ///      bit of `E` maps `result` to `(result * 0) / p == 0` and it can never leave. `E > 0`
    ///      guarantees a set bit exists — the top bit of any positive integer is set — which
    ///      is the whole content of the side condition.
    ///
    ///      Total, and stated over the full `uint256` domain with no `try`: with `base == 0`
    ///      every product in the loop is `0 * something`, so no multiply can overflow no
    ///      matter how large `p` is, and `p != 0` rules out the only division fault. This is
    ///      the one symbolic-exponent property in the file that needs neither a narrowing nor
    ///      a `catch`.
    function test_base_zeroBaseCollapsesToZero(uint256 exponent, uint256 precision) public view {
        vm.assume(exponent != 0);
        vm.assume(precision != 0);

        assertEq(harness.pow(0, exponent, precision), 0, "a zero base must annihilate the result");
    }

    // =======================================================================
    // The workhorse — contraction when the base is at most the unit
    // =======================================================================

    /// @notice `B <= p  ==>  pow(B, E, p) <= p`. The base is a fraction, so no power of it
    ///         can exceed one.
    /// @dev **This is the property everything else leans on.** It is what discharges
    ///      `DutchAuction`'s decay-direction claim: `decayFactor < 1e18` is enforced at build
    ///      time (`DutchAuctionArgsBuilder.build:28`), so `decay = pow(decayFactor, elapsed,
    ///      1e18) <= 1e18` and `balanceIn * decay / 1e18 <= balanceIn` at `DutchAuction.sol:87`
    ///      — the auction can only ever shrink the input balance, never inflate it. Without
    ///      this bound the instruction's entire direction of travel is unproven.
    ///
    ///      Proof by induction on `bitlength(E)`, using only that `x |-> floor(x*y/p)` is
    ///      monotone: the pair `(result <= p, base <= p)` is preserved by both loop
    ///      statements, since `result * base <= p * p` floors to at most `p` and likewise for
    ///      `base * base`. No exponential and no closed form appears. Note the invariant is
    ///      on *both* registers — a proof attempt tracking only `result` will not close.
    ///
    ///      Full `uint256` domain. `base <= precision` is a comparison, so unlike an overflow
    ///      bound it puts no symbolic `DIV` into the path condition.
    function test_bound_neverExceedsPrecision(uint256 base, uint256 exponent, uint256 precision) public view {
        vm.assume(base <= precision);

        try harness.pow(base, exponent, precision) returns (uint256 result) {
            assertLe(result, precision, "a base below the unit must never produce a result above it");
        } catch { /* the checked arithmetic overflowed: nothing to bound */ }
    }

    /// @notice The same bound with an 8-bit exponent — the tractable restriction.
    /// @dev `bitlength(E) <= 8` caps the loop at 8 iterations and the KCFG at 256 leaves,
    ///      which `--bmc-depth 9` can close. Prove this one before attempting the `uint256`
    ///      form: if the invariant is wrong, it fails here in minutes instead of never
    ///      converging there. Not a weakening — the full-domain statement above is the
    ///      theorem, and this is a corollary chosen for provability.
    function test_bound_neverExceedsPrecisionSmallExponent(uint256 base, uint8 exponent, uint256 precision)
        public
        view
    {
        vm.assume(base <= precision);

        try harness.pow(base, exponent, precision) returns (uint256 result) {
            assertLe(result, precision, "a base below the unit must never produce a result above it");
        } catch { /* the checked arithmetic overflowed: nothing to bound */ }
    }

    /// @notice `B <= p <= 2**128 - 1  ==>  no `Panic(0x11)`; the call is total.
    /// @dev The overflow half of the same invariant. Every multiply in the loop is either
    ///      `result * base` or `base * base` with both operands pinned at or below `p` by the
    ///      induction above, so every product is at most `p * p`, which fits precisely when
    ///      `p <= 2**128 - 1`. With `p != 0` there is no division fault either, so the
    ///      function is total on this domain and the call is made without `try`.
    ///
    ///      This is also the non-vacuity certificate for `test_bound_neverExceedsPrecision`:
    ///      it proves the `try` body is reached, over a domain rather than at a point.
    ///
    ///      DOMAIN NARROWING, and the only one in the file: `precision <= type(uint128).max`.
    ///      Both production callers use `p == 1e18 < 2**128`, so nothing real is excluded, and
    ///      `test_total_boundaryIsExact` shows the bound cannot be relaxed by even one.
    function test_total_noPanicWhenBaseAtMostPrecision(uint128 base, uint128 precision, uint256 exponent)
        public
        view
    {
        vm.assume(precision != 0);
        vm.assume(base <= precision);

        uint256 result = harness.pow(base, exponent, precision);

        assertLe(result, precision, "the total domain must also satisfy the bound");
    }

    /// @notice The `2**128` boundary is exact: one above it, `pow` panics with `B == p`.
    /// @dev Pins that `test_total_noPanicWhenBaseAtMostPrecision`'s narrowing is the real
    ///      frontier and not a conservative guess. At `p == 2**128 - 1` the call succeeds and
    ///      returns `p`; at `p == 2**128` the first `base * base` is exactly `2**256` and it
    ///      panics — even though the mathematical answer, `1.0`, is representable.
    ///
    ///      Concrete on both sides, so it is two single-path goals under Kontrol.
    function test_total_boundaryIsExact() public {
        uint256 justUnder = MAX_TOTAL_PRECISION; // 2**128 - 1

        assertEq(harness.pow(justUnder, 3, justUnder), justUnder, "p * p must still fit at 2**128 - 1");

        vm.expectRevert(stdError.arithmeticError);
        harness.pow(1 << 128, 2, 1 << 128);
    }

    // =======================================================================
    // Monotonicity — in the exponent, and in the base
    // =======================================================================

    /// @notice `B <= p` and `E1 <= E2`  ==>  `pow(B, E2, p) <= pow(B, E1, p)`.
    ///         Raising a fraction to a higher power never increases it.
    /// @dev The order property that gives the decay schedule its shape: a `DutchAuction`'s
    ///      `decay` is non-increasing in `elapsed`, so `balanceIn` shrinks monotonically as
    ///      the auction runs and `balanceOut` grows monotonically. A caller reading only
    ///      `test_bound_neverExceedsPrecision` knows the price is bounded but not that it
    ///      moves in one direction.
    ///
    ///      This is *not* a consequence of the closed form — the two runs share no
    ///      intermediate state, since the bit patterns of `E1` and `E2` differ and the
    ///      squaring chains have different lengths. It follows from the contraction invariant
    ///      instead: with `B <= p` each additional consumed set bit maps `result` to
    ///      `floor(result * b / p) <= result`, because `b <= p`.
    ///
    ///      Both calls are wrapped, because neither call's success implies the other's: the
    ///      squaring chain for `E1` is a prefix of `E2`'s, but the `result` multiplies are not
    ///      nested, so `E2` can succeed where `E1` panics and conversely.
    function test_mono_nonIncreasingInExponent(uint256 base, uint256 e1, uint256 e2, uint256 precision) public view {
        vm.assume(base <= precision);
        vm.assume(e1 <= e2);

        try harness.pow(base, e2, precision) returns (uint256 hi) {
            try harness.pow(base, e1, precision) returns (uint256 lo) {
                assertLe(hi, lo, "a larger exponent must never give a larger result");
            } catch { /* the smaller exponent overflowed: nothing to compare */ }
        } catch { /* the larger exponent overflowed: nothing to compare */ }
    }

    /// @notice The same, on the total domain — no `try`, so the comparison provably happens.
    /// @dev Non-vacuity certificate for the property above, and simultaneously the
    ///      `uint8`-exponent restriction that `--bmc-depth 9` can close. Both exponents live
    ///      inside `type(uint8).max` and `precision <= type(uint128).max`, so
    ///      `test_total_noPanicWhenBaseAtMostPrecision` applies to both calls and neither can
    ///      revert.
    function test_mono_nonIncreasingInExponentTotal(uint128 base, uint8 e1, uint8 e2, uint128 precision) public view {
        vm.assume(precision != 0);
        vm.assume(base <= precision);
        vm.assume(e1 <= e2);

        assertLe(
            harness.pow(base, e2, precision),
            harness.pow(base, e1, precision),
            "a larger exponent must never give a larger result"
        );
    }

    /// @notice `B1 <= B2  ==>  pow(B1, E, p) <= pow(B2, E, p)`. Monotone in the base.
    /// @dev Needs no `base <= precision` side condition: the two runs consume the *same* bit
    ///      pattern, so they execute the same sequence of statements and the induction is a
    ///      direct application of monotonicity of `x |-> floor(x*y/p)` in both arguments,
    ///      valid for bases above the unit too.
    ///
    ///      Worth stating because it is what makes the decay factor a meaningful dial: a
    ///      maker who raises `decayFactor` gets a decay at least as large at every elapsed
    ///      time, so the parameter is not merely correlated with the schedule but ordered
    ///      with it.
    function test_mono_nonDecreasingInBase(uint256 b1, uint256 b2, uint256 exponent, uint256 precision) public view {
        vm.assume(b1 <= b2);

        try harness.pow(b2, exponent, precision) returns (uint256 hi) {
            try harness.pow(b1, exponent, precision) returns (uint256 lo) {
                assertLe(lo, hi, "a larger base must never give a smaller result");
            } catch { /* the smaller base overflowed: nothing to compare */ }
        } catch { /* the larger base overflowed: nothing to compare */ }
    }

    /// @notice The base ordering is *strict* at three legal decay factors.
    /// @dev `test_mono_nonDecreasingInBase` and its total twin are both `<=`, so a `pow` that
    ///      collapsed every input to a single value would satisfy them. This pins that it does
    ///      not: at 50%, 10% and 1% per-second decay the results are strictly ordered at every
    ///      elapsed time checked, so the `decayFactor` argument really is a dial and not a
    ///      formality.
    ///
    ///      Kept as a strict-inequality witness rather than more literal equalities because
    ///      the exact values are already pinned by `test_witness_decayFactorPowersAreExact`;
    ///      what is added here is the *separation*. Fully concrete, and written out rather
    ///      than looped: a loop in the *spec* is as much a path multiplier under Kontrol as a
    ///      loop in the code, and this way each assertion is one straight-line goal.
    ///
    ///      Mutation record: this is what kills the branch-inversion and the `result = 1`
    ///      initialisation for the base-monotonicity group, both of which make the three
    ///      calls agree and which the `<=` forms therefore cannot see.
    function test_mono_strictlyIncreasingInBaseAtLegalDecayFactors() public view {
        assertLt(harness.pow(0.5e18, 3, ONE), harness.pow(0.9e18, 3, ONE), "0.5^3 < 0.9^3");
        assertLt(harness.pow(0.9e18, 3, ONE), harness.pow(DECAY_99, 3, ONE), "0.9^3 < 0.99^3");

        assertLt(harness.pow(0.5e18, 7, ONE), harness.pow(0.9e18, 7, ONE), "0.5^7 < 0.9^7");
        assertLt(harness.pow(0.9e18, 7, ONE), harness.pow(DECAY_99, 7, ONE), "0.9^7 < 0.99^7");

        assertLt(harness.pow(0.5e18, 16, ONE), harness.pow(0.9e18, 16, ONE), "0.5^16 < 0.9^16");
        assertLt(harness.pow(0.9e18, 16, ONE), harness.pow(DECAY_99, 16, ONE), "0.9^16 < 0.99^16");
    }

    /// @notice The same, on the total domain.
    /// @dev Non-vacuity certificate for the property above. `b1 <= b2 <= precision <= 2**128 - 1`
    ///      puts both calls inside `test_total_noPanicWhenBaseAtMostPrecision`'s domain.
    function test_mono_nonDecreasingInBaseTotal(uint128 b1, uint128 b2, uint8 exponent, uint128 precision)
        public
        view
    {
        vm.assume(precision != 0);
        vm.assume(b1 <= b2 && b2 <= precision);

        assertLe(
            harness.pow(b1, exponent, precision),
            harness.pow(b2, exponent, precision),
            "a larger base must never give a smaller result"
        );
    }

    // =======================================================================
    // precision == 0 — FINDINGS.md bug 3, and a correction to it
    // =======================================================================

    /// @notice `p == 0` and `E > 0`  ==>  the call always reverts.
    /// @dev `result` is initialised to `precision == 0`, so the loop body divides by zero on
    ///      its very first iteration whichever arm it takes. Full `uint256` domain, and
    ///      deliberately stated as "reverts" rather than "reverts with `Panic(0x12)`" —
    ///      *which* panic fires is not uniform, which the next two properties pin exactly.
    ///
    ///      `E > 0` is necessary, not decoration: `pow(B, 0, 0) == 0` and does not revert.
    function test_precisionZero_anyPositiveExponentReverts(uint256 base, uint256 exponent) public {
        vm.assume(exponent != 0);

        vm.expectRevert();
        harness.pow(base, exponent, 0);
    }

    /// @notice An odd exponent gives `Panic(0x12)` — division by zero — for every base.
    /// @dev With the low bit set the first statement executed is `(result * base) / precision`
    ///      and `result` is still `0`, so the multiply is `0 * base` and cannot overflow
    ///      however large `base` is. The division is therefore always reached, and it always
    ///      divides by zero.
    ///
    ///      `exponent` is built as `e | 1` rather than filtered with
    ///      `vm.assume(exponent & 1 == 1)`: identical domain, no rejected samples, and under
    ///      Kontrol an `OR` on the term instead of an extra path constraint.
    function test_precisionZero_oddExponentPanicsWithDivisionByZero(uint256 base, uint256 e) public {
        uint256 exponent = e | 1;

        vm.expectRevert(stdError.divisionError);
        harness.pow(base, exponent, 0);
    }

    /// @notice An even, positive exponent also gives `Panic(0x12)` — but only while
    ///         `base <= type(uint128).max`.
    /// @dev With the low bit clear the first statement executed is the trailing square,
    ///      `(base * base) / precision`. The multiply comes first, so it decides which panic
    ///      fires. Below `2**128` it cannot overflow and the division-by-zero is reached.
    ///
    ///      `exponent` is `(e | 1) << 1` with `e` a `uint128`: even by construction, non-zero
    ///      by construction, and small enough that the shift cannot discard the top bit and
    ///      silently produce zero.
    function test_precisionZero_evenExponentPanicsWithDivisionByZeroForSmallBase(uint128 base, uint128 e) public {
        uint256 exponent = (uint256(e) | 1) << 1;

        vm.expectRevert(stdError.divisionError);
        harness.pow(base, exponent, 0);
    }

    /// @notice CORRECTION to `FINDINGS.md` bug 3: `p == 0` does **not** always give
    ///         `Panic(0x12)`.
    /// @dev At `base == 2**128` with an even exponent, `base * base` is exactly `2**256` and
    ///      the checked multiply panics with `Panic(0x11)` *before* the zero divisor is ever
    ///      inspected. The recorded claim "`DutchAuction.sol:97` divides by `decay` ... giving
    ///      a reachable unguarded `Panic(0x12)`" is right about reachability and about the
    ///      call site, but the panic code attributed to `Power.pow` itself is not uniform over
    ///      the domain.
    ///
    ///      This matters for anyone writing `vm.expectRevert(stdError.divisionError)` around a
    ///      zero-precision call and concluding from a green test that they have characterised
    ///      the failure: they have characterised a sub-domain. Concrete witness, single path.
    function test_precisionZero_largeBaseOverflowsBeforeDividing() public {
        vm.expectRevert(stdError.arithmeticError);
        harness.pow(1 << 128, 2, 0);
    }

    // =======================================================================
    // precision == 1 — pow degenerates to plain exponentiation
    // =======================================================================

    /// @notice `pow(B, E, 1) == B ** E` wherever `pow` is defined.
    /// @dev Both divisions become the identity at `p == 1`, so the algorithm is textbook
    ///      exponentiation by squaring over the integers with no rounding anywhere. This is
    ///      the only place the spec pins an *exact closed form*, and it is the reason the
    ///      spec is not satisfiable by a function that ignores its arguments: it forces `pow`
    ///      to compute a genuine power.
    ///
    ///      The reference is `PowerHarness.checkedExp`, i.e. solc's own `**`. That is an
    ///      independent implementation, not a copy: solc's `checked_exp_helper` iterates while
    ///      `exponent > 1`, so it omits the trailing square, and it falls back to a slow path
    ///      rather than panicking when a squaring would overflow.
    ///
    ///      The implication is one-directional and the `try` sits on `pow` accordingly:
    ///      whenever `pow` succeeds, `result` is exactly `B^E`, so `B^E` fits and the
    ///      reference cannot revert inside the body. The converse fails, which is the next
    ///      property.
    function test_unitPrecision_agreesWithCheckedExponentiation(uint256 base, uint256 exponent) public view {
        try harness.pow(base, exponent, 1) returns (uint256 result) {
            assertEq(result, harness.checkedExp(base, exponent), "at precision 1, pow must be exact exponentiation");
        } catch { /* the trailing square overflowed: see test_squaring_* */ }
    }

    /// @notice The tractable restriction: eight-bit exponent, still symbolic in the base.
    /// @dev Same statement, loop capped at 8 iterations. Note that `checkedExp` is itself a
    ///      loop of the same shape, so proving this doubles the path count relative to the
    ///      order properties — take it last, and with `--bmc-depth 9`.
    function test_unitPrecision_agreesWithCheckedExponentiationSmallExponent(uint256 base, uint8 exponent)
        public
        view
    {
        try harness.pow(base, exponent, 1) returns (uint256 result) {
            assertEq(result, harness.checkedExp(base, exponent), "at precision 1, pow must be exact exponentiation");
        } catch { /* the trailing square overflowed: see test_squaring_* */ }
    }

    /// @notice Non-vacuity for the two properties above: concrete non-degenerate powers.
    /// @dev Without this, a `pow` that reverted on every input with `precision == 1` would
    ///      satisfy both. `3 ** 5 == 243` and `7 ** 8 == 5764801` are pinned as literals so
    ///      the assertion cannot agree with a broken implementation by construction.
    function test_unitPrecision_concretePowers() public view {
        assertEq(harness.pow(3, 5, 1), 243, "3^5");
        assertEq(harness.pow(7, 8, 1), 5_764_801, "7^8");
        assertEq(harness.pow(2, 10, 1), 1024, "2^10");
        assertEq(harness.pow(0, 0, 1), 1, "the empty product is one");
    }

    // =======================================================================
    // The trailing square — dead work that can panic on an answer that fits
    // =======================================================================

    /// @notice `pow` squares `base` once more than it needs to, and that square can panic on
    ///         inputs whose result is representable.
    /// @dev `while (exponent > 0)` runs the body for the final set bit and then squares
    ///      `base` again, even though `exponent >>= 1` is about to end the loop and that value
    ///      is never read. At `base == 2**128, exponent == 1` the answer is just `base`, but
    ///      the dead square is `2**256` and the call reverts with `Panic(0x11)`.
    ///
    ///      Not merely a `precision == 1` artefact — it fires at production precision too, so
    ///      the third assertion uses `1e18`. Any caller of `Power.pow` with a base above
    ///      `2**128` can be denied a perfectly representable answer. `DutchAuction` and
    ///      `TWAPSwap` are both unaffected in practice, since their bases are below `1e18`;
    ///      the library's contract with any other caller is what this pins.
    ///
    ///      `checkedExp` returns the value on the same input, which is what makes this a bug
    ///      in `pow` rather than a limit of 256-bit arithmetic.
    function test_squaring_trailingSquareCanPanicOnAnAnswerThatFits() public {
        assertEq(harness.checkedExp(1 << 128, 1), 1 << 128, "solc's ** returns the answer");

        vm.expectRevert(stdError.arithmeticError);
        harness.pow(1 << 128, 1, 1);

        vm.expectRevert(stdError.arithmeticError);
        harness.pow(1 << 128, 1, ONE);
    }

    /// @notice A second witness with a small base, showing the cost is in `bitlength(E)`.
    /// @dev `pow(2, 255, 1)` reverts: the squaring chain reaches `2**128` on the seventh
    ///      iteration and the eighth square is `2**256`. `2 ** 255` is representable and
    ///      `checkedExp` returns it. So the input domain `pow` rejects is not a thin edge
    ///      around `2**128` — for an exponent with `bitlength(E) == k` it rejects every base
    ///      above roughly `2**(256 / 2**(k-1))`, which for `k == 8` is `2` itself.
    function test_squaring_smallBaseIsAlsoRejectedAtLargeExponents() public {
        assertEq(harness.checkedExp(2, 255), 1 << 255, "solc's ** returns 2^255");

        vm.expectRevert(stdError.arithmeticError);
        harness.pow(2, 255, 1);
    }

    // =======================================================================
    // Concrete exponents — single-path, fully symbolic in base and precision
    // =======================================================================
    //
    // A literal exponent makes the loop condition and every `exponent & 1` concrete, so the
    // KCFG has exactly one leaf however large `base` and `precision` are. These are the
    // cheapest non-trivial goals in the file and the route FINDINGS.md recommends.
    //
    // Each reference below recomputes only products that the harness call itself already
    // performed, in the same order, so a reference-side panic inside a `try` body is
    // impossible: if the harness returned, every product in the reference fits.

    /// @notice `pow(B, 1, p) == B` exactly.
    /// @dev One iteration: `result = (p * B) / p`, which is `B` for any non-zero `p` — the
    ///      multiply and the division cancel with no floor loss because `p` divides `p * B`.
    ///      `p == 0` reverts and is caught. Note the trailing square still runs and is still
    ///      able to panic here; `test_squaring_*` is the same statement at a concrete base.
    function test_unroll_exponentOne(uint256 base, uint256 precision) public view {
        try harness.pow(base, 1, precision) returns (uint256 result) {
            assertEq(result, base, "pow(B, 1, p) == B");
        } catch { /* p == 0, or the trailing square overflowed */ }
    }

    /// @notice `pow(B, 2, p) == floor(B*B / p)`.
    /// @dev Bit pattern `10`: iteration one squares, iteration two consumes the set bit as
    ///      `result = (p * b1) / p == b1`.
    function test_unroll_exponentTwo(uint256 base, uint256 precision) public view {
        try harness.pow(base, 2, precision) returns (uint256 result) {
            assertEq(result, (base * base) / precision, "pow(B, 2, p) == floor(B^2 / p)");
        } catch { /* p == 0, or a checked multiply overflowed */ }
    }

    /// @notice `pow(B, 3, p) == floor(B * floor(B*B / p) / p)`.
    /// @dev Bit pattern `11`, the smallest exponent at which two floors compose and the
    ///      result is strictly below the exact `B^3 / p^2` in general. This is where the
    ///      closed form stops holding as an equality.
    function test_unroll_exponentThree(uint256 base, uint256 precision) public view {
        try harness.pow(base, 3, precision) returns (uint256 result) {
            uint256 b1 = (base * base) / precision;
            assertEq(result, (base * b1) / precision, "pow(B, 3, p) == floor(B * floor(B^2/p) / p)");
        } catch { /* p == 0, or a checked multiply overflowed */ }
    }

    /// @notice `pow(B, 7, p)` — bit pattern `111`, every arm of the branch taken.
    /// @dev The densest three-bit exponent: three set bits, so all three iterations run both
    ///      statements. Three composed floors on the `result` chain and two on the `base`
    ///      chain, which is the deepest rounding interaction the file pins exactly.
    function test_unroll_exponentSeven(uint256 base, uint256 precision) public view {
        try harness.pow(base, 7, precision) returns (uint256 result) {
            uint256 b1 = (base * base) / precision; // base after iteration 1
            uint256 r2 = (base * b1) / precision; // result after iteration 2
            uint256 b2 = (b1 * b1) / precision; // base after iteration 2
            assertEq(result, (r2 * b2) / precision, "pow(B, 7, p) is the exact three-floor product");
        } catch { /* p == 0, or a checked multiply overflowed */ }
    }

    /// @notice `pow(B, 8, p)` — bit pattern `1000`, the sparsest four-bit exponent.
    /// @dev Only the last iteration has its bit set, so the result is the third square of the
    ///      base chain and the `result` register is touched exactly once. The complement of
    ///      the `E == 7` case: same trip count class, opposite branch profile.
    function test_unroll_exponentEight(uint256 base, uint256 precision) public view {
        try harness.pow(base, 8, precision) returns (uint256 result) {
            uint256 b1 = (base * base) / precision;
            uint256 b2 = (b1 * b1) / precision;
            uint256 b3 = (b2 * b2) / precision;
            assertEq(result, b3, "pow(B, 8, p) == the third repeated square");
        } catch { /* p == 0, or a checked multiply overflowed */ }
    }

    /// @notice Non-vacuity for the whole `test_unroll_*` family: the `try` bodies are reached
    ///         with values that are neither `0` nor `p`.
    /// @dev A spec satisfied by a `pow` returning `0` always, or `p` always, would be
    ///      worthless. Every value below is strictly between the two, computed independently
    ///      at 1e18 fixed point, and written as a literal rather than as an expression over
    ///      `harness` output.
    ///
    ///      `0.99e18` is a legal `decayFactor` (`DutchAuctionArgsBuilder.build:28` requires
    ///      `< 1e18`) and appears verbatim in the instruction's docstring
    ///      (`DutchAuction.sol:62`), so these are the actual decay multipliers a 1%-per-second
    ///      auction applies at 1, 2, 3, 7, 8 and 16 seconds elapsed.
    function test_witness_decayFactorPowersAreExact() public view {
        assertEq(harness.pow(DECAY_99, 0, ONE), 1e18, "0.99^0");
        assertEq(harness.pow(DECAY_99, 1, ONE), 990_000_000_000_000_000, "0.99^1");
        assertEq(harness.pow(DECAY_99, 2, ONE), 980_100_000_000_000_000, "0.99^2");
        assertEq(harness.pow(DECAY_99, 3, ONE), 970_299_000_000_000_000, "0.99^3");
        assertEq(harness.pow(DECAY_99, 7, ONE), 932_065_347_906_990_000, "0.99^7");
        assertEq(harness.pow(DECAY_99, 8, ONE), 922_744_694_427_920_100, "0.99^8");
        assertEq(harness.pow(DECAY_99, 16, ONE), 851_457_771_094_875_639, "0.99^16");
    }

    // =======================================================================
    // FINDINGS.md bug 3 — the decay really does reach zero, in range
    // =======================================================================

    /// @notice `pow(0.99e18, 4097, 1e18) == 0`, and `4097 <= type(uint16).max`.
    /// @dev `FINDINGS.md` bug 3 records that `DutchAuction.sol:97` divides by `decay` and that
    ///      repeated squaring drives `decay` to zero, but records no witness. This is one, and
    ///      it is in range: `duration` is a `uint16` (`DutchAuctionArgsBuilder.build:23`), so a
    ///      maker may legally write any `duration` up to 65 535, and `elapsed` reaches 4 097
    ///      long before the expiry check at `DutchAuction.sol:83` fires. At that point
    ///      `_dutchAuctionBalanceOut1D` computes `balanceOut * 1e18 / 0` and panics with
    ///      `Panic(0x12)` — an unguarded liveness failure, not a domain error the maker can
    ///      distinguish.
    ///
    ///      The pair `4096 -> 1`, `4097 -> 0` brackets it exactly, which also shows the
    ///      approach to zero is not asymptotic-but-never-reached: the last non-zero value is
    ///      `1 wei` and the very next second it is gone.
    function test_witness_decayReachesZeroWithinUint16Duration() public view {
        assertEq(harness.pow(DECAY_99, 4096, ONE), 1, "one wei of decay left");
        assertEq(harness.pow(DECAY_99, 4097, ONE), 0, "decay is exactly zero, and :97 divides by it");
    }

    /// @notice A far more aggressive decay reaches zero in under a minute.
    /// @dev `0.5e18` is also a legal `decayFactor` — 50% per second, well inside the `< 1e18`
    ///      build-time check. It underflows to zero at `elapsed == 60`, so the unguarded
    ///      division at `DutchAuction.sol:97` is not an exotic long-duration corner: a
    ///      one-minute auction with a steep decay hits it. Cheaper to prove than the 4 097
    ///      witness too — six loop iterations instead of thirteen.
    function test_witness_decayReachesZeroInSixtySeconds() public view {
        assertEq(harness.pow(0.5e18, 59, ONE), 1, "one wei of decay left after 59s");
        assertEq(harness.pow(0.5e18, 60, ONE), 0, "zero decay after 60s");
    }

    /// @notice Once the decay is zero it stays zero — the failure is permanent, not a blip.
    /// @dev A direct corollary of `test_base_zeroBaseCollapsesToZero` composed with
    ///      `test_mono_nonIncreasingInExponent`, but worth pinning concretely: a maker whose
    ///      auction crosses the threshold cannot wait it out, and every subsequent second is
    ///      also a revert.
    function test_witness_decayStaysZeroAfterCollapse(uint8 extra) public view {
        assertEq(harness.pow(0.5e18, uint256(60) + extra, ONE), 0, "decay must not recover");
    }
}

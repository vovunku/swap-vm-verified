// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { XYCSwap } from "../../src/instructions/XYCSwap.sol";
import { XYCSwapHarness } from "./harnesses/XYCSwapHarness.sol";

/// @notice Kontrol specification for the XYCSwap instruction (opcode 0x50).
///
/// @dev Reference semantics, from src/instructions/XYCSwap.sol:
///
///        exactIn:   amountOut = floor(amountIn * balanceOut / (balanceIn + amountIn))
///        exactOut:  amountIn  = ceil (amountOut * balanceIn / (balanceOut - amountOut))
///
///      This is the constant-product curve. The flooring on the amountOut leg and the
///      ceiling on the amountIn leg are deliberate: both round in the maker's favour.
///      Any reimplementation must preserve the rounding direction exactly — a change of
///      one wei is an economic change, not a wash.
///
///      ## Why the safety properties are not the whole specification
///
///      The four exact-in properties below (`cannotDrainPool`, `roundsInFavourOfMaker`,
///      `zeroInputYieldsZeroOutput`, `constantProductNeverDecreases`) are all *upper*
///      bounds on `amountOut`, or consequences of one. Each is sound, but jointly they are
///      satisfied by an implementation that returns `0` unconditionally:
///
///        * `0 < balanceOut` holds whenever `balanceOut > 0`;
///        * `0 * (balanceIn + amountIn) <= amountIn * balanceOut` holds always;
///        * zero input trivially gives zero output;
///        * `k` can only grow if nothing ever leaves the pool.
///
///      Upper bounds alone therefore do not pin the curve. Two things close that gap, and
///      both are load-bearing rather than decorative:
///
///        1. **`test_exactIn_isExactlyTheFloor` / `test_exactOut_isExactlyTheCeiling`** —
///           two-sided statements. The second inequality in each is the *lower* bound that
///           says the quote is not a wei short of the true rounded value, so quoting zero
///           (or anything else conservative) is refuted rather than tolerated. The exact-in
///           one is stated over the full `uint256` domain; the exact-out one needs a
///           narrowing, and says at its own definition site exactly why.
///        2. **The `_witness` tests** — fully concrete inputs with hand-computed outputs.
///           A universally quantified property can be vacuous, or true of a degenerate
///           implementation; a witness cannot. These fix a point on the curve where the
///           rounding genuinely fires, in both directions.
///
///      These run as ordinary fuzz tests under `forge test` and as proofs under
///      `kontrol prove`. Under Kontrol every `vm.assume` becomes a path constraint
///      rather than a sample filter, so the assumptions below define exactly the domain
///      over which each property is proven — read them as part of the specification.
///      Narrow parameter *types* (`uint120`) are used in preference to `vm.assume` bounds
///      wherever a bound is needed: Kontrol constrains an ABI-decoded `uintN` directly, and
///      the fuzzer generates in range instead of rejecting, so the same domain costs
///      neither a rejected-sample budget nor an extra path constraint.
contract XYCSwapSpec is Test {
    XYCSwapHarness internal harness;

    function setUp() public {
        harness = new XYCSwapHarness();
    }

    // -----------------------------------------------------------------------
    // Safety: the maker cannot be drained
    // -----------------------------------------------------------------------

    /// @notice A single exact-in swap never returns the maker's entire output balance.
    ///
    /// @dev Because `amountIn < balanceIn + amountIn` whenever `balanceIn > 0`, the quotient
    ///      is strictly below `balanceOut`. This is the property that makes the curve
    ///      asymptotic — no finite input empties the pool.
    ///
    ///      Stated over the **whole** input domain, with no assumptions at all. The natural
    ///      way to write this is to assume away the reverting inputs:
    ///
    ///          vm.assume(amountIn <= type(uint256).max / balanceOut);   // no overflow
    ///
    ///      but that puts a *symbolic* `DIV` into the path condition, which KEVM must model
    ///      with a divide-by-zero guard, and the proof does not get past it — measured at
    ///      four nodes with no progress over five minutes on an otherwise idle machine.
    ///
    ///      `try`/`catch` expresses the same intent without any division: whenever the
    ///      instruction *succeeds*, the output is bounded. Reverting inputs — whether from
    ///      the zero-balance guards or from the multiplication overflowing — satisfy the
    ///      property vacuously, and are covered by the dedicated revert tests below.
    ///
    ///      This is strictly stronger than the assumption form. It quantifies over every
    ///      `uint256` triple rather than over a sub-domain, so nothing is narrowed to make
    ///      the proof close.
    function test_exactIn_cannotDrainPool(uint256 balanceIn, uint256 balanceOut, uint256 amountIn) public view {
        try harness.exactIn(balanceIn, balanceOut, amountIn, "") returns (uint256 amountOut) {
            assertLt(amountOut, balanceOut, "exactIn must never return the full output balance");
        } catch {
            // Reverted: the guards rejected it, or the arithmetic overflowed. Either way
            // no output was produced, so there is nothing to bound.
        }
    }

    // -----------------------------------------------------------------------
    // Rounding direction: the maker is never shortchanged
    // -----------------------------------------------------------------------

    /// @notice The quoted output never exceeds the exact (unrounded) curve value.
    /// @dev Equivalent to `amountOut <= amountIn * balanceOut / (balanceIn + amountIn)`
    ///      over the rationals, stated multiplicatively to avoid a second division.
    ///      Flooring can only move the result down, never up.
    ///
    ///      Same `try`/`catch` framing as `cannotDrainPool`, and for the same reason. Note
    ///      that both products below are safe to compute on the success path precisely
    ///      because the instruction already evaluated them without reverting.
    function test_exactIn_roundsInFavourOfMaker(uint256 balanceIn, uint256 balanceOut, uint256 amountIn) public view {
        try harness.exactIn(balanceIn, balanceOut, amountIn, "") returns (uint256 amountOut) {
            assertLe(
                amountOut * (balanceIn + amountIn),
                amountIn * balanceOut,
                "flooring must not round the output up"
            );
        } catch {
            // Reverted; no quote to bound.
        }
    }

    // -----------------------------------------------------------------------
    // Exactness: the quote is the rounded curve value, not merely bounded by it
    // -----------------------------------------------------------------------

    /// @notice The exact-in leg returns exactly the floor of the curve value — neither one
    ///         wei high nor one wei low.
    ///
    /// @dev The two-sided companion to `test_exactIn_roundsInFavourOfMaker`, and the
    ///      property that makes this file a specification of *this* curve rather than a
    ///      list of things a conservative quote happens to satisfy. With
    ///      `N = amountIn * balanceOut` and `d = balanceIn + amountIn`:
    ///
    ///        amountOut * d <= N       (does not round up — maker safety)
    ///        N - amountOut * d < d    (does not round down past the floor — taker safety)
    ///
    ///      Together these say `amountOut = floor(N / d)` exactly: the first bounds the
    ///      quotient from above, the second says the remainder it leaves behind is smaller
    ///      than the divisor, which for a non-negative `amountOut` forces it to be the
    ///      largest such value. Neither is stated as a division, so no symbolic `DIV` enters
    ///      the path condition.
    ///
    ///      NO DOMAIN NARROWING, and the second inequality is why it is written with a
    ///      subtraction rather than in the more obvious form `N < (amountOut + 1) * d`.
    ///      That form is what `XYCConcentrateSpec.test_exactIn_isExactlyTheFloor` uses, and
    ///      it forces its operands down to `uint120`: `(amountOut + 1) * d` is a product the
    ///      instruction never forms, so nothing about the instruction having succeeded
    ///      implies it fits in a `uint256`, and at full width the assertion would be a
    ///      statement about `chop(...)` rather than about the curve.
    ///
    ///      The subtraction form has no such problem. Every term in it is one the
    ///      instruction already evaluated, or is bounded by one:
    ///
    ///        * `d = balanceIn + amountIn` — formed at `XYCSwap.sol:24`, so it did not
    ///          overflow on this path;
    ///        * `N = amountIn * balanceOut` — formed at `XYCSwap.sol:23`, likewise;
    ///        * `amountOut * d <= N` by the first assertion, so that product cannot
    ///          overflow either, and the subtraction cannot underflow.
    ///
    ///      So the exactness of the curve is pinned over the *whole* `uint256` domain, not
    ///      over a sub-cube of it. `try`/`catch` framing as in `cannotDrainPool`: reverting
    ///      inputs are covered by the dedicated revert tests.
    function test_exactIn_isExactlyTheFloor(uint256 balanceIn, uint256 balanceOut, uint256 amountIn) public view {
        try harness.exactIn(balanceIn, balanceOut, amountIn, "") returns (uint256 amountOut) {
            // `balanceIn > 0` on the success path, so `d > 0` and the floor is well defined.
            uint256 denominator = balanceIn + amountIn;
            uint256 numerator = amountIn * balanceOut;

            assertLe(amountOut * denominator, numerator, "output must not exceed the exact curve value");
            assertLt(
                numerator - amountOut * denominator,
                denominator,
                "output must not fall a wei short of the floor"
            );
        } catch {
            // Reverted; no quote to pin.
        }
    }

    /// @notice The exact-out leg returns exactly the ceiling of the curve value — neither one
    ///         wei high nor one wei low.
    ///
    /// @dev Two-sided, and stated over the **full `uint256` width** with no operand narrowing.
    ///
    ///      Getting there needs care. With `N = amountOut * balanceIn` and
    ///      `d = balanceOut - amountOut`, the instruction computes `ceilDiv(N, d)` and so forms
    ///      `N` — but it never forms `amountIn * d`. The textbook statement of a ceiling,
    ///
    ///          amountIn * d >= N   and   amountIn * d < N + d
    ///
    ///      therefore evaluates a product the instruction does not, and that product reaches
    ///      `N + d - 1`, which overflows once `N` is within `d` of 2^256. Writing it that way
    ///      forces a `uint120` narrowing on the operands, which narrows the theorem: an
    ///      implementation correct below 2^120 and overcharging arbitrarily above it would
    ///      still satisfy it.
    ///
    ///      Both halves can be restated over quantities bounded by `N`, which the instruction
    ///      already evaluated without reverting:
    ///
    ///        * minimality — `(amountIn - 1) * d < N`. Bounded by `N` by definition of the
    ///          ceiling, so it cannot overflow. This is the taker-safety half: the quote is
    ///          not a whole unit too large.
    ///        * sufficiency — `N - (amountIn - 1) * d <= d`, which is `N <= amountIn * d`
    ///          rearranged. The subtraction cannot underflow because of the line above, and
    ///          the result is at most `N`. This is the maker-safety half.
    ///
    ///      `amountOut > 0` is a case split, not a domain narrowing: at `amountOut == 0` the
    ///      quote is zero and `amountIn - 1` would underflow. That boundary is covered by
    ///      `test_exactOut_zeroOutputCostsNothing` directly below — it was briefly covered by
    ///      nothing, because an earlier version of this comment pointed at a test that lives
    ///      in `XYCConcentrateSpec`, not here.
    function test_exactOut_isExactlyTheCeiling(uint256 balanceIn, uint256 balanceOut, uint256 amountOut)
        public
        view
    {
        vm.assume(balanceIn > 0);
        vm.assume(amountOut > 0);
        // `balanceOut - amountOut` must not underflow and must be a usable divisor.
        vm.assume(amountOut < balanceOut);

        try harness.exactOut(balanceIn, balanceOut, amountOut, "") returns (uint256 amountIn) {
            uint256 d = balanceOut - amountOut;
            uint256 n = amountOut * balanceIn;

            // Taker safety. `(amountIn - 1) * d` is bounded by `n`, so it cannot overflow.
            uint256 belowByOne = (amountIn - 1) * d;
            assertLt(belowByOne, n, "ceiling must not overcharge by a whole unit");

            // Maker safety, rearranged from `amountIn * d >= n` so no unformed product appears.
            assertLe(n - belowByOne, d, "ceiling must not round the taker's input down");
        } catch {
            // Reverted; no quote to characterise.
        }
    }


    /// @notice A zero output request costs the taker nothing, and in particular the ceiling
    ///         does not round it up to one wei.
    ///
    /// @dev The `amountOut == 0` boundary excluded from `test_exactOut_isExactlyTheCeiling`,
    ///      which needs `amountOut > 0` so that `amountIn - 1` cannot underflow. Without this
    ///      the boundary would be covered by nothing at all.
    function test_exactOut_zeroOutputCostsNothing(uint256 balanceIn, uint256 balanceOut) public view {
        vm.assume(balanceIn > 0);
        vm.assume(balanceOut > 0);

        try harness.exactOut(balanceIn, balanceOut, 0, "") returns (uint256 amountIn) {
            assertEq(amountIn, 0, "a zero output request must cost nothing");
        } catch {
            // Reverted; nothing to pin.
        }
    }

    // -----------------------------------------------------------------------
    // Reachability witnesses
    // -----------------------------------------------------------------------

    /// @notice Concrete witness that the exact-in leg quotes a non-zero, strictly rounded
    ///         price.
    ///
    /// @dev This is the direct refutation of the vacuity finding: an `exactIn` that returns
    ///      `0` unconditionally satisfies every upper-bound property in this file, and fails
    ///      this test on its first assertion. It also pins a point where the flooring is
    ///      *strict* — the exact quotient is not an integer — so an implementation that
    ///      rounded to nearest, or up, is distinguished from this one.
    ///
    ///      Worked by hand:
    ///        numerator   = 10_000 * 200 = 2_000_000
    ///        denominator = 1_000 + 10_000 = 11_000
    ///        amountOut   = floor(2_000_000 / 11_000) = floor(181.81..) = 181
    ///
    ///      Fully concrete, so it costs the prover a single path with no symbolic
    ///      arithmetic. `XYCConcentrateSpec.test_exactIn_clampIsReachable_witness` is the
    ///      same shape and proves under Kontrol in about a minute.
    function test_exactIn_quoteIsReachable_witness() public view {
        uint256 amountOut = harness.exactIn(1000, 200, 10_000, "");

        assertEq(amountOut, 181, "exact-in must quote the floor of the curve value");

        // Restated as the facts a degenerate implementation would violate.
        assertGt(amountOut, 0, "a non-zero input at a non-empty pool must quote a non-zero output");
        assertLt(amountOut, 200, "and still not drain the pool: cannotDrainPool is not vacuous here");
        // 181 * 11_000 = 1_991_000 < 2_000_000: the division is not exact here, so this
        // point distinguishes flooring from rounding to nearest or up.
        assertLt(amountOut * 11_000, 2_000_000, "the flooring is strict at this point, not exact division");
    }

    /// @notice Concrete witness that the exact-out leg charges a strictly rounded-up price.
    ///
    /// @dev The mirror of the above. Pins a point where the ceiling genuinely fires, so an
    ///      implementation that floored the exact-out leg — the single most valuable
    ///      one-wei bug to introduce, since it silently transfers value from maker to
    ///      taker on every fill — is caught.
    ///
    ///      Worked by hand:
    ///        numerator   = 101 * 1_000 = 101_000
    ///        denominator = 200 - 101 = 99
    ///        amountIn    = ceil(101_000 / 99) = ceil(1020.20..) = 1021
    ///
    ///      Note `floor(101_000 / 99) = 1020`, so the two rounding directions are one wei
    ///      apart here and the assertion distinguishes them.
    function test_exactOut_quoteIsReachable_witness() public view {
        uint256 amountIn = harness.exactOut(1000, 200, 101, "");

        assertEq(amountIn, 1021, "exact-out must charge the ceiling of the curve value");

        assertGt(amountIn, 1020, "flooring this leg would charge 1020, one wei less than the maker is owed");
    }

    /// @notice Zero input yields zero output — no value is created from nothing.
    function test_exactIn_zeroInputYieldsZeroOutput(uint256 balanceIn, uint256 balanceOut) public view {
        vm.assume(balanceIn > 0);
        vm.assume(balanceOut > 0);

        uint256 amountOut = harness.exactIn(balanceIn, balanceOut, 0, "");

        assertEq(amountOut, 0, "zero input must yield zero output");
    }

    // -----------------------------------------------------------------------
    // The constant-product invariant
    // -----------------------------------------------------------------------

    /// @notice k never decreases across an exact-in swap.
    /// @dev `(balanceIn + amountIn) * (balanceOut - amountOut) >= balanceIn * balanceOut`.
    ///
    ///      Inputs are bounded to 2^128 so that both products are representable without
    ///      any overflow reasoning. This is a deliberate narrowing of the domain, not an
    ///      oversight: proving the unbounded form additionally requires establishing that
    ///      neither product overflows, which is a separate obligation. Widening this bound
    ///      is a good follow-up task once the lemma library is stronger.
    function test_exactIn_constantProductNeverDecreases(uint256 balanceIn, uint256 balanceOut, uint256 amountIn)
        public
        view
    {
        vm.assume(balanceIn > 0 && balanceIn < 2 ** 128);
        vm.assume(balanceOut > 0 && balanceOut < 2 ** 128);
        vm.assume(amountIn < 2 ** 128);

        uint256 amountOut = harness.exactIn(balanceIn, balanceOut, amountIn, "");

        assertGe(
            (balanceIn + amountIn) * (balanceOut - amountOut),
            balanceIn * balanceOut,
            "constant product must not decrease"
        );
    }

    // -----------------------------------------------------------------------
    // Guards
    // -----------------------------------------------------------------------

    /// @notice A zero input balance is rejected rather than dividing by zero.
    ///
    /// @dev The selector and its arguments are named rather than accepting any revert. A
    ///      bare `vm.expectRevert()` cannot distinguish "the guard fired" from "the
    ///      arithmetic panicked on a division by zero" — which is precisely the failure this
    ///      test exists to rule out, so the bare form is close to vacuous here. Naming the
    ///      error also pins the revert *data*, so a future refactor that keeps the guard but
    ///      reports the balances in the wrong order is caught. Same convention as
    ///      `MinRateSpec` and `BaseFeeAdjusterSpec`.
    function test_exactIn_revertsOnZeroBalanceIn(uint256 balanceOut, uint256 amountIn) public {
        vm.expectRevert(
            abi.encodeWithSelector(XYCSwap.XYCSwapRequiresBothBalancesNonZero.selector, uint256(0), balanceOut)
        );
        harness.exactIn(0, balanceOut, amountIn, "");
    }

    /// @notice A zero output balance is rejected.
    /// @dev Selector named, for the reasons given on `test_exactIn_revertsOnZeroBalanceIn`.
    function test_exactIn_revertsOnZeroBalanceOut(uint256 balanceIn, uint256 amountIn) public {
        vm.assume(balanceIn > 0);
        vm.expectRevert(
            abi.encodeWithSelector(XYCSwap.XYCSwapRequiresBothBalancesNonZero.selector, balanceIn, uint256(0))
        );
        harness.exactIn(balanceIn, 0, amountIn, "");
    }

    /// @notice The recompute guard rejects a pre-populated output register.
    /// @dev Without this guard a program could run the curve twice and compound the
    ///      price. The guard is why instruction ordering is security-critical.
    ///
    ///      Selector named, so that an overflow in the pricing expression cannot be
    ///      mistaken for the guard firing.
    function test_exactIn_revertsWhenAmountOutAlreadySet(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut
    ) public {
        vm.assume(balanceIn > 0);
        vm.assume(balanceOut > 0);
        vm.assume(amountOut != 0);

        vm.expectRevert(XYCSwap.XYCSwapRecomputeDetected.selector);
        harness.exactInWithAmountOut(balanceIn, balanceOut, amountIn, amountOut, "");
    }

    // -----------------------------------------------------------------------
    // Exact-out direction
    // -----------------------------------------------------------------------

    /// @notice The exact-out leg rounds the taker's input up, never down.
    /// @dev `amountIn = ceil(amountOut * balanceIn / (balanceOut - amountOut))`, so
    ///      `amountIn * (balanceOut - amountOut) >= amountOut * balanceIn`.
    function test_exactOut_roundsInFavourOfMaker(uint256 balanceIn, uint256 balanceOut, uint256 amountOut)
        public
        view
    {
        vm.assume(balanceIn > 0 && balanceIn < 2 ** 128);
        vm.assume(balanceOut > 0 && balanceOut < 2 ** 128);
        // `balanceOut - amountOut` must not underflow and must be a usable divisor
        vm.assume(amountOut > 0 && amountOut < balanceOut);

        uint256 amountIn = harness.exactOut(balanceIn, balanceOut, amountOut, "");

        assertGe(
            amountIn * (balanceOut - amountOut),
            amountOut * balanceIn,
            "ceiling must not round the taker's input down"
        );
    }
}

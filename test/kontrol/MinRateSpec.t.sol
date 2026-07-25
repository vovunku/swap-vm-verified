// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { MinRateHarness } from "./harnesses/MinRateHarness.sol";

/// @notice Kontrol specification for the MinRate instructions (opcodes 0x55, 0x56).
///
/// @dev Reference semantics, from src/instructions/MinRate.sol:
///
///        _requireMinRate1D:  revert unless  swapAmountIn * rateOut >= rateIn * swapAmountOut
///        _adjustMinRate1D :  if swapAmountIn * rateOut <  rateIn * swapAmountOut, clamp:
///                              exact-in :  amountOut = amountIn * rateOut / rateIn       (floor)
///                              exact-out:  amountIn  = ceil(amountOut * rateIn / rateOut)
///
///      The comparison is the cross-product form of `swapAmountIn / swapAmountOut >= rateIn /
///      rateOut`, avoiding a second division. Flooring on the exact-in leg and ceiling on the
///      exact-out leg both round in the maker's favour: a reimplementation that flipped a
///      rounding direction would silently underpay the maker by up to one unit of the divisor.
///
///      `rateIn` / `rateOut` are NOT taken positionally from `args`. `MinRateArgsBuilder.parse`
///      routes them by token address: `(rateIn, rateOut) = tokenIn < tokenOut ?
///      (rateLt, rateGt) : (rateGt, rateLt)`. A taker cannot reinterpret a buy as a sell by
///      swapping the token arguments, because the maker signed the rates against token
///      ordering. This is the vulnerability class flagged in
///      `.cursor/rules/security-review.mdc` and is proven explicitly below.
///
/// @dev Harness caveat. Both entrypoints call `ctx.runLoop()`, which dispatches through the
///      internal function pointer `ctx.vm.dispatch` — the pattern the WORKPLAN classifies as
///      a separate, unscheduled project. The harness installs a stub dispatcher that fills
///      the missing swap register with a caller-chosen value, so the properties below
///      verify MinRate's rate logic conditional on `runLoop` returning that value. They do
///      not verify the run loop or any real pricing instruction. See MinRateHarness.sol.
///
/// @dev Overflow bounds. Every `vm.assume` becomes a path constraint under Kontrol, so each
///      one is SMT work. The products `amountIn * rateGt` and `computedAmountOut * rateLt`
///      are guarded against overflow not by the division-shaped `amount <= max / rate`
///      (which forces the solver to reason about symbolic division and was the dominant
///      stall in early runs) but by bounding each operand to 128 bits: `2^128 * 2^64 =
///      2^192`, comfortably below `maxUInt256`. This is a deliberate narrowing of the domain
///      — the unbounded form is a follow-up once the lemma library has a division-simplification
///      rule.
contract MinRateSpec is Test {
    MinRateHarness internal harness;

    /// @dev Distinct token addresses with a fixed ordering, so the direction-routing tests
    ///      can pin which rate lands in which slot without branching on arbitrary addresses.
    address internal constant TOKEN_LO = address(0x1111);
    address internal constant TOKEN_HI = address(0x2222);

    /// @dev The one-opcode program that drives the stub dispatcher exactly once. Passed
    ///      through calldata so the `CalldataPtr` references the current call frame.
    bytes internal constant STUB_PROGRAM = hex"0000";

    /// @dev 2^128. With uint64 rates, products are at most 2^(128+64) = 2^192 < maxUInt256.
    uint256 internal constant BOUND = 2 ** 128;

    function setUp() public {
        harness = new MinRateHarness();
    }

    /// @dev Packs `(rateLt, rateGt)` the way `MinRateArgsBuilder.build` does.
    function _args(uint64 rateLt, uint64 rateGt) internal pure returns (bytes memory) {
        return abi.encodePacked(rateLt, rateGt);
    }

    /// @dev Domain common to every rate-check property: positive rates, positive amounts
    ///      bounded to 128 bits so the cross-products cannot overflow.
    function _assumeDomain(uint256 amountIn, uint256 amountOut, uint64 rateLt, uint64 rateGt)
        internal
        pure
    {
        vm.assume(rateLt > 0 && rateGt > 0);
        vm.assume(amountIn > 0 && amountIn < BOUND);
        vm.assume(amountOut > 0 && amountOut < BOUND);
    }

    // -----------------------------------------------------------------------
    // Argument routing: rateLt / rateGt are selected by token ordering
    // -----------------------------------------------------------------------

    /// @notice Swapping the token arguments swaps which rate lands in `rateIn` vs `rateOut`.
    /// @dev This is the security-critical property: the maker signs rates against token
    ///      ordering, so a taker cannot flip a buy into a sell by reordering the token
    ///      parameters. A one-sided test ("tokenIn < tokenOut gives rateIn = rateLt") would
    ///      pass even if the routing were positional; this test fails in that case.
    function test_parse_directionDependence(uint64 rateLt, uint64 rateGt) public view {
        bytes memory args = _args(rateLt, rateGt);

        (uint64 rateIn, uint64 rateOut) = harness.parse(args, TOKEN_LO, TOKEN_HI);
        assertEq(rateIn, rateLt, "tokenIn < tokenOut: rateIn must be rateLt");
        assertEq(rateOut, rateGt, "tokenIn < tokenOut: rateOut must be rateGt");

        (rateIn, rateOut) = harness.parse(args, TOKEN_HI, TOKEN_LO);
        assertEq(rateIn, rateGt, "tokenIn > tokenOut: rateIn must be rateGt");
        assertEq(rateOut, rateLt, "tokenIn > tokenOut: rateOut must be rateLt");
    }

    /// @notice `build` then `parse` round-trips the rates, for either token ordering.
    function test_parse_buildRoundtrip(address tokenA, address tokenB, uint64 rateA, uint64 rateB)
        public
        view
    {
        vm.assume(tokenA != tokenB);

        bytes memory args = harness.build(tokenA, tokenB, rateA, rateB);

        (uint64 rateIn, uint64 rateOut) = harness.parse(args, tokenA, tokenB);
        // build places rateA on tokenA and rateB on tokenB; parse reads them back in the
        // same token order, so rateIn is whichever rate was attached to tokenA.
        assertEq(rateIn, rateA, "roundtrip: rateIn must be the rate placed on tokenA");
        assertEq(rateOut, rateB, "roundtrip: rateOut must be the rate placed on tokenB");
    }

    // -----------------------------------------------------------------------
    // _requireMinRate1D — the boundary: rejects strictly below, accepts at the floor
    // -----------------------------------------------------------------------

    /// @notice A swap whose rate is strictly below the floor is rejected.
    /// @dev With TOKEN_LO < TOKEN_HI, `rateIn = rateLt` and `rateOut = rateGt`. Exact-in
    ///      fills `amountOut = computedAmountOut`, so the check becomes
    ///      `amountIn * rateGt >= rateLt * computedAmountOut`. Below-floor means the strict
    ///      inequality fails.
    function test_require_revertsBelowFloor(
        uint256 amountIn,
        uint256 computedAmountOut,
        uint64 rateLt,
        uint64 rateGt
    ) public {
        _assumeDomain(amountIn, computedAmountOut, rateLt, rateGt);
        // The swap rate is strictly below the floor.
        vm.assume(amountIn * rateGt < rateLt * computedAmountOut);

        vm.expectRevert();
        harness.requireMinRateExactIn(
            amountIn, computedAmountOut, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), STUB_PROGRAM
        );
    }

    /// @notice A swap whose rate equals the floor is accepted — the boundary is inclusive.
    /// @dev The WORKPLAN calls this out specifically: prove behaviour *at* equality, not
    ///      just either side. `ceilDiv` / floor asymmetry would hide at the boundary.
    function test_require_acceptsAtFloor(uint256 amountIn, uint64 rateLt, uint64 rateGt) public {
        vm.assume(rateLt > 0 && rateGt > 0);
        vm.assume(amountIn > 0 && amountIn < BOUND);
        // Pick computedAmountOut so the rate is exactly at the floor:
        //   amountIn * rateGt == rateLt * computedAmountOut.
        uint256 computedAmountOut = (uint256(amountIn) * rateGt) / rateLt;
        vm.assume(computedAmountOut > 0 && computedAmountOut < BOUND);

        // No vm.expectRevert: the call must succeed.
        harness.requireMinRateExactIn(
            amountIn, computedAmountOut, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), STUB_PROGRAM
        );
    }

    /// @notice A swap whose rate is strictly above the floor is accepted.
    function test_require_acceptsAboveFloor(
        uint256 amountIn,
        uint256 computedAmountOut,
        uint64 rateLt,
        uint64 rateGt
    ) public {
        _assumeDomain(amountIn, computedAmountOut, rateLt, rateGt);
        // The swap rate is strictly above the floor.
        vm.assume(amountIn * rateGt > rateLt * computedAmountOut);

        harness.requireMinRateExactIn(
            amountIn, computedAmountOut, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), STUB_PROGRAM
        );
    }

    // -----------------------------------------------------------------------
    // _requireMinRate1D — the direction guard works symmetrically
    // -----------------------------------------------------------------------

    /// @notice The same below-floor swap is rejected when the tokens are presented in the
    ///         opposite order, with the rates swapped to match. This pins that the guard
    ///         behaves identically after `parse` reroutes the rates.
    /// @dev With TOKEN_HI as tokenIn (> TOKEN_LO), parse assigns rateIn = rateGt, rateOut =
    ///      rateLt. Feeding the same rateLt/rateGt pair therefore reproduces the mirror image
    ///      of `test_require_revertsBelowFloor`.
    function test_require_revertsBelowFloorSwappedTokens(
        uint256 amountIn,
        uint256 computedAmountOut,
        uint64 rateLt,
        uint64 rateGt
    ) public {
        _assumeDomain(amountIn, computedAmountOut, rateLt, rateGt);
        // Below-floor after the swap: amountIn * rateLt < rateGt * computedAmountOut.
        vm.assume(amountIn * rateLt < rateGt * computedAmountOut);

        vm.expectRevert();
        harness.requireMinRateExactIn(
            amountIn, computedAmountOut, TOKEN_HI, TOKEN_LO, _args(rateLt, rateGt), STUB_PROGRAM
        );
    }

    // -----------------------------------------------------------------------
    // _requireMinRate1D — precondition guard
    // -----------------------------------------------------------------------

    /// @notice The instruction refuses to run if both swap amounts are already populated,
    ///         because the rate check is only meaningful before the swap is computed.
    function test_require_revertsWhenBothAmountsAlreadySet(uint256 amountIn, uint256 amountOut)
        public
    {
        vm.assume(amountIn > 0 && amountOut > 0);

        vm.expectRevert();
        harness.requireMinRateBothSet(
            amountIn, amountOut, TOKEN_LO, TOKEN_HI, _args(1, 1), STUB_PROGRAM
        );
    }

    // -----------------------------------------------------------------------
    // _adjustMinRate1D — exact-in: no-op when the rate already conforms
    // -----------------------------------------------------------------------

    /// @notice When the swap rate is at or above the floor, the adjustment is a no-op:
    ///         `amountOut` is left exactly as the swap program produced it.
    function test_adjustExactIn_noOpWhenConforming(
        uint256 amountIn,
        uint256 computedAmountOut,
        uint64 rateLt,
        uint64 rateGt
    ) public {
        _assumeDomain(amountIn, computedAmountOut, rateLt, rateGt);
        // Rate conforms: at or above the floor.
        vm.assume(amountIn * rateGt >= rateLt * computedAmountOut);

        uint256 result = harness.adjustMinRateExactIn(
            amountIn, computedAmountOut, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), STUB_PROGRAM
        );

        assertEq(result, computedAmountOut, "conforming rate must not be adjusted");
    }

    // -----------------------------------------------------------------------
    // _adjustMinRate1D — exact-in: clamps below-floor rates
    // -----------------------------------------------------------------------

    /// @notice When the swap rate is below the floor, `amountOut` is clamped down to
    ///         `amountIn * rateGt / rateLt`, the largest output that just satisfies the floor.
    function test_adjustExactIn_clampsBelowFloor(
        uint256 amountIn,
        uint256 computedAmountOut,
        uint64 rateLt,
        uint64 rateGt
    ) public {
        _assumeDomain(amountIn, computedAmountOut, rateLt, rateGt);
        // Rate below the floor.
        vm.assume(amountIn * rateGt < rateLt * computedAmountOut);

        uint256 result = harness.adjustMinRateExactIn(
            amountIn, computedAmountOut, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), STUB_PROGRAM
        );

        assertEq(result, (uint256(amountIn) * rateGt) / rateLt, "must clamp to the floor rate");
    }

    /// @notice After clamping, the adjusted amounts satisfy the floor — the maker is not
    ///         shortchanged even at the boundary. This is the `div-mul-le` lemma in action:
    ///         `rateLt * floor(amountIn * rateGt / rateLt) <= amountIn * rateGt`.
    function test_adjustExactIn_adjustedSatisfiesFloor(
        uint256 amountIn,
        uint256 computedAmountOut,
        uint64 rateLt,
        uint64 rateGt
    ) public {
        _assumeDomain(amountIn, computedAmountOut, rateLt, rateGt);
        vm.assume(amountIn * rateGt < rateLt * computedAmountOut);

        uint256 result = harness.adjustMinRateExactIn(
            amountIn, computedAmountOut, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), STUB_PROGRAM
        );

        // amountIn * rateGt >= rateLt * result  <=>  the adjusted rate is at or above floor.
        assertGe(
            uint256(amountIn) * rateGt,
            uint256(rateLt) * result,
            "adjusted rate must satisfy the floor"
        );
    }

    // -----------------------------------------------------------------------
    // _adjustMinRate1D — exact-out: no-op when conforming, clamp otherwise
    // -----------------------------------------------------------------------

    /// @notice Exact-out mirror of the no-op property.
    function test_adjustExactOut_noOpWhenConforming(
        uint256 amountOut,
        uint256 computedAmountIn,
        uint64 rateLt,
        uint64 rateGt
    ) public {
        _assumeDomain(computedAmountIn, amountOut, rateLt, rateGt);
        // Rate conforms: computedAmountIn * rateGt >= rateLt * amountOut.
        vm.assume(computedAmountIn * rateGt >= rateLt * amountOut);

        uint256 result = harness.adjustMinRateExactOut(
            amountOut, computedAmountIn, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), STUB_PROGRAM
        );

        assertEq(result, computedAmountIn, "conforming rate must not be adjusted");
    }

    /// @notice Exact-out mirror of the clamp: `amountIn` is clamped up to
    ///         `ceil(amountOut * rateLt / rateGt)`, the smallest input that satisfies the floor.
    function test_adjustExactOut_clampsBelowFloor(
        uint256 amountOut,
        uint256 computedAmountIn,
        uint64 rateLt,
        uint64 rateGt
    ) public {
        _assumeDomain(computedAmountIn, amountOut, rateLt, rateGt);
        // Rate below the floor.
        vm.assume(computedAmountIn * rateGt < rateLt * amountOut);

        uint256 result = harness.adjustMinRateExactOut(
            amountOut, computedAmountIn, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), STUB_PROGRAM
        );

        // ceilDiv from OpenZeppelin's Math: (a + d - 1) / d for d > 0.
        uint256 expected = (uint256(amountOut) * rateLt + rateGt - 1) / rateGt;
        assertEq(result, expected, "must clamp up to the floor rate");
    }

    /// @notice After clamping, the adjusted amounts satisfy the floor. Ceiling can only
    ///         move the input up, so `result * rateGt >= rateLt * amountOut` holds.
    function test_adjustExactOut_adjustedSatisfiesFloor(
        uint256 amountOut,
        uint256 computedAmountIn,
        uint64 rateLt,
        uint64 rateGt
    ) public {
        _assumeDomain(computedAmountIn, amountOut, rateLt, rateGt);
        vm.assume(computedAmountIn * rateGt < rateLt * amountOut);

        uint256 result = harness.adjustMinRateExactOut(
            amountOut, computedAmountIn, TOKEN_LO, TOKEN_HI, _args(rateLt, rateGt), STUB_PROGRAM
        );

        assertGe(
            uint256(result) * rateGt,
            uint256(rateLt) * amountOut,
            "adjusted rate must satisfy the floor"
        );
    }
}

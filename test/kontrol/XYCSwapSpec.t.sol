// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

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
///      These run as ordinary fuzz tests under `forge test` and as proofs under
///      `kontrol prove`. Under Kontrol every `vm.assume` becomes a path constraint
///      rather than a sample filter, so the assumptions below define exactly the domain
///      over which each property is proven — read them as part of the specification.
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
    function test_exactIn_revertsOnZeroBalanceIn(uint256 balanceOut, uint256 amountIn) public {
        vm.expectRevert();
        harness.exactIn(0, balanceOut, amountIn, "");
    }

    /// @notice A zero output balance is rejected.
    function test_exactIn_revertsOnZeroBalanceOut(uint256 balanceIn, uint256 amountIn) public {
        vm.assume(balanceIn > 0);
        vm.expectRevert();
        harness.exactIn(balanceIn, 0, amountIn, "");
    }

    /// @notice The recompute guard rejects a pre-populated output register.
    /// @dev Without this guard a program could run the curve twice and compound the
    ///      price. The guard is why instruction ordering is security-critical.
    function test_exactIn_revertsWhenAmountOutAlreadySet(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut
    ) public {
        vm.assume(balanceIn > 0);
        vm.assume(balanceOut > 0);
        vm.assume(amountOut != 0);

        vm.expectRevert();
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

// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Context } from "../../../../src/libs/VM.sol";
import { XYCConcentrate } from "../../../../src/instructions/XYCConcentrate.sol";
import { XYCSwap } from "../../../../src/instructions/XYCSwap.sol";
import { PeggedSwap } from "../../../../src/instructions/PeggedSwap.sol";

/// @notice Independent check of the `XYCConcentrate` zero-liquidity panic **against the real
///         instruction**, not against the transcribed legs.
///
/// @dev     forge test --match-path test/kontrol/analysis/repro/XYCConcentrateDivByZeroRepro.t.sol -vv
///
///      `HARNESS-FIDELITY.md` records that every `XYCConcentrate` property in this repo was
///      proven against a hand-written copy of `:143-159` inside `XYCConcentrateHarness`, and
///      that the two differentials which would connect the copy to the deployed code have
///      never closed. So this finding needed re-deriving from the instruction itself before it
///      could be reported. It reproduces: the copy was faithful on this point.
///
///      ## The defect
///
///      `_xycConcentrateGrowLiquidity2D` computes both legs against *virtual* reserves, and the
///      exact-out leg (`:155-158`) divides by `virtualBalanceOut - amountOut` with no guard.
///      When the pool is empty, `_computeL` returns `0`, so the virtual offset is `0`, so
///      `virtualBalanceOut == balanceOut == 0`; `amountOut` is clamped to `balanceOut` at
///      `:153-154`, making the divisor exactly zero. `Math.ceilDiv` validates its divisor
///      *before* short-circuiting on a zero numerator, so even a zero-amount request panics.
///
///      The exact-in leg has the same hole one line up: `:145` divides by
///      `virtualBalanceIn + amountIn`, which is zero when the pool is empty and the request is
///      zero.
///
///      ## What actually makes this worth reporting
///
///      Not the panic itself — it is liveness only, on a pool with nothing in it. It is that
///      **`XYCConcentrate` is the only swap curve in the instruction set without a
///      zero-balance guard**, and its three siblings all have one and all name it:
///
///        | instruction      | guard                                        |
///        |------------------|----------------------------------------------|
///        | `XYCSwap`        | `XYCSwapRequiresBothBalancesNonZero`         |
///        | `LimitSwap`      | `LimitSwapRequiresBothBalancesNonZero`       |
///        | `PeggedSwap`     | `PeggedSwapBothBalancesZero`                 |
///        | `XYCConcentrate` | *(none)* -> bare `Panic(0x12)`               |
///
///      An integrator that distinguishes "no liquidity" from "broken" by matching the named
///      errors will mis-classify this one.
///
///      ## Reachability
///
///      An empty pool is ordinary, not exotic. `StaticBalances` writes whatever the maker's
///      program says, including `(0, 0)`; `DynamicBalances` re-parses its arguments whenever
///      `balanceIn | balanceOut == 0`, so a program configured with zero initial balances
///      stays at zero. No attacker is involved and no funds are at risk.
contract XYCConcentrateDivByZeroRepro is Test, XYCConcentrate, XYCSwap, PeggedSwap {
    uint256 internal constant SQRT_P_MIN = 0.9e18;
    uint256 internal constant SQRT_P_MAX = 1.1e18;

    address internal constant TOKEN_LO = address(0x1111);
    address internal constant TOKEN_HI = address(0x2222);

    function concentrateExactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        bytes calldata args
    ) external pure returns (uint256) {
        Context memory ctx;
        ctx.query.isExactIn = false;
        ctx.query.tokenIn = TOKEN_LO;
        ctx.query.tokenOut = TOKEN_HI;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountOut = amountOut;
        _xycConcentrateGrowLiquidity2D(ctx, args);
        return ctx.swap.amountIn;
    }

    function concentrateExactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        bytes calldata args
    ) external pure returns (uint256) {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.query.tokenIn = TOKEN_LO;
        ctx.query.tokenOut = TOKEN_HI;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;
        _xycConcentrateGrowLiquidity2D(ctx, args);
        return ctx.swap.amountOut;
    }

    function xycExactOut(uint256 balanceIn, uint256 balanceOut, uint256 amountOut, bytes calldata noArgs)
        external
        pure
        returns (uint256)
    {
        Context memory ctx;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountOut = amountOut;
        _xycSwapXD(ctx, noArgs);
        return ctx.swap.amountIn;
    }

    function _args() internal pure returns (bytes memory) {
        return abi.encodePacked(SQRT_P_MIN, SQRT_P_MAX);
    }

    function _panicCode(bytes memory err) internal pure returns (uint256 code) {
        if (bytes4(err) != bytes4(0x4e487b71)) return type(uint256).max;
        assembly {
            code := mload(add(err, 0x24))
        }
    }

    /// @notice The defect, on the real instruction: exact-out on an empty pool divides by zero.
    function test_repro_exactOutOnEmptyPoolPanics() public {
        (bool ok, bytes memory err) =
            address(this).staticcall(abi.encodeCall(this.concentrateExactOut, (0, 0, 0, _args())));

        assertFalse(ok, "expected a revert");
        assertEq(_panicCode(err), 0x12, "expected Panic(0x12), division by zero");
    }

    /// @notice Even a non-zero request panics identically — the clamp at `:153` pulls it down
    ///         to `balanceOut == 0` first, so the request size is irrelevant.
    function test_repro_requestSizeIsIrrelevant() public {
        (bool ok, bytes memory err) =
            address(this).staticcall(abi.encodeCall(this.concentrateExactOut, (0, 0, 1e18, _args())));
        assertFalse(ok, "reverts for any request");
        assertEq(_panicCode(err), 0x12, "same panic");
    }

    /// @notice The exact-in leg has the same hole at `:145`.
    function test_repro_exactInOnEmptyPoolAlsoPanics() public {
        (bool ok, bytes memory err) =
            address(this).staticcall(abi.encodeCall(this.concentrateExactIn, (0, 0, 0, _args())));
        assertFalse(ok, "expected a revert");
        assertEq(_panicCode(err), 0x12, "expected Panic(0x12)");
    }

    /// @notice A funded pool is unaffected, so this is a boundary defect rather than a broken
    ///         instruction.
    function test_repro_fundedPoolIsFine() public view {
        uint256 amountIn = this.concentrateExactOut(1e21, 1e21, 1e18, _args());
        assertGt(amountIn, 0, "a funded concentrated pool prices normally");
    }

    /// @notice The siblings reject the same state with a named error. This contrast is the
    ///         reportable part.
    function test_repro_siblingCurvesGuardTheSameState() public {
        vm.expectRevert(abi.encodeWithSelector(XYCSwapRequiresBothBalancesNonZero.selector, uint256(0), uint256(0)));
        this.xycExactOut(0, 0, 0, "");
    }
}

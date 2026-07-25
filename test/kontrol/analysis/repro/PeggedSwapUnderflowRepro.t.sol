// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Context } from "../../../../src/libs/VM.sol";
import { PeggedSwap } from "../../../../src/instructions/PeggedSwap.sol";

/// @notice Standalone reproducer for an unguarded `Panic(0x11)` in `PeggedSwap`.
///
/// @dev Self-contained: depends only on `src/`, not on the Kontrol harnesses, so it can be
///      dropped into a clean checkout and run with
///
///          forge test --match-path test/kontrol/analysis/repro/PeggedSwapUnderflowRepro.t.sol -vv
///
///      ## The defect
///
///      `PeggedSwap.sol:215` computes `Math.ceilDiv(x1 - x0, rateIn)` with a **checked**
///      subtraction, where `x1` is reconstructed from `x0` via
///
///          x0  ->  u = x0 * ONE / x0_init      (floor, PeggedSwapMath.sol:47)
///          u   ->  u' = solve(...)             (two floors, PeggedSwapMath.sol:100 and :103)
///          u'  ->  x1 = ceilDiv(u' * x0_init, ONE)
///
///      That round trip is not expansive. When `x0_init` is large relative to `ONE = 1e27`,
///      one `u`-ulp is worth `x0_init / ONE` wei of `x0`, which exceeds what the
///      reconstructing `ceilDiv` can add back — so `x1 < x0` is reachable and the checked
///      subtraction reverts.
///
///      The revert is a bare `Panic(0x11)`, not a named SwapVM error, so a caller cannot
///      distinguish it from any other arithmetic fault.
///
///      ## Exact arithmetic at the witness
///
///      With `x0_init = y0_init = 1e30`, `linearWidth = 0`, `rateLt = rateGt = 1`,
///      `balanceIn = 1e30 + 1`, `balanceOut = 1`, `amountOut = 1`, `tokenIn < tokenOut`:
///
///        | quantity                        | value                                  |
///        |---------------------------------|----------------------------------------|
///        | `x0 = balanceIn * rateIn`        | `1e30 + 1`                             |
///        | `u  = x0 * ONE / x0_init`        | `1e27`  <- the `+1` truncates away     |
///        | `v  = y0 * ONE / y0_init`        | `0`                                    |
///        | `C  = invariantFromReserves(..)` | `1e27`                                 |
///        | `y1 = y0 - amountOut * rateOut`  | `0`                                    |
///        | `v1`, `invariantV1`              | `0`, `0`                               |
///        | `rightSide = C - invariantV1`    | `1e27`                                 |
///        | `u' = solve(1e27, 0)`            | `1e27`                                 |
///        | `x1 = ceilDiv(u' * x0_init, ONE)`| `1e30`                                 |
///        | **`x1 - x0`**                    | **`-1`  -> Panic(0x11)**               |
///
///      One `u`-ulp here is `x0_init / ONE = 1000` wei, so the single extra wei in
///      `balanceIn` is invisible to `u` and is lost. At `balanceIn = 1e30` exactly (no `+1`)
///      the same path gives `x1 - x0 = 0`, `amountIn = 0`, bumped to `1` by the guard at
///      `:218-220`, and the call succeeds. The underflow is exactly one wei deep.
///
///      ## Scope
///
///      Empirically clean at `x0_init <= 2e26`; first underflows around `3e26`; widespread at
///      `1e27` and above. Realistic pools sit near `1e21`
///      (`test/invariants/pegged/BalancedCurve.t.sol:17-18`), nine orders of magnitude below
///      the threshold — but **nothing on-chain rejects a larger normaliser**. `parse`
///      (`PeggedSwap.sol:52-61`) checks only that `x0` and `y0` are non-zero, and the source
///      comments at `:162` and `:202` contemplate `x1 <= 1e30` while enforcing nothing.
///      `test/PeggedSwap.t.sol:1024` exercises `1e30` directly.
///
///      Programs are maker-signed, so this is maker self-harm rather than a taker attack:
///      the effect is that an order configured this way is silently unfillable in the
///      exact-out direction while appearing healthy.
contract PeggedSwapUnderflowRepro is Test, PeggedSwap {
    /// @dev Minimal external surface over the internal instruction. `PeggedSwap` never calls
    ///      `ctx.runLoop()`, so leaving `ctx.vm` zero-initialised is safe here — the null
    ///      dispatch pointer is never invoked.
    function exactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        address tokenIn,
        address tokenOut,
        bytes calldata args
    ) external pure returns (uint256 amountIn) {
        Context memory ctx;
        ctx.query.isExactIn = false;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountOut = amountOut;

        _peggedSwapGrowPriceRange2D(ctx, args);

        amountIn = ctx.swap.amountIn;
    }

    address internal constant TOKEN_LO = address(0x1111);
    address internal constant TOKEN_HI = address(0x2222);

    function _args() internal pure returns (bytes memory) {
        // x0, y0, linearWidth, rateLt, rateGt
        return abi.encodePacked(uint256(1e30), uint256(1e30), uint256(0), uint256(1), uint256(1));
    }

    /// @notice The defect: an ordinary exact-out quote reverts with a bare arithmetic panic.
    function test_repro_exactOutPanicsOnOneExtraWei() public {
        bytes memory args = _args();

        (bool ok, bytes memory err) = address(this).staticcall(
            abi.encodeCall(this.exactOut, (1e30 + 1, 1, 1, TOKEN_LO, TOKEN_HI, args))
        );

        assertFalse(ok, "expected the call to revert");

        // Panic(uint256) selector, argument 0x11 == arithmetic under/overflow.
        assertEq(bytes4(err), bytes4(0x4e487b71), "expected Panic(uint256)");
        uint256 code;
        assembly {
            code := mload(add(err, 0x24))
        }
        assertEq(code, 0x11, "expected Panic(0x11), arithmetic underflow");
    }

    /// @notice The boundary: one wei less on the input balance and the same call succeeds.
    /// @dev This is what makes it a defect rather than a documented domain limit — the
    ///      failure is discontinuous in a single wei of a maker-supplied balance.
    function test_repro_oneWeiLessSucceeds() public view {
        bytes memory args = _args();

        uint256 amountIn = this.exactOut(1e30, 1, 1, TOKEN_LO, TOKEN_HI, args);

        assertEq(amountIn, 1, "at 1e30 the quote succeeds and is bumped to one wei");
    }

    /// @notice Realistic pool sizes are unaffected, which is why fuzzing at default scales
    ///         never finds this.
    function test_repro_realisticNormaliserIsUnaffected() public view {
        bytes memory args = abi.encodePacked(uint256(1e21), uint256(1e21), uint256(0), uint256(1), uint256(1));

        uint256 amountIn = this.exactOut(1e21 + 1, 1, 1, TOKEN_LO, TOKEN_HI, args);

        assertGt(amountIn, 0, "a 1e21 normaliser prices without reverting");
    }
}

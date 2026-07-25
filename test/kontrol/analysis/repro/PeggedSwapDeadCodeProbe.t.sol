// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Context } from "../../../../src/libs/VM.sol";
import { PeggedSwap } from "../../../../src/instructions/PeggedSwap.sol";
import { PeggedSwapMath } from "../../../../src/libs/PeggedSwapMath.sol";

/// @notice Evidence for the two "dead code" entries in the ledger.
///
/// @dev     forge test --match-path test/kontrol/analysis/repro/PeggedSwapDeadCodeProbe.t.sol -vv
///
///      Unreachability is a negative claim, so no execution can *witness* it — the ledger entry
///      stays at SOURCE by construction. What execution can do is fail to refute it, and that is
///      what this file does: a fuzz over the whole reachable input surface that would flag either
///      error the moment it fired.
///
///      ## `PeggedSwapMathNoSolution` (`PeggedSwapMath.sol:95`)
///
///      `discriminant = ONE + fourARightSide >= ONE` at `:89`, so
///      `sqrtDiscriminant = isqrt(discriminant * ONE) >= isqrt(ONE * ONE) = ONE` by monotonicity,
///      and the `require` at `:95` cannot fail. Note the proof needs monotonicity **and**
///      `isqrt(ONE * ONE) == ONE`; the latter alone is not enough.
///
///      ## `PeggedSwapMathInvalidInput` (`PeggedSwap.sol:206`)
///
///      The clamp at `:196` gives `amountOut <= balanceOut`, hence `y1 <= y0`, hence
///      `v1 = floor(y1 * ONE / y0_init) <= v = floor(y0 * ONE / y0_init)` by monotonicity of
///      flooring. Therefore
///
///          invariantV1 = isqrt(v1*ONE) + floor(a*v1/ONE)
///                     <= isqrt(v *ONE) + floor(a*(u+v)/ONE)
///                     <= isqrt(u*ONE) + isqrt(v*ONE) + floor(a*(u+v)/ONE)
///                      = targetInvariant
///
///      so `targetInvariant >= invariantV1` always holds.
///
///      **Corollary, and the reason this matters beyond tidiness:** the subtraction at `:199`
///      cannot underflow either, which leaves `:215` as the *only* candidate when attributing an
///      exact-out `Panic(0x11)` in this instruction. That is what licenses the attribution in
///      `PeggedSwapUnderflowRepro`.
contract PeggedSwapDeadCodeProbe is Test, PeggedSwap {
    address internal constant TOKEN_LO = address(0x1111);
    address internal constant TOKEN_HI = address(0x2222);

    function run(
        bool isExactIn,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amount,
        bytes calldata args
    ) external pure returns (uint256, uint256) {
        Context memory ctx;
        ctx.query.isExactIn = isExactIn;
        ctx.query.tokenIn = TOKEN_LO;
        ctx.query.tokenOut = TOKEN_HI;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        if (isExactIn) ctx.swap.amountIn = amount;
        else ctx.swap.amountOut = amount;

        _peggedSwapGrowPriceRange2D(ctx, args);
        return (ctx.swap.amountIn, ctx.swap.amountOut);
    }

    /// @notice Neither error fires anywhere in a broad fuzz of the instruction.
    function testFuzz_probe_neitherDeadErrorEverFires(
        bool isExactIn,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amount,
        uint256 x0,
        uint256 y0,
        uint256 a
    ) public {
        balanceIn = bound(balanceIn, 0, 1e33);
        balanceOut = bound(balanceOut, 1, 1e33);
        amount = bound(amount, 0, 1e33);
        x0 = bound(x0, 1, 1e33);
        y0 = bound(y0, 1, 1e33);
        a = bound(a, 0, PeggedSwapMath.MAX_LINEAR_WIDTH);

        bytes memory args = abi.encodePacked(x0, y0, a, uint256(1), uint256(1));

        (bool ok, bytes memory err) =
            address(this).staticcall(abi.encodeCall(this.run, (isExactIn, balanceIn, balanceOut, amount, args)));

        if (ok) return;
        assertTrue(
            bytes4(err) != PeggedSwapMath.PeggedSwapMathNoSolution.selector, "PeggedSwapMathNoSolution is reachable"
        );
        assertTrue(
            bytes4(err) != PeggedSwapMath.PeggedSwapMathInvalidInput.selector, "PeggedSwapMathInvalidInput is reachable"
        );
    }

    /// @notice The extreme corners of the domain specifically, since fuzzers under-sample them.
    function test_probe_extremeCornersDoNotFireEither() public {
        uint256[6] memory scales = [uint256(1), 2, 1e18, 1e27, 1e30, 1e33];
        uint256[3] memory widths = [uint256(0), 1, PeggedSwapMath.MAX_LINEAR_WIDTH];

        for (uint256 i = 0; i < 6; ++i) {
            for (uint256 j = 0; j < 6; ++j) {
                for (uint256 w = 0; w < 3; ++w) {
                    bytes memory args = abi.encodePacked(scales[i], scales[j], widths[w], uint256(1), uint256(1));
                    for (uint256 k = 0; k < 6; ++k) {
                        _assertNeitherError(false, scales[i], scales[j], scales[k], args);
                        _assertNeitherError(true, scales[i], scales[j], scales[k], args);
                    }
                }
            }
        }
    }

    function _assertNeitherError(
        bool isExactIn,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amount,
        bytes memory args
    ) internal {
        (bool ok, bytes memory err) =
            address(this).staticcall(abi.encodeCall(this.run, (isExactIn, balanceIn, balanceOut, amount, args)));
        if (ok) return;
        assertTrue(bytes4(err) != PeggedSwapMath.PeggedSwapMathNoSolution.selector, "NoSolution fired");
        assertTrue(bytes4(err) != PeggedSwapMath.PeggedSwapMathInvalidInput.selector, "InvalidInput fired");
    }
}

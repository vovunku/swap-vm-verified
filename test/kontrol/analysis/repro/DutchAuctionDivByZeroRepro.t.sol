// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Context } from "../../../../src/libs/VM.sol";
import { DutchAuction, DutchAuctionArgsBuilder } from "../../../../src/instructions/DutchAuction.sol";
import { XYCSwap } from "../../../../src/instructions/XYCSwap.sol";

/// @notice Executed witness for the unguarded division by zero in `DutchAuction`, against the
///         real instruction rather than against `Power` in isolation.
///
/// @dev     forge test --match-path test/kontrol/analysis/repro/DutchAuctionDivByZeroRepro.t.sol -vv
///
///      ## The defect
///
///      `DutchAuction.sol:96-97` computes `decay = decayFactor.pow(elapsed, 1e18)` and then
///      `balanceOut * 1e18 / decay`. `decay` reaches **exactly zero** in finite time for every
///      legal `decayFactor`, and the division is unguarded, so the instruction panics with a
///      bare `Panic(0x12)`.
///
///      The collapse is a cliff, not an asymptote: the last non-zero value is 1 wei and the
///      next step is 0. With the docstring's own headline factor `0.99e18` ("1% decay/sec")
///      that step happens at **elapsed = 4097 seconds**, about 68 minutes — comfortably inside
///      `duration`, which is a `uint16` and so may be up to 65 535 seconds.
///
///      `decayFactor < 1e18` is enforced only in `DutchAuctionArgsBuilder.build`, which is an
///      off-chain helper. `parse` (`:36-44`) checks nothing, so on-chain there is no bound at
///      all — but the bound would not help anyway, since the panic happens for legal factors.
///
///      ## Reachability
///
///      Nothing needs to be attacked and no unusual parameter is required. The maker picks a
///      documented decay factor and a duration in the ordinary range; the auction then dies of
///      old age partway through its own advertised lifetime, before its deadline. Time is the
///      only input.
///
///      ## Impact, and the asymmetry between the two variants
///
///      Both variants stop working, in different ways, and neither loses funds:
///
///        * `_dutchAuctionBalanceOut1D` divides by `decay` -> **`Panic(0x12)`**. Bare panic, no
///          named error, so an integrator cannot tell an expired auction from a bug.
///        * `_dutchAuctionBalanceIn1D` multiplies by `decay` -> `balanceIn` becomes **0**. That
///          looks far worse — a constant-product swap against a zero input reserve would hand
///          the taker the entire output balance for one wei — but it is **already guarded**:
///          `XYCSwap` reverts with `XYCSwapRequiresBothBalancesNonZero` and `LimitSwap` with
///          `LimitSwapRequiresBothBalancesNonZero`. Both guards are pinned below, because the
///          absence of a drain here is the single most important fact about this finding.
contract DutchAuctionDivByZeroRepro is Test, DutchAuction, XYCSwap {
    uint40 internal constant START = 1_000_000;

    function decayBalanceOut(uint256 balanceOut, bytes calldata args) external view returns (uint256) {
        Context memory ctx;
        ctx.swap.balanceOut = balanceOut;
        _dutchAuctionBalanceOut1D(ctx, args);
        return ctx.swap.balanceOut;
    }

    function decayBalanceIn(uint256 balanceIn, bytes calldata args) external view returns (uint256) {
        Context memory ctx;
        ctx.swap.balanceIn = balanceIn;
        _dutchAuctionBalanceIn1D(ctx, args);
        return ctx.swap.balanceIn;
    }

    /// @dev The two instructions `DutchAuction` is documented to sit alongside, given a zero
    ///      input reserve.
    function xycExactIn(uint256 balanceIn, uint256 balanceOut, uint256 amountIn, bytes calldata noArgs)
        external
        pure
        returns (uint256)
    {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;
        _xycSwapXD(ctx, noArgs);
        return ctx.swap.amountOut;
    }

    function _args(uint16 duration, uint64 decayFactor) internal pure returns (bytes memory) {
        return abi.encodePacked(START, duration, decayFactor);
    }

    /// @notice The defect: a 0.99e18 auction divides by zero 4097 seconds in.
    function test_repro_balanceOutPanicsAt4097Seconds() public {
        bytes memory args = _args(type(uint16).max, 0.99e18);

        vm.warp(START + 4096);
        uint256 stillAlive = this.decayBalanceOut(1e21, args);
        assertGt(stillAlive, 0, "at 4096s the decay is still 1 wei and the division succeeds");

        vm.warp(START + 4097);
        (bool ok, bytes memory err) = address(this).staticcall(abi.encodeCall(this.decayBalanceOut, (1e21, args)));

        assertFalse(ok, "expected a revert");
        assertEq(bytes4(err), bytes4(0x4e487b71), "expected Panic(uint256)");
        uint256 code;
        assembly {
            code := mload(add(err, 0x24))
        }
        assertEq(code, 0x12, "expected Panic(0x12), division by zero");
    }

    /// @notice A steeper but equally legal factor gets there in one minute.
    function test_repro_steepFactorPanicsInSixtySeconds() public {
        bytes memory args = _args(type(uint16).max, 0.5e18);

        vm.warp(START + 59);
        assertGt(this.decayBalanceOut(1e21, args), 0, "59s is still alive");

        vm.warp(START + 60);
        (bool ok,) = address(this).staticcall(abi.encodeCall(this.decayBalanceOut, (1e21, args)));
        assertFalse(ok, "60s divides by zero");
    }

    /// @notice The auction is still inside its own deadline when it dies.
    /// @dev `require(block.timestamp <= startTime + duration)` passes; the panic is not an
    ///      expiry, and `DutchAuctionExpired` is never the error the caller sees.
    function test_repro_deathIsBeforeExpiry() public {
        bytes memory args = _args(type(uint16).max, 0.99e18);
        vm.warp(START + 4097);
        assertLt(uint256(4097), uint256(type(uint16).max), "well inside the declared duration");

        (bool ok, bytes memory err) = address(this).staticcall(abi.encodeCall(this.decayBalanceOut, (1e21, args)));
        assertFalse(ok, "reverts");
        assertTrue(bytes4(err) != DutchAuctionExpired.selector, "and not with the expiry error");
    }

    /// @notice The mirror variant zeroes the input reserve instead of panicking.
    function test_repro_balanceInCollapsesToZero() public {
        bytes memory args = _args(type(uint16).max, 0.99e18);
        vm.warp(START + 4097);
        assertEq(this.decayBalanceIn(1e21, args), 0, "input reserve collapses to zero, silently");
    }

    /// @notice ...but the collapse cannot be turned into a drain, because the swap curves
    ///         reject a zero reserve. This is the guard that keeps the whole finding at
    ///         liveness rather than loss of funds.
    function test_repro_zeroBalanceInIsGuardedDownstream() public {
        vm.expectRevert(abi.encodeWithSelector(XYCSwapRequiresBothBalancesNonZero.selector, uint256(0), uint256(1e21)));
        this.xycExactIn(0, 1e21, 1, "");
    }
}

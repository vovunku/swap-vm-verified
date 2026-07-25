// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Context } from "../../../../src/libs/VM.sol";
import { PiecewiseLinearScale } from "../../../../src/instructions/PiecewiseLinearScale.sol";

/// @notice Executed witness for the non-terminating loop in `PiecewiseLinearScale._calcScaleNow`.
///
/// @dev     forge test --match-path test/kontrol/analysis/repro/PiecewiseLinearScaleNonTerminationRepro.t.sol -vv
///
///      ## The defect, in two independent halves
///
///      `:128` computes `max = args.length / 5 - 1` inside an `unchecked` block, and `:142`
///      exits on `++num == max`.
///
///        * `args.length <= 4` — `0 / 5 - 1` wraps to `type(uint256).max`, which `++num` will
///          never reach.
///        * `5 <= args.length <= 9` — **no underflow**; `max` is cleanly `0`. The loop still
///          cannot exit, because `num` is *pre*-incremented, so `++num == 0` is exactly as
///          unreachable as `++num == 2**256 - 1`.
///
///      A fix that only guards the subtraction closes the first half and leaves the second
///      wide open. Ten, not thirteen, is the smallest terminating `args.length`.
///
///      The loop body cannot make progress either: `Calldata.slice` does no bounds checking by
///      design, so `parseIntervalDuration(num)` reads past the end of `args`, and `timeLeft -= 0`
///      is a no-op. The result is out-of-gas, not a revert — there is no error to catch and
///      nothing to attribute it to.
///
///      ## Reachability
///
///      `args.length` is the second byte of each instruction word in the program
///      (`VM.sol:131`), so it is chosen by the **maker** when the program is assembled, and it
///      is a full `uint8` — every value `0..255` is expressible. Nothing between the program
///      bytes and `_calcScaleNow` validates it: `runLoop` checks only that `pcs <= length`, and
///      the instruction itself checks nothing. A maker who mis-assembles a short argument list,
///      or an off-by-one in a builder, produces an order that consumes the whole gas limit on
///      every quote.
///
///      Consequence: **maker self-harm plus a taker gas trap**. The order is permanently
///      unfillable, and every taker who quotes it burns their entire gas budget rather than
///      receiving a revert they could handle. The maker signs it, so no third party can impose
///      it on someone else's order.
contract PiecewiseLinearScaleNonTerminationRepro is Test, PiecewiseLinearScale {
    /// @dev The instruction is `internal view`; this is the minimal external surface over it.
    ///      `ctx.vm.dispatch` is never invoked by this instruction, so leaving it zero is safe.
    function scaleIn(uint256 balanceIn, bytes calldata points) external view returns (uint256) {
        Context memory ctx;
        ctx.swap.balanceIn = balanceIn;
        _piecewiseLinearScaleBalanceIn1D(ctx, points);
        return ctx.swap.balanceIn;
    }

    function setUp() public {
        // Any timestamp strictly greater than the parsed start (which is 0 for all-zero args)
        // gets past the `timeLeft <= start` early exit at `:134`.
        vm.warp(1_000_000);
    }

    /// @dev Calls with a hard gas cap. A terminating call returns; a non-terminating one burns
    ///      the cap and returns `(false, "")` — an out-of-gas child frame, which is
    ///      distinguishable from a revert by having empty return data.
    function _runsOutOfGas(uint256 len) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            address(this).staticcall{ gas: 3_000_000 }(abi.encodeCall(this.scaleIn, (1e18, new bytes(len))));
        return !ok && ret.length == 0;
    }

    /// @notice First half: the `unchecked` underflow region.
    function test_repro_underflowRegionNeverTerminates() public view {
        for (uint256 len = 0; len <= 4; ++len) {
            assertTrue(_runsOutOfGas(len), "args.length <= 4 must run out of gas");
        }
    }

    /// @notice Second half: no underflow, `max == 0`, and still no exit. This is the half a
    ///         `require(args.length >= 5)` fix would miss.
    function test_repro_noUnderflowRegionAlsoNeverTerminates() public view {
        for (uint256 len = 5; len <= 9; ++len) {
            assertTrue(_runsOutOfGas(len), "5 <= args.length <= 9 must run out of gas");
        }
    }

    /// @notice Ten is the smallest terminating length — not the thirteen the docstring implies.
    /// @dev `:116` states "(a) At least two points provided -> args.length >= 13 bytes". Ten
    ///      bytes is one point and one duration; `max == 1`, the loop exits on the first
    ///      increment, and `parsePointScale(1)` reads past the arguments (unchecked by design)
    ///      to produce the returned scale. It terminates, and it returns garbage.
    function test_repro_tenBytesTerminates() public view {
        for (uint256 len = 10; len <= 16; ++len) {
            assertFalse(_runsOutOfGas(len), "args.length >= 10 must terminate");
        }
    }

    /// @notice A well-formed 13-byte argument list behaves normally, so the bug is confined to
    ///         malformed lengths rather than being a general breakage.
    function test_repro_wellFormedArgsAreFine() public view {
        // [5 bytes timestamp][3 bytes scale0][2 bytes duration0][3 bytes scale1]
        bytes memory args =
            abi.encodePacked(uint40(1_000_000), uint24(0x7fffff), uint16(100), uint24(0xffffff));
        assertEq(args.length, 13, "sanity");
        uint256 scaled = this.scaleIn(1e18, args);
        assertGt(scaled, 0, "a well-formed argument list scales without looping");
    }
}

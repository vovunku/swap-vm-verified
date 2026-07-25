// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Context } from "../../../../src/libs/VM.sol";
import { CalldataPtrLib } from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";
import { MinRate } from "../../../../src/instructions/MinRate.sol";

/// @notice Executed witness that `AdjustMinRate` does not enforce the floor it advertises.
///
/// @dev     forge test --match-path test/kontrol/analysis/repro/MinRateAdjustStaleRegisterRepro.t.sol -vv
///
///      `MinRate` belongs to another track; this file only *reads* `src/instructions/MinRate.sol`
///      and drives it through its own dispatch stub. No `MinRate` source, spec or harness is
///      touched, and no proof is run against one.
///
///      ## The defect
///
///      `_adjustMinRate1D` snapshots `amountIn`/`amountOut` at `:56-57`, **before** `ctx.runLoop()`
///      at `:60`. The rate comparison at `:65` correctly uses the loop's results, but the
///      correction at `:67`/`:69` recomputes from the stale snapshot. If any instruction inside
///      the loop changed the register the correction reads — an input-side fee, a partial fill,
///      a balance adjustment — the correction is computed from a number that no longer describes
///      the swap, and lands on a rate that is still below the floor.
///
///      ## Witness
///
///      Floor 1:1 (`rateLt = rateGt = 1`), exact-in, `amountIn = 100` on entry. The inner
///      program prices the swap and returns `(amountIn, amountOut) = (50, 100)` — a 0.5:1 rate,
///      below the floor, with the input side reduced by 50 (a fee, a partial fill, either).
///
///        * `:65` sees `50 * 1 < 1 * 100`, so the floor is breached and the correction fires.
///        * `:67` sets `amountOut = 100 * 1 / 1 = 100` — recomputed from the **pre-loop** 100.
///        * The registers end at `(50, 100)`, i.e. **still 0.5:1**. Nothing was corrected.
///
///      `RequireMinRate` with the same arguments rejects exactly this state, which is the
///      cleanest possible statement of the inconsistency: the enforcing variant and the
///      correcting variant disagree about whether the same swap is acceptable.
///
///      ## Impact and reachability
///
///      Silent wrong arithmetic, and the **maker** bears it: they attached a minimum-rate floor
///      to their order and the instruction returns a fill below it without reverting. No taker
///      action is needed beyond triggering the ordinary program path; any program that sequences
///      a fee or a partial-filling curve between `AdjustMinRate` and the swap reaches it. What
///      the finding does *not* establish is how common such a program shape is in practice —
///      that depends on maker-authored bytecode this repository does not contain.
contract MinRateAdjustStaleRegisterRepro is Test, MinRate {
    /// @dev What the stubbed inner program writes into the registers.
    uint256 internal stubAmountIn;
    uint256 internal stubAmountOut;

    address internal constant TOKEN_LO = address(0x1111);
    address internal constant TOKEN_HI = address(0x2222);

    /// @dev Stands in for `VM.dispatch`. One instruction, which simply reports the amounts the
    ///      inner program computed.
    function _stub(Context memory ctx, uint256, bytes calldata) internal view {
        ctx.swap.amountIn = stubAmountIn;
        ctx.swap.amountOut = stubAmountOut;
    }

    function _ctx(bytes calldata program, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (Context memory ctx)
    {
        ctx.vm.programPtr = CalldataPtrLib.from(program);
        ctx.vm.dispatch = _stub;
        ctx.query.tokenIn = TOKEN_LO;
        ctx.query.tokenOut = TOKEN_HI;
        ctx.query.isExactIn = true;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;
    }

    function adjust(
        bytes calldata program,
        uint256 amountIn,
        uint256 amountOut,
        bytes calldata args
    ) external returns (uint256, uint256) {
        Context memory ctx = _ctx(program, amountIn, amountOut);
        _adjustMinRate1D(ctx, args);
        return (ctx.swap.amountIn, ctx.swap.amountOut);
    }

    function requireRate(
        bytes calldata program,
        uint256 amountIn,
        uint256 amountOut,
        bytes calldata args
    ) external returns (uint256, uint256) {
        Context memory ctx = _ctx(program, amountIn, amountOut);
        _requireMinRate1D(ctx, args);
        return (ctx.swap.amountIn, ctx.swap.amountOut);
    }

    /// @dev A one-instruction program: opcode 0x00, zero argument bytes.
    function _program() internal pure returns (bytes memory) {
        return hex"0000";
    }

    /// @dev Floor of 1:1 in both directions.
    function _args() internal pure returns (bytes memory) {
        return abi.encodePacked(uint64(1), uint64(1));
    }

    /// @notice Sanity: the stub really does drive the registers, so the witness is not vacuous.
    function test_repro_stubDrivesTheRegisters() public {
        stubAmountIn = 100;
        stubAmountOut = 100;

        (uint256 amountIn, uint256 amountOut) = this.adjust(_program(), 100, 0, _args());
        assertEq(amountIn, 100, "at exactly the floor the correction does not fire");
        assertEq(amountOut, 100, "");
    }

    /// @notice The defect: the correction fires and leaves the rate below the floor.
    function test_repro_adjustLeavesRateBelowFloor() public {
        stubAmountIn = 50;
        stubAmountOut = 100;

        (uint256 amountIn, uint256 amountOut) = this.adjust(_program(), 100, 0, _args());

        assertEq(amountIn, 50, "input register untouched by the correction");
        assertEq(amountOut, 100, "output recomputed from the stale pre-loop amountIn");
        assertLt(amountIn, amountOut, "the resulting rate is 0.5:1, below the 1:1 floor");
    }

    /// @notice The enforcing sibling rejects the very state the correcting one produces.
    function test_repro_requireMinRateRejectsWhatAdjustAccepts() public {
        stubAmountIn = 50;
        stubAmountOut = 100;

        vm.expectRevert(
            abi.encodeWithSelector(MinRateFailed.selector, uint256(50), uint256(100), uint256(1), uint256(1))
        );
        this.requireRate(_program(), 100, 0, _args());
    }

    /// @notice When the inner program leaves `amountIn` alone, the correction is right — which
    ///         is why the bug survives the obvious tests.
    function test_repro_correctionIsRightWhenAmountInIsUnchanged() public {
        stubAmountIn = 100;
        stubAmountOut = 200;

        (uint256 amountIn, uint256 amountOut) = this.adjust(_program(), 100, 0, _args());

        assertEq(amountIn, 100, "");
        assertEq(amountOut, 100, "corrected down to exactly the 1:1 floor");
    }
}

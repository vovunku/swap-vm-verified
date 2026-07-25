// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Context } from "../../../../src/libs/VM.sol";
import { BaseFeeAdjuster } from "../../../../src/instructions/BaseFeeAdjuster.sol";

/// @notice Executed witnesses for the three unguarded paths in `BaseFeeAdjuster`.
///
/// @dev     forge test --match-path test/kontrol/analysis/repro/BaseFeeAdjusterRepro.t.sol -vv
///
///      All three share a precondition — `block.basefee > baseGasPrice` (`:83`) — which is why
///      an order carrying any of them looks perfectly healthy while gas is cheap and starts
///      misbehaving only when the network gets busy. None of them is caught by a named error.
///
///      1. **`maxPriceDecay > 2e18` bricks exact-in.** `2e18 - maxPriceDecay` at `:93` is a
///         checked subtraction on a `uint64` parameter whose full range is `~1.8e19`. Bare
///         `Panic(0x11)`.
///
///      2. **Exact-out underflows instead of clamping.** `:98` computes `1e18 - q` and `:99`
///         then clamps with `Math.max(..., maxPriceDecay)`. The clamp is one line too late: the
///         subtraction has already reverted. `q > 1e18` means the gas compensation exceeds the
///         whole trade, which is exactly what happens to a *small* order in a gas spike — the
///         case the clamp was written for. The same order in the same block succeeds exact-in
///         and reverts exact-out.
///
///      3. **`maxPriceDecay > 1e18` inverts the adjustment against the taker.** `Math.max` at
///         `:99` floors `priceDecay` at `maxPriceDecay`; above `1e18` that floor is a
///         *multiplier*, so `amountIn` at `:100` goes **up**. The instruction's entire purpose
///         is to discount the taker for gas; at `maxPriceDecay = 2e18` it doubles their bill
///         instead. This is the only one of the three that moves funds rather than reverting.
///
///      ## Who bears it, and what stops it
///
///      (1) and (2) are denial of service: the maker's order stops filling and the taker loses
///      gas. (3) charges the taker. `maxPriceDecay` is maker-supplied and nothing on chain
///      bounds it — `BaseFeeAdjusterArgsBuilder` has no `require` at all, unlike
///      `DutchAuctionArgsBuilder`, which at least checks its factor in `build`.
///
///      **Partial guard, and it is opt-in.** `TakerTraits.validate` (`:191-201`) caps `amountIn`
///      in the exact-out direction — but only when the taker supplied a threshold, and
///      `threshold()` (`:236-239`) reports `hasThreshold` purely from whether a 32-byte slice
///      is present. A taker who sets a slippage limit converts (3) from an overcharge into a
///      revert; a taker who does not is charged whatever the maker wrote. So (3) is a real
///      taker-facing loss with a widely-used but not mandatory mitigation.
contract BaseFeeAdjusterRepro is Test, BaseFeeAdjuster {
    uint64 internal constant BASE_GAS_PRICE = 20 gwei;
    uint96 internal constant ETH_TO_TOKEN1 = 3000e18;
    uint24 internal constant GAS_AMOUNT = 150_000;

    function adjust(
        bool isExactIn,
        uint256 amountIn,
        uint256 amountOut,
        bytes calldata args
    ) external view returns (uint256, uint256) {
        Context memory ctx;
        ctx.query.isExactIn = isExactIn;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;
        _baseFeeAdjuster1D(ctx, args);
        return (ctx.swap.amountIn, ctx.swap.amountOut);
    }

    function _args(uint64 maxPriceDecay) internal pure returns (bytes memory) {
        return abi.encodePacked(BASE_GAS_PRICE, ETH_TO_TOKEN1, GAS_AMOUNT, maxPriceDecay);
    }

    function _panicCode(bytes memory err) internal pure returns (uint256 code) {
        if (bytes4(err) != bytes4(0x4e487b71)) return type(uint256).max;
        assembly {
            code := mload(add(err, 0x24))
        }
    }

    function setUp() public {
        vm.fee(100 gwei); // a busy but entirely ordinary block
    }

    /// @notice (1) `maxPriceDecay > 2e18` makes the order unexecutable exact-in.
    function test_repro_maxPriceDecayAboveTwoBricksExactIn() public {
        (bool ok, bytes memory err) =
            address(this).staticcall(abi.encodeCall(this.adjust, (true, 1e21, 3000e21, _args(3e18))));

        assertFalse(ok, "expected a revert");
        assertEq(_panicCode(err), 0x11, "expected Panic(0x11) from 2e18 - maxPriceDecay");
    }

    /// @notice ...and is invisible while gas is below base, which is what makes it a trap.
    function test_repro_sameOrderIsHealthyWhileGasIsCheap() public {
        vm.fee(1 gwei);
        (uint256 amountIn, uint256 amountOut) = this.adjust(true, 1e21, 3000e21, _args(3e18));
        assertEq(amountIn, 1e21, "unchanged");
        assertEq(amountOut, 3000e21, "unchanged");
    }

    /// @notice (2) Exact-out underflows on a small order where the clamp was supposed to save it.
    /// @dev At 100 gwei the gas compensation is 36 token1; a 1-token1 order therefore has
    ///      `q = 36e18 > 1e18`.
    function test_repro_exactOutUnderflowsBeforeTheClamp() public {
        bytes memory args = _args(0.99e18); // a perfectly ordinary 1% floor

        (bool ok, bytes memory err) =
            address(this).staticcall(abi.encodeCall(this.adjust, (false, 1e18, 1e18, args)));

        assertFalse(ok, "expected a revert");
        assertEq(_panicCode(err), 0x11, "expected Panic(0x11) from 1e18 - q");

        // The clamp exists and would have produced 0.99e18 had it been applied first.
        // Same order, same block, opposite direction: fine.
        (uint256 aIn, uint256 aOut) = this.adjust(true, 1e18, 1e18, args);
        assertEq(aIn, 1e18, "exact-in leaves amountIn alone");
        assertGt(aOut, 1e18, "and successfully improves amountOut");
    }

    /// @notice A large order in the same block is unaffected, so the failure is specifically a
    ///         small-order-in-a-gas-spike failure.
    function test_repro_exactOutIsFineOnceTheOrderIsLarge() public view {
        (uint256 amountIn,) = this.adjust(false, 1000e18, 1000e18, _args(0.99e18));
        assertLt(amountIn, 1000e18, "large exact-out order gets its intended discount");
    }

    /// @notice (3) The economically serious one: the discount becomes a surcharge.
    function test_repro_maxPriceDecayAboveOneChargesTheTakerDouble() public view {
        bytes memory args = _args(2e18);

        (uint256 amountIn,) = this.adjust(false, 1000e18, 1000e18, args);

        assertEq(amountIn, 2000e18, "taker is charged exactly double instead of discounted");
    }

    /// @notice The inversion is monotone in `maxPriceDecay`, i.e. it is a dial the maker turns,
    ///         not a knife-edge.
    function test_repro_surchargeScalesWithTheParameter() public view {
        (uint256 at1x,) = this.adjust(false, 1000e18, 1000e18, _args(1e18));
        (uint256 at1p5x,) = this.adjust(false, 1000e18, 1000e18, _args(1.5e18));
        (uint256 at2x,) = this.adjust(false, 1000e18, 1000e18, _args(2e18));

        assertEq(at1x, 1000e18, "1e18 is the no-op point");
        assertEq(at1p5x, 1500e18, "");
        assertEq(at2x, 2000e18, "");
    }
}

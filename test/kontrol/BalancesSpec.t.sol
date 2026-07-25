// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { BalancesHarness } from "./harnesses/BalancesHarness.sol";

/// @notice Kontrol specification for the `Balances._staticBalancesXD` instruction.
///
/// @dev Reference semantics, from src/instructions/Balances.sol:
///
///        require(ctx.swap.balanceIn == 0 && ctx.swap.balanceOut == 0);
///        if (tokenIn < tokenOut) (balanceIn, balanceOut) = parse(args);   // args = [A, B]
///        else                     (balanceOut, balanceIn) = parse(args);
///        ctx.swap.balanceIn  = balanceIn;
///        ctx.swap.balanceOut = balanceOut;
///
///      where `parse(args)` returns `(uint256(args[0:32]), uint256(args[32:64]))`.
///
///      The two args words are therefore always ordered by token address, never by swap
///      direction: `args[0]` is the balance of whichever token has the *lower* address,
///      `args[1]` the balance of the token with the *higher* address. Swapping which token
///      is `tokenIn` vs `tokenOut` swaps which register receives which word — it must not
///      change which balance is associated with which token. This matters because the
///      program is signed over token *names*; a taker re-labeling the in/out direction must
///      not be able to rebind the maker's balances.
///
///      The leading `require` makes a second application *reject* whenever the first set a
///      non-zero register — the instruction is not idempotent, it refuses to overwrite. The
///      only case that survives a second call is the degenerate all-zero args.
contract BalancesSpec is Test {
    BalancesHarness internal harness;

    function setUp() public {
        harness = new BalancesHarness();
    }

    /// @dev 64-byte args: two packed uint256, matching `BalancesArgsBuilder.build`.
    function _args(uint256 balanceA, uint256 balanceB) internal pure returns (bytes memory) {
        return abi.encodePacked(balanceA, balanceB);
    }

    // -----------------------------------------------------------------------
    // Token-ordered assignment
    // -----------------------------------------------------------------------

    /// @notice `args[0]` always lands in the register of the lower-address token;
    ///         `args[1]` always lands in the register of the higher-address token.
    /// @dev This is the central A3 property. The assignment is by token *address*, not by
    ///      in/out direction — a taker swapping the `tokenIn`/`tokenOut` arguments cannot
    ///      rebind which balance belongs to which token.
    function test_assignmentOrderedByTokenAddress(
        address tokenIn,
        address tokenOut,
        uint256 balanceA,
        uint256 balanceB
    ) public view {
        // `tokenIn == tokenOut` is not a meaningful swap; the source takes the `else` branch
        // in that case, but it is out of scope for the ordering property.
        vm.assume(tokenIn != tokenOut);

        (uint256 bin, uint256 bout) =
            harness.applyStatic(tokenIn, tokenOut, 0, 0, _args(balanceA, balanceB));

        if (tokenIn < tokenOut) {
            // tokenIn is the lower-address token → its register gets args[0].
            assertEq(bin, balanceA, "tokenIn<tokenOut: balanceIn must equal args[0]");
            assertEq(bout, balanceB, "tokenIn<tokenOut: balanceOut must equal args[1]");
        } else {
            // tokenOut is the lower-address token → its register gets args[0].
            assertEq(bin, balanceB, "tokenIn>tokenOut: balanceIn must equal args[1]");
            assertEq(bout, balanceA, "tokenIn>tokenOut: balanceOut must equal args[0]");
        }
    }

    /// @notice Swapping `tokenIn`/`tokenOut` swaps which register gets which args word.
    /// @dev Direct corollary of the ordering above, stated as a symmetry so a regression
    ///      that breaks one direction without the other is caught independently. Holding
    ///      `args` fixed and flipping the tokens must exchange the two resulting registers.
    function test_swappingTokensSwapsRegisterAssignment(
        address tokenIn,
        address tokenOut,
        uint256 balanceA,
        uint256 balanceB
    ) public view {
        vm.assume(tokenIn != tokenOut);

        (uint256 bin, uint256 bout) =
            harness.applyStatic(tokenIn, tokenOut, 0, 0, _args(balanceA, balanceB));
        (uint256 binSwapped, uint256 boutSwapped) =
            harness.applyStatic(tokenOut, tokenIn, 0, 0, _args(balanceA, balanceB));

        assertEq(bin, boutSwapped, "balanceIn(tIn,tOut) must equal balanceOut(tOut,tIn)");
        assertEq(bout, binSwapped, "balanceOut(tIn,tOut) must equal balanceIn(tOut,tIn)");
    }

    // -----------------------------------------------------------------------
    // The zero-balance guard: second application is rejected, not idempotent
    // -----------------------------------------------------------------------

    /// @notice Any non-zero incoming balance register causes a revert.
    /// @dev This is what makes a second application fail: after the first call sets the
    ///      registers from `args`, at least one is non-zero (unless `args` was all zeros),
    ///      so a repeat call hits the guard. The instruction is therefore *not* idempotent;
    ///      it refuses to overwrite an already-populated register pair.
    function test_revertsUnlessBothIncomingBalancesZero(
        address tokenIn,
        address tokenOut,
        uint256 incomingBalanceIn,
        uint256 incomingBalanceOut,
        uint256 balanceA,
        uint256 balanceB
    ) public {
        vm.assume(incomingBalanceIn != 0 || incomingBalanceOut != 0);

        vm.expectRevert();
        harness.applyStatic(tokenIn, tokenOut, incomingBalanceIn, incomingBalanceOut, _args(balanceA, balanceB));
    }

    /// @notice The guard accepts the all-zero incoming state, which is the only way the
    ///         instruction is permitted to run. Combined with the property above, this pins
    ///         the guard exactly: revert iff (bin != 0 || bout != 0).
    function test_succeedsWithBothIncomingBalancesZero(
        address tokenIn,
        address tokenOut,
        uint256 balanceA,
        uint256 balanceB
    ) public view {
        vm.assume(tokenIn != tokenOut);

        (uint256 bin, uint256 bout) = harness.applyStatic(tokenIn, tokenOut, 0, 0, _args(balanceA, balanceB));

        // Result matches the ordering property — sanity that the "happy path" agrees.
        if (tokenIn < tokenOut) {
            assertEq(bin, balanceA);
            assertEq(bout, balanceB);
        } else {
            assertEq(bin, balanceB);
            assertEq(bout, balanceA);
        }
    }

    // -----------------------------------------------------------------------
    // Degenerate idempotent case
    // -----------------------------------------------------------------------

    /// @notice With all-zero args and zero registers, the instruction is a no-op.
    /// @dev This is the single case where a "second application" would not revert: both
    ///      registers stay zero, so the guard still passes. Pinning it documents the only
    ///      idempotent corner rather than leaving the idempotency question open.
    function test_zeroArgsIsNoOpWhenRegistersZero(address tokenIn, address tokenOut) public view {
        (uint256 bin, uint256 bout) = harness.applyStatic(tokenIn, tokenOut, 0, 0, _args(0, 0));

        assertEq(bin, 0, "all-zero args must leave balanceIn at zero");
        assertEq(bout, 0, "all-zero args must leave balanceOut at zero");
    }
}

// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Balances } from "../../../src/instructions/Balances.sol";
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

    /// @notice Any non-zero incoming balance register reverts with the exact guard
    ///         error `SetBalancesExpectZeroBalances(incomingBalanceIn, incomingBalanceOut)`.
    /// @dev This is what makes a second application fail: after the first call sets the
    ///      registers from `args`, at least one is non-zero (unless `args` was all zeros),
    ///      so a repeat call hits the guard. The instruction is therefore *not* idempotent;
    ///      it refuses to overwrite an already-populated register pair.
    ///
    ///      The revert payload is pinned, not just the fact of a revert: a bare `revert()`,
    ///      an out-of-gas, or a different selector would all pass `vm.expectRevert()` but
    ///      would be a behaviour change. The error carries the *incoming* register values
    ///      (not the parsed `args` values), matching the source `require(...)`.
    function test_revertsUnlessBothIncomingBalancesZero(
        address tokenIn,
        address tokenOut,
        uint256 incomingBalanceIn,
        uint256 incomingBalanceOut,
        uint256 balanceA,
        uint256 balanceB
    ) public {
        vm.assume(incomingBalanceIn != 0 || incomingBalanceOut != 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                Balances.SetBalancesExpectZeroBalances.selector, incomingBalanceIn, incomingBalanceOut
            )
        );
        harness.applyStatic(tokenIn, tokenOut, incomingBalanceIn, incomingBalanceOut, _args(balanceA, balanceB));
    }

    /// @notice The guard accepts the all-zero incoming state — the complement of the property
    ///         above, pinning the guard exactly: revert iff (bin != 0 || bout != 0).
    /// @dev Non-revert *is* the property here, so the post-state values are asserted by the
    ///      ordering test rather than duplicated below.
    function test_succeedsWithBothIncomingBalancesZero(
        address tokenIn,
        address tokenOut,
        uint256 balanceA,
        uint256 balanceB
    ) public {
        vm.assume(tokenIn != tokenOut);

        harness.applyStatic(tokenIn, tokenOut, 0, 0, _args(balanceA, balanceB));
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

    // -----------------------------------------------------------------------
    // Edge cases: degenerate and out-of-spec inputs
    // -----------------------------------------------------------------------

    /// @notice When `tokenIn == tokenOut`, the source takes the `else` branch — the same
    ///         path as `tokenIn > tokenOut` — so `balanceIn` receives `args[1]` and
    ///         `balanceOut` receives `args[0]`.
    /// @dev `tokenIn == tokenOut` is not a meaningful swap, but the behaviour is concrete
    ///      and worth pinning rather than leaving hidden behind `vm.assume(tokenIn != tokenOut)`.
    ///      A future refactor that, e.g., added an explicit equality revert would be caught here.
    function test_equalTokensTakesElseBranch() public {
        address token = address(0xABCD);

        (uint256 bin, uint256 bout) =
            harness.applyStatic(token, token, 0, 0, _args(uint256(1), uint256(2)));

        assertEq(bin, 2, "tokenIn==tokenOut must take the else branch: balanceIn = args[1]");
        assertEq(bout, 1, "tokenIn==tokenOut must take the else branch: balanceOut = args[0]");
    }

    /// @notice Extra trailing bytes in `args` are ignored: only the first two 32-byte
    ///         words are consumed.
    /// @dev `parse` reads fixed offsets 0 and 32 and never inspects `args.length`, so a
    ///      longer buffer is harmless. This is the benign side of the missing length check
    ///      — the harmful side (short args) is documented below.
    function test_oversizedArgsIgnoreTrailingBytes(address tokenIn, address tokenOut, uint256 extra) public {
        vm.assume(tokenIn != tokenOut);

        bytes memory args = abi.encodePacked(uint256(1), uint256(2), extra);

        (uint256 bin, uint256 bout) = harness.applyStatic(tokenIn, tokenOut, 0, 0, args);

        if (tokenIn < tokenOut) {
            assertEq(bin, 1);
            assertEq(bout, 2);
        } else {
            assertEq(bin, 2);
            assertEq(bout, 1);
        }
    }

    // -----------------------------------------------------------------------
    // Finding: NO length validation on `args` (not a desired invariant)
    // -----------------------------------------------------------------------
    //
    // `BalancesArgsBuilder.parse` reads `args[0:32]` and `args[32:64]` via
    // `uint256(bytes32(args))` and `uint256(bytes32(args.slice(32)))`. The `Calldata.slice`
    // variant used here is unchecked assembly (`node_modules/@1inch/solidity-utils/.../
    // Calldata.sol`): when `args.length < 64` it does NOT revert — `slice(32)` underflows
    // the length and `bytes2` reads whatever bytes happen to follow in calldata.
    //
    // This is stated symbolically over `args.length`, not as concrete examples: the property
    // is that for EVERY args shorter than 64 bytes, the instruction does not revert. A safe
    // API would reject a short buffer; this one silently reads adjacent calldata instead.
    // It is a documented bug, not a desired invariant — the fix is a length check in `parse`
    // (or the bounds-checked `slice(..., bytes4)` overload). Whether short args are reachable
    // depends on the dispatcher, which is out of scope for this instruction-level spec.
    // (If a future fix adds the bounds check, this test should flip to expect that revert.)

    /// @notice For any `args` shorter than 64 bytes, the instruction does NOT revert — the
    ///         missing length check. `balanceOut` (and possibly `balanceIn`) silently read
    ///         adjacent calldata instead.
    /// @dev Reaching the end of the test = no revert. The read register values are
    ///      nondeterministic adjacent-calldata garbage, so there is nothing to assert beyond
    ///      the absence of a revert. Zero incoming balances are used so the only candidate
    ///      revert (the zero-balance guard) cannot fire, isolating the length-check gap.
    function test_finding_shortArgsNeverRevert(bytes calldata args) public {
        vm.assume(args.length < 64);

        harness.applyStatic(address(1), address(2), 0, 0, args);
    }
}

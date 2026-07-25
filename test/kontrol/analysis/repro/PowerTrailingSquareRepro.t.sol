// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Context } from "../../../../src/libs/VM.sol";
import { Power } from "../../../../src/libs/Power.sol";
import { DutchAuction } from "../../../../src/instructions/DutchAuction.sol";

/// @notice Executed witnesses for `Power.pow`'s trailing square, and — more importantly — the
///         reachability check that the ledger was missing.
///
/// @dev     forge test --match-path test/kontrol/analysis/repro/PowerTrailingSquareRepro.t.sol -vv
///
///      ## The defect
///
///      `Power.pow`'s loop is `while (exponent > 0)`, so `base = base * base / precision`
///      executes once more after the final set bit has been consumed. That square is dead
///      work — nothing ever reads its result — but it is checked arithmetic, so it can revert
///      on an input whose answer is perfectly representable. solc's own `**` iterates while
///      `exponent > 1` and does not have this.
///
///      ## Reachability — this is where the ledger stopped short
///
///      `Power` has exactly two callers in the repository (`FINDINGS.md` establishes this by
///      exhaustive grep): `DutchAuction.sol:85`/`:96` and `TWAPSwap.sol:152`.
///
///        * `TWAPSwap` passes the constant `0.9999e18`. `base <= precision` holds forever, the
///          squarings are contractions, and no overflow is possible. **Unreachable.**
///        * `DutchAuction` passes `decayFactor`, parsed as a `uint64`. `build` requires
///          `decayFactor < 1e18`, which also makes every squaring a contraction — but `build`
///          is an off-chain helper and `parse` (`:36-44`) enforces nothing, so a maker who
///          assembles the program bytes directly can pass any `uint64`.
///
///      With `1e18 < decayFactor <= type(uint64).max` the base *expands* on every squaring, and
///      the reachable witness below shows the trailing square panicking on an answer that is
///      representable: `pow(2e18, 128, 1e18) == 2**128 * 1e18 ~= 3.4e56`, which fits, yet the
///      call reverts.
///
///      So the defect is reachable through `DutchAuction`, but only for a `decayFactor > 1e18`,
///      which inverts the auction — the price gets *worse* for the taker over time. It is
///      maker-signed self-harm on an already-nonsensical configuration. For every sane
///      parameter set the trailing square is unreachable and this is a latent library defect,
///      dangerous to the *next* caller rather than to the current ones.
contract PowerTrailingSquareRepro is Test, DutchAuction {
    using Power for uint256;

    uint40 internal constant START = 1_000_000;

    function pow(uint256 base, uint256 exponent, uint256 precision) external pure returns (uint256) {
        return base.pow(exponent, precision);
    }

    function decayBalanceOut(uint256 balanceOut, bytes calldata args) external view returns (uint256) {
        Context memory ctx;
        ctx.swap.balanceOut = balanceOut;
        _dutchAuctionBalanceOut1D(ctx, args);
        return ctx.swap.balanceOut;
    }

    /// @notice Library level: the answer is `base`, and the call reverts anyway.
    function test_repro_trailingSquarePanicsOnRepresentableAnswer() public {
        // pow(B, 1, p) == B for every p. The loop consumes the single set bit, computes the
        // answer, and then squares B one more time for nothing.
        (bool ok, bytes memory err) = address(this).staticcall(abi.encodeCall(this.pow, (2 ** 128, 1, 1e18)));
        assertFalse(ok, "pow(2**128, 1, 1e18) must revert");
        assertEq(bytes4(err), bytes4(0x4e487b71), "Panic(uint256)");
        uint256 code;
        assembly {
            code := mload(add(err, 0x24))
        }
        assertEq(code, 0x11, "Panic(0x11), arithmetic overflow");

        // One wei below the frontier the same shape succeeds.
        assertEq(this.pow(2 ** 128 - 1, 3, 2 ** 128 - 1), 2 ** 128 - 1, "precision <= uint128.max is total");
    }

    /// @notice The totality frontier is exactly `precision <= type(uint128).max`.
    function test_repro_frontierIsUint128() public {
        (bool ok,) = address(this).staticcall(abi.encodeCall(this.pow, (2 ** 128, 2, 2 ** 128)));
        assertFalse(ok, "pow(2**128, 2, 2**128) panics");
    }

    /// @notice `pow(2, 255, 1)` reverts although `2 ** 255` is representable.
    function test_repro_exactIntegerPowerReverts() public {
        (bool ok,) = address(this).staticcall(abi.encodeCall(this.pow, (2, 255, 1)));
        assertFalse(ok, "pow(2, 255, 1) panics");
        assertEq(2 ** 255, 57896044618658097711785492504343953926634992332820282019728792003956564819968, "answer fits");
    }

    /// @notice Reachable through the real instruction — but only on an inverted auction.
    /// @dev `decayFactor = 2e18 > 1e18` is rejected by `build` and accepted by `parse`. At
    ///      `elapsed = 128` the exponent has one set bit, the result `2**128 * 1e18` is
    ///      representable, and the dead trailing square overflows.
    function test_repro_reachableThroughDutchAuctionOnlyWithIllegalFactor() public {
        bytes memory args = abi.encodePacked(START, type(uint16).max, uint64(2e18));

        vm.warp(START + 128);
        (bool ok, bytes memory err) = address(this).staticcall(abi.encodeCall(this.decayBalanceOut, (1e21, args)));
        assertFalse(ok, "the instruction reverts");
        assertEq(bytes4(err), bytes4(0x4e487b71), "with a bare Panic");
        uint256 code;
        assembly {
            code := mload(add(err, 0x24))
        }
        assertEq(code, 0x11, "0x11, i.e. the trailing square, not the division");
    }

    /// @notice Every legal decay factor is immune: `base <= precision` makes each squaring a
    ///         contraction, so no `pow` call from a well-formed `DutchAuction` can overflow.
    function test_repro_legalFactorsNeverOverflow() public view {
        uint64[4] memory factors = [uint64(0.5e18), 0.9e18, 0.99e18, 0.999999e18];
        for (uint256 i = 0; i < 4; ++i) {
            for (uint256 e = 0; e <= type(uint16).max; e += 4095) {
                assertLe(this.pow(factors[i], e, 1e18), 1e18, "result stays inside the precision");
            }
        }
    }
}

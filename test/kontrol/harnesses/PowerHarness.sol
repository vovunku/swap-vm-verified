// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Power } from "../../../src/libs/Power.sol";

/// @notice External surface over the `Power` library, for symbolic execution.
///
/// @dev `Power.pow` is `internal pure` on a plain `library`, so it has no address of its own
///      and cannot be called across an ABI boundary. This harness is the thinnest possible
///      wrapper that gives it one: no state, no constructor, no `immutable`, no `Context`,
///      no calldata parsing. Every argument is a bare `uint256`, so — unlike the instruction
///      harnesses in this directory — there is no register struct to assemble and nothing
///      about the VM is on the proof path.
///
///      **This is not a transcription harness.** `pow` is called, not reimplemented, so
///      every property in `PowerSpec.t.sol` is a claim about the real library bytecode. The
///      only thing the wrapper adds is the external dispatch prologue.
///
///      **No `immutable`, no initialised state variable, no constructor body.** Kontrol loads
///      contracts from `deployedBytecode` and `run-constructor = false` in `kontrol.toml`, so
///      anything a constructor would have written reads back as zero under `kontrol prove`
///      while reading correctly under `forge test`. See the long note at the head of
///      `PeggedSwapSpec.t.sol` for the failure mode. This harness sidesteps it by holding no
///      data at all.
contract PowerHarness {
    /// @notice `Power.pow(base, exponent, precision)`, verbatim.
    /// @dev Reference semantics (`src/libs/Power.sol:13-23`), with no `unchecked` anywhere,
    ///      so every `*` is overflow-checked and every `/` is zero-checked:
    ///
    ///        result = precision;
    ///        while (exponent > 0) {
    ///            if (exponent & 1 == 1) { result = (result * base) / precision; }
    ///            base = (base * base) / precision;
    ///            exponent >>= 1;
    ///        }
    ///
    ///      Two structural facts the spec leans on. The trip count is exactly
    ///      `bitlength(exponent)`, so the loop always terminates — at most 256 iterations
    ///      unconditionally, and at most 16 for `DutchAuction`, whose exponent is
    ///      `elapsed <= duration` with `duration` a `uint16`. And the squaring on the last
    ///      line runs on *every* iteration including the final one, after the last set bit
    ///      has already been consumed; that trailing square is dead work and can panic on
    ///      inputs whose answer fits. `test_squaring_*` pins that.
    function pow(uint256 base, uint256 exponent, uint256 precision) external pure returns (uint256) {
        return Power.pow(base, exponent, precision);
    }

    /// @notice Solidity's own checked exponentiation, as an independent reference for the
    ///         `precision == 1` case where `pow` degenerates to plain `base ** exponent`.
    /// @dev Deliberately *not* a second copy of the same algorithm. solc's
    ///      `checked_exp_helper` is also exponentiation by squaring, but it iterates while
    ///      `exponent > 1` rather than `exponent > 0`, so it does not perform the trailing
    ///      square, and it falls back to a slow path instead of panicking when a squaring
    ///      would overflow. Those two differences are exactly what
    ///      `test_squaring_trailingSquareCanPanicOnAnAnswerThatFits` exhibits: the reference
    ///      returns a value where `pow` reverts.
    function checkedExp(uint256 base, uint256 exponent) external pure returns (uint256) {
        return base ** exponent;
    }
}

// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";
import { Opcode } from "../../src/libs/OpcodeList.sol";
import { ControlsArgsBuilder } from "../../src/instructions/Controls.sol";
import { BalancesArgsBuilder } from "../../src/instructions/Balances.sol";
import { LimitSwapArgsBuilder } from "../../src/instructions/LimitSwap.sol";

/// @title The example SwapVM program, built with the SDK
///
/// @notice A maker's strategy: an institutional gate — only takers holding a required token or
///         NFT may fill — in front of a fixed-rate limit order. Taken from
///         `docs/PROGRAMS.md` §4 "SwapVM Programs with Conditional Flow", Example A.
///
/// @dev This is the artefact the formal semantics is about. It is built the way a real maker
///      builds one: `ProgramBuilder.build` with the real `Opcode` enum and the real
///      `*ArgsBuilder` helpers from `src/instructions/`. Nothing here is hand-assembled.
///
///      That matters for more than tidiness. `semantics/programs/permissioned-swap.md`
///      documents the byte layout, and the K semantics decodes those bytes. Both were derived
///      by reading the encoders. `ProgramBytesTest` asserts that this SDK-built program is
///      byte-identical to that documented layout — so if an encoder ever changes, or if the
///      hand-derivation was wrong, the test fails rather than the semantics silently
///      describing a program nobody builds.
library PermissionedSwapExample {
    using ProgramBuilder for Program;

    /// @notice Build the program.
    /// @param gateToken Token or NFT the taker must hold a non-zero balance of.
    /// @param balanceIn  Maker's offered balance of the lower-sorting token.
    /// @param balanceOut Maker's offered balance of the higher-sorting token.
    /// @param tokenIn  Taker's input token — only its ordering against `tokenOut` is encoded.
    /// @param tokenOut Taker's output token.
    function build(address gateToken, uint256 balanceIn, uint256 balanceOut, address tokenIn, address tokenOut)
        internal
        pure
        returns (bytes memory)
    {
        Program p;
        return bytes.concat(
            // Gate: restrict execution to takers holding `gateToken`.
            p.build(Opcode.OnlyTakerTokenBalanceNonZero, ControlsArgsBuilder.buildTokenBalanceNonZero(gateToken)),
            // Fixed-rate balances for a 1D swap.
            p.build(Opcode.StaticBalances, BalancesArgsBuilder.build([balanceIn, balanceOut])),
            // Compute limit-order amounts.
            p.build(Opcode.LimitSwap, LimitSwapArgsBuilder.build(tokenIn, tokenOut))
        );
    }
}

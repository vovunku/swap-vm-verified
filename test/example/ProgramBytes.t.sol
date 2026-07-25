// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test, console } from "forge-std/Test.sol";

import { PermissionedSwapExample } from "./PermissionedSwapExample.sol";

/// @title The SDK-to-K bridge
///
/// @notice Asserts that the SDK-built program is byte-identical to the layout the K semantics
///         decodes, and emits the bytes in the form `krun` consumes.
///
/// @dev Closes the loop the project claims: a maker builds a program with the SDK, those exact
///      bytes are what the semantics reasons about, and a theorem about them is a theorem
///      about the maker's strategy. Without this test the semantics describes a byte string
///      that was derived by hand and might match nothing anyone builds.
contract ProgramBytesTest is Test {
    address internal constant GATE = address(uint160(0xaa));
    address internal constant TOKEN_LO = address(uint160(1));
    address internal constant TOKEN_HI = address(uint160(2));

    /// @dev The layout documented in `semantics/programs/permissioned-swap.md` and hard-coded
    ///      in the conformance tests. Derived by reading the encoders; this test is what makes
    ///      that derivation trustworthy rather than merely plausible.
    bytes internal constant DOCUMENTED =
        hex"231400000000000000000000000000000000000000aa"
        hex"9040"
        hex"00000000000000000000000000000000000000000000003635c9adc5dea00000"   // 1000e18
        hex"00000000000000000000000000000000000000000000006c6b935b8bbd400000"   // 2000e18
        hex"530101";

    /// @notice The SDK produces exactly the bytes the semantics decodes.
    function test_sdkProgramMatchesDocumentedLayout() public pure {
        bytes memory built = PermissionedSwapExample.build(GATE, 1000e18, 2000e18, TOKEN_LO, TOKEN_HI);

        assertEq(built.length, 91, "22 (gate) + 66 (balances) + 3 (limit) == 91");
        assertEq(built, DOCUMENTED, "SDK output must equal the layout the K semantics decodes");
    }

    /// @notice Reversed token order flips only the direction byte, not the structure.
    /// @dev `LimitSwapArgsBuilder.build(tokenIn, tokenOut)` encodes only `tokenIn < tokenOut`,
    ///      so the tokens themselves never appear in the program. Easy to miss from the
    ///      catalogue snippet, which reads as though they are stored.
    function test_sdkDirectionByteReflectsTokenOrder() public pure {
        bytes memory fwd = PermissionedSwapExample.build(GATE, 1000e18, 2000e18, TOKEN_LO, TOKEN_HI);
        bytes memory rev = PermissionedSwapExample.build(GATE, 1000e18, 2000e18, TOKEN_HI, TOKEN_LO);

        assertEq(fwd.length, rev.length, "same length");
        assertEq(uint8(fwd[90]), 1, "tokenIn < tokenOut");
        assertEq(uint8(rev[90]), 0, "tokenIn > tokenOut");

        // Everything before the direction byte is identical.
        for (uint256 i = 0; i < 90; i++) {
            assertEq(uint8(fwd[i]), uint8(rev[i]), "only the direction byte differs");
        }
    }

    /// @notice Emit the program as a K `Bytes` literal, for `krun -cPGM=...`.
    /// @dev Run with `forge test --match-test test_emitKLiteral -vv`. This is the mechanical
    ///      SDK-to-K path: no hand transcription of bytes at any point.
    function test_emitKLiteral() public pure {
        bytes memory built = PermissionedSwapExample.build(GATE, 1000e18, 2000e18, TOKEN_LO, TOKEN_HI);

        string memory lit = 'b"';
        for (uint256 i = 0; i < built.length; i++) {
            lit = string.concat(lit, "\\x", _hex2(uint8(built[i])));
        }
        console.log(string.concat(lit, '"'));
    }

    function _hex2(uint8 b) private pure returns (string memory) {
        bytes memory d = "0123456789abcdef";
        bytes memory o = new bytes(2);
        o[0] = d[b >> 4];
        o[1] = d[b & 0x0f];
        return string(o);
    }
}

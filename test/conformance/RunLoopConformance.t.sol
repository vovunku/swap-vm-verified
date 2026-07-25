// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { CalldataPtrLib } from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";

import { Context, ContextLib } from "../../src/libs/VM.sol";

/// @title Phase 0 conformance — the SwapVM decode loop
///
/// @notice Drives the REAL `ContextLib.runLoop` with a no-op dispatch stub and records what it
///         decoded, so its behaviour can be diffed against the K semantics in
///         `semantics/swapvm.md`.
///
/// @dev Why a stub dispatch is the right abstraction here, and not a cheat.
///
///      Phase 0 of `semantics/PLAN.md` defines the decode loop and NO instruction rules — an
///      unknown opcode in K is a no-op that records itself in the trace. This driver makes the
///      Solidity side match exactly: dispatch records the opcode and returns. Both engines
///      therefore do nothing per instruction, and what is being compared is purely the
///      fetch/decode/advance/bound-check behaviour of the loop itself.
///
///      Comparing anything else at this phase would be meaningless: the real VM executes
///      instructions the K semantics does not implement yet, so the register outputs would
///      differ by construction.
///
///      `ctx.vm.dispatch` cannot be left null — `runLoop` invokes it once per instruction, so
///      a null function pointer would fault. There is exactly one function of dispatch's type
///      in this contract, so the assignment is unambiguous.
contract RunLoopConformanceTest is Test {
    using ContextLib for Context;
    using CalldataPtrLib for bytes;

    /// @dev Opcodes seen by the stub, in execution order. Storage, because the stub must
    ///      persist observations across the internal call.
    uint256[] internal _seenOpcodes;
    /// @dev Args length seen per instruction, parallel to `_seenOpcodes`.
    uint256[] internal _seenArgsLengths;

    /// @dev Bound to `ctx.vm.dispatch`. Records and returns — the Solidity twin of the K
    ///      `#unknown` rule.
    function _recordingStub(Context memory, uint256 opcode, bytes calldata args) internal {
        _seenOpcodes.push(opcode);
        _seenArgsLengths.push(args.length);
    }

    /// @notice Run `program` through the real loop.
    /// @dev External so that `program` is genuine calldata — `CalldataPtrLib.from` packs a
    ///      calldata offset, so a memory array would produce a pointer into the wrong region.
    function runProgram(bytes calldata program) external returns (uint256 pc, uint256 count) {
        delete _seenOpcodes;
        delete _seenArgsLengths;

        Context memory ctx;
        ctx.vm.programPtr = CalldataPtrLib.from(program);
        ctx.vm.dispatch = _recordingStub;

        ctx.runLoop();

        return (ctx.vm.nextPC, _seenOpcodes.length);
    }

    function seenOpcode(uint256 i) external view returns (uint256) {
        return _seenOpcodes[i];
    }

    function seenArgsLength(uint256 i) external view returns (uint256) {
        return _seenArgsLengths[i];
    }

    // ---------------------------------------------------------------------
    // The catalogue program: docs/PROGRAMS.md §4 Example A, 91 bytes.
    // Byte-for-byte identical to semantics/programs/permissioned-swap.md.
    // ---------------------------------------------------------------------

    bytes internal constant PERMISSIONED_SWAP =
        hex"231400000000000000000000000000000000000000aa"
        hex"9040"
        hex"00000000000000000000000000000000000000000000003635c9adc5dea00000"   // 1000e18
        hex"00000000000000000000000000000000000000000000006c6b935b8bbd400000"   // 2000e18
        hex"530101";

    /// @notice The loop consumes the whole program and decodes exactly three instructions.
    /// @dev K side: `<pc>` ends at 91, trace holds `#unknown(35,·)`, `#unknown(144,·)`,
    ///      `#unknown(83,·)` with args lengths 20, 64, 1.
    function test_conformance_decodesCatalogueProgram() public {
        assertEq(PERMISSIONED_SWAP.length, 91, "program length");

        (uint256 pc, uint256 count) = this.runProgram(PERMISSIONED_SWAP);

        assertEq(pc, 91, "pc must land exactly on the end of the program");
        assertEq(count, 3, "three instructions decoded");

        assertEq(this.seenOpcode(0), 0x23, "first opcode  OnlyTakerTokenBalanceNonZero");
        assertEq(this.seenOpcode(1), 0x90, "second opcode StaticBalances");
        assertEq(this.seenOpcode(2), 0x53, "third opcode  LimitSwap");

        assertEq(this.seenArgsLength(0), 20, "gate token is 20 bytes");
        assertEq(this.seenArgsLength(1), 64, "two uint256 balances");
        assertEq(this.seenArgsLength(2), 1, "makerDirectionLt is a single byte");
    }

    /// @notice Truncating the last byte trips the bound check.
    /// @dev K side: `Reverted("RunLoopExceedProgramLength")` with `<pc>` advanced to 91 — past the
    ///      start of the `LimitSwap` header, whose declared 1 byte of args now runs past the
    ///      end. The loop must refuse to read out of bounds rather than truncate silently.
    function test_conformance_truncatedProgramReverts() public {
        bytes memory truncated = new bytes(PERMISSIONED_SWAP.length - 1);
        for (uint256 i = 0; i < truncated.length; i++) {
            truncated[i] = PERMISSIONED_SWAP[i];
        }

        vm.expectRevert(abi.encodeWithSelector(ContextLib.RunLoopExceedProgramLength.selector, 91, 90));
        this.runProgram(truncated);
    }

    /// @notice A header that does not fit is also caught.
    /// @dev The `pcs > length` check fires after `pcs` advances past the two-byte header, so a
    ///      lone opcode byte with no length byte reverts. K has a separate rule for this arm.
    function test_conformance_loneOpcodeByteReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ContextLib.RunLoopExceedProgramLength.selector, 2, 1));
        this.runProgram(hex"53");
    }

    /// @notice Declared args running past the end revert with nothing executed.
    /// @dev The sharpest decode-loop test in the file: the FIRST instruction is malformed, so
    ///      no instruction runs before the revert. Isolates the loop from every other concern.
    function test_conformance_firstInstructionArgsOverrunReverts() public {
        // opcode 0x53, declares 0x40 = 64 args bytes, supplies none.
        vm.expectRevert(abi.encodeWithSelector(ContextLib.RunLoopExceedProgramLength.selector, 66, 2));
        this.runProgram(hex"5340");
    }

    /// @notice The empty program terminates immediately, executing nothing.
    /// @dev `while (pcs < length)` falls through. K side: `#run => .K` with `<pc>` 0.
    function test_conformance_emptyProgramTerminates() public {
        (uint256 pc, uint256 count) = this.runProgram(hex"");
        assertEq(pc, 0, "pc unmoved");
        assertEq(count, 0, "nothing dispatched");
    }

    /// @notice An instruction with zero args is decoded and advances by exactly two.
    /// @dev Guards the `pc += 2 + argsLength` arithmetic at the boundary case.
    function test_conformance_zeroArgInstruction() public {
        (uint256 pc, uint256 count) = this.runProgram(hex"5000");
        assertEq(pc, 2, "two-byte header only");
        assertEq(count, 1, "one instruction");
        assertEq(this.seenOpcode(0), 0x50, "XYCSwap");
        assertEq(this.seenArgsLength(0), 0, "no args");
    }
}

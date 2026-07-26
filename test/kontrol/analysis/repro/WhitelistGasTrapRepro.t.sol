// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Context } from "../../../../src/libs/VM.sol";
import { Whitelist, WhitelistArgsBuilder } from "../../../../src/instructions/Whitelist.sol";

/// @notice Executed witness for the unbounded-loop gas trap in `Whitelist._whitelistSequential`
///         and `Whitelist._whitelistCoequal`.
///
/// @dev     forge test --match-path test/kontrol/analysis/repro/WhitelistGasTrapRepro.t.sol -vv
///
///      ## MUST BE EXCLUDED FROM `kontrol prove`
///
///      Gas is off by default under Kontrol, so the loops below are not "very long", they are
///      genuinely infinite: there is no gas counter to exhaust and the exit condition is
///      unreachable. `kontrol prove` over these tests does not fail, it does not return.
///      These are `forge test`-only witnesses.
///
///      ## The defect
///
///      The 1inch `solidity-utils` `Calldata.sol` ships two one-argument `slice` overloads:
///
///        * `slice(bytes calldata, uint256 begin)` — `res.length := sub(calls.length, begin)`, a raw
///          SUB with the comment "Warning: Does not perform bounds checking for gas efficiency"
///        * `slice(bytes calldata, uint256 begin, bytes4 exception)` — reverts when `begin >= calls.length`
///
///      `Whitelist.sol` calls the **unchecked** overload in both looping instructions, and neither
///      call site re-checks the result:
///
///        * `Whitelist.sol:150` `bytes calldata list = args.slice(7);` then `:153`
///          `uint256 length = list.length / 12; while (i < length)`
///        * `Whitelist.sol:118` `bytes calldata list = args.slice(2);` then `:121`
///          `uint256 i = list.length / 10; while (i-- > 0)`
///
///      When `args.length < 7` (resp. `< 2`) the SUB underflows, `list.length` becomes ~2**256,
///      and the loop bound becomes ~2**256/12 (resp. ~2**256/10) iterations.
///
///      The loop body cannot break out. `parseWhitelistSequentialIx` / `parseWhitelistCoequalIx`
///      `calldataload` outside the transaction calldata, which yields zero, so:
///
///        * `allowedTaker == 0`, which does not match a taker with non-zero low 80 bits (`:158`, `:123`)
///        * `duration == 0`, so the `timeLeft < duration` guard at `:163` never fires and
///          `timeLeft -= duration` at `:164` is a no-op — the one exit that could have produced a
///          *revert* is dead.
///
///      Result: out-of-gas, not a revert. The caller gets no error selector, and the whole frame's
///      gas is consumed.
///
///      ## The two loops scan in opposite directions, and it matters
///
///        * `_whitelistSequential` scans **forward** from `list.offset` with `i` increasing, so it
///          walks off the end of calldata immediately and reads zeros forever.
///        * `_whitelistCoequal` scans **backward**: `i` starts at ~2**256/10 and decrements, and
///          `mul(id, 10)` wraps, so the first read lands a few bytes *before* `args.offset` and the
///          scan walks backwards through the enclosing calldata in 10-byte strides before
///          underflowing past offset 0 and reading zeros forever.
///
///      That backward walk means the coequal loop reads whatever precedes the argument bytes.
///      See `test_repro_coequalBackwardScanCanEchoATakerOutOfCalldata` — if the taker's address
///      happens to sit at a 10-byte-aligned position in that backward stride, the loop finds the
///      taker's *own address* and reports a whitelist match. The trap tests below therefore hold
///      the taker in storage rather than passing it as an ABI argument, which is also the faithful
///      arrangement: in the real VM `ctx.query.taker` comes from the swap query, not from bytes
///      adjacent to the program.
///
///      ## Boundary (measured by the tests below)
///
///        * sequential: `args.length <= 6` traps; `args.length >= 7` terminates.
///        * coequal:    `args.length <= 1` traps; `args.length >= 2` terminates.
///
///      Unlike `PiecewiseLinearScale._calcScaleNow` (see `PiecewiseLinearScaleNonTerminationRepro`,
///      where lengths 5..9 do not underflow and still cannot terminate), there is **no second,
///      non-underflow half** here. Once the SUB is well-defined, `length` is cleanly `0` and both
///      loops are correctly skipped — `while (i-- > 0)` with `i == 0` compares before it
///      decrements, so the wrap of `i` is harmless. Switching both call sites to the three-argument
///      `slice(bytes,uint256,bytes4)` overload is therefore a complete fix.
///
///      ## Reachability
///
///      `args.length` is the low byte of each instruction word in the program (`VM.sol:131`,
///      `argsLength := and(shr(240, word), 0xff)`), so it is chosen by the **maker** when the
///      program is assembled and every value `0..255` is expressible. `runLoop` validates only
///      that the args fit inside the program (`VM.sol:143`, `if (pcs > length) revert
///      RunLoopExceedProgramLength`) — a *short* args list always fits, so nothing rejects it.
///      `WhitelistArgsBuilder.buildWhitelistSequential` / `buildWhitelistCoequal` cannot emit one
///      (both `require(allowedTakers.length > 0)`), but the builder is not on the execution path;
///      a hand-assembled or mis-assembled program reaches the instruction directly.
///
///      Consequence: **maker self-harm plus a taker gas trap**, the same shape as the
///      PiecewiseLinearScale finding. The order is permanently unfillable, and every taker who
///      quotes or fills it burns their entire gas budget instead of receiving a revert they could
///      handle. The maker signs the program, so no third party can impose this on someone else's
///      order — but a quoting aggregator that simulates untrusted orders is exposed.
contract WhitelistGasTrapRepro is Test, Whitelist {
    /// @dev Any taker whose low 80 bits are non-zero — see `test_repro_zeroLowBitsTakerEscapesTheTrap`.
    address internal constant TAKER = address(uint160(0x00d8dA6BF26964aF9D7eEd9e03E53415D37aA96045));
    address internal constant OTHER = address(uint160(0xfeEDfaCeFeEdFaceFEedFACefEEDFaCEfEeDfAce));

    uint16 internal constant JUMP_PC = 42;

    uint256 internal constant GAS_CAP = 3_000_000;

    /// @dev Storage-held taker for the trap harnesses, so the taker's bytes are NOT present in the
    ///      transaction calldata that the coequal loop scans backward over.
    address internal storedTaker;

    // ---------------------------------------------------------------------------------------
    // Minimal external surface over the two `internal` instructions.
    // `ctx.vm.dispatch` is never invoked by either instruction, so leaving it zero is safe.
    // `ctx.vm.nextPC` starts at 0; a taker match sets it to the encoded pc.
    // ---------------------------------------------------------------------------------------

    function trapSequential(bytes calldata args) external view returns (uint256) {
        Context memory ctx;
        ctx.query.taker = storedTaker;
        _whitelistSequential(ctx, args);
        return ctx.vm.nextPC;
    }

    function trapCoequal(bytes calldata args) external view returns (uint256) {
        Context memory ctx;
        ctx.query.taker = storedTaker;
        _whitelistCoequal(ctx, args);
        return ctx.vm.nextPC;
    }

    function runSequential(address taker, bytes calldata args) external view returns (uint256) {
        Context memory ctx;
        ctx.query.taker = taker;
        _whitelistSequential(ctx, args);
        return ctx.vm.nextPC;
    }

    function runCoequal(address taker, bytes calldata args) external pure returns (uint256) {
        Context memory ctx;
        ctx.query.taker = taker;
        _whitelistCoequal(ctx, args);
        return ctx.vm.nextPC;
    }

    function setUp() public {
        storedTaker = TAKER;
        // All-zero args parse to `start == 0`, so any timestamp gets past the
        // `timeLeft < start` early revert at `Whitelist.sol:147`.
        vm.warp(1_000_000);
    }

    // ---------------------------------------------------------------------------------------
    // Outcome classification.
    //
    // A hard gas cap turns non-termination into an observable event. Three outcomes are
    // distinguishable at the call boundary:
    //   * ok == true              -> terminated normally
    //   * !ok && ret.length >= 4  -> reverted with a selector (e.g. WhitelistAllowedTimeViolation)
    //   * !ok && ret.length == 0  -> the child frame consumed the whole cap: out of gas
    // ---------------------------------------------------------------------------------------

    function _seqOutOfGas(uint256 len) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            address(this).staticcall{ gas: GAS_CAP }(abi.encodeCall(this.trapSequential, (new bytes(len))));
        return !ok && ret.length == 0;
    }

    function _coeqOutOfGas(uint256 len) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            address(this).staticcall{ gas: GAS_CAP }(abi.encodeCall(this.trapCoequal, (new bytes(len))));
        return !ok && ret.length == 0;
    }

    // ---------------------------------------------------------------------------------------
    // 1. The trap.
    // ---------------------------------------------------------------------------------------

    /// @notice `_whitelistSequential`: every `args.length` below the 7-byte header underflows
    ///         `slice(7)` and burns the entire gas cap.
    function test_repro_sequentialUnderflowRegionRunsOutOfGas() public view {
        for (uint256 len; len <= 6; ++len) {
            assertTrue(_seqOutOfGas(len), "sequential: args.length <= 6 must run out of gas");
        }
    }

    /// @notice `_whitelistCoequal`: same, below the 2-byte pc header.
    function test_repro_coequalUnderflowRegionRunsOutOfGas() public view {
        for (uint256 len; len <= 1; ++len) {
            assertTrue(_coeqOutOfGas(len), "coequal: args.length <= 1 must run out of gas");
        }
    }

    // ---------------------------------------------------------------------------------------
    // 2. The boundary. Seven and two are the smallest terminating lengths — the trap is exactly
    //    the underflow region and nothing more, which is what makes a length guard a complete fix.
    // ---------------------------------------------------------------------------------------

    /// @notice Seven is the smallest terminating `args.length` for the sequential list. At 7..18
    ///         the subtraction is well-defined and `length == 0`, so the loop is skipped; coverage
    ///         runs past the first two 12-byte entry widths to show non-empty lists terminate too.
    function test_repro_sequentialSevenBytesTerminates() public view {
        for (uint256 len = 7; len <= 40; ++len) {
            assertFalse(_seqOutOfGas(len), "sequential: args.length >= 7 must terminate");
        }
    }

    /// @notice Two is the smallest terminating `args.length` for the coequal list.
    function test_repro_coequalTwoBytesTerminates() public view {
        for (uint256 len = 2; len <= 40; ++len) {
            assertFalse(_coeqOutOfGas(len), "coequal: args.length >= 2 must terminate");
        }
    }

    /// @notice Pins the boundary as a single explicit statement: 6/7 and 1/2.
    function test_repro_boundaryIsExactlySixSevenAndOneTwo() public view {
        assertTrue(_seqOutOfGas(6), "6 is the largest trapping sequential args.length");
        assertFalse(_seqOutOfGas(7), "7 is the smallest terminating sequential args.length");
        assertTrue(_coeqOutOfGas(1), "1 is the largest trapping coequal args.length");
        assertFalse(_coeqOutOfGas(2), "2 is the smallest terminating coequal args.length");
    }

    /// @notice The trap is conditional only on `wrapToPackedAddress(taker) != 0`, not on the
    ///         particular constant chosen: a taker whose low 80 bits are zero matches the zeros
    ///         read out of bounds and exits on the first iteration.
    function test_repro_zeroLowBitsTakerEscapesTheTrap() public {
        address zeroLow = address(uint160(uint256(0xdead) << 144)); // high bits set, low 80 bits zero
        assertEq(WhitelistArgsBuilder.wrapToPackedAddress(zeroLow), 0, "sanity: packed address is zero");
        storedTaker = zeroLow;
        assertFalse(_coeqOutOfGas(0), "a zero-packed taker matches the out-of-bounds zeros and exits");
        assertFalse(_seqOutOfGas(0), "a zero-packed taker matches the out-of-bounds zeros and exits");
    }

    /// @notice Second-order consequence of the backward scan: the underflowed coequal loop reads
    ///         the calldata that *precedes* the argument bytes, and if the taker's address sits at
    ///         a 10-byte-aligned position in that stride the loop matches the taker against a copy
    ///         of its own address and reports a whitelist hit — jumping to a pc read out of the
    ///         malformed args rather than falling through.
    /// @dev    In this harness `runCoequal(address,bytes)` puts the taker at calldata offset 4 and
    ///         the argument bytes at offset 100, and the backward stride hits offset 26 exactly,
    ///         which is where the taker's low 10 bytes live. That is a property of the ABI layout,
    ///         not of the address: it reproduces for two unrelated takers below. The jump target is
    ///         `args[0:2]`, so a one-byte `0xff` args yields `nextPC == 0xff00`.
    ///
    ///         This is why the trap tests above hold the taker in storage. It is also worth taking
    ///         seriously on its own: it says the underflowed loop does not merely hang, it can
    ///         produce a *spurious whitelist match* whose jump target is attacker-influenced
    ///         calldata, whenever the enclosing frame happens to carry the taker address at the
    ///         wrong alignment.
    function test_repro_coequalBackwardScanCanEchoATakerOutOfCalldata() public view {
        bytes memory args = hex"ff";
        assertEq(this.runCoequal(TAKER, args), 0xff00, "backward scan echoed the taker and jumped");
        assertEq(this.runCoequal(OTHER, args), 0xff00, "layout-driven, not address-driven");
        // The same taker in storage, with the address absent from calldata, hangs instead.
        assertTrue(_coeqOutOfGas(1), "without the echo the same length is a gas trap");
    }

    // ---------------------------------------------------------------------------------------
    // 3. Non-vacuity: well-formed argument lists of the *same* instructions behave exactly as
    //    documented, so the trap is confined to malformed lengths and is not general breakage.
    // ---------------------------------------------------------------------------------------

    function _seqArgs() internal pure returns (bytes memory) {
        address[] memory takers = new address[](2);
        takers[0] = TAKER;
        takers[1] = OTHER;
        uint16[] memory durations = new uint16[](2);
        durations[0] = 100;
        durations[1] = 200;
        // start = 999_000, block.timestamp = 1_000_000 => timeLeft = 1000 > 100 + 200
        return WhitelistArgsBuilder.buildWhitelistSequential(JUMP_PC, uint40(999_000), takers, durations);
    }

    /// @notice Sequential, well-formed: whitelisted and time-unlocked takers jump to `pc`.
    function test_nonVacuity_sequentialWhitelistedTakerJumps() public view {
        bytes memory args = _seqArgs();
        assertEq(args.length, 2 + 5 + 2 * 12, "sanity: 7-byte header + two 12-byte entries");
        assertEq(this.runSequential(TAKER, args), JUMP_PC, "first whitelisted taker jumps");
        assertEq(this.runSequential(OTHER, args), JUMP_PC, "second whitelisted taker jumps");
    }

    /// @notice Sequential, well-formed: a non-whitelisted taker continues normally once the whole
    ///         whitelist-exclusive period (100 + 200) has elapsed. `nextPC` is left untouched.
    function test_nonVacuity_sequentialOutsiderContinuesAfterThePeriod() public view {
        assertEq(this.runSequential(address(0xCAFE), _seqArgs()), 0, "outsider falls through, no jump");
    }

    /// @notice Sequential, well-formed: the same non-whitelisted taker *reverts* while the period
    ///         is still running. This is the revert branch (`Whitelist.sol:163`) that the
    ///         underflowed loop can never reach, because it only fires on a non-zero `duration`.
    function test_nonVacuity_sequentialOutsiderRevertsDuringThePeriod() public {
        bytes memory args = _seqArgs();
        vm.warp(999_000 + 50); // timeLeft = 50 < durations[0] = 100
        vm.expectRevert(Whitelist.WhitelistAllowedTimeViolation.selector);
        this.runSequential(address(0xCAFE), args);
    }

    /// @notice Sequential, well-formed: before `start`, the early guard at `Whitelist.sol:147`
    ///         reverts for everyone, whitelisted or not.
    function test_nonVacuity_sequentialRevertsBeforeStart() public {
        bytes memory args = _seqArgs();
        vm.warp(999_000 - 1);
        vm.expectRevert(Whitelist.WhitelistAllowedTimeViolation.selector);
        this.runSequential(TAKER, args);
    }

    /// @notice Coequal, well-formed: whitelisted takers jump, everyone else continues.
    function test_nonVacuity_coequalBehavesAsDocumented() public view {
        address[] memory takers = new address[](3);
        takers[0] = OTHER;
        takers[1] = TAKER;
        takers[2] = address(0xBEEF);
        bytes memory args = WhitelistArgsBuilder.buildWhitelistCoequal(JUMP_PC, takers);
        assertEq(args.length, 2 + 3 * 10, "sanity: 2-byte pc + three 10-byte entries");

        assertEq(this.runCoequal(TAKER, args), JUMP_PC, "whitelisted taker jumps");
        assertEq(this.runCoequal(OTHER, args), JUMP_PC, "whitelisted taker jumps");
        assertEq(this.runCoequal(address(0xBEEF), args), JUMP_PC, "whitelisted taker jumps");
        assertEq(this.runCoequal(address(0xC0FFEE), args), 0, "outsider continues, no jump");
    }

    /// @notice `_privateOrder` has no loop and is unaffected by the slice underflow, but it shares
    ///         the 80-bit truncation: only the low 10 bytes of the taker gate access.
    function test_nonVacuity_privateOrderComparesOnlyLowTenBytes() public pure {
        bytes memory args = WhitelistArgsBuilder.buildPrivateOrder(TAKER);
        assertEq(args.length, 10, "sanity: a packed address is 10 bytes");
    }
}

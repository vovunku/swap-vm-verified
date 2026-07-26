// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { CalldataPtr, CalldataPtrLib } from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";

import { Context, ContextLib, SwapRegisters } from "../../../src/libs/VM.sol";
import { Whitelist } from "../../../src/instructions/Whitelist.sol";

/// @notice External surface over the three `Whitelist` instructions, for symbolic execution.
///         Covers `_privateOrder` (pure), `_whitelistCoequal` (pure) and `_whitelistSequential`
///         (view — it reads `block.timestamp`).
///
/// @dev Plain harness, per `analysis/HARNESS-FIDELITY.md`: every entry point assembles a
///      `Context` in memory, calls the **real** internal instruction, and reads the registers
///      back. There is no transcription of any instruction logic anywhere in this file, so
///      there is nothing that can drift from the deployed source. Tier 1.
///
///      ## Why `Context` is assembled rather than passed
///
///      `VM` embeds `function(Context memory, uint256, bytes calldata) internal dispatch`
///      (`src/libs/VM.sol:24`). An internal function pointer is a code offset with no ABI
///      type, so `Context` cannot cross an external call and the harness must take the
///      registers as scalars.
///
///      `ctx.vm.dispatch` is left zero-initialised. That is safe here, and the check is
///      mechanical rather than assumed: `src/instructions/Whitelist.sol` contains no
///      `runLoop`, `dispatch`, `program()`, `takerArgs()`, `setNextPC` or `tryChopTakerArgs`
///      call on any path. The three instructions read `ctx.query.taker` and — for the two
///      jumping ones — write `ctx.vm.nextPC`. Nothing else in `ctx.vm` is touched.
///
///      ## `nextPC` is an INPUT, not just an output
///
///      Every entry point that can jump takes `nextPCIn` and installs it before the call.
///      This is not decoration. In the real VM `runLoop` sets `ctx.vm.nextPC = pcs` — the
///      program counter of the *next* instruction — immediately before dispatching
///      (`src/libs/VM.sol:145`), and reads it back afterwards (`:147`). So the instruction
///      never runs with `nextPC == 0` in production, and a harness that pinned it to zero
///      would make "jumped to pc" and "left nextPC alone" indistinguishable whenever the
///      encoded `pc` is itself zero — i.e. it would quietly weaken every jump property to a
///      one-sided one. With `nextPCIn` symbolic and independent of `pc`, the two outcomes are
///      always distinguishable and the properties are genuine biconditionals.
///
///      ## Why `args` is a slice of `msg.data` rather than a `bytes calldata` parameter
///
///      This is the single design decision in this file, so it is worth stating precisely.
///
///      An ABI-decoded `bytes calldata` parameter carries a **symbolic length**: Kontrol
///      constrains it only by `#rangeUInt(64, lengthBytes(B))` (`solc_to_k.py:1006`). Both
///      looping instructions derive their trip count from that length — `list.length / 10`
///      at `Whitelist.sol:121` and `list.length / 12` at `:153` — so a symbolic length gives
///      a symbolic trip count, which is the exact shape that has never once completed in this
///      repository (`HARNESS-FIDELITY.md`, "the `PeggedSwap` seam … has never once been
///      exercised, because the harness takes `bytes calldata args` fully symbolic and
///      `lengthBytes(args)` propagates into every memory offset").
///
///      It is also genuinely non-terminating below the header size rather than merely slow:
///      `args.slice(2)` / `args.slice(7)` use the **unchecked** one-argument overload, so a
///      short `args` underflows the length to ~2**256 and the loop cannot exit. With gas off
///      by default under Kontrol there is no counter to exhaust. This is measured, not
///      predicted — see `analysis/repro/WhitelistGasTrapRepro.t.sol`, which pins the boundary
///      at `args.length <= 6` (sequential) and `<= 1` (coequal) and is `forge test`-only for
///      this reason.
///
///      The fixed-shape entry points below therefore take the argument bytes as a `bytes32`
///      **word** and hand the instruction `msg.data[a:b]` with `a` and `b` literal. Both the
///      offset and the length are then concrete, the trip count is concrete, and no BMC bound
///      is involved — while the argument *content* stays fully symbolic. Precedent:
///      `XYCSwapHarness` passes `msg.data[0:0]` for the same class of reason.
///
///      What this costs, stated plainly: each fixed-shape entry point quantifies over one
///      entry count, not over all of them. The entry count is bounded by the encoding —
///      `argsLength` is a single byte (`src/libs/VM.sol:131`), so `args.length <= 255` and
///      hence at most 25 coequal entries or 20 sequential ones — so the general theorem is a
///      finite conjunction of which these prove a prefix. The `*Any` entry points at the
///      bottom of this file take a real `bytes calldata` and exist to state the unrestricted
///      form; see `WhitelistSpec` for their status.
///
///      ## Reads past the argument window
///
///      The parsers are raw `calldataload`s: each loads a full 32-byte word and shifts away
///      what it does not want. For every fixed-shape entry point below, the *used* bits of
///      every load lie inside the declared `msg.data[a:b]` window — the discarded remainder
///      falls into the following parameter word, or past `calldatasize` where it reads zero.
///      This is arithmetic on literal offsets and is checked entry point by entry point in
///      the comments. It is *not* what the same loads yield inside the real VM, where the
///      bytes after `args` are the following instructions of the maker's program; but since
///      no used bit ever comes from there, the difference is unobservable.
contract WhitelistHarness is Whitelist {
    using ContextLib for Context;
    using CalldataPtrLib for CalldataPtr;

    // -----------------------------------------------------------------------------------
    // `_privateOrder` — opcode arguments are 10 bytes: allowedTaker.
    //
    // Calldata layout of `privateOrder(address,bytes32)`:
    //   [0,4)    selector
    //   [4,36)   taker
    //   [36,68)  argsWord
    // so the argument block is msg.data[36:46] and `parsePrivateOrder` loads word 36 and
    // keeps its top 10 bytes — exactly the window.
    // -----------------------------------------------------------------------------------

    /// @notice `_privateOrder` over a 10-byte argument block taken from the top of `argsWord`.
    /// @dev Reverts with `WhitelistInvalidTaker` iff `uint80(uint160(taker))` differs from the
    ///      encoded value. Nothing is returned because the instruction writes no register.
    function privateOrder(address taker, bytes32 /* argsWord */ ) external pure {
        Context memory ctx;
        ctx.query.taker = taker;

        _privateOrder(ctx, msg.data[36:46]);
    }

    /// @notice Frame-condition surface for `_privateOrder`: registers in, registers out.
    /// @dev Calldata: selector | taker | argsWord | regs(5 words). The argument window is
    ///      unchanged at msg.data[36:46].
    function privateOrderRegisters(address taker, bytes32 /* argsWord */, SwapRegisters memory regs)
        external
        pure
        returns (SwapRegisters memory)
    {
        Context memory ctx;
        ctx.query.taker = taker;
        ctx.swap = regs;

        _privateOrder(ctx, msg.data[36:46]);

        return ctx.swap;
    }

    // -----------------------------------------------------------------------------------
    // `_whitelistCoequal` — arguments are pc(2) followed by N * takerPacked(10).
    //
    // Calldata layout of `coequalN(address,uint256,bytes32)`:
    //   [0,4)     selector
    //   [4,36)    taker
    //   [36,68)   nextPCIn
    //   [68,100)  argsWord
    // so the argument block starts at 68 and N entries occupy 2 + 10N bytes.
    //
    // Byte map of `argsWord` at N = 3:
    //   argsWord[0:2]   pc
    //   argsWord[2:12]  allowedTakers[0]
    //   argsWord[12:22] allowedTakers[1]
    //   argsWord[22:32] allowedTakers[2]
    //
    // `parseWhitelistCoequalIx(list, i)` loads word `68 + 2 + 10i` and keeps its top 10
    // bytes, i.e. msg.data[70+10i : 80+10i] — inside [68,100) for every i < 3.
    // `parseWhitelistCoequalPC` loads word 68 and keeps its top 2 bytes.
    // -----------------------------------------------------------------------------------

    /// @notice `_whitelistCoequal` with an EMPTY list: 2 bytes of arguments, pc only.
    /// @dev The smallest well-formed coequal argument block. `list.length` is exactly 0, so
    ///      `while (i-- > 0)` compares before it decrements and the loop body never runs —
    ///      the wrap of `i` is harmless. This is the boundary the gas trap sits just below.
    function coequal0(address taker, uint256 nextPCIn, bytes32 /* argsWord */ )
        external
        pure
        returns (uint256 nextPC)
    {
        Context memory ctx;
        ctx.query.taker = taker;
        ctx.vm.nextPC = nextPCIn;

        _whitelistCoequal(ctx, msg.data[68:70]);

        nextPC = ctx.vm.nextPC;
    }

    /// @notice `_whitelistCoequal` over a one-entry list: 12 bytes of arguments.
    function coequal1(address taker, uint256 nextPCIn, bytes32 /* argsWord */ )
        external
        pure
        returns (uint256 nextPC)
    {
        Context memory ctx;
        ctx.query.taker = taker;
        ctx.vm.nextPC = nextPCIn;

        _whitelistCoequal(ctx, msg.data[68:80]);

        nextPC = ctx.vm.nextPC;
    }

    /// @notice `_whitelistCoequal` over a three-entry list: 32 bytes of arguments.
    /// @dev Three entries is the widest list that fits in one word, and it is the shape the
    ///      symbolic properties use: three iterations is enough for the backward scan order to
    ///      matter and for a duplicated entry to be expressible.
    function coequal3(address taker, uint256 nextPCIn, bytes32 /* argsWord */ )
        external
        pure
        returns (uint256 nextPC)
    {
        Context memory ctx;
        ctx.query.taker = taker;
        ctx.vm.nextPC = nextPCIn;

        _whitelistCoequal(ctx, msg.data[68:100]);

        nextPC = ctx.vm.nextPC;
    }

    /// @notice Frame-condition surface for `_whitelistCoequal` at three entries.
    /// @dev Calldata: selector | taker | nextPCIn | argsWord | regs(5 words). The argument
    ///      window is unchanged at msg.data[68:100].
    function coequal3Registers(
        address taker,
        uint256 nextPCIn,
        bytes32, /* argsWord */
        SwapRegisters memory regs
    ) external pure returns (SwapRegisters memory, uint256 nextPC) {
        Context memory ctx;
        ctx.query.taker = taker;
        ctx.vm.nextPC = nextPCIn;
        ctx.swap = regs;

        _whitelistCoequal(ctx, msg.data[68:100]);

        return (ctx.swap, ctx.vm.nextPC);
    }

    // -----------------------------------------------------------------------------------
    // `_whitelistSequential` — arguments are pc(2), start(5), then N * (duration(2),
    // takerPacked(10)).
    //
    // Calldata layout of `sequentialN(address,uint256,bytes32)` is identical to the coequal
    // one, so the argument block again starts at 68.
    //
    // Byte map of `argsWord` at N = 2 (31 bytes used, the 32nd is padding):
    //   argsWord[0:2]   pc
    //   argsWord[2:7]   start
    //   argsWord[7:9]   durations[0]
    //   argsWord[9:19]  allowedTakers[0]
    //   argsWord[19:21] durations[1]
    //   argsWord[21:31] allowedTakers[1]
    //
    // `parseWhitelistSequentialIx(list, i)` loads word `68 + 7 + 12i` and keeps its top 12
    // bytes, i.e. msg.data[75+12i : 87+12i] — inside [68,99) for every i < 2.
    // `parseWhitelistSequentialStartPC` loads word 68 and keeps its top 7 bytes.
    // -----------------------------------------------------------------------------------

    /// @notice `_whitelistSequential` with an EMPTY schedule: 7 bytes of arguments.
    /// @dev The smallest well-formed sequential argument block, one byte above the gas trap.
    ///      The `timeLeft < start` guard still runs, so this entry point isolates that guard
    ///      from the loop entirely.
    function sequential0(address taker, uint256 nextPCIn, bytes32 /* argsWord */ )
        external
        view
        returns (uint256 nextPC)
    {
        Context memory ctx;
        ctx.query.taker = taker;
        ctx.vm.nextPC = nextPCIn;

        _whitelistSequential(ctx, msg.data[68:75]);

        nextPC = ctx.vm.nextPC;
    }

    /// @notice `_whitelistSequential` over a one-entry schedule: 19 bytes of arguments.
    function sequential1(address taker, uint256 nextPCIn, bytes32 /* argsWord */ )
        external
        view
        returns (uint256 nextPC)
    {
        Context memory ctx;
        ctx.query.taker = taker;
        ctx.vm.nextPC = nextPCIn;

        _whitelistSequential(ctx, msg.data[68:87]);

        nextPC = ctx.vm.nextPC;
    }

    /// @notice `_whitelistSequential` over a two-entry schedule: 31 bytes of arguments.
    /// @dev Two entries is the widest schedule that fits in one word. It is the smallest
    ///      shape in which the time-monotonicity property has content: reaching index 1
    ///      requires surviving the `timeLeft < durations[0]` guard.
    function sequential2(address taker, uint256 nextPCIn, bytes32 /* argsWord */ )
        external
        view
        returns (uint256 nextPC)
    {
        Context memory ctx;
        ctx.query.taker = taker;
        ctx.vm.nextPC = nextPCIn;

        _whitelistSequential(ctx, msg.data[68:99]);

        nextPC = ctx.vm.nextPC;
    }

    /// @notice `_whitelistSequential` over a three-entry schedule: 43 bytes of arguments.
    /// @dev 43 bytes does not fit in one word, so the block spans two adjacent parameter
    ///      words. Calldata: selector | taker | nextPCIn | word0 | word1, i.e.
    ///      msg.data[68:100) is `word0` and msg.data[100:132) is `word1`; the argument block
    ///      is msg.data[68:111]. Entry 2 therefore straddles the boundary: its `duration`
    ///      occupies msg.data[99:101], the last byte of `word0` and the first of `word1`.
    ///      `WhitelistSpec._sequentialWords3` builds the pair and documents the split.
    function sequential3(address taker, uint256 nextPCIn, bytes32, /* word0 */ bytes32 /* word1 */ )
        external
        view
        returns (uint256 nextPC)
    {
        Context memory ctx;
        ctx.query.taker = taker;
        ctx.vm.nextPC = nextPCIn;

        _whitelistSequential(ctx, msg.data[68:111]);

        nextPC = ctx.vm.nextPC;
    }

    /// @notice Frame-condition surface for `_whitelistSequential` at two entries.
    function sequential2Registers(
        address taker,
        uint256 nextPCIn,
        bytes32, /* argsWord */
        SwapRegisters memory regs
    ) external view returns (SwapRegisters memory, uint256 nextPC) {
        Context memory ctx;
        ctx.query.taker = taker;
        ctx.vm.nextPC = nextPCIn;
        ctx.swap = regs;

        _whitelistSequential(ctx, msg.data[68:99]);

        return (ctx.swap, ctx.vm.nextPC);
    }

    // -----------------------------------------------------------------------------------
    // Unrestricted surfaces.
    //
    // These take a real ABI-decoded `bytes calldata`, so `args.length` is symbolic over
    // `[0, 2**64)` and the loop trip count is symbolic with it. They exist so that the
    // unrestricted form of each property can be *stated* rather than silently dropped; see
    // the `@custom:kontrol-status OPEN` properties in `WhitelistSpec`.
    //
    // No length guard is imposed here on purpose. A `require` in the harness would convert
    // the non-terminating region into a revert, which changes the theorem: the whole point of
    // the unrestricted surface is that it is the deployed behaviour. Callers constrain the
    // length themselves, and say so.
    // -----------------------------------------------------------------------------------

    /// @notice `_whitelistCoequal` over a fully symbolic argument block.
    function coequalAny(address taker, uint256 nextPCIn, bytes calldata args)
        external
        pure
        returns (uint256 nextPC)
    {
        Context memory ctx;
        ctx.query.taker = taker;
        ctx.vm.nextPC = nextPCIn;

        _whitelistCoequal(ctx, args);

        nextPC = ctx.vm.nextPC;
    }

    /// @notice `_whitelistSequential` over a fully symbolic argument block.
    function sequentialAny(address taker, uint256 nextPCIn, bytes calldata args)
        external
        view
        returns (uint256 nextPC)
    {
        Context memory ctx;
        ctx.query.taker = taker;
        ctx.vm.nextPC = nextPCIn;

        _whitelistSequential(ctx, args);

        nextPC = ctx.vm.nextPC;
    }

    // -----------------------------------------------------------------------------------
    // Run-loop surface — `forge test` ONLY.
    //
    // ############################ MUST BE EXCLUDED FROM `kontrol prove` ##################
    //
    // The whole point of this surface is to execute a program whose jump target points back
    // at itself, which is a NON-TERMINATING loop. Gas is off by default under Kontrol, so
    // there is no counter to exhaust and the exit condition is unreachable: a proof over
    // `WhitelistSpec.test_forgeOnly_*` would not fail, it would not return. Same handling as
    // `analysis/repro/WhitelistGasTrapRepro.t.sol`, which is excluded for the same reason.
    // Select tests by name, and never with a bare `--mt 'WhitelistSpec\.'`.
    // ####################################################################################
    //
    // Everything above this line proves things about an instruction called in isolation.
    // This entry point exists because one finding cannot be stated that way: the consequence
    // of an unvalidated jump target is a property of the *loop that consumes it*, not of the
    // instruction that writes it. `ContextLib.runLoop` sets `ctx.vm.nextPC` to the pc of the
    // following instruction immediately before dispatching (`src/libs/VM.sol:145`) and reads
    // it straight back afterwards (`:147`), with no validation in between beyond the
    // `pcs > length` check on the freshly decoded instruction (`:143`) and the loop condition
    // `pcs < length` (`:123`). Neither constrains a *backward* target.
    //
    // Following `MinRateHarness`, the real `runLoop` executes — the calldata slicing, the
    // `argsLength` byte read and the pc advance are all the production code. Only the opcode
    // table is stubbed, and there is exactly ONE function of the dispatch type in this
    // contract, so the indirect `JUMP` has a single destination.
    // -----------------------------------------------------------------------------------

    /// @dev The one and only dispatch-typed function in this harness. Routes every opcode to
    ///      the real `_whitelistCoequal`, which is what makes the program below a pure test of
    ///      the jump target rather than of any surrounding instruction.
    function _dispatchCoequal(Context memory ctx, uint256, bytes calldata args) internal {
        _whitelistCoequal(ctx, args);
    }

    /// @notice Executes `program` through the REAL `ContextLib.runLoop`, dispatching every
    ///         opcode to the real `_whitelistCoequal`.
    /// @dev    `forge test` only — see the banner above.
    /// @param  program The maker's program, as it would appear in calldata.
    /// @return nextPC  The program counter left behind when the loop exits.
    function runProgramCoequal(address taker, bytes calldata program) external returns (uint256 nextPC) {
        Context memory ctx;
        ctx.query.taker = taker;
        ctx.vm.nextPC = 0;
        ctx.vm.programPtr = CalldataPtrLib.from(program);
        ctx.vm.dispatch = _dispatchCoequal;

        ctx.runLoop();

        nextPC = ctx.vm.nextPC;
    }
}

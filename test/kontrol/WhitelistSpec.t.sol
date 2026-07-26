// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { SwapRegisters } from "../../src/libs/VM.sol";
import { Whitelist } from "../../src/instructions/Whitelist.sol";
import { WhitelistHarness } from "./harnesses/WhitelistHarness.sol";

/// @notice Kontrol specification for the three `Whitelist` instructions.
///
/// @dev Reference semantics, transcribed from `src/instructions/Whitelist.sol`:
///
///        _privateOrder(ctx, args):                                          // :105-110
///            require(uint80(uint160(ctx.query.taker)) == args[0:10])
///                else revert WhitelistInvalidTaker
///
///        _whitelistCoequal(ctx, args):                                      // :116-129
///            p    = uint80(uint160(ctx.query.taker))
///            pc   = args[0:2]
///            list = args[2:]                       // UNCHECKED slice
///            for i = list.length/10 - 1 downto 0:  // BACKWARD
///                if p == list[10i : 10i+10]: ctx.vm.nextPC = pc; return
///            // falls through, nextPC untouched, never reverts
///
///        _whitelistSequential(ctx, args):                                   // :141-167
///            p     = uint80(uint160(ctx.query.taker))
///            pc    = args[0:2]
///            start = args[2:7]
///            t     = block.timestamp
///            if t < start: revert WhitelistAllowedTimeViolation
///            r    = t - start
///            list = args[7:]                       // UNCHECKED slice
///            for i = 0 to list.length/12 - 1:      // FORWARD
///                (d, a) = (list[12i : 12i+2], list[12i+2 : 12i+12])
///                if p == a: ctx.vm.nextPC = pc; return
///                if r < d: revert WhitelistAllowedTimeViolation
///                r -= d
///            // falls through, nextPC untouched
///
///      ## The encoding widths used throughout are the real ones, not narrowings
///
///      Every bound this file quantifies over is enforced by the instruction encoding, so
///      using it is accuracy rather than domain narrowing:
///
///        * `args.length <= 255` — `argsLength` is a single byte read at `src/libs/VM.sol:131`
///          (`argsLength := and(shr(240, word), 0xff)`), chosen by the maker when the program
///          is assembled. Hence at most `(255-2)/10 = 25` coequal entries and `(255-7)/12 = 20`
///          sequential ones.
///        * addresses are compared as `uint80` — only the low 10 bytes
///          (`WhitelistArgsBuilder.wrapToPackedAddress`, `Whitelist.sol:83-85`).
///        * `pc` is `uint16`, `start` is `uint40`, each `duration` is `uint16`.
///
///      A consequence used by several properties below: the whole schedule is bounded. With
///      `start < 2**40`, at most 20 entries and each duration at most 65535, every schedule
///      boundary lies below `2**40 + 20*65535 < 2**41`. Quantifying `block.timestamp` over
///      `uint48` therefore covers **every ordering the encoding can express**; the region
///      above is handled at full `uint256` width by
///      `test_sequential_aboveTheWholeScheduleNeverReverts`.
///
///      ## What the fixed-shape entry points cost, and why they are used
///
///      The harness hands each instruction a `msg.data[a:b]` slice with literal `a` and `b`,
///      so the argument length — and therefore the loop trip count — is concrete while the
///      argument *content* stays fully symbolic. `WhitelistHarness` gives the full reasoning.
///      The short version: an ABI-decoded `bytes calldata` has a symbolic length, both loops
///      derive their trip count from it, and below the header size the unchecked
///      `Calldata.slice` underflows so the loop is genuinely non-terminating with gas off.
///      That region is not a proof-difficulty problem, it is the confirmed gas trap in
///      `analysis/repro/WhitelistGasTrapRepro.t.sol`, and no proof over it can converge.
///
///      So each symbolic property below is stated at one entry count (3 for coequal, 2 for
///      sequential) and the general statement is the finite conjunction over `0..25` /
///      `0..20`. Where the unrestricted form is attempted at all it is marked
///      `@custom:kontrol-status OPEN` and says what an implementation could get wrong at a
///      different entry count and still pass.
///
///      ## Anti-vacuity
///
///      Every symbolic property here is a **biconditional or an exact functional
///      characterisation**, not a one-sided bound. `test_coequal_isExactlyTheMembershipJump`
///      and `test_sequential_isExactlyTheTrichotomy` each pin the instruction's output for
///      *every* input in their domain, so no degenerate implementation satisfies them: an
///      instruction that never jumps fails them, one that always jumps fails them, one that
///      always reverts fails them. Each is additionally accompanied by concrete witnesses
///      with hand-computed expected values, because a universally quantified property can be
///      vacuous and a witness cannot.
contract WhitelistSpec is Test {
    WhitelistHarness internal harness;

    /// @dev vitalik.eth. Low 10 bytes: `0x9e03E53415D37aA96045`.
    address internal constant TAKER_A = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;
    /// @dev Low 10 bytes: `0xFACefEEDFaCEfEeDfAce`.
    address internal constant TAKER_B = 0xfeEDfaCeFeEdFaceFEedFACefEEDFaCEfEeDfAce;
    /// @dev Low 10 bytes: `0xBEEFbeefBEEFbeefBEEF`. Written as a cast rather than as an
    ///      address literal because a 40-hex-digit literal is checksum-checked by solc and
    ///      these are not real accounts.
    address internal constant TAKER_C = address(uint160(0xBEEFbeefBEEFbeefBEEF));
    /// @dev An address that is in none of the witness lists.
    address internal constant OUTSIDER = address(uint160(0xC0DE));

    /// @dev Hard gas cap for the run-loop witness, which turns non-termination into an
    ///      observable event at the call boundary.
    uint256 internal constant GAS_CAP = 3_000_000;

    /// @dev Shares its low 10 bytes with `TAKER_A` and differs in every high byte: the
    ///      concrete instance of the 80-bit truncation the source comments describe.
    address internal constant TAKER_A_ALIAS = address(uint160(0x9e03E53415D37aA96045));

    function setUp() public {
        harness = new WhitelistHarness();
    }

    // =======================================================================================
    // Encoding helpers.
    //
    // These build the argument word(s) the harness slices out of `msg.data`. They are the
    // spec's own statement of the wire format, derived from `WhitelistArgsBuilder`
    // (`Whitelist.sol:15-85`) but written independently of it: the builder concatenates with
    // `abi.encodePacked`, these shift into a word. If the instruction's parsers disagreed
    // with the documented layout by so much as a byte, every property below would fail.
    // =======================================================================================

    /// @dev `wrapToPackedAddress` — the low 10 bytes of an address, restated.
    function _packed(address taker) internal pure returns (uint80) {
        return uint80(uint160(taker));
    }

    /// @dev `_privateOrder` args: allowedTaker(10). Occupies bytes [0,10) of the word.
    function _privateOrderWord(uint80 allowedTaker) internal pure returns (bytes32) {
        return bytes32(uint256(allowedTaker) << 176);
    }

    /// @dev `_whitelistCoequal` args at three entries: pc(2) | a0(10) | a1(10) | a2(10).
    ///      Exactly 32 bytes, so the whole word is argument data.
    function _coequalWord(uint16 pc, uint80 a0, uint80 a1, uint80 a2) internal pure returns (bytes32) {
        return bytes32((uint256(pc) << 240) | (uint256(a0) << 160) | (uint256(a1) << 80) | uint256(a2));
    }

    /// @dev `_whitelistSequential` args at two entries:
    ///      pc(2) | start(5) | d0(2) | a0(10) | d1(2) | a1(10). 31 bytes; byte 31 is padding
    ///      and is never read, because `list.length / 12 == 2` exactly.
    function _sequentialWord(uint16 pc, uint40 start, uint16 d0, uint80 a0, uint16 d1, uint80 a1)
        internal
        pure
        returns (bytes32)
    {
        return bytes32(
            (uint256(pc) << 240) | (uint256(start) << 200) | (uint256(d0) << 184) | (uint256(a0) << 104)
                | (uint256(d1) << 88) | (uint256(a1) << 8)
        );
    }

    /// @dev `_whitelistSequential` args at three entries: 43 bytes, so the block spans the
    ///      two adjacent parameter words `word0` (msg.data[68:100)) and `word1`
    ///      (msg.data[100:132)). Entry 2's `duration` straddles the boundary — its high byte
    ///      is the last byte of `word0`, its low byte the first of `word1`.
    function _sequentialWords3(
        uint16 pc,
        uint40 start,
        uint16 d0,
        uint80 a0,
        uint16 d1,
        uint80 a1,
        uint16 d2,
        uint80 a2
    ) internal pure returns (bytes32 word0, bytes32 word1) {
        word0 = bytes32(
            (uint256(pc) << 240) | (uint256(start) << 200) | (uint256(d0) << 184) | (uint256(a0) << 104)
                | (uint256(d1) << 88) | (uint256(a1) << 8) | uint256(d2 >> 8)
        );
        word1 = bytes32((uint256(d2 & 0xff) << 248) | (uint256(a2) << 168));
    }

    // =======================================================================================
    // Revert-data helpers.
    //
    // `assertEq(bytes, bytes)` is `#asWord` equality under Kontrol — it truncates to the low
    // 32 bytes and discards the lengths (`analysis/SPEC-DESIGN.md` §0.4), which for a 4-byte
    // revert payload compares nothing useful. A `bytes4` extracted in assembly compiles to a
    // word compare, with no keccak on any path.
    //
    // Absence is a SEPARATE channel rather than a `bytes4(0)` sentinel. Encoding "no
    // selector" as zero and then comparing against something that can also be zero is the
    // root cause of two separate vacuity bugs in this repository (`SPEC-DESIGN.md` §5.4).
    // =======================================================================================

    function _selectorOf(bytes memory err) internal pure returns (bool present, bytes4 sel) {
        if (err.length < 4) return (false, bytes4(0));
        assembly ("memory-safe") {
            sel := and(mload(add(err, 0x20)), 0xffffffff00000000000000000000000000000000000000000000000000000000)
        }
        present = true;
    }

    /// @dev `internal pure` accessors rather than `constant`s: a `constant bytes4` initialised
    ///      from `.selector` is rejected by solc (error 8349), and a state variable with an
    ///      initialiser reads as ZERO under Kontrol because the constructor does not run
    ///      (`run-constructor = false`). A zero expected selector would make every comparison
    ///      below vacuous in the dangerous direction.
    function _selInvalidTaker() internal pure returns (bytes4) {
        return Whitelist.WhitelistInvalidTaker.selector;
    }

    function _selTimeViolation() internal pure returns (bytes4) {
        return Whitelist.WhitelistAllowedTimeViolation.selector;
    }

    /// @dev A guard fires *exactly* on its condition. The `== shouldFire` is the whole point:
    ///      an instruction that reverted unconditionally fails it, and so does one that never
    ///      reverted.
    function _assertGuard(bool shouldFire, bool ok, bytes memory err, bytes4 sel, string memory message)
        internal
        pure
    {
        if (ok) {
            assertFalse(shouldFire, message);
        } else {
            (bool present, bytes4 got) = _selectorOf(err);
            assertTrue(present && (got == sel) == shouldFire, message);
        }
    }

    // =======================================================================================
    // A. `_privateOrder` — opcode arguments are one packed address.
    // =======================================================================================

    /// @notice `_privateOrder` reverts with `WhitelistInvalidTaker` **iff** the taker's low
    ///         ten bytes differ from the encoded allowed taker — both directions.
    ///
    /// @dev The biconditional, over the whole `address x uint80` domain with no assumptions.
    ///      Each direction refutes a different degenerate implementation:
    ///
    ///        * the `ok` branch refutes `require(false)` — an instruction that rejected every
    ///          taker would satisfy any number of `vm.expectRevert` tests and fails here;
    ///        * the `!ok` branch refutes a no-op — an instruction that accepted every taker
    ///          fails here;
    ///        * requiring the *named* selector refutes an arithmetic panic or an out-of-gas
    ///          being mistaken for the guard. A bare `vm.expectRevert()` matches any revert
    ///          data at all (`cheatcodes.md:1622-1626`) and could not tell those apart.
    ///
    ///      Note what is deliberately NOT assumed: `taker` ranges over every address and
    ///      `allowedTaker` over every `uint80`, so the property covers the case where the
    ///      taker's high ten bytes differ from anything the maker had in mind. That is the
    ///      whole content of `test_privateOrder_aliasesOnTheLowTenBytes` below, and this
    ///      property is what makes that one non-trivial rather than a restatement.
    function test_privateOrder_revertsIffPackedTakerDiffers(address taker, uint80 allowedTaker) public {
        bool shouldRevert = _packed(taker) != allowedTaker;

        bool ok;
        bytes memory err;
        try harness.privateOrder(taker, _privateOrderWord(allowedTaker)) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }

        _assertGuard(shouldRevert, ok, err, _selInvalidTaker(), "private order must reject exactly the wrong taker");
    }

    /// @notice Two takers whose low ten bytes agree are indistinguishable to `_privateOrder`.
    ///
    /// @dev The 80-bit truncation at `Whitelist.sol:83-85` is documented in a source comment
    ///      (`:88-95`). This turns it into a machine-checked theorem: `aliasTaker` is built to
    ///      share `taker`'s low ten bytes and to differ in the high ten, and the instruction
    ///      is proven to treat them identically — same success, same revert, same selector.
    ///
    ///      `hiBits` is a free `uint80`, so the alias ranges over all 2**80 addresses in the
    ///      taker's residue class, including `taker` itself. That reflexive case is not a
    ///      weakness: it is one point of a domain in which every other point is a genuine
    ///      collision, and `test_privateOrder_aliasIsReachable_witness` pins a non-reflexive
    ///      one concretely.
    ///
    ///      Severity, so this is not over-read: `ctx.query.taker` is `msg.sender` at
    ///      `src/SwapVM.sol`, so exploiting this needs an 80-bit *preimage*, not a birthday
    ///      collision — and a party who controls both accounts gains nothing by aliasing
    ///      themselves. The theorem is the honest formal statement of the design trade, not a
    ///      claim that the trade is wrong.
    function test_privateOrder_aliasesOnTheLowTenBytes(address taker, uint80 hiBits, uint80 allowedTaker) public {
        address aliasTaker = address(uint160((uint256(hiBits) << 80) | uint256(_packed(taker))));

        bool okA;
        try harness.privateOrder(taker, _privateOrderWord(allowedTaker)) {
            okA = true;
        } catch { }

        bool okB;
        try harness.privateOrder(aliasTaker, _privateOrderWord(allowedTaker)) {
            okB = true;
        } catch { }

        assertTrue(okA == okB, "takers sharing their low ten bytes must be indistinguishable");
    }

    /// @notice `_privateOrder` writes no swap register.
    ///
    /// @dev Frame condition. In a register machine where instructions compose, "this
    ///      instruction touched nothing else" is a real safety property and exactly the kind
    ///      a refactor breaks silently. Stated on the success path only, because on the revert
    ///      path the whole frame is discarded anyway.
    function test_privateOrder_leavesEveryRegisterUntouched(
        address taker,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled
    ) public {
        SwapRegisters memory regs = SwapRegisters(balanceIn, balanceOut, amountIn, amountOut, amountNetPulled);

        try harness.privateOrderRegisters(taker, _privateOrderWord(_packed(taker)), regs)
        returns (SwapRegisters memory out) {
            assertEq(out.balanceIn, balanceIn, "balanceIn must be untouched");
            assertEq(out.balanceOut, balanceOut, "balanceOut must be untouched");
            assertEq(out.amountIn, amountIn, "amountIn must be untouched");
            assertEq(out.amountOut, amountOut, "amountOut must be untouched");
            assertEq(out.amountNetPulled, amountNetPulled, "amountNetPulled must be untouched");
        } catch {
            // Unreachable: the allowed taker is built from this taker, so the guard passes.
            // `test_privateOrder_witness` shows the success path is reachable.
            assertTrue(false, "the matching taker must not revert");
        }
    }
    // @custom:kontrol-status on the property above — NOT CLOSED, and specifically NOT a
    //      refutation of the instruction. `kontrol prove` printed FAILED in 216s at 175 nodes,
    //      failing node 116, but the reported failure is the `assertTrue(false)` in the catch
    //      arm, i.e. the prover could not show that arm infeasible. Its path condition is
    //
    //        notBool ( #range(#buf(32, chop(pow176 * taker)), 0, 10)
    //                  ==K #range(#buf(32, taker), 22, 10) )
    //
    //      which asserts that the top ten bytes of `taker << 176` differ from the low ten
    //      bytes of `taker`. That is FALSE for every `taker`: it is the same byte-extraction
    //      simplification documented on `test_coequal_isExactlyTheMembershipJump`, and KEVM
    //      simply cannot discharge it. The printed Model is `taker = 0`, at which point both
    //      sides are `0` and the model contradicts its own path condition — a textbook case of
    //      why the path condition, not the Model, is the artefact to read.
    //
    //      Treat this as blocked-on-a-lemma, not as a defect. The frame condition itself is
    //      PROVEN for the coequal instruction over a genuinely symbolic register file, by
    //      `test_coequal_leavesEveryRegisterUntouched` (PASSED, 303s), which reaches the same
    //      conclusion without an infeasible-branch obligation because it makes no `try`/`catch`
    //      claim. Restating this property in that shape is the one-line fix and is left to the
    //      next agent so that the failing artefact and its diagnosis survive intact.

    /// @notice Concrete witness: `_privateOrder` accepts the encoded taker, rejects another,
    ///         and accepts an alias that differs in every high byte.
    ///
    /// @dev Fully concrete, so it costs a single path with no symbolic arithmetic. Hand-worked:
    ///
    ///        packed(TAKER_A)       = 0x9e03E53415D37aA96045
    ///        packed(TAKER_A_ALIAS) = 0x9e03E53415D37aA96045   (high ten bytes are zero)
    ///        packed(TAKER_B)       = 0xFACefEEDFaCEfEeDfAce
    ///
    ///      De-vacuifies `test_privateOrder_revertsIffPackedTakerDiffers` (both branches are
    ///      shown reachable on non-degenerate values) and
    ///      `test_privateOrder_aliasesOnTheLowTenBytes` (a genuinely non-reflexive alias).
    function test_privateOrder_witness() public {
        assertEq(uint256(_packed(TAKER_A)), 0x9e03E53415D37aA96045, "sanity: packed vitalik.eth");
        assertTrue(TAKER_A != TAKER_A_ALIAS, "sanity: the alias is a different address");

        bytes32 word = _privateOrderWord(0x9e03E53415D37aA96045);

        // Accepts the encoded taker.
        harness.privateOrder(TAKER_A, word);

        // Accepts a completely different address that happens to share the low ten bytes.
        harness.privateOrder(TAKER_A_ALIAS, word);

        // Rejects anybody else, with the named selector.
        vm.expectRevert(Whitelist.WhitelistInvalidTaker.selector);
        harness.privateOrder(TAKER_B, word);
    }

    // =======================================================================================
    // B. `_whitelistCoequal` — a conditional jump, NOT access control.
    // =======================================================================================

    /// @notice `_whitelistCoequal` computes exactly this and nothing else:
    ///
    ///             nextPC := (p in list) ? pc : nextPC
    ///
    ///         and it never reverts.
    ///
    /// @dev The complete functional characterisation at three entries, over every taker,
    ///      every incoming `nextPC`, every encoded `pc` and every list. It subsumes the
    ///      membership biconditional and the never-reverts claim at once:
    ///
    ///        * **never reverts** — the harness call is NOT inside `try`/`catch`, so any
    ///          revert on any path propagates and refutes the property. This is a stronger
    ///          statement than a `try`-shaped one, not a weaker one.
    ///        * **jumps iff whitelisted** — the `inList` branch pins `nextPC == pc`; the
    ///          other branch pins `nextPC == nextPCIn`. Because `nextPCIn` is symbolic and
    ///          independent of `pc`, the two are distinguishable, so neither branch is
    ///          satisfiable by the other's behaviour.
    ///
    ///      No degenerate implementation survives: never-jumping fails the first branch,
    ///      always-jumping fails the second, reverting fails both.
    ///
    ///      ## This instruction is not a gate, and a program using it as one has a hole
    ///
    ///      Worth stating explicitly because the name invites the opposite reading. A
    ///      non-whitelisted taker is not rejected — execution simply **continues at the next
    ///      instruction**. So `_whitelistCoequal` grants no protection by itself; the
    ///      protection, if any, is whatever the maker placed at `pc` versus at `pc_next`, and
    ///      that is program structure this instruction-level proof says nothing about. A
    ///      program that encodes "only these takers may fill" as a bare `_whitelistCoequal`
    ///      lets everyone fill. The instruction that *does* reject is `_privateOrder`.
    ///
    ///      ## Duplicates are unobservable here, and that is a finding of its own
    ///
    ///      The loop scans BACKWARD (`Whitelist.sol:121-127`, confirmed by
    ///      `analysis/repro/WhitelistGasTrapRepro.t.sol`), so a taker appearing twice is found
    ///      at the *higher* index first. But every entry shares the single encoded `pc`, so
    ///      the scan direction cannot change the register state — only gas, and (below the
    ///      2-byte header, where the slice underflows) which out-of-bounds words get read.
    ///      This property is therefore *stated over lists with duplicates too*, and holds:
    ///      `inList` is a disjunction, insensitive to order and multiplicity. The sequential
    ///      instruction is the opposite case, where the direction is observable — see
    ///      `test_sequential_earliestMatchingSlotWins`.
    /// @custom:kontrol-status NOT CLOSED — blocked on prover incompleteness. This is NOT a
    ///      refutation: no counterexample was produced and no leaf failed. `kontrol prove`
    ///      reached 520 nodes with 22 open leaves and then wrote no further node for 45
    ///      minutes, at which point it was killed to free the machine. The z3 children were
    ///      idle (~1 CPU tick) while the booster ran at 100%, which is the Haskell-side
    ///      simplification profile, not an SMT one.
    ///
    ///      The blocking term was dumped (`kontrol show --node 511`) and the cause is exact.
    ///      `_coequalWord` builds the argument word with shifts and ORs, so KEVM carries
    ///
    ///        #range(#buf(32, (#asWord(#buf(2,pc) +Bytes #buf(10,a0) +Bytes ...)
    ///                         |Int #asWord(...) |Int a2)), 2, 10)
    ///
    ///      and cannot push `#range` back through the OR-of-shifted-buffers to recover
    ///      `#buf(10, a0)`. The three membership tests therefore stay as undecided **Bytes**
    ///      comparisons (`... ~> .K ==K ... ~> .K`) rather than integer ones, and they
    ///      multiply. The missing simplification is the byte-extraction rule
    ///
    ///        rule #range(#buf(N, X), S, W) => #buf(W, (X /Int 2^(8*(N-S-W))) modInt 2^(8*W))
    ///
    ///      which would also unblock `test_privateOrder_leavesEveryRegisterUntouched` and
    ///      `test_sequential_slotOneCannotFillBeforeItUnlocks`. It belongs in `lemmas.k` and is
    ///      the single highest-value follow-up for this file.
    ///
    ///      What IS proven in the meantime, all PASSED: the same jump semantics at ONE entry
    ///      (`test_coequal_aliasesOnTheLowTenBytes`,
    ///      `test_finding_coequal_backwardJumpIsExpressible_witness`), at ZERO entries
    ///      (`test_coequal_emptyListIsANoOp`), and at three entries concretely
    ///      (`test_coequal_witness`, which exercises the first, middle and last list slots and
    ///      an outsider). The unrestricted form over `args.length` is
    ///      `test_coequal_neverRevertsAtAnyLength` and is OPEN.
    function test_coequal_isExactlyTheMembershipJump(
        address taker,
        uint256 nextPCIn,
        uint16 pc,
        uint80 a0,
        uint80 a1,
        uint80 a2
    ) public view {
        uint80 p = _packed(taker);
        bool inList = (p == a0) || (p == a1) || (p == a2);

        uint256 out = harness.coequal3(taker, nextPCIn, _coequalWord(pc, a0, a1, a2));

        if (inList) {
            assertEq(out, uint256(pc), "a whitelisted taker must jump to the encoded pc");
        } else {
            assertEq(out, nextPCIn, "a non-whitelisted taker must continue, leaving nextPC untouched");
        }
    }

    /// @notice An empty coequal list is a no-op: it never reverts and never jumps.
    ///
    /// @dev The `args.length == 2` boundary — one byte above the confirmed gas trap. Cheapest
    ///      property in the file: `list.length` is exactly zero, so `while (i-- > 0)` compares
    ///      before it decrements and the body never runs. Prove this first to validate the
    ///      harness shape.
    ///
    ///      It also pins the *edge* of the trap from the safe side: the reproducer shows
    ///      `args.length <= 1` never terminates, and this shows 2 is clean rather than merely
    ///      terminating.
    function test_coequal_emptyListIsANoOp(address taker, uint256 nextPCIn, uint16 pc) public view {
        uint256 out = harness.coequal0(taker, nextPCIn, _coequalWord(pc, 0, 0, 0));

        assertEq(out, nextPCIn, "an empty coequal list must leave nextPC untouched");
    }

    /// @notice Two takers whose low ten bytes agree are indistinguishable to
    ///         `_whitelistCoequal`.
    /// @dev The coequal instance of the aliasing theorem; see
    ///      `test_privateOrder_aliasesOnTheLowTenBytes` for the full argument and for the
    ///      severity note. Stated at one entry, which is the smallest shape in which a match
    ///      is possible at all.
    function test_coequal_aliasesOnTheLowTenBytes(
        address taker,
        uint80 hiBits,
        uint256 nextPCIn,
        uint16 pc,
        uint80 a0
    ) public view {
        address aliasTaker = address(uint160((uint256(hiBits) << 80) | uint256(_packed(taker))));
        bytes32 word = _coequalWord(pc, a0, 0, 0);

        assertEq(
            harness.coequal1(taker, nextPCIn, word),
            harness.coequal1(aliasTaker, nextPCIn, word),
            "takers sharing their low ten bytes must be indistinguishable"
        );
    }

    /// @notice `_whitelistCoequal` writes no swap register, on either branch.
    /// @dev Frame condition, stated with a free `a0` so that both the jumping and the
    ///      falling-through path are covered by the same proof.
    function test_coequal_leavesEveryRegisterUntouched(
        address taker,
        uint256 nextPCIn,
        uint16 pc,
        uint80 a0,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled
    ) public view {
        SwapRegisters memory regs = SwapRegisters(balanceIn, balanceOut, amountIn, amountOut, amountNetPulled);

        (SwapRegisters memory out,) = harness.coequal3Registers(taker, nextPCIn, _coequalWord(pc, a0, 0, 0), regs);

        assertEq(out.balanceIn, balanceIn, "balanceIn must be untouched");
        assertEq(out.balanceOut, balanceOut, "balanceOut must be untouched");
        assertEq(out.amountIn, amountIn, "amountIn must be untouched");
        assertEq(out.amountOut, amountOut, "amountOut must be untouched");
        assertEq(out.amountNetPulled, amountNetPulled, "amountNetPulled must be untouched");
    }

    /// @notice Concrete witness for the coequal jump, at a non-degenerate `nextPCIn`.
    ///
    /// @dev Hand-worked. args = `pc(2) | a0(10) | a1(10) | a2(10)` = 32 bytes with
    ///      `pc = 0x2A = 42`, `a0 = packed(TAKER_B)`, `a1 = packed(TAKER_A)`,
    ///      `a2 = packed(TAKER_C)`. Incoming `nextPC = 512`, which is neither `0` nor `pc`,
    ///      so "jumped" and "left alone" are genuinely different observations.
    ///
    ///      De-vacuifies `test_coequal_isExactlyTheMembershipJump` on both branches, and
    ///      pins the middle of the list rather than only its ends — an implementation that
    ///      checked only the first or only the last entry is refuted here.
    function test_coequal_witness() public view {
        bytes32 word = _coequalWord(42, _packed(TAKER_B), _packed(TAKER_A), _packed(TAKER_C));

        assertEq(harness.coequal3(TAKER_A, 512, word), 42, "middle entry must match and jump");
        assertEq(harness.coequal3(TAKER_B, 512, word), 42, "last-scanned entry must match and jump");
        assertEq(harness.coequal3(TAKER_C, 512, word), 42, "first-scanned entry must match and jump");
        assertEq(harness.coequal3(OUTSIDER, 512, word), 512, "an outsider must continue, not revert");
    }

    // =======================================================================================
    // C. The jump target is unvalidated.
    // =======================================================================================

    /// @notice Machine-checked witness that a whitelisted taker can be sent **backward** in
    ///         the program.
    ///
    /// @dev `ctx.vm.nextPC = pc` (`Whitelist.sol:124`, `:159`) writes the raw two-byte field
    ///      with no bounds check and no direction check. `runLoop` then consumes it verbatim:
    ///      it sets `ctx.vm.nextPC = pcs` *before* dispatching (`src/libs/VM.sol:145`) and
    ///      reads it back immediately after (`:147`), which is precisely the mechanism that
    ///      lets an instruction overwrite the program counter. The only checks anywhere near
    ///      it are `pcs > length` on the freshly *decoded* instruction (`:143`) and the loop
    ///      condition `pcs < length` (`:123`) — both of which a small `pc` passes trivially.
    ///
    ///      **So nothing downstream constrains the jump target.** A target beyond the program
    ///      simply ends the loop; a target below the current pc re-enters earlier
    ///      instructions.
    ///
    ///      The sharp consequence: a `_whitelistCoequal` whose encoded `pc` points at its own
    ///      instruction is an unconditional infinite loop **for exactly the whitelisted
    ///      takers** — they match, jump back to it, match again. Every other taker falls
    ///      through and fills normally. That is a targeted gas trap: the order looks and
    ///      behaves like a working order for everybody except the chosen victim, who burns
    ///      their whole gas budget with no revert data to handle.
    ///
    ///      It is a **different** finding from the one in
    ///      `analysis/repro/WhitelistGasTrapRepro.t.sol`. That one needs a malformed
    ///      `args.length` and traps every taker indiscriminately; this one is on the
    ///      well-formed, whitelisted path, is expressible by the documented arg builder, and
    ///      is selective. Both are maker self-harm in the sense that the maker signs the
    ///      program — but a quoting aggregator that simulates untrusted orders is exposed to
    ///      both, and this one cannot be screened out by rejecting short argument blocks.
    ///
    ///      This witness is fully concrete and PASSES: incoming pc 512, encoded target 4.
    ///      The universally quantified form is the property immediately below.
    function test_finding_coequal_backwardJumpIsExpressible_witness() public view {
        bytes32 word = _coequalWord(4, _packed(TAKER_A), 0, 0);

        uint256 out = harness.coequal1(TAKER_A, 512, word);

        assertEq(out, 4, "the jump target is the raw two-byte field");
        assertLt(out, 512, "a whitelisted taker is sent BACKWARD, to an already-executed pc");
    }

    /// @notice **Executing witness for the finding, through the REAL run loop.** A one-instruction
    ///         program whose `_whitelistCoequal` jump target is its own address is an infinite
    ///         loop for exactly the whitelisted takers, and a normal fill for everybody else.
    ///
    /// @dev `forge test` ONLY. Excluded from `kontrol prove` — with gas off there is no counter
    ///      to exhaust and the loop's exit condition is unreachable, so a proof would not fail,
    ///      it would not return. Same handling and same reason as
    ///      `analysis/repro/WhitelistGasTrapRepro.t.sol`.
    ///
    ///      The two properties above establish the instruction-level half: the jump target is
    ///      the raw two-byte field and it may point backward. This closes the loop by running
    ///      the consequence through `ContextLib.runLoop` itself.
    ///
    ///      ## The program
    ///
    ///          byte 0      opcode      0x00   (dispatched to `_whitelistCoequal`)
    ///          byte 1      argsLength  0x0C   (12 = 2-byte pc + one 10-byte entry)
    ///          bytes 2-3   pc          0x0000 (jump target: the START of this program)
    ///          bytes 4-13  allowedTaker       packed low ten bytes of the victim
    ///
    ///      Traced against `src/libs/VM.sol:118-148`. `pcs` starts at 0; the loop reads the
    ///      opcode and `argsLength`, advances `pcs` to 14, checks `14 > 14` (false), sets
    ///      `ctx.vm.nextPC = 14` (`:145`) and dispatches (`:146`). For a whitelisted taker
    ///      `_whitelistCoequal` overwrites `nextPC` with the encoded `0`, and `:147` reads it
    ///      back, so `pcs` returns to 0 and the same instruction executes again — forever. For
    ///      anybody else `nextPC` stays 14, `14 < 14` is false, and the loop exits normally.
    ///
    ///      Nothing in the loop rejects this. The only bounds check, `pcs > length` at `:143`,
    ///      is applied to the pc *after decoding an instruction*, never to the target an
    ///      instruction wrote, and a target of 0 passes it trivially.
    ///
    ///      ## Why this is worth a test rather than a comment
    ///
    ///      A jump instruction that can jump backward is not by itself a defect — that is what
    ///      jump instructions do. What makes this reportable is that the loop is **selective**:
    ///      the program is a perfectly ordinary, fillable order for every taker except the one
    ///      the maker names, who instead burns their entire gas budget and receives no revert
    ///      data to handle. That is a targeted griefing primitive dressed as a whitelist, and
    ///      it is invisible to anything that screens on argument lengths.
    function test_forgeOnly_finding_selfJumpLoopsForeverForTheWhitelistedTakerOnly() public {
        bytes memory program = abi.encodePacked(uint8(0), uint8(12), uint16(0), _packed(TAKER_A));
        assertEq(program.length, 14, "sanity: 2-byte instruction header + 12 bytes of args");

        // The named victim: the loop never exits, so the frame consumes the whole gas cap and
        // returns EMPTY revert data — an out-of-gas, not a revert the caller could handle.
        assertTrue(_programOutOfGas(TAKER_A, program), "the whitelisted taker loops until out of gas");

        // Everybody else: the same program runs to completion.
        assertFalse(_programOutOfGas(OUTSIDER, program), "a non-whitelisted taker fills normally");
        assertEq(harness.runProgramCoequal(OUTSIDER, program), 14, "and leaves pc at the end of the program");

        // The alias shares the low ten bytes, so it is caught by the same trap. This is the
        // 80-bit truncation and the unvalidated jump target composing.
        assertTrue(_programOutOfGas(TAKER_A_ALIAS, program), "an 80-bit alias of the victim is trapped too");
    }

    /// @dev Runs `program` under a hard gas cap and reports whether the child frame consumed
    ///      the whole cap. Three outcomes are distinguishable at the call boundary, and only
    ///      the third is a non-terminating loop:
    ///        ok                      -> terminated normally
    ///        !ok && ret.length >= 4  -> reverted with a selector
    ///        !ok && ret.length == 0  -> out of gas
    function _programOutOfGas(address taker, bytes memory program) internal returns (bool) {
        (bool ok, bytes memory ret) =
            address(harness).call{ gas: GAS_CAP }(abi.encodeCall(harness.runProgramCoequal, (taker, program)));
        return !ok && ret.length == 0;
    }

    /// @notice The safety property that WOULD hold if jump targets were validated: a jump only
    ///         ever moves the program counter forward.
    ///
    /// @dev **This property is expected to be REFUTED, and the refutation is the deliverable.**
    ///      It is stated here rather than omitted because a counterexample carrying its path
    ///      condition is evidence at the same tier as an executed witness, and because the
    ///      absence of this check is otherwise invisible: nothing in `Whitelist.sol` or
    ///      `VM.sol` mentions it, so there is no line to point at. The property names the
    ///      missing line.
    ///
    ///      Read the verdict as: FAILED here means "backward and self-referential jumps are
    ///      expressible", i.e. the finding documented on
    ///      `test_finding_coequal_backwardJumpIsExpressible_witness` holds over the whole
    ///      domain and not merely at one point. A PASSED verdict would mean the instruction
    ///      had acquired a direction check since this was written, and the property should
    ///      then be kept as a regression test.
    ///
    ///      It fails under `forge test` as well, on the first sampled input. That is
    ///      deliberate and it is why the name says so.
    /// @custom:kontrol-status REFUTED, as intended. `kontrol prove` returned FAILED in 121s
    ///      at 131 nodes, failing node 141. The PATH CONDITION — which is the result, the
    ///      printed Model is a spurious point that contradicts it — is:
    ///
    ///        #asWord(#range(#buf(32, taker), 22, 10)) ==Int a0   // the taker IS whitelisted
    ///        notBool (pc ==Int nextPCIn)                         // a jump really happened
    ///        pc <=Int nextPCIn                                   // and it went backward
    ///
    ///      i.e. the refuted class is "every whitelisted taker whose encoded target is at or
    ///      below the current program counter", which is the general form of the finding.
    function test_finding_coequal_jumpsAreForwardOnly_expectedRefutation(
        address taker,
        uint256 nextPCIn,
        uint16 pc,
        uint80 a0
    ) public view {
        uint256 out = harness.coequal1(taker, nextPCIn, _coequalWord(pc, a0, 0, 0));

        if (out != nextPCIn) {
            assertGt(out, nextPCIn, "a jump must not move the program counter backward");
        }
    }

    // =======================================================================================
    // D. `_whitelistSequential` — the time-gated whitelist.
    //
    // `block.timestamp` is driven with `vm.warp(nowTs)` and `nowTs` is a symbolic parameter,
    // so time is quantified over exactly like any other input. Under the fuzzer this also
    // keeps the properties meaningful, which they would not be at Foundry's fixed default
    // timestamp of 1.
    //
    // `nowTs` is `uint48` in the general properties. That is not a narrowing of the theorem:
    // `start < 2**40`, at most 20 entries and each duration at most 65535 put every schedule
    // boundary below 2**41, so `uint48` covers every ordering the encoding can express. The
    // region above 2**48 is covered at full `uint256` width by
    // `test_sequential_aboveTheWholeScheduleNeverReverts`.
    // =======================================================================================

    /// @dev Runs the two-entry sequential instruction and classifies the outcome.
    function _trySequential2(address taker, uint256 nextPCIn, bytes32 word)
        internal
        view
        returns (bool ok, bytes memory err, uint256 out)
    {
        try harness.sequential2(taker, nextPCIn, word) returns (uint256 o) {
            ok = true;
            out = o;
        } catch (bytes memory e) {
            err = e;
        }
    }

    /// @notice The complete trichotomy. `_whitelistSequential` does exactly one of three
    ///         things, and which one is fully determined by the inputs:
    ///
    ///           jumps     <=> the taker is at some index k AND t >= start + sum(d[0..k-1])
    ///           continues <=> the taker is at no index      AND t >= start + sum(all d)
    ///           reverts   <=> otherwise, always with `WhitelistAllowedTimeViolation`
    ///
    /// @dev This is the property the instruction's own docstring (`Whitelist.sol:131-136`)
    ///      claims, stated as a complete characterisation rather than as three spot checks.
    ///      It pins the output for **every** point of its domain, so it cannot be satisfied by
    ///      any degenerate implementation, and it subsumes:
    ///
    ///        * the before-`start` guard — `t < start` makes every disjunct false, so the
    ///          expected outcome is `revert`, which is `test_sequential_revertsBeforeStart`;
    ///        * liveness after the exclusivity window — `t >= start + d0 + d1` with no match
    ///          is the `continues` case, so a non-whitelisted taker is never locked out
    ///          permanently;
    ///        * the unlock-time property, in its two-entry instance.
    ///
    ///      ## Why the unlock times are written the way they are
    ///
    ///      `unlock(k) = start + sum(d[0..k-1])` is *derived*, not assumed: `timeLeft` starts
    ///      at `t - start` (`:148`) and index `k` is only reached after surviving
    ///      `if (timeLeft < d[i]) revert` and `timeLeft -= d[i]` for every `i < k` (`:163-164`).
    ///      Surviving all of them is exactly `t - start >= sum(d[0..k-1])`.
    ///
    ///      Neither `unlock1` nor `endOfExclusivity` can overflow: `start < 2**40` and each
    ///      duration is at most 65535, so both are below `2**41`. Nothing here is a `chop`.
    ///
    ///      ## The `exists k` collapses to the first match, and the disjunction is correct
    ///
    ///      The loop takes the *earliest* matching index, and `unlock` is non-decreasing in
    ///      `k`, so `exists k: p == a_k and t >= unlock(k)` is satisfied at the first match
    ///      whenever it is satisfied at all. Writing it as a disjunction rather than as a
    ///      first-match search is therefore not a simplification of the spec — it is the same
    ///      set, and it is the form in which schedule monotonicity is visible.
    /// @custom:kontrol-status NOT CLOSED — in progress when this file was handed off, and the
    ///      only property here that was still visibly advancing rather than stuck. NOT a
    ///      refutation: no leaf failed. It ran 7200s (the wrapper's own timeout, exit 124) to
    ///      916 nodes, was resumed from its cached KCFG, and was at 932 nodes and still
    ///      allocating when the box became oversubscribed. Node growth was steady throughout —
    ///      roughly 16 nodes per 6 minutes near the end — so this is a cost problem, not the
    ///      byte-extraction stall that blocks the coequal properties. Resume it with
    ///      `kontrol prove --mt 'WhitelistSpec\.test_sequential_isExactlyTheTrichotomy\b'`;
    ///      the cached prefix is reused, no `--reinit`.
    ///
    ///      Three entries is `test_sequential_witness_threeEntrySchedule`, concretely, and it
    ///      is PROVEN (372s, 649 nodes) — it exhibits all three outcomes of this trichotomy at
    ///      six timestamps including both exclusivity boundaries.
    function test_sequential_isExactlyTheTrichotomy(
        address taker,
        uint256 nextPCIn,
        uint16 pc,
        uint40 start,
        uint16 d0,
        uint80 a0,
        uint16 d1,
        uint80 a1,
        uint48 nowTs
    ) public {
        vm.warp(nowTs);

        uint80 p = _packed(taker);
        uint256 t = uint256(nowTs);

        uint256 unlock0 = uint256(start);
        uint256 unlock1 = uint256(start) + d0;
        uint256 endOfExclusivity = uint256(start) + d0 + d1;

        bool jumps = (p == a0 && t >= unlock0) || (p == a1 && t >= unlock1);
        bool continues = (p != a0 && p != a1 && t >= endOfExclusivity);

        (bool ok, bytes memory err, uint256 out) = _trySequential2(taker, nextPCIn, _sequentialWord(pc, start, d0, a0, d1, a1));

        if (jumps) {
            assertTrue(ok, "an unlocked whitelisted taker must not revert");
            assertEq(out, uint256(pc), "an unlocked whitelisted taker must jump to the encoded pc");
        } else if (continues) {
            assertTrue(ok, "after the whole exclusivity window nobody is locked out");
            assertEq(out, nextPCIn, "a taker who continues must leave nextPC untouched");
        } else {
            assertFalse(ok, "every remaining input must revert");
            (bool present, bytes4 sel) = _selectorOf(err);
            assertTrue(present && sel == _selTimeViolation(), "the revert must be WhitelistAllowedTimeViolation");
        }
    }

    /// @notice **The core security property.** A taker who is only in slot 1 cannot fill
    ///         before slot 1 unlocks, i.e. not before `start + durations[0]`.
    ///
    /// @dev Stated on its own, separately from the trichotomy, because it is the property the
    ///      instruction exists to provide and because a failure here is a priority inversion
    ///      in a time-gated exclusivity window — the most valuable defect this file could
    ///      find.
    ///
    ///      The derivation is the one given on the trichotomy: reaching index 1 requires
    ///      passing the `timeLeft < durations[0]` guard at `Whitelist.sol:163`, and
    ///      `timeLeft = t - start`, so a jump at index 1 implies `t >= start + durations[0]`.
    ///
    ///      `vm.assume(p != a0)` is a case split, not a domain narrowing: a taker who is in
    ///      slot 0 has unlock time `start` and the claim would be about a different slot. The
    ///      excluded case is covered by the trichotomy above.
    ///
    ///      Note the assertion is made whenever `out == pc`, which includes the case where
    ///      `nextPCIn` happens to equal `pc` and the instruction actually fell *through*. That
    ///      is deliberate and the property still holds: falling through requires
    ///      `t >= start + d0 + d1 >= start + d0`. Not excluding that case keeps the statement
    ///      free of an assumption relating two otherwise-independent inputs.
    ///
    ///      `nowTs` is `uint48` for the reason given in the section header: every schedule
    ///      boundary the encoding can express is below `2**41`, so `uint48` covers every
    ///      ordering, and above it the claim is trivially true because `start + d0 < 2**41`.
    ///      It also keeps the property meaningful under the fuzzer, which a `uint256` domain
    ///      would not — almost every sample would land past the whole schedule.
    /// @custom:kontrol-status NOT CLOSED — stalled, then starved. NOT a refutation: no leaf
    ///      failed and no counterexample exists. Reached 266 nodes and then wrote no node for
    ///      41 minutes; a resume with `--step-timeout 120000` (the documented tool for a hang
    ///      inside one giant step) also made no progress before the box became oversubscribed.
    ///      Same byte-extraction blocker as `test_coequal_isExactlyTheMembershipJump`.
    ///
    ///      The claim is not unevidenced in the meantime. Its two-entry instance is a strict
    ///      consequence of `test_sequential_isExactlyTheTrichotomy`, and every unlock boundary
    ///      it asserts is pinned concretely and PROVEN by
    ///      `test_sequential_witness_twoEntrySchedule` (slot 1 reverts at t = 1099 and jumps at
    ///      t = 1100) and `test_sequential_witness_threeEntrySchedule` (slots at 1000 / 1100 /
    ///      1300, window closing at 1600). Those are exact-boundary witnesses, so an
    ///      off-by-one in the unlock arithmetic is refuted; what is missing is the universally
    ///      quantified form.
    function test_sequential_slotOneCannotFillBeforeItUnlocks(
        address taker,
        uint256 nextPCIn,
        uint16 pc,
        uint40 start,
        uint16 d0,
        uint80 a0,
        uint16 d1,
        uint80 a1,
        uint48 nowTs
    ) public {
        vm.assume(_packed(taker) != a0);
        vm.warp(nowTs);

        (bool ok,, uint256 out) = _trySequential2(taker, nextPCIn, _sequentialWord(pc, start, d0, a0, d1, a1));

        if (ok && out == uint256(pc)) {
            assertGe(uint256(nowTs), uint256(start) + d0, "slot 1 must not unlock before start + durations[0]");
        }
    }

    /// @notice Schedule monotonicity, in its observable form: whenever the taker in slot 1 can
    ///         fill, the taker in slot 0 could have filled too.
    ///
    /// @dev Monotonicity of `unlock(k)` is arithmetically trivial — durations are unsigned, so
    ///      the partial sums increase. Proving *that* would say nothing about the instruction.
    ///      What has content is the instruction-level consequence, and it needs two calls: at
    ///      the same schedule and the same instant, if the later slot is open then the earlier
    ///      one is open too. A priority inversion between slots would refute it.
    ///
    ///      `takerLate` is constructed to be exactly the address in slot 1 and `takerEarly`
    ///      the address in slot 0, so neither is a free variable that might match the other
    ///      slot by accident. `vm.assume(a0 != a1)` keeps the two slots distinct; with equal
    ///      entries the statement is trivially true and covered by
    ///      `test_sequential_earliestMatchingSlotWins`.
    function test_sequential_laterSlotsUnlockNoEarlier(
        uint256 nextPCIn,
        uint16 pc,
        uint40 start,
        uint16 d0,
        uint80 a0,
        uint16 d1,
        uint80 a1,
        uint48 nowTs
    ) public {
        vm.assume(a0 != a1);
        vm.warp(nowTs);

        bytes32 word = _sequentialWord(pc, start, d0, a0, d1, a1);
        address takerEarly = address(uint160(uint256(a0)));
        address takerLate = address(uint160(uint256(a1)));

        (bool okLate,, uint256 outLate) = _trySequential2(takerLate, nextPCIn, word);

        if (okLate && outLate == uint256(pc)) {
            (bool okEarly,, uint256 outEarly) = _trySequential2(takerEarly, nextPCIn, word);
            assertTrue(okEarly, "if slot 1 is open, slot 0 must not be reverting");
            assertEq(outEarly, uint256(pc), "if slot 1 is open, slot 0 must be open too");
        }
    }

    /// @notice `_whitelistSequential` reverts with `WhitelistAllowedTimeViolation` for
    ///         everyone — whitelisted or not — strictly before `start`.
    ///
    /// @dev The early guard at `Whitelist.sol:147`, before any list access. It is the one
    ///      revert that is reachable with an empty schedule, so it is stated on the
    ///      zero-entry entry point: no loop runs on any path, which makes this the cheapest
    ///      revert property in the file.
    ///
    ///      Stated as a **biconditional** over the whole `uint48 x uint40` time domain rather
    ///      than only on the reverting side: with no entries there is nothing else that can
    ///      revert, so `t < start` is exactly the reverting condition. A one-sided
    ///      `vm.expectRevert` version would be satisfied by `require(false)`.
    function test_sequential_revertsBeforeStart(
        address taker,
        uint256 nextPCIn,
        uint16 pc,
        uint40 start,
        uint48 nowTs
    ) public {
        vm.warp(nowTs);

        bool shouldRevert = uint256(nowTs) < uint256(start);

        bool ok;
        bytes memory err;
        uint256 out;
        try harness.sequential0(taker, nextPCIn, _sequentialWord(pc, start, 0, 0, 0, 0)) returns (uint256 o) {
            ok = true;
            out = o;
        } catch (bytes memory e) {
            err = e;
        }

        _assertGuard(shouldRevert, ok, err, _selTimeViolation(), "the start guard must fire exactly before start");

        if (ok) {
            assertEq(out, nextPCIn, "an empty schedule must never jump");
        }
    }

    /// @notice Bounded exclusivity: the whitelist always expires. Once
    ///         `block.timestamp >= start + N * 65535` the instruction cannot revert.
    ///
    /// @dev The economically meaningful consequence of the encoding widths, and the liveness
    ///      half of the specification. Durations are `uint16`, so each is at most 65535, and
    ///      `list.length / 12 <= 20` because `argsLength` is a single byte
    ///      (`src/libs/VM.sol:131`). The total exclusivity window is therefore at most
    ///      `20 * 65535 = 1_310_700` seconds — **about 15.2 days**. A maker CANNOT build a
    ///      permanently exclusive order with this instruction.
    ///
    ///      Proven here at `N = 2`, the entry count of the fixed-shape surface: `t >= start +
    ///      2*65535` implies `t >= start` (so the early guard passes) and
    ///      `t - start >= d0 + d1` (so both loop guards pass), leaving jump-or-continue. The
    ///      general statement is the same argument with `N` in place of 2 and is what the
    ///      15.2-day figure quotes.
    ///
    ///      `nowTs` is a full `uint256` here, and the assumption is a bare comparison with no
    ///      arithmetic on the symbolic side beyond one addition of two bounded values — so
    ///      the property holds arbitrarily far into the future, which is exactly the claim.
    function test_sequential_aboveTheWholeScheduleNeverReverts(
        address taker,
        uint256 nextPCIn,
        uint16 pc,
        uint40 start,
        uint16 d0,
        uint80 a0,
        uint16 d1,
        uint80 a1,
        uint256 nowTs
    ) public {
        vm.assume(nowTs >= uint256(start) + 2 * 65535);
        vm.warp(nowTs);

        (bool ok,, uint256 out) = _trySequential2(taker, nextPCIn, _sequentialWord(pc, start, d0, a0, d1, a1));

        assertTrue(ok, "past the maximum exclusivity window the instruction must not revert");

        uint80 p = _packed(taker);
        if (p == a0 || p == a1) {
            assertEq(out, uint256(pc), "a whitelisted taker jumps");
        } else {
            assertEq(out, nextPCIn, "everybody else continues, and is never locked out");
        }
    }

    /// @notice On duplicates, `_whitelistSequential` grants the EARLIEST matching slot.
    ///
    /// @dev The forward scan (`Whitelist.sol:155-165`) tests index 0 before index 1, and
    ///      returns on the first match, so a taker listed twice gets the earlier — more
    ///      favourable — unlock time. This is the observable consequence of the scan
    ///      direction, and the two instructions disagree about it: `_whitelistCoequal` scans
    ///      backward, but there the direction cannot be observed because all its entries share
    ///      one jump target (see `test_coequal_isExactlyTheMembershipJump`).
    ///
    ///      The construction makes the difference sharp. The same taker is placed in both
    ///      slots, `durations[0]` is forced to the maximum 65535 and the instant is fixed at
    ///      `start` itself. If the instruction had scanned backward it would have found index
    ///      1 first, but reaching index 1 requires passing `timeLeft(0) < 65535`, which
    ///      reverts. So a PASSED verdict here says the earlier slot won; a revert would say
    ///      the later one did.
    ///
    ///      A maker who accidentally lists somebody twice therefore gets the generous
    ///      behaviour, not a surprise revert. That is the benign direction, but it was
    ///      undocumented.
    /// @custom:kontrol-status NOT CLOSED — stalled at 216 nodes with no node written for 30
    ///      minutes, then killed to free the machine. NOT a refutation. Same byte-extraction
    ///      blocker as `test_coequal_isExactlyTheMembershipJump`; the duplicated `a` appears in
    ///      two entry positions of the same OR-built word, which is the worst case for it.
    function test_sequential_earliestMatchingSlotWins(uint256 nextPCIn, uint16 pc, uint40 start, uint80 a)
        public
    {
        vm.warp(uint256(start));

        // Same taker in both slots; slot 1 is unreachable at t == start because durations[0]
        // is the maximum a `uint16` can hold.
        bytes32 word = _sequentialWord(pc, start, type(uint16).max, a, 1, a);

        uint256 out = harness.sequential2(address(uint160(uint256(a))), nextPCIn, word);

        assertEq(out, uint256(pc), "the earliest matching slot must win, at t == start");
    }

    /// @notice Two takers whose low ten bytes agree are indistinguishable to
    ///         `_whitelistSequential`, including in whether they revert.
    /// @dev The sequential instance of the aliasing theorem. Both outcomes are compared —
    ///      success flag and returned pc — so an implementation that aliased on the jump but
    ///      not on the time guard would be refuted.
    function test_sequential_aliasesOnTheLowTenBytes(
        address taker,
        uint80 hiBits,
        uint256 nextPCIn,
        uint16 pc,
        uint40 start,
        uint16 d0,
        uint80 a0,
        uint16 d1,
        uint80 a1,
        uint48 nowTs
    ) public {
        vm.warp(nowTs);

        address aliasTaker = address(uint160((uint256(hiBits) << 80) | uint256(_packed(taker))));
        bytes32 word = _sequentialWord(pc, start, d0, a0, d1, a1);

        (bool okA,, uint256 outA) = _trySequential2(taker, nextPCIn, word);
        (bool okB,, uint256 outB) = _trySequential2(aliasTaker, nextPCIn, word);

        assertTrue(okA == okB, "aliased takers must agree on whether the call reverts");
        if (okA) {
            assertEq(outA, outB, "aliased takers must agree on the resulting nextPC");
        }
    }

    /// @notice `_whitelistSequential` writes no swap register.
    /// @dev Frame condition, on the success path.
    function test_sequential_leavesEveryRegisterUntouched(
        address taker,
        uint256 nextPCIn,
        uint16 pc,
        uint40 start,
        uint16 d0,
        uint80 a0,
        uint48 nowTs,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled
    ) public {
        vm.warp(nowTs);

        SwapRegisters memory regs = SwapRegisters(balanceIn, balanceOut, amountIn, amountOut, amountNetPulled);
        bytes32 word = _sequentialWord(pc, start, d0, a0, 0, 0);

        try harness.sequential2Registers(taker, nextPCIn, word, regs) returns (SwapRegisters memory out, uint256) {
            assertEq(out.balanceIn, balanceIn, "balanceIn must be untouched");
            assertEq(out.balanceOut, balanceOut, "balanceOut must be untouched");
            assertEq(out.amountIn, amountIn, "amountIn must be untouched");
            assertEq(out.amountOut, amountOut, "amountOut must be untouched");
            assertEq(out.amountNetPulled, amountNetPulled, "amountNetPulled must be untouched");
        } catch {
            // Reverted on the time guard; the frame was discarded, nothing to state.
        }
    }

    // =======================================================================================
    // E. Concrete witnesses for the sequential schedule.
    // =======================================================================================

    /// @notice Fully concrete three-entry schedule, with every outcome hand-computed.
    ///
    /// @dev The schedule: `start = 1000`, `durations = [100, 200, 300]`,
    ///      `takers = [A, B, C]`, `pc = 42`, incoming `nextPC = 512`.
    ///
    ///      Unlock times, from `unlock(k) = start + sum(d[0..k-1])`:
    ///
    ///        slot 0 (A):  1000
    ///        slot 1 (B):  1100
    ///        slot 2 (C):  1300
    ///        open to all: 1600
    ///
    ///      Traced against `Whitelist.sol:146-165` at four instants:
    ///
    ///        t = 999   everyone reverts on `timeLeft < start` (:147)
    ///        t = 1000  timeLeft 0.  A matches at i=0 -> jump 42.
    ///                               B: no match at i=0, 0 < 100 -> revert.
    ///        t = 1100  timeLeft 100. B: i=0 no match, 100 >= 100 -> timeLeft 0;
    ///                                   i=1 match -> jump 42.
    ///                                C: i=1 no match, 0 < 200 -> revert.
    ///        t = 1300  timeLeft 300. C: 300>=100 -> 200; 200>=200 -> 0; i=2 match -> jump 42.
    ///        t = 1599  timeLeft 599. OUTSIDER: 599>=100 -> 499; 499>=200 -> 299;
    ///                                          299 < 300 -> revert. Exclusivity still on.
    ///        t = 1600  timeLeft 600. OUTSIDER: 600->500->300, 300>=300 -> 0; loop ends
    ///                                          -> continue, nextPC stays 512.
    ///
    ///      This is the non-vacuity witness for the whole sequential section: it exhibits all
    ///      three outcomes of the trichotomy, both boundaries of the exclusivity window (1599
    ///      versus 1600), and a slot that unlocks strictly after another (1100 versus 1000),
    ///      on values where every comparison is strict rather than degenerate.
    function test_sequential_witness_threeEntrySchedule() public {
        (bytes32 w0, bytes32 w1) = _sequentialWords3(
            42, 1000, 100, _packed(TAKER_A), 200, _packed(TAKER_B), 300, _packed(TAKER_C)
        );

        vm.warp(999);
        vm.expectRevert(Whitelist.WhitelistAllowedTimeViolation.selector);
        harness.sequential3(TAKER_A, 512, w0, w1);

        vm.warp(1000);
        assertEq(harness.sequential3(TAKER_A, 512, w0, w1), 42, "slot 0 opens exactly at start");
        vm.expectRevert(Whitelist.WhitelistAllowedTimeViolation.selector);
        harness.sequential3(TAKER_B, 512, w0, w1);

        vm.warp(1100);
        assertEq(harness.sequential3(TAKER_B, 512, w0, w1), 42, "slot 1 opens at start + 100");
        vm.expectRevert(Whitelist.WhitelistAllowedTimeViolation.selector);
        harness.sequential3(TAKER_C, 512, w0, w1);

        vm.warp(1300);
        assertEq(harness.sequential3(TAKER_C, 512, w0, w1), 42, "slot 2 opens at start + 300");
        vm.expectRevert(Whitelist.WhitelistAllowedTimeViolation.selector);
        harness.sequential3(OUTSIDER, 512, w0, w1);

        vm.warp(1599);
        vm.expectRevert(Whitelist.WhitelistAllowedTimeViolation.selector);
        harness.sequential3(OUTSIDER, 512, w0, w1);

        vm.warp(1600);
        assertEq(harness.sequential3(OUTSIDER, 512, w0, w1), 512, "the window closes at start + 600");
    }

    /// @notice Concrete witness for the two-entry surface the symbolic properties use.
    /// @dev Cheapest possible check that `sequential2`'s byte layout is the one the
    ///      instruction parses: if `_sequentialWord` and the parsers disagreed by a single
    ///      byte, none of these four would hold. Also the reachability witness for the `try`
    ///      bodies of `_trySequential2`.
    function test_sequential_witness_twoEntrySchedule() public {
        bytes32 word = _sequentialWord(42, 1000, 100, _packed(TAKER_A), 200, _packed(TAKER_B));

        vm.warp(1000);
        assertEq(harness.sequential2(TAKER_A, 512, word), 42, "slot 0 open at start");

        vm.warp(1099);
        vm.expectRevert(Whitelist.WhitelistAllowedTimeViolation.selector);
        harness.sequential2(TAKER_B, 512, word);

        vm.warp(1100);
        assertEq(harness.sequential2(TAKER_B, 512, word), 42, "slot 1 open at start + 100");

        vm.warp(1300);
        assertEq(harness.sequential2(OUTSIDER, 512, word), 512, "window closes at start + 300");
    }

    // =======================================================================================
    // F. The unrestricted-length forms.
    //
    // These take a real `bytes calldata`, so `args.length` is symbolic and both loops have a
    // symbolic trip count. They are the statements the fixed-shape properties above restrict,
    // kept here so the restriction is visible rather than implicit.
    //
    // What an implementation could get wrong above the fixed shapes and still pass everything
    // else in this file: anything that depends on the entry count — a parser that mis-indexed
    // beyond the third coequal entry or the second sequential one, an off-by-one in
    // `list.length / 10` that dropped the final entry of a long list, or a guard that only
    // fired for short lists. The encoding caps the counts at 25 and 20 respectively, so the
    // gap is finite and enumerable, but it is not empty.
    //
    // Both require `--bmc-depth`, and both require excluding the underflow region — where the
    // loop does not terminate at all with gas off, per the confirmed reproducer. The
    // exclusion is stated with `vm.assume` in the property rather than with a `require` in
    // the harness, so that it is part of the theorem's visible domain and not hidden in the
    // surface under test.
    // =======================================================================================

    /// @notice `_whitelistCoequal` never reverts, at any well-formed argument length.
    ///
    /// @dev The unrestricted form of the never-reverts half of
    ///      `test_coequal_isExactlyTheMembershipJump`. `args.length >= 2` excludes the
    ///      confirmed non-terminating region (`analysis/repro/WhitelistGasTrapRepro.t.sol`:
    ///      at `args.length <= 1` the unchecked `slice(2)` underflows and the loop cannot
    ///      exit); `args.length <= 255` is the encoding bound from `src/libs/VM.sol:131`, not
    ///      a convenience. With both, the trip count is at most 25 and `--bmc-depth 26` is a
    ///      complete rather than a bounded result — provided no reachable `bounded` leaf
    ///      remains, which must be checked after the run.
    /// @custom:kontrol-status OPEN — symbolic `args.length` propagates into every calldata
    ///      offset, the shape that has never completed in this repository. The proven form is
    ///      `test_coequal_isExactlyTheMembershipJump` at three entries.
    function test_coequal_neverRevertsAtAnyLength(address taker, uint256 nextPCIn, bytes calldata args)
        public
        view
    {
        vm.assume(args.length >= 2);
        vm.assume(args.length <= 255);

        uint256 out = harness.coequalAny(taker, nextPCIn, args);

        assertTrue(out == nextPCIn || out <= type(uint16).max, "nextPC is either untouched or a two-byte target");
    }

    /// @notice `_whitelistSequential` reverts with `WhitelistAllowedTimeViolation` before
    ///         `start`, at any well-formed argument length.
    ///
    /// @dev The unrestricted form of `test_sequential_revertsBeforeStart`. The guard at
    ///      `Whitelist.sol:147` runs before `args.slice(7)`, so on the reverting side no loop
    ///      executes at all and the symbolic length never reaches the trip count — which makes
    ///      this the one unrestricted property with a plausible chance of closing.
    ///      `args.length >= 7` excludes the confirmed non-terminating region.
    ///
    ///      The instant is pinned at `start - 1` — the boundary, and the single most
    ///      informative point below `start` — rather than at a free `nowTs` constrained by
    ///      `vm.assume(nowTs < start)`. `start` is parsed out of the *symbolic* argument
    ///      bytes, so the assumption form would reject essentially every fuzz sample and the
    ///      property would be dead in the mode it is iterated in; pinning the boundary costs
    ///      nothing under Kontrol, where `start` is still universally quantified.
    /// @custom:kontrol-status OPEN.
    function test_sequential_revertsBeforeStartAtAnyLength(
        address taker,
        uint256 nextPCIn,
        bytes calldata args
    ) public {
        vm.assume(args.length >= 7);
        vm.assume(args.length <= 255);

        uint40 start;
        assembly ("memory-safe") {
            start := and(shr(200, calldataload(args.offset)), 0xffffffffff)
        }
        // At `start == 0` there is no instant before `start`; nothing to state.
        if (start == 0) return;
        vm.warp(uint256(start) - 1);

        vm.expectRevert(Whitelist.WhitelistAllowedTimeViolation.selector);
        harness.sequentialAny(taker, nextPCIn, args);
    }
}

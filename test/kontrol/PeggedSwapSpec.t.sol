// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { SwapRegisters } from "../../src/libs/VM.sol";
import { PeggedSwap, PeggedSwapArgsBuilder } from "../../src/instructions/PeggedSwap.sol";
import { PeggedSwapMath } from "../../src/libs/PeggedSwapMath.sol";
import { PeggedSwapHarness } from "./harnesses/PeggedSwapHarness.sol";

/// @notice Kontrol specification for the PeggedSwap instruction (opcode 0x58).
///
/// @dev Reference semantics, derived from `src/instructions/PeggedSwap.sol` and
///      `src/libs/PeggedSwapMath.sol`. The source is authoritative; the doc comments are
///      not — see `test/kontrol/analysis/FINDINGS.md`, "Documentation that contradicts the
///      code", and the notes at the end of this comment.
///
///      Args are a 160-byte packed record (`PeggedSwapArgsBuilder.Args`, five words):
///
///        x0 | y0 | linearWidth | rateLt | rateGt
///
///      `parse` (`:52-61`) applies four guards, in this order:
///
///        1. `data.length >= 160`              else `PeggedSwapInvalidArgsLength(length)`
///        2. `x0 > 0 && y0 > 0`                else `PeggedSwapInvalidInitialBalances(x0, y0)`
///        3. `linearWidth <= 5000e27`          else `PeggedSwapInvalidLinearWidth(lw)`
///        4. `rateLt > 0 && rateGt > 0`        else `PeggedSwapInvalidRates(rateLt, rateGt)`
///
///      then the instruction proper:
///
///        5. `(balanceIn | balanceOut) != 0`   else `PeggedSwapBothBalancesZero()`   (:104)
///        6. rate/normaliser selection by token address ordering (:76-78, :137-141):
///             tokenIn < tokenOut  ->  (rateIn, rateOut, x0_init, y0_init) = (rateLt, rateGt, x0, y0)
///             tokenIn > tokenOut  ->  (rateIn, rateOut, x0_init, y0_init) = (rateGt, rateLt, y0, x0)
///        7. `x0 = balanceIn * rateIn`, `y0 = balanceOut * rateOut`                  (:144-145)
///        8. `C = invariantFromReserves(x0, y0, x0_init, y0_init, A)`                (:148-154)
///             u = x0*ONE/x0_init, v = y0*ONE/y0_init, ONE = 1e27
///             C = isqrt(u*ONE) + isqrt(v*ONE) + A*(u+v)/ONE
///        9a. exact-in:  `require(amountOut == 0)` else `PeggedSwapRecomputeDetected()` (:157)
///        9b. exact-out: `require(amountIn  == 0)` else `PeggedSwapRecomputeDetected()` (:194)
///                       then `amountOut = min(amountOut, balanceOut)`                 (:196)
///                       and `amountIn == 0 && amountOut != 0  =>  amountIn = 1`        (:218-220)
///
///      THREE FACTS THAT SHAPE THIS FILE, all from `analysis/FINDINGS.md`:
///
///      * **Rounding does not always favour the maker.** Checked against the exact curve at
///        120 decimal digits: `amountOut` can land one wei *above* `floor(exact)` and
///        `amountIn` one wei *below* `ceil(exact)`, because the two floors inside
///        `PeggedSwapMath.solve` (`:100`, `:103`) round in the taker's favour and are not
///        always compensated by the reconstructing `ceilDiv`s. There is therefore no
///        zero-slack rounding property in this file. The provable form is a +/-1-wei bound
///        and it needs the sqrt abstraction, so it is deliberately out of scope here.
///
///      * **There is no fixed global invariant.** The doc comment's `= 1 + A` right-hand
///        side is wrong twice over: at the nominal point the left side is `2(1 + A)`, and
///        more importantly the code recomputes the target from *current* reserves on every
///        call (`:148-154`). Any "invariant preserved" property would have to be stated
///        per-call, not across calls.
///
///      * **`Panic(0x11)` is reachable** at `:179` and `:215` once the normalisers approach
///        `ONE = 1e27`; clean at `<= 2e26`. `test_knownUnderflow_exactOutAtLargeReserves`
///        pins the recorded witness. This is why no property here claims the instruction is
///        total, and why every success-path property is stated through `try`/`catch`.
///        `test_knownOverflow_exactInAtSmallNormaliser` pins a *second*, distinct panic not
///        recorded in FINDINGS.md: an overflow at `:167`, driven by the unbounded ratio
///        `amountIn / x0_init` rather than by the absolute size of the normalisers.
///
///      SCOPE. `Math.sqrt` runs four times per path, each with seven data-dependent
///      branches for the MSB estimate and six unrolled Newton steps over symbolic operands.
///      Properties whose *proof* must reason through a sqrt *value* are out of scope until
///      an uninterpreted-function abstraction exists. Everything below either stops before
///      the first sqrt, or treats the sqrt results as opaque. The two `...IsUnreachable`
///      properties are the exception and are labelled as such: they need `isqrt`
///      monotonicity and `isqrt(ONE*ONE) == ONE`.
///
///      METHOD. Guards are stated as biconditionals — "fires exactly on its condition" —
///      because a guard that always reverts passes a one-sided test. The negative direction
///      cannot be written with `vm.expectRevert`, which can only assert *that* a revert
///      happened, so the guard properties use `try`/`catch` and inspect the returned
///      selector directly. That also keeps the whole domain in scope: an input that reverts
///      for some *other* reason still satisfies "this guard did not fire".
///
///      DOMAIN. Following `README.md`, "Avoid putting a symbolic division in the path
///      condition", no property below assumes its way onto the success path with a symbolic
///      `DIV`. Where a *valid* argument field is needed, it is produced by a saturating
///      ternary (`_validWidth`, `_nonZero`, ...) rather than by `vm.assume`. Under Kontrol
///      each ternary splits into two branches whose union covers the entire valid range
///      symbolically, so this is exhaustive rather than a narrowing. The one genuine
///      narrowing in the file is `_safeBalance`/`_safeRate`/`_safeInit`, used only by the
///      two `...FiresWithExactSelector` recompute properties; it is documented at its
///      definition.
///
///      These run as ordinary fuzz tests under `forge test` and as proofs under
///      `kontrol prove`. Under Kontrol every `vm.assume` becomes a path constraint rather
///      than a sample filter, so the assumptions below define exactly the domain over which
///      each property is proven — read them as part of the specification.
contract PeggedSwapSpec is Test {
    PeggedSwapHarness internal harness;

    uint256 internal constant ONE = 1e27;
    uint256 internal constant MAX_LINEAR_WIDTH = 5000 * ONE;

    /// @dev Two addresses with a known order, so that `tokenIn < tokenOut` is decided
    ///      statically and the direction-symmetry properties can flip it deliberately.
    address internal constant TOKEN_LO = address(uint160(1));
    address internal constant TOKEN_HI = address(uint160(2));

    /// @dev The expected selectors, as `internal pure` accessors rather than as state.
    ///
    ///      NOT `immutable`, and this is load-bearing under Kontrol — an earlier revision of
    ///      this file used `immutable` and it silently broke every proof in the file that
    ///      inspects a selector.
    ///
    ///      An `immutable` is not part of the compiled runtime object. solc emits zero
    ///      placeholders in `deployedBytecode` plus an `immutableReferences` map, and the
    ///      real values are substituted by the **constructor**, at deployment. Kontrol loads
    ///      the test contract straight from `deployedBytecode` and, unless `run-constructor`
    ///      is enabled — it is `false` in `kontrol.toml`, matching Kontrol's default — never
    ///      runs that constructor. So under `kontrol prove` all nine read back as
    ///      `0x00000000`, while reading correctly under `forge test`, which does deploy.
    ///
    ///      The symptom is a proof that fails on a *selector* comparison while the identical
    ///      test passes the fuzzer, e.g. `test_knownUnderflow_exactOutAtLargeReserves`
    ///      failing its `== _selPanic()` assertion because `0x4e487b71 != 0x00000000`. That is
    ///      not KEVM and revm disagreeing about the EVM: they agree on every byte of the
    ///      execution and both produce the same `Panic(0x11)`. They disagree only about
    ///      whether a constructor ran.
    ///
    ///      `constant` would be the natural fix but solc rejects it — an error selector is
    ///      not a compile-time constant expression (error 8349), though it is one in fact.
    ///      An `internal pure` accessor is accepted, and it resolves entirely inside the
    ///      runtime object: after this change the artifact's `immutableReferences` map is
    ///      empty, i.e. nothing in `deployedBytecode` is left for a constructor to fill in.
    ///      No storage read either, and no `KECCAK256` on any proof path.
    ///
    ///      Check after touching this block:
    ///        python3 -c "import json;print(json.load(open(
    ///          'out/PeggedSwapSpec.t.sol/PeggedSwapSpec.json'))['deployedBytecode']
    ///          .get('immutableReferences'))"
    ///      It must print `None` or `{}`. Anything else is a value Kontrol will read as zero.
    function _selArgsLength() internal pure returns (bytes4) {
        return PeggedSwapArgsBuilder.PeggedSwapInvalidArgsLength.selector;
    }

    function _selInitBalances() internal pure returns (bytes4) {
        return PeggedSwapArgsBuilder.PeggedSwapInvalidInitialBalances.selector;
    }

    function _selLinearWidth() internal pure returns (bytes4) {
        return PeggedSwapArgsBuilder.PeggedSwapInvalidLinearWidth.selector;
    }

    function _selRates() internal pure returns (bytes4) {
        return PeggedSwapArgsBuilder.PeggedSwapInvalidRates.selector;
    }

    function _selBothZero() internal pure returns (bytes4) {
        return PeggedSwap.PeggedSwapBothBalancesZero.selector;
    }

    function _selRecompute() internal pure returns (bytes4) {
        return PeggedSwap.PeggedSwapRecomputeDetected.selector;
    }

    function _selNoSolution() internal pure returns (bytes4) {
        return PeggedSwapMath.PeggedSwapMathNoSolution.selector;
    }

    function _selInvalidInput() internal pure returns (bytes4) {
        return PeggedSwapMath.PeggedSwapMathInvalidInput.selector;
    }

    /// @dev Solidity exposes no `Panic.selector`, so the ABI's panic selector is spelled out.
    ///      A literal rather than `bytes4(keccak256("Panic(uint256)"))`: the hash of a string
    ///      literal is only folded away by the optimiser, and if it were not folded it would
    ///      put a `KECCAK256` on every proof path — which the revert-data helpers below go out
    ///      of their way to avoid, since KEVM treats `keccak` as an uninterpreted function.
    ///      `test_panicSelectorIsTheAbiPanicSelector` pins the literal against the hash.
    function _selPanic() internal pure returns (bytes4) {
        return 0x4e487b71;
    }

    function setUp() public {
        harness = new PeggedSwapHarness();
    }

    // -----------------------------------------------------------------------
    // Helpers — argument construction
    // -----------------------------------------------------------------------

    /// @dev Exactly `PeggedSwapArgsBuilder.build`, inlined so the spec does not depend on
    ///      the builder being correct.
    function _args(
        uint256 x0,
        uint256 y0,
        uint256 linearWidth,
        uint256 rateLt,
        uint256 rateGt
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(x0, y0, linearWidth, rateLt, rateGt);
    }

    /// @dev Saturating maps onto the valid sub-domain of each argument field. Preferred over
    ///      `vm.assume` for two reasons: the fuzzer would reject essentially every sample of
    ///      `linearWidth <= 5000e27` drawn from `uint256`, and under Kontrol a ternary splits
    ///      into two branches whose union still covers the whole valid range symbolically —
    ///      so unlike a narrower fuzz type (`uint96 linearWidth`, say) nothing is lost.
    function _nonZero(uint256 v) internal pure returns (uint256) {
        return v == 0 ? 1 : v;
    }

    function _validWidth(uint256 v) internal pure returns (uint256) {
        return v > MAX_LINEAR_WIDTH ? MAX_LINEAR_WIDTH : v;
    }

    /// @dev The one genuine domain narrowing in this file, used only by the two
    ///      `...recomputeGuardFiresWithExactSelector` properties.
    ///
    ///      Those two need the recompute guard (`:157` / `:194`) to be the *first* thing
    ///      that can revert, and the guard sits after the invariant computation at `:148`.
    ///      That computation is not total over `uint256`: `balanceIn * rateIn`,
    ///      `u * ONE` and `A * (u + v)` can each overflow, and on those inputs the
    ///      instruction panics before ever reaching the guard, so the biconditional is
    ///      simply false there.
    ///
    ///      With `balance <= 1e24`, `rate <= 1e12` and `x0_init, y0_init >= 1e21`:
    ///        x0 = balance*rate <= 1e36; u = x0*ONE/x0_init <= 1e63/1e21 = 1e42;
    ///        u*ONE <= 1e69 < 2^256; A*(u+v) <= 5e30 * 2e42 = 1e73 < 2^256.
    ///      so `:148` is provably total on this domain and the guard is reached on every
    ///      input. The *negative* direction of both guards, and every other property in
    ///      this file, is stated over the full `uint256` domain and needs none of this.
    uint256 internal constant SAFE_BALANCE_MAX = 1e24;
    uint256 internal constant SAFE_RATE_MAX = 1e12;
    uint256 internal constant SAFE_INIT_MIN = 1e21;

    function _safeBalance(uint256 v) internal pure returns (uint256) {
        return v > SAFE_BALANCE_MAX ? SAFE_BALANCE_MAX : v;
    }

    function _safeRate(uint256 v) internal pure returns (uint256) {
        if (v == 0) {
            return 1;
        }
        return v > SAFE_RATE_MAX ? SAFE_RATE_MAX : v;
    }

    function _safeInit(uint256 v) internal pure returns (uint256) {
        return v < SAFE_INIT_MIN ? SAFE_INIT_MIN : v;
    }

    // -----------------------------------------------------------------------
    // Helpers — revert-data inspection
    // -----------------------------------------------------------------------

    /// @dev The 4-byte selector of returned revert data, or `0x00000000` if there is none.
    ///      Deliberately *not* `assertEq(bytes, bytes)`: forge-std compares byte strings by
    ///      `keccak256`, and under Kontrol `keccak` is an uninterpreted function, so such a
    ///      comparison would rest on hash injectivity rather than on the bytes themselves.
    function _selectorOf(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length < 4) {
            return bytes4(0);
        }
        assembly ("memory-safe") {
            s := and(mload(add(err, 0x20)), 0xffffffff00000000000000000000000000000000000000000000000000000000)
        }
    }

    /// @dev The `i`-th 32-byte argument word of returned revert data, or 0 if absent.
    function _errorArg(bytes memory err, uint256 i) internal pure returns (uint256 w) {
        if (err.length < 4 + 32 * (i + 1)) {
            return 0;
        }
        assembly ("memory-safe") {
            w := mload(add(err, add(0x24, mul(0x20, i))))
        }
    }

    /// @dev A guard fires *exactly* on its condition:
    ///        - the call succeeded  => the condition did not hold;
    ///        - the call reverted   => it reverted with this selector iff the condition held.
    ///      The second clause is what makes this two-sided. A guard that reverted
    ///      unconditionally would satisfy a `vm.expectRevert`-shaped test and fail here.
    function _assertGuard(bool shouldFire, bool ok, bytes memory err, bytes4 sel, string memory message) internal pure {
        if (ok) {
            assertFalse(shouldFire, message);
        } else {
            assertTrue((_selectorOf(err) == sel) == shouldFire, message);
        }
    }

    // -----------------------------------------------------------------------
    // Helpers — calling the harness without letting a revert escape
    // -----------------------------------------------------------------------

    function _tryExactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        address tokenIn,
        address tokenOut,
        bytes memory args
    )
        internal
        view
        returns (bool ok, bytes memory err, SwapRegisters memory regs)
    {
        try harness.exactIn(balanceIn, balanceOut, amountIn, tokenIn, tokenOut, args) returns (SwapRegisters memory r) {
            return (true, "", r);
        } catch (bytes memory e) {
            return (false, e, regs);
        }
    }

    function _tryExactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        address tokenIn,
        address tokenOut,
        bytes memory args
    )
        internal
        view
        returns (bool ok, bytes memory err, SwapRegisters memory regs)
    {
        try harness.exactOut(balanceIn, balanceOut, amountOut, tokenIn, tokenOut, args) returns (
            SwapRegisters memory r
        ) {
            return (true, "", r);
        } catch (bytes memory e) {
            return (false, e, regs);
        }
    }

    // =======================================================================
    // 1. The four `parse` guards (PeggedSwap.sol:52-61)
    //
    //    None of these reaches any arithmetic, so they are the cheapest proofs in the
    //    file: no `Math.sqrt` is executed on any path they explore.
    // =======================================================================

    /// @notice `PeggedSwapInvalidArgsLength` fires exactly when `args.length < 160`, and
    ///         reports the offending length.
    /// @dev Quantifies over the whole `bytes` domain — the length is symbolic, not a
    ///      fixed-size record. Success implies the length was sufficient, which is the
    ///      other half of the biconditional.
    function test_parse_argsLengthGuardIsExactlyBelow160(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        bytes calldata data
    )
        public
        view
    {
        (bool ok, bytes memory err,) = _tryExactIn(balanceIn, balanceOut, amountIn, TOKEN_LO, TOKEN_HI, data);

        bool shouldFire = data.length < 160;
        _assertGuard(shouldFire, ok, err, _selArgsLength(), "args-length guard must fire exactly below 160 bytes");

        if (!ok && shouldFire) {
            assertEq(_errorArg(err, 0), data.length, "guard must report the actual args length");
        }
    }

    /// @notice `PeggedSwapInvalidInitialBalances` fires exactly when `x0 == 0 || y0 == 0`,
    ///         and reports both normalisers.
    /// @dev `zeroX`/`zeroY` drive the two zero cases; the non-zero cases keep the field
    ///      symbolic over the whole non-zero range via `_nonZero`.
    function test_parse_initialBalancesGuardIsExactlyZeroNormaliser(
        bool zeroX,
        bool zeroY,
        uint256 x0Seed,
        uint256 y0Seed,
        uint256 widthSeed,
        uint256 rateLtSeed,
        uint256 rateGtSeed,
        uint256 balanceIn,
        uint256 amountIn
    )
        public
        view
    {
        uint256 x0 = zeroX ? 0 : _nonZero(x0Seed);
        uint256 y0 = zeroY ? 0 : _nonZero(y0Seed);
        bytes memory args = _args(x0, y0, _validWidth(widthSeed), _nonZero(rateLtSeed), _nonZero(rateGtSeed));

        (bool ok, bytes memory err,) = _tryExactIn(balanceIn, 1, amountIn, TOKEN_LO, TOKEN_HI, args);

        bool shouldFire = x0 == 0 || y0 == 0;
        _assertGuard(
            shouldFire, ok, err, _selInitBalances(), "initial-balances guard must fire exactly on a zero normaliser"
        );

        if (!ok && shouldFire) {
            assertEq(_errorArg(err, 0), x0, "guard must report x0");
            assertEq(_errorArg(err, 1), y0, "guard must report y0");
        }
    }

    /// @notice `PeggedSwapInvalidLinearWidth` fires exactly when `linearWidth > 5000e27`.
    /// @dev `linearWidth` is fully symbolic over `uint256` here — the boundary at exactly
    ///      `MAX_LINEAR_WIDTH` is inside the domain and the guard must *accept* it.
    function test_parse_linearWidthGuardIsExactlyAboveMax(
        uint256 linearWidth,
        uint256 x0Seed,
        uint256 y0Seed,
        uint256 rateLtSeed,
        uint256 rateGtSeed,
        uint256 balanceIn,
        uint256 amountIn
    )
        public
        view
    {
        bytes memory args =
            _args(_nonZero(x0Seed), _nonZero(y0Seed), linearWidth, _nonZero(rateLtSeed), _nonZero(rateGtSeed));

        (bool ok, bytes memory err,) = _tryExactIn(balanceIn, 1, amountIn, TOKEN_LO, TOKEN_HI, args);

        bool shouldFire = linearWidth > MAX_LINEAR_WIDTH;
        _assertGuard(shouldFire, ok, err, _selLinearWidth(), "linear-width guard must fire exactly above 5000e27");

        if (!ok && shouldFire) {
            assertEq(_errorArg(err, 0), linearWidth, "guard must report the offending linear width");
        }
    }

    /// @notice The linear-width bound is inclusive: `linearWidth == 5000e27` is accepted.
    /// @dev Pinned separately because an off-by-one here is exactly the kind of change a
    ///      biconditional over a symbolic width would still catch, but a reader would not.
    function test_parse_linearWidthBoundIsInclusive(uint256 balanceIn, uint256 amountIn) public view {
        bytes memory args = _args(1e21, 1e21, MAX_LINEAR_WIDTH, 1, 1);

        (bool ok, bytes memory err,) = _tryExactIn(balanceIn, 1, amountIn, TOKEN_LO, TOKEN_HI, args);

        if (!ok) {
            assertTrue(_selectorOf(err) != _selLinearWidth(), "linearWidth == MAX must be accepted");
        }
    }

    /// @notice `PeggedSwapInvalidRates` fires exactly when `rateLt == 0 || rateGt == 0`.
    /// @dev The width is mapped onto its valid range so that guard 3 cannot pre-empt guard 4.
    function test_parse_ratesGuardIsExactlyZeroRate(
        bool zeroLt,
        bool zeroGt,
        uint256 rateLtSeed,
        uint256 rateGtSeed,
        uint256 x0Seed,
        uint256 y0Seed,
        uint256 widthSeed,
        uint256 balanceIn,
        uint256 amountIn
    )
        public
        view
    {
        uint256 rateLt = zeroLt ? 0 : _nonZero(rateLtSeed);
        uint256 rateGt = zeroGt ? 0 : _nonZero(rateGtSeed);
        bytes memory args = _args(_nonZero(x0Seed), _nonZero(y0Seed), _validWidth(widthSeed), rateLt, rateGt);

        (bool ok, bytes memory err,) = _tryExactIn(balanceIn, 1, amountIn, TOKEN_LO, TOKEN_HI, args);

        bool shouldFire = rateLt == 0 || rateGt == 0;
        _assertGuard(shouldFire, ok, err, _selRates(), "rates guard must fire exactly on a zero rate");

        if (!ok && shouldFire) {
            assertEq(_errorArg(err, 0), rateLt, "guard must report rateLt");
            assertEq(_errorArg(err, 1), rateGt, "guard must report rateGt");
        }
    }

    // =======================================================================
    // 2. `PeggedSwapBothBalancesZero` (PeggedSwap.sol:104)
    //
    //    `require(x0_raw | y0_raw != 0, ...)`. Solidity binds `|` *tighter* than `!=`,
    //    unlike C, so this parses as `(x0_raw | y0_raw) != 0` and correctly means "not
    //    both zero" rather than "balanceIn | (balanceOut != 0)" — which would not even
    //    typecheck. The misreading is common enough to be worth pinning from both sides.
    // =======================================================================

    /// @notice The guard fires when both balances are zero.
    /// @dev Reached immediately after `parse`, before any arithmetic, so this explores no
    ///      `Math.sqrt` at all.
    function test_bothBalancesZeroGuardFiresWhenBothZero(
        uint256 x0Seed,
        uint256 y0Seed,
        uint256 widthSeed,
        uint256 rateLtSeed,
        uint256 rateGtSeed,
        uint256 amountIn
    )
        public
        view
    {
        bytes memory args = _args(
            _nonZero(x0Seed), _nonZero(y0Seed), _validWidth(widthSeed), _nonZero(rateLtSeed), _nonZero(rateGtSeed)
        );

        (bool ok, bytes memory err,) = _tryExactIn(0, 0, amountIn, TOKEN_LO, TOKEN_HI, args);

        assertFalse(ok, "both balances zero must revert");
        assertTrue(_selectorOf(err) == _selBothZero(), "both-balances-zero guard must fire with its own selector");
    }

    /// @notice The guard never fires when at least one balance is non-zero.
    /// @dev The other half of the biconditional, over the full `uint256` domain and both
    ///      swap directions' worth of registers. Inputs that revert for an unrelated reason
    ///      still satisfy it — the claim is about *which* error, not about totality.
    function test_bothBalancesZeroGuardNeverFiresWhenEitherIsNonZero(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 x0Seed,
        uint256 y0Seed,
        uint256 widthSeed,
        uint256 rateLtSeed,
        uint256 rateGtSeed
    )
        public
        view
    {
        vm.assume(balanceIn != 0 || balanceOut != 0);

        bytes memory args = _args(
            _nonZero(x0Seed), _nonZero(y0Seed), _validWidth(widthSeed), _nonZero(rateLtSeed), _nonZero(rateGtSeed)
        );

        (bool ok, bytes memory err,) = _tryExactIn(balanceIn, balanceOut, amountIn, TOKEN_LO, TOKEN_HI, args);

        if (!ok) {
            assertTrue(_selectorOf(err) != _selBothZero(), "guard must not fire when one balance is non-zero");
        }
    }

    /// @notice A zero *input* balance alone passes the guard.
    /// @dev Stated so that it stops at the recompute guard rather than running the whole
    ///      curve: a non-zero `amountOut` on the exact-in leg means the next thing that can
    ///      revert is `:157`. Observing `PeggedSwapRecomputeDetected` is therefore direct
    ///      evidence that execution got *past* `:104`. With `balanceIn == 0` the `u` side of
    ///      the invariant is concretely zero, so only one symbolic `Math.sqrt` is explored.
    function test_bothBalancesZero_zeroInputBalanceAlonePassesTheGuard(
        uint256 balanceOutSeed,
        uint256 amountOut,
        uint256 x0Seed,
        uint256 y0Seed,
        uint256 widthSeed
    )
        public
        view
    {
        vm.assume(amountOut != 0);

        bytes memory args = _args(_safeInit(x0Seed), _safeInit(y0Seed), _validWidth(widthSeed), 1, 1);

        SwapRegisters memory regs;
        bool ok = true;
        bytes memory err;
        try harness.run(
            true, 0, _nonZero(_safeBalance(balanceOutSeed)), 0, amountOut, 0, TOKEN_LO, TOKEN_HI, args
        ) returns (
            SwapRegisters memory r
        ) {
            regs = r;
        } catch (bytes memory e) {
            ok = false;
            err = e;
        }

        assertFalse(ok, "a pre-set amountOut must be rejected");
        assertTrue(_selectorOf(err) == _selRecompute(), "execution must reach the recompute guard, i.e. pass :104");
    }

    /// @notice A zero *output* balance alone passes the guard. Mirror of the above.
    function test_bothBalancesZero_zeroOutputBalanceAlonePassesTheGuard(
        uint256 balanceInSeed,
        uint256 amountOut,
        uint256 x0Seed,
        uint256 y0Seed,
        uint256 widthSeed
    )
        public
        view
    {
        vm.assume(amountOut != 0);

        bytes memory args = _args(_safeInit(x0Seed), _safeInit(y0Seed), _validWidth(widthSeed), 1, 1);

        bool ok = true;
        bytes memory err;
        try harness.run(
            true, _nonZero(_safeBalance(balanceInSeed)), 0, 0, amountOut, 0, TOKEN_LO, TOKEN_HI, args
        ) returns (
            SwapRegisters memory
        ) {
        // reached the end without reverting
        }
        catch (bytes memory e) {
            ok = false;
            err = e;
        }

        assertFalse(ok, "a pre-set amountOut must be rejected");
        assertTrue(_selectorOf(err) == _selRecompute(), "execution must reach the recompute guard, i.e. pass :104");
    }

    // =======================================================================
    // 3. The two recompute guards (PeggedSwap.sol:157 exact-in, :194 exact-out)
    //
    //    Without them a program could run the curve twice and compound the price, so
    //    instruction ordering is security-critical. Each is stated three ways: the
    //    positive direction over the full domain (weaker conclusion, no narrowing), the
    //    positive direction with the exact selector (narrowed domain, see `_safeBalance`),
    //    and the negative direction over the full domain.
    // =======================================================================

    /// @notice Exact-in with a pre-populated `amountOut` can never succeed.
    /// @dev Full `uint256` domain, no assumptions on the args at all: either the invariant
    ///      computation panics first, or `:157` rejects. Either way there is no path on
    ///      which a second pricing pass produces a quote.
    function test_exactIn_alwaysRevertsWhenAmountOutIsPreset(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled,
        bytes calldata args
    )
        public
        view
    {
        vm.assume(amountOut != 0);

        try harness.run(
            true, balanceIn, balanceOut, amountIn, amountOut, amountNetPulled, TOKEN_LO, TOKEN_HI, args
        ) returns (
            SwapRegisters memory
        ) {
            assertTrue(false, "exact-in must never price with amountOut already set");
        } catch { }
    }

    /// @notice Exact-in with a pre-populated `amountOut` reverts with
    ///         `PeggedSwapRecomputeDetected` specifically.
    /// @dev NARROWED to the safe-arithmetic domain — see `_safeBalance`. Off it, the
    ///      invariant computation at `:148` can panic before the guard is reached, and the
    ///      *selector* claim is genuinely false there while the claim above still holds.
    function test_exactIn_recomputeGuardFiresWithExactSelector(
        uint256 balanceInSeed,
        uint256 balanceOutSeed,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled,
        uint256 x0Seed,
        uint256 y0Seed,
        uint256 widthSeed,
        uint256 rateLtSeed,
        uint256 rateGtSeed
    )
        public
        view
    {
        vm.assume(amountOut != 0);

        bytes memory args = _args(
            _safeInit(x0Seed), _safeInit(y0Seed), _validWidth(widthSeed), _safeRate(rateLtSeed), _safeRate(rateGtSeed)
        );

        bool ok = true;
        bytes memory err;
        try harness.run(
            true,
            _nonZero(_safeBalance(balanceInSeed)),
            _safeBalance(balanceOutSeed),
            amountIn,
            amountOut,
            amountNetPulled,
            TOKEN_LO,
            TOKEN_HI,
            args
        ) returns (
            SwapRegisters memory
        ) {
            ok = true;
        } catch (bytes memory e) {
            ok = false;
            err = e;
        }

        assertFalse(ok, "exact-in recompute guard must reject a pre-set amountOut");
        assertTrue(_selectorOf(err) == _selRecompute(), "exact-in recompute guard must use its own selector");
    }

    /// @notice The exact-in recompute guard never fires when `amountOut == 0`.
    /// @dev Full domain. This is the direction a one-sided `vm.expectRevert` test misses.
    function test_exactIn_recomputeGuardNeverFiresWhenAmountOutIsZero(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        bytes calldata args
    )
        public
        view
    {
        (bool ok, bytes memory err,) = _tryExactIn(balanceIn, balanceOut, amountIn, TOKEN_LO, TOKEN_HI, args);

        if (!ok) {
            assertTrue(_selectorOf(err) != _selRecompute(), "recompute guard must not fire on a clean amountOut register");
        }
    }

    /// @notice Exact-out with a pre-populated `amountIn` can never succeed. Full domain.
    function test_exactOut_alwaysRevertsWhenAmountInIsPreset(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled,
        bytes calldata args
    )
        public
        view
    {
        vm.assume(amountIn != 0);

        try harness.run(
            false, balanceIn, balanceOut, amountIn, amountOut, amountNetPulled, TOKEN_LO, TOKEN_HI, args
        ) returns (
            SwapRegisters memory
        ) {
            assertTrue(false, "exact-out must never price with amountIn already set");
        } catch { }
    }

    /// @notice Exact-out with a pre-populated `amountIn` reverts with
    ///         `PeggedSwapRecomputeDetected` specifically.
    /// @dev NARROWED to the safe-arithmetic domain, for the same reason as its exact-in twin.
    function test_exactOut_recomputeGuardFiresWithExactSelector(
        uint256 balanceInSeed,
        uint256 balanceOutSeed,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled,
        uint256 x0Seed,
        uint256 y0Seed,
        uint256 widthSeed,
        uint256 rateLtSeed,
        uint256 rateGtSeed
    )
        public
        view
    {
        vm.assume(amountIn != 0);

        bytes memory args = _args(
            _safeInit(x0Seed), _safeInit(y0Seed), _validWidth(widthSeed), _safeRate(rateLtSeed), _safeRate(rateGtSeed)
        );

        bool ok = true;
        bytes memory err;
        try harness.run(
            false,
            _nonZero(_safeBalance(balanceInSeed)),
            _safeBalance(balanceOutSeed),
            amountIn,
            amountOut,
            amountNetPulled,
            TOKEN_LO,
            TOKEN_HI,
            args
        ) returns (
            SwapRegisters memory
        ) {
            ok = true;
        } catch (bytes memory e) {
            ok = false;
            err = e;
        }

        assertFalse(ok, "exact-out recompute guard must reject a pre-set amountIn");
        assertTrue(_selectorOf(err) == _selRecompute(), "exact-out recompute guard must use its own selector");
    }

    /// @notice The exact-out recompute guard never fires when `amountIn == 0`. Full domain.
    function test_exactOut_recomputeGuardNeverFiresWhenAmountInIsZero(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        bytes calldata args
    )
        public
        view
    {
        (bool ok, bytes memory err,) = _tryExactOut(balanceIn, balanceOut, amountOut, TOKEN_LO, TOKEN_HI, args);

        if (!ok) {
            assertTrue(_selectorOf(err) != _selRecompute(), "recompute guard must not fire on a clean amountIn register");
        }
    }

    // =======================================================================
    // 4. Exact-out output clamp and minimum input (PeggedSwap.sol:196, :218-220)
    // =======================================================================

    /// @notice The exact-out leg clamps the requested output to the available balance.
    /// @dev `amountOut' = min(amountOut, balanceOut)` (`:196`), and nothing later in the
    ///      instruction touches `ctx.swap.amountOut`, so the clamp is observable in the
    ///      final register. Stated over the full `uint256` domain through `try`/`catch`;
    ///      the sqrt results are never inspected, only the fact that the run completed.
    function test_exactOut_amountOutIsClampedToBalanceOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        bytes calldata args
    )
        public
        view
    {
        (bool ok,, SwapRegisters memory regs) = _tryExactOut(balanceIn, balanceOut, amountOut, TOKEN_LO, TOKEN_HI, args);

        if (ok) {
            uint256 expected = amountOut > balanceOut ? balanceOut : amountOut;
            assertEq(regs.amountOut, expected, "exact-out must clamp the requested output to balanceOut");
        }
    }

    /// @notice Any non-zero exact-out fill costs the taker at least one wei of input.
    /// @dev The bump at `:218-220`. Without it a taker could extract dust for free whenever
    ///      the `ceilDiv` at `:215` returns zero — which it can, since `x1 - x0` may be zero
    ///      after the normalisation round trip.
    function test_exactOut_nonZeroOutputCostsAtLeastOneWei(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        bytes calldata args
    )
        public
        view
    {
        (bool ok,, SwapRegisters memory regs) = _tryExactOut(balanceIn, balanceOut, amountOut, TOKEN_LO, TOKEN_HI, args);

        if (ok && regs.amountOut != 0) {
            assertGe(regs.amountIn, 1, "a non-zero exact-out fill must cost at least one wei in");
        }
    }

    // =======================================================================
    // 5. Register isolation
    // =======================================================================

    /// @notice Exact-in touches neither balance register nor `amountNetPulled`.
    /// @dev `amountNetPulled` is the fee accounting register; an instruction that wrote it
    ///      would silently change what a downstream `Fee` instruction charges. The balances
    ///      are the maker's state as observed by the rest of the program — PeggedSwap prices
    ///      against them but must not rewrite them.
    function test_exactIn_leavesBalancesAndNetPulledUntouched(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountNetPulled,
        bytes calldata args
    )
        public
        view
    {
        try harness.run(true, balanceIn, balanceOut, amountIn, 0, amountNetPulled, TOKEN_LO, TOKEN_HI, args) returns (
            SwapRegisters memory regs
        ) {
            assertEq(regs.balanceIn, balanceIn, "balanceIn must be untouched");
            assertEq(regs.balanceOut, balanceOut, "balanceOut must be untouched");
            assertEq(regs.amountNetPulled, amountNetPulled, "amountNetPulled must be untouched");
        } catch { }
    }

    /// @notice Exact-out touches neither balance register nor `amountNetPulled`.
    function test_exactOut_leavesBalancesAndNetPulledUntouched(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        uint256 amountNetPulled,
        bytes calldata args
    )
        public
        view
    {
        try harness.run(false, balanceIn, balanceOut, 0, amountOut, amountNetPulled, TOKEN_LO, TOKEN_HI, args) returns (
            SwapRegisters memory regs
        ) {
            assertEq(regs.balanceIn, balanceIn, "balanceIn must be untouched");
            assertEq(regs.balanceOut, balanceOut, "balanceOut must be untouched");
            assertEq(regs.amountNetPulled, amountNetPulled, "amountNetPulled must be untouched");
        } catch { }
    }

    /// @notice Exact-in never writes the register the taker fixed.
    /// @dev `ctx.swap.amountIn` is only assigned on the drain branch (`:179`); on the
    ///      ordinary branch it must survive unchanged, and on the drain branch it is
    ///      recomputed deliberately. This pins that the *ordinary* branch does not touch it.
    ///      Stated as "either unchanged, or the whole output balance was drained", which is
    ///      exactly the disjunction the two branches produce.
    function test_exactIn_amountInSurvivesUnlessTheOutputReserveIsDrained(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        bytes calldata args
    )
        public
        view
    {
        (bool ok,, SwapRegisters memory regs) = _tryExactIn(balanceIn, balanceOut, amountIn, TOKEN_LO, TOKEN_HI, args);

        if (ok) {
            assertTrue(
                regs.amountIn == amountIn || regs.amountOut == balanceOut,
                "exact-in may only rewrite amountIn on the drain branch"
            );
        }
    }

    // =======================================================================
    // 6. Direction symmetry (PeggedSwapArgsBuilder.parseRatesAndBalances, :76-78)
    //
    //    The rate/normaliser selection is by token *address ordering*, not by argument
    //    position. Flipping `(tokenIn, tokenOut)` together with `(x0, y0)` and
    //    `(rateLt, rateGt)` must therefore be a no-op: both calls select the same
    //    `(rateIn, rateOut, x0_init, y0_init)` tuple, so execution after `:141` is
    //    identical. Getting this wrong — reading `rateLt` for the input token regardless
    //    of ordering — is a known vulnerability class in this codebase.
    // =======================================================================

    function test_directionSymmetry_exactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 x0,
        uint256 y0,
        uint256 linearWidth,
        uint256 rateLt,
        uint256 rateGt
    )
        public
        view
    {
        (bool okLo, bytes memory errLo, SwapRegisters memory lo) = _tryExactIn(
            balanceIn, balanceOut, amountIn, TOKEN_LO, TOKEN_HI, _args(x0, y0, linearWidth, rateLt, rateGt)
        );
        (bool okHi, bytes memory errHi, SwapRegisters memory hi) = _tryExactIn(
            balanceIn, balanceOut, amountIn, TOKEN_HI, TOKEN_LO, _args(y0, x0, linearWidth, rateGt, rateLt)
        );

        assertTrue(okLo == okHi, "mirrored configurations must agree on success");
        if (okLo) {
            assertEq(lo.amountOut, hi.amountOut, "mirrored configurations must quote the same output");
            assertEq(lo.amountIn, hi.amountIn, "mirrored configurations must quote the same input");
        } else {
            assertTrue(_selectorOf(errLo) == _selectorOf(errHi), "mirrored configurations must fail identically");
        }
    }

    function test_directionSymmetry_exactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        uint256 x0,
        uint256 y0,
        uint256 linearWidth,
        uint256 rateLt,
        uint256 rateGt
    )
        public
        view
    {
        (bool okLo, bytes memory errLo, SwapRegisters memory lo) = _tryExactOut(
            balanceIn, balanceOut, amountOut, TOKEN_LO, TOKEN_HI, _args(x0, y0, linearWidth, rateLt, rateGt)
        );
        (bool okHi, bytes memory errHi, SwapRegisters memory hi) = _tryExactOut(
            balanceIn, balanceOut, amountOut, TOKEN_HI, TOKEN_LO, _args(y0, x0, linearWidth, rateGt, rateLt)
        );

        assertTrue(okLo == okHi, "mirrored configurations must agree on success");
        if (okLo) {
            assertEq(lo.amountIn, hi.amountIn, "mirrored configurations must quote the same input");
            assertEq(lo.amountOut, hi.amountOut, "mirrored configurations must quote the same output");
        } else {
            assertTrue(_selectorOf(errLo) == _selectorOf(errHi), "mirrored configurations must fail identically");
        }
    }

    // =======================================================================
    // 7. Dead code
    //
    //    Two `require`s in the arithmetic can never fail. Both proofs are cheap in path
    //    count but — unlike everything above — both DO need the prover to know something
    //    about `Math.sqrt`'s *value*, so both are expected to stall until the `isqrt`
    //    abstraction exists. They are stated here because they are the natural first
    //    consumers of that abstraction.
    // =======================================================================

    /// @notice `PeggedSwapMathNoSolution` is unreachable. (FINDINGS.md, apparent bug 5.)
    /// @dev `PeggedSwapMath.sol:89` sets `discriminant = ONE + fourARightSide >= ONE`, so
    ///      `sqrtDiscriminant = isqrt(discriminant * ONE) >= isqrt(ONE * ONE) = ONE` and the
    ///      `require` at `:95` cannot fail. Needs exactly two `isqrt` facts: monotonicity
    ///      and `isqrt(ONE * ONE) == ONE`.
    function test_deadCode_noSolutionIsUnreachable_exactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        bytes calldata args
    )
        public
        view
    {
        (bool ok, bytes memory err,) = _tryExactIn(balanceIn, balanceOut, amountIn, TOKEN_LO, TOKEN_HI, args);

        if (!ok) {
            assertTrue(_selectorOf(err) != _selNoSolution(), "PeggedSwapMathNoSolution must be unreachable");
        }
    }

    /// @notice Same, on the exact-out leg.
    function test_deadCode_noSolutionIsUnreachable_exactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        bytes calldata args
    )
        public
        view
    {
        (bool ok, bytes memory err,) = _tryExactOut(balanceIn, balanceOut, amountOut, TOKEN_LO, TOKEN_HI, args);

        if (!ok) {
            assertTrue(_selectorOf(err) != _selNoSolution(), "PeggedSwapMathNoSolution must be unreachable");
        }
    }

    /// @notice `PeggedSwapMathInvalidInput` at `PeggedSwap.sol:206` is unreachable.
    ///
    /// @dev NOT in FINDINGS.md — recorded here as a second dead `require`, on the same
    ///      footing as `PeggedSwapMathNoSolution`.
    ///
    ///      The clamp at `:196` gives `amountOut <= balanceOut`, hence
    ///      `amountOut * rateOut <= balanceOut * rateOut == y0` (no overflow, since `y0`
    ///      was already computed), so `y1 <= y0` and therefore `v1 = y1*ONE/y0_init <= v`.
    ///      Flooring is monotone, so
    ///
    ///        invariantV1 = isqrt(v1*ONE) + A*v1/ONE
    ///                   <= isqrt(v*ONE)  + A*(u+v)/ONE
    ///                   <= isqrt(u*ONE) + isqrt(v*ONE) + A*(u+v)/ONE
    ///                    = targetInvariant
    ///
    ///      so `targetInvariant >= invariantV1` holds on every input and the `require`
    ///      cannot fail. Needs `isqrt` monotonicity only — no closed form.
    ///
    ///      Note the same argument shows the subtraction at `:199` never underflows, which
    ///      is worth keeping in mind when attributing a `Panic(0x11)` to `:215`.
    function test_deadCode_invalidInputIsUnreachable_exactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        bytes calldata args
    )
        public
        view
    {
        (bool ok, bytes memory err,) = _tryExactOut(balanceIn, balanceOut, amountOut, TOKEN_LO, TOKEN_HI, args);

        if (!ok) {
            assertTrue(_selectorOf(err) != _selInvalidInput(), "PeggedSwapMathInvalidInput must be unreachable");
        }
    }

    // =======================================================================
    // 8. Known-reachable arithmetic panics (FINDINGS.md, apparent bug 1, and one more)
    //
    //    Pinned rather than asserted away. `PeggedSwap.sol:215` computes
    //    `ceilDiv(x1 - x0, rateIn)` with a *checked* subtraction, and the round trip
    //    `x0 -> u -> solve -> u' -> x1` is not expansive, so `x1 < x0` is reachable and
    //    the subtraction panics. Empirically clean at normalisers <= 2e26, first
    //    underflows around 3e26, widespread at 1e27 and above.
    //
    //    Concrete inputs, so this costs the prover nothing; it exists so that a future
    //    change which makes the instruction total, or which moves the threshold, shows up
    //    as a failing test rather than as silence.
    // =======================================================================

    /// @notice `_selPanic()` really is `bytes4(keccak256("Panic(uint256)"))`.
    /// @dev The one place in this file where a `keccak256` is evaluated, and the reason the
    ///      other eight selectors are derived from `.selector` rather than hardcoded. Fully
    ///      concrete on both sides, so KEVM discharges it with its concrete `keccak` rule and
    ///      no uninterpreted hash term ever enters a path condition.
    function test_panicSelectorIsTheAbiPanicSelector() public pure {
        assertTrue(_selPanic() == bytes4(keccak256("Panic(uint256)")), "panic selector literal has drifted");
    }

    function test_knownUnderflow_exactOutAtLargeReserves() public view {
        bytes memory args = _args(1e30, 1e30, 0, 1, 1);

        (bool ok, bytes memory err,) = _tryExactOut(1e30 + 1, 1, 1, TOKEN_LO, TOKEN_HI, args);

        assertFalse(ok, "recorded witness must still revert");
        assertTrue(_selectorOf(err) == _selPanic(), "recorded witness must revert with a Panic, not a custom error");
        assertEq(_errorArg(err, 0), 0x11, "recorded witness must be an arithmetic underflow, Panic(0x11)");
    }

    /// @notice A second, distinct reachable `Panic(0x11)` — an *overflow*, at `:167`.
    ///
    /// @dev NOT in FINDINGS.md, which records only the two `ceilDiv` *underflows* at `:179`
    ///      and `:215`. This one is on the exact-in leg and fires much earlier and at far
    ///      smaller inputs.
    ///
    ///      `PeggedSwap.sol:167` evaluates `Math.sqrt(u1 * ONE)` where
    ///      `u1 = (x0 + amountIn*rateIn) * ONE / x0_init` (`:163`). Nothing bounds the ratio
    ///      `x1 / x0_init`, so `u1` is only bounded by `2^256/ONE`, and `u1 * ONE` overflows
    ///      as soon as `u1 > ~1.16e50`. The source comment at `:162` asserts `x1 <= 1e30`
    ///      and the one at `:166` asserts `a <= 2e27`; neither is enforced anywhere.
    ///
    ///      Witness: a one-wei input reserve with a matching normaliser (`x0_init == 1`), so
    ///      the pool starts exactly at its nominal point, and a taker input of 1e24 — an
    ///      ordinary size for an 18-decimal token. `u1` reaches 1e51 and the multiply
    ///      overflows. Note that unlike the `:215` underflow this needs no exotic
    ///      normaliser: it is driven by the *ratio* `amountIn/x0_init`, which is unbounded
    ///      whenever the maker configures a small `x0`.
    function test_knownOverflow_exactInAtSmallNormaliser() public view {
        bytes memory args = _args(1, 1, 0, 1, 1);

        (bool ok, bytes memory err,) = _tryExactIn(1, 1, 1e24, TOKEN_LO, TOKEN_HI, args);

        assertFalse(ok, "recorded witness must still revert");
        assertTrue(_selectorOf(err) == _selPanic(), "recorded witness must revert with a Panic, not a custom error");
        assertEq(_errorArg(err, 0), 0x11, "recorded witness must be an arithmetic overflow, Panic(0x11)");
    }

    // =======================================================================
    // 9. Success-path exercise at a nominal pool
    //
    //    Everything in sections 4-6 is stated over the full `uint256` domain through
    //    `try`/`catch`, which is the right shape for Kontrol but leaves the *fuzzer*
    //    almost always on the reverting branch: a `bytes` drawn at random is shorter than
    //    160 bytes, and a five-tuple of random `uint256` fails one of the parse guards or
    //    overflows the normalisation. Those properties are therefore close to vacuous
    //    under `forge test` even though they are exactly right under `kontrol prove`.
    //
    //    The two properties below restate the same claims over a pool that is *at* its
    //    nominal point — `x0_init == balanceIn * rateIn`, `y0_init == balanceOut * rateOut`,
    //    so `u == v == ONE` — at magnitudes below the underflow threshold recorded in
    //    FINDINGS.md. That is a genuine narrowing and it is the reason these are separate
    //    tests rather than assumptions bolted onto the full-domain versions: the theorem
    //    is the full-domain one, and this pair exists to keep the fast loop honest.
    // =======================================================================

    /// @dev Magnitudes chosen so that the whole exact-in path is provably free of the
    ///      arithmetic panics documented in section 8. With `balance in [1e6, 1e20]`,
    ///      `rate <= 1e6` and `amountIn <= 8 * balanceIn`:
    ///        x0_init = balanceIn*rateIn in [1e6, 1e26];  x1 = x0 + amountIn*rateIn <= 9e26;
    ///        u1 = x1*ONE/x0_init <= 9e47, so u1*ONE <= 9e74 < 2^256 at line 167.
    ///      They also sit an order of magnitude below the 2e26 normaliser threshold at
    ///      which FINDINGS.md records the first `:179`/`:215` underflow.
    uint256 internal constant NOMINAL_BALANCE_MIN = 1e6;
    uint256 internal constant NOMINAL_BALANCE_MAX = 1e20;
    uint256 internal constant NOMINAL_RATE_MAX = 1e6;

    function _nominalBalance(uint256 v) internal pure returns (uint256) {
        if (v < NOMINAL_BALANCE_MIN) {
            return NOMINAL_BALANCE_MIN;
        }
        return v > NOMINAL_BALANCE_MAX ? NOMINAL_BALANCE_MAX : v;
    }

    function _nominalRate(uint256 v) internal pure returns (uint256) {
        if (v == 0) {
            return 1;
        }
        return v > NOMINAL_RATE_MAX ? NOMINAL_RATE_MAX : v;
    }

    /// @notice Exact-out over a nominal pool: it prices, it clamps, it charges at least one
    ///         wei, and it leaves the other registers alone.
    function test_nominalPool_exactOutSuccessPath(
        uint256 balanceInSeed,
        uint256 balanceOutSeed,
        uint256 amountOut,
        uint256 amountNetPulled,
        uint256 widthSeed,
        uint256 rateLtSeed,
        uint256 rateGtSeed
    )
        public
        view
    {
        uint256 balanceIn = _nominalBalance(balanceInSeed);
        uint256 balanceOut = _nominalBalance(balanceOutSeed);
        uint256 rateLt = _nominalRate(rateLtSeed);
        uint256 rateGt = _nominalRate(rateGtSeed);

        // tokenIn == TOKEN_LO < TOKEN_HI == tokenOut, so rateIn == rateLt and rateOut == rateGt.
        bytes memory args = _args(balanceIn * rateLt, balanceOut * rateGt, _validWidth(widthSeed), rateLt, rateGt);

        SwapRegisters memory regs =
            harness.run(false, balanceIn, balanceOut, 0, amountOut, amountNetPulled, TOKEN_LO, TOKEN_HI, args);

        assertEq(
            regs.amountOut, amountOut > balanceOut ? balanceOut : amountOut, "output must be clamped to balanceOut"
        );
        if (regs.amountOut != 0) {
            assertGe(regs.amountIn, 1, "a non-zero fill must cost at least one wei in");
        }
        assertEq(regs.balanceIn, balanceIn, "balanceIn must be untouched");
        assertEq(regs.balanceOut, balanceOut, "balanceOut must be untouched");
        assertEq(regs.amountNetPulled, amountNetPulled, "amountNetPulled must be untouched");
    }

    /// @notice Exact-in over a nominal pool: it prices, it never over-quotes the output
    ///         reserve, and it leaves the other registers alone.
    /// @dev `amountOut <= balanceOut` is the exact-in counterpart of the `:196` clamp. It
    ///      is not stated over the full domain because the non-drain branch establishes it
    ///      only through `y1 <= y0`, i.e. through a `Math.sqrt` value.
    ///
    ///      `drain` selects which of the two exact-in branches is taken. A saturating clamp
    ///      alone would not: a `uint256` drawn at random saturates at the cap on virtually
    ///      every sample, so one branch would get all the coverage. `8 * balanceIn` is above
    ///      the capacity bound for every admissible `A` — `uMax = solve(C, A)` lies in
    ///      `[2*ONE, 4*ONE]`, and `u1 = 9*ONE` at a nominal pool — so it always drains,
    ///      while `min(seed, balanceIn)` gives `u1 <= 2*ONE` and never does.
    function test_nominalPool_exactInSuccessPath(
        bool drain,
        uint256 balanceInSeed,
        uint256 balanceOutSeed,
        uint256 amountInSeed,
        uint256 amountNetPulled,
        uint256 widthSeed,
        uint256 rateLtSeed,
        uint256 rateGtSeed
    )
        public
        view
    {
        uint256 balanceIn = _nominalBalance(balanceInSeed);
        uint256 balanceOut = _nominalBalance(balanceOutSeed);
        uint256 rateLt = _nominalRate(rateLtSeed);
        uint256 rateGt = _nominalRate(rateGtSeed);
        uint256 amountIn = drain ? 8 * balanceIn : (amountInSeed > balanceIn ? balanceIn : amountInSeed);

        bytes memory args = _args(balanceIn * rateLt, balanceOut * rateGt, _validWidth(widthSeed), rateLt, rateGt);

        SwapRegisters memory regs =
            harness.run(true, balanceIn, balanceOut, amountIn, 0, amountNetPulled, TOKEN_LO, TOKEN_HI, args);

        assertLe(regs.amountOut, balanceOut, "exact-in must never quote more than the output reserve");
        assertTrue(
            regs.amountIn == amountIn || regs.amountOut == balanceOut,
            "exact-in may only rewrite amountIn on the drain branch"
        );
        assertEq(regs.amountOut == balanceOut, drain, "the capacity check must pick the intended branch");
        assertEq(regs.balanceIn, balanceIn, "balanceIn must be untouched");
        assertEq(regs.balanceOut, balanceOut, "balanceOut must be untouched");
        assertEq(regs.amountNetPulled, amountNetPulled, "amountNetPulled must be untouched");
    }

    /// @notice The same shape at a realistic pool size does not underflow.
    /// @dev The companion to the witness above: it pins that the bug is confined to the
    ///      oversized-normaliser regime and that ordinary pools price cleanly, so the
    ///      success path exercised by the `try`/`catch` properties above is not vacuous.
    function test_exactOut_realisticPoolPricesCleanly() public view {
        bytes memory args = _args(1e21, 1e21, 100e27, 1, 1);

        (bool ok,, SwapRegisters memory regs) = _tryExactOut(1e21, 1e21, 1e18, TOKEN_LO, TOKEN_HI, args);

        assertTrue(ok, "a realistic pegged pool must price without reverting");
        assertEq(regs.amountOut, 1e18, "the requested output is below the balance and must not be clamped");
        assertGe(regs.amountIn, 1, "a non-zero fill must cost at least one wei in");
    }

    // =======================================================================
    // 9. The `isqrt` seam
    //
    //    `PeggedSwapHarness` Surface 2 (`seamExactIn`/`seamExactOut`) is the same
    //    instruction with each of the four `Math.sqrt(z)` call sites replaced by
    //    `_isqrt(z, w)`, which checks a caller-supplied witness `w` against
    //
    //        w * w <= z   and   z < (w + 1) * (w + 1)
    //
    //    instead of computing a root. Those two inequalities characterise
    //    `floor(sqrt(z))` uniquely, so the seam accepts exactly one witness per radicand;
    //    under Kontrol they land in the path condition as symbolic-square comparisons,
    //    which is the shape `lemmas.k` Section 7 (`sq-monotonic`, `sq-monotonic-strict`,
    //    `sq-no-overflow`) was written for, and `Math.sqrt`'s ~128-path body never runs.
    //
    //    TRUST BOUNDARY. Section 9a states the two `deadCode` properties of section 7 over
    //    the seam. They are theorems about the transcription, conditional on OZ's
    //    `Math.sqrt` returning `floor(sqrt(·))`. Section 9b is the discharge: it feeds
    //    `seamExactIn` the witnesses the real `Math.sqrt` produces and asserts the seam and
    //    the instruction agree register-for-register and revert-for-revert. Read 9a as
    //    conditional on 9b, and 9b as a *fuzz* discharge only — it calls the real
    //    `Math.sqrt` by construction and is as expensive symbolically as the unseamed
    //    instruction, so it must not be included in a `kontrol prove` run.
    //
    //    See `PeggedSwapHarness.sol`, "Surface 2", for why the witnesses are parameters
    //    rather than `vm.randomUint()` draws, and `analysis/SPEC-DESIGN.md` §2.6-2.7.
    // =======================================================================

    function _trySeamExactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint128 witnessU,
        uint128 witnessV,
        uint128 witnessMid,
        uint128 witnessDisc,
        bytes memory args
    )
        internal
        view
        returns (bool ok, bytes memory err, SwapRegisters memory regs)
    {
        try harness.seamExactIn(
            balanceIn, balanceOut, amountIn, TOKEN_LO, TOKEN_HI, witnessU, witnessV, witnessMid, witnessDisc, args
        ) returns (SwapRegisters memory r) {
            return (true, "", r);
        } catch (bytes memory e) {
            return (false, e, regs);
        }
    }

    function _trySeamExactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        uint128 witnessU,
        uint128 witnessV,
        uint128 witnessMid,
        uint128 witnessDisc,
        bytes memory args
    )
        internal
        view
        returns (bool ok, bytes memory err, SwapRegisters memory regs)
    {
        try harness.seamExactOut(
            balanceIn, balanceOut, amountOut, TOKEN_LO, TOKEN_HI, witnessU, witnessV, witnessMid, witnessDisc, args
        ) returns (SwapRegisters memory r) {
            return (true, "", r);
        } catch (bytes memory e) {
            return (false, e, regs);
        }
    }

    // -----------------------------------------------------------------------
    // 9a. Group E over the seam — the intended proof targets
    // -----------------------------------------------------------------------

    /// @notice `PeggedSwapMathNoSolution` is unreachable, stated over the seam.
    /// @dev The seamed form of `test_deadCode_noSolutionIsUnreachable_exactIn`. The proof
    ///      the seam is meant to enable: `discriminant = ONE + fourARightSide >= ONE`, so
    ///      the witness `w` at the `solve` site satisfies
    ///      `w * w <= discriminant * ONE` and `discriminant * ONE < (w + 1) * (w + 1)`;
    ///      if `w < ONE` then `(w + 1) * (w + 1) <= ONE * ONE <= discriminant * ONE`,
    ///      contradiction. That is `sq-monotonic` applied with a concrete right operand.
    ///
    ///      Vacuous under `forge test` — a fuzzed witness is rejected by the seam and the
    ///      revert carries `PeggedSwapHarnessSqrtWitness*`, not `PeggedSwapMathNoSolution`.
    ///      Under Kontrol the accepting branch is a genuine obligation, which is the point.
    function test_seam_deadCode_noSolutionIsUnreachable_exactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint128 witnessU,
        uint128 witnessV,
        uint128 witnessMid,
        uint128 witnessDisc,
        bytes calldata args
    )
        public
        view
    {
        (bool ok, bytes memory err,) =
            _trySeamExactIn(balanceIn, balanceOut, amountIn, witnessU, witnessV, witnessMid, witnessDisc, args);

        if (!ok) {
            assertTrue(_selectorOf(err) != _selNoSolution(), "PeggedSwapMathNoSolution must be unreachable");
        }
    }

    /// @notice Same, on the exact-out leg.
    function test_seam_deadCode_noSolutionIsUnreachable_exactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        uint128 witnessU,
        uint128 witnessV,
        uint128 witnessMid,
        uint128 witnessDisc,
        bytes calldata args
    )
        public
        view
    {
        (bool ok, bytes memory err,) =
            _trySeamExactOut(balanceIn, balanceOut, amountOut, witnessU, witnessV, witnessMid, witnessDisc, args);

        if (!ok) {
            assertTrue(_selectorOf(err) != _selNoSolution(), "PeggedSwapMathNoSolution must be unreachable");
        }
    }

    /// @notice `PeggedSwapMathInvalidInput` is unreachable, stated over the seam.
    /// @dev The seamed form of `test_deadCode_invalidInputIsUnreachable_exactOut`, and the
    ///      property that most needs the witnesses to be *nameable*: it is a statement
    ///      relating two different sqrt call sites. With `v1 <= v` from the `:196` clamp,
    ///      `witnessMid * witnessMid <= v1 * ONE <= v * ONE < (witnessV + 1) * (witnessV + 1)`,
    ///      so `witnessMid <= witnessV` by `sq-monotonic-strict`, and hence
    ///      `invariantV1 <= targetInvariant` since the linear terms are ordered by
    ///      `div-monotonic` (`lemmas.k` Section 4).
    function test_seam_deadCode_invalidInputIsUnreachable_exactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        uint128 witnessU,
        uint128 witnessV,
        uint128 witnessMid,
        uint128 witnessDisc,
        bytes calldata args
    )
        public
        view
    {
        (bool ok, bytes memory err,) =
            _trySeamExactOut(balanceIn, balanceOut, amountOut, witnessU, witnessV, witnessMid, witnessDisc, args);

        if (!ok) {
            assertTrue(_selectorOf(err) != _selInvalidInput(), "PeggedSwapMathInvalidInput must be unreachable");
        }
    }

    // -----------------------------------------------------------------------
    // 9b. The differential — discharge of the seam's trust boundary
    //
    //     FUZZ ONLY. Never add these to a `kontrol prove` run: they call the real
    //     `Math.sqrt` four times through `witnesses*` and again through `exactIn`/
    //     `exactOut`, which is the path explosion the seam exists to avoid.
    // -----------------------------------------------------------------------

    /// @notice The seam, fed the witnesses the real `Math.sqrt` produces, is the real
    ///         instruction — register for register, and revert for revert.
    ///
    /// @dev Follows `XYCConcentrateSpec`'s `test_diff_*` shape (`SPEC-DESIGN.md` §2.7):
    ///
    ///        1. every register compared, not just `amountOut` — the drain branch at
    ///           `PeggedSwap.sol:179` rewrites `amountIn`, and `balanceIn`/`balanceOut`/
    ///           `amountNetPulled` must be shown untouched by the transcription too;
    ///        2. the seam call sits *outside* the `try`, so a rejection of a witness the
    ///           recorder just produced is a test failure, not a skipped sample — that is
    ///           the completeness half of "the seam accepts exactly `floor(sqrt(·))`";
    ///        3. when the recorder reverts the instruction must revert with the same
    ///           selector, which is how the shared `Panic(0x11)` and guard paths are covered.
    ///
    ///      Domain: the nominal pool of `test_nominalPool_exactInSuccessPath`, so the
    ///      success path is actually reached — over unconstrained `args` the recorder would
    ///      revert in `parse` on virtually every sample and the property would degenerate
    ///      into selector agreement. `drain` picks between the two exact-in branches for
    ///      the same reason it does there.
    function test_diff_seamMatchesInstruction_exactIn(
        bool drain,
        uint256 balanceInSeed,
        uint256 balanceOutSeed,
        uint256 amountInSeed,
        uint256 widthSeed,
        uint256 rateLtSeed,
        uint256 rateGtSeed
    )
        public
        view
    {
        uint256 balanceIn = _nominalBalance(balanceInSeed);
        uint256 balanceOut = _nominalBalance(balanceOutSeed);
        uint256 rateLt = _nominalRate(rateLtSeed);
        uint256 rateGt = _nominalRate(rateGtSeed);
        uint256 amountIn = drain ? 8 * balanceIn : (amountInSeed > balanceIn ? balanceIn : amountInSeed);
        bytes memory args = _args(balanceIn * rateLt, balanceOut * rateGt, _validWidth(widthSeed), rateLt, rateGt);

        (bool okReal, bytes memory errReal, SwapRegisters memory expected) =
            _tryExactIn(balanceIn, balanceOut, amountIn, TOKEN_LO, TOKEN_HI, args);

        try harness.witnessesExactIn(balanceIn, balanceOut, amountIn, TOKEN_LO, TOKEN_HI, args) returns (
            uint128 witnessU, uint128 witnessV, uint128 witnessMid, uint128 witnessDisc
        ) {
            assertTrue(okReal, "the transcription priced where the instruction reverted");

            SwapRegisters memory actual = harness.seamExactIn(
                balanceIn, balanceOut, amountIn, TOKEN_LO, TOKEN_HI, witnessU, witnessV, witnessMid, witnessDisc, args
            );

            assertEq(actual.amountIn, expected.amountIn, "seam and instruction must agree on amountIn");
            assertEq(actual.amountOut, expected.amountOut, "seam and instruction must agree on amountOut");
            assertEq(actual.balanceIn, expected.balanceIn, "seam and instruction must agree on balanceIn");
            assertEq(actual.balanceOut, expected.balanceOut, "seam and instruction must agree on balanceOut");
            assertEq(
                actual.amountNetPulled, expected.amountNetPulled, "seam and instruction must agree on amountNetPulled"
            );
        } catch (bytes memory errSeam) {
            assertFalse(okReal, "the transcription reverted where the instruction priced");
            assertTrue(_selectorOf(errSeam) == _selectorOf(errReal), "seam and instruction must fail identically");
        }
    }

    /// @notice Same, on the exact-out leg.
    function test_diff_seamMatchesInstruction_exactOut(
        uint256 balanceInSeed,
        uint256 balanceOutSeed,
        uint256 amountOut,
        uint256 widthSeed,
        uint256 rateLtSeed,
        uint256 rateGtSeed
    )
        public
        view
    {
        uint256 balanceIn = _nominalBalance(balanceInSeed);
        uint256 balanceOut = _nominalBalance(balanceOutSeed);
        uint256 rateLt = _nominalRate(rateLtSeed);
        uint256 rateGt = _nominalRate(rateGtSeed);
        bytes memory args = _args(balanceIn * rateLt, balanceOut * rateGt, _validWidth(widthSeed), rateLt, rateGt);

        (bool okReal, bytes memory errReal, SwapRegisters memory expected) =
            _tryExactOut(balanceIn, balanceOut, amountOut, TOKEN_LO, TOKEN_HI, args);

        try harness.witnessesExactOut(balanceIn, balanceOut, amountOut, TOKEN_LO, TOKEN_HI, args) returns (
            uint128 witnessU, uint128 witnessV, uint128 witnessMid, uint128 witnessDisc
        ) {
            assertTrue(okReal, "the transcription priced where the instruction reverted");

            SwapRegisters memory actual = harness.seamExactOut(
                balanceIn, balanceOut, amountOut, TOKEN_LO, TOKEN_HI, witnessU, witnessV, witnessMid, witnessDisc, args
            );

            assertEq(actual.amountIn, expected.amountIn, "seam and instruction must agree on amountIn");
            assertEq(actual.amountOut, expected.amountOut, "seam and instruction must agree on amountOut");
            assertEq(actual.balanceIn, expected.balanceIn, "seam and instruction must agree on balanceIn");
            assertEq(actual.balanceOut, expected.balanceOut, "seam and instruction must agree on balanceOut");
            assertEq(
                actual.amountNetPulled, expected.amountNetPulled, "seam and instruction must agree on amountNetPulled"
            );
        } catch (bytes memory errSeam) {
            assertFalse(okReal, "the transcription reverted where the instruction priced");
            assertTrue(_selectorOf(errSeam) == _selectorOf(errReal), "seam and instruction must fail identically");
        }
    }

    /// @notice The seam prices the realistic pool identically to the instruction, and does
    ///         so on the branch where all four sqrt sites are live.
    /// @dev The anti-vacuity anchor for section 9, and the companion to
    ///      `test_exactOut_realisticPoolPricesCleanly`. Fully concrete on both sides, so it
    ///      costs the prover nothing and can be included in a `kontrol prove` run as a
    ///      cheap check that the seam is wired up — `linearWidth = 100e27 != 0`, so `solve`
    ///      runs its `Math.sqrt` and `witnessDisc` is genuinely exercised.
    function test_seam_realisticPoolMatchesInstruction() public view {
        bytes memory args = _args(1e21, 1e21, 100e27, 1, 1);

        (uint128 witnessU, uint128 witnessV, uint128 witnessMid, uint128 witnessDisc) =
            harness.witnessesExactOut(1e21, 1e21, 1e18, TOKEN_LO, TOKEN_HI, args);

        assertTrue(witnessDisc != 0, "the solve-site witness must be exercised at a non-zero linear width");

        SwapRegisters memory actual = harness.seamExactOut(
            1e21, 1e21, 1e18, TOKEN_LO, TOKEN_HI, witnessU, witnessV, witnessMid, witnessDisc, args
        );

        (bool ok,, SwapRegisters memory expected) = _tryExactOut(1e21, 1e21, 1e18, TOKEN_LO, TOKEN_HI, args);

        assertTrue(ok, "a realistic pegged pool must price without reverting");
        assertEq(actual.amountIn, expected.amountIn, "seam and instruction must agree on amountIn");
        assertEq(actual.amountOut, expected.amountOut, "seam and instruction must agree on amountOut");
    }
}

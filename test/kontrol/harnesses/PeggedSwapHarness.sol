// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context, SwapRegisters } from "../../../src/libs/VM.sol";
import { PeggedSwap, PeggedSwapArgsBuilder } from "../../../src/instructions/PeggedSwap.sol";
import { PeggedSwapMath } from "../../../src/libs/PeggedSwapMath.sol";

/// @notice External surface over PeggedSwap's internal instruction, for symbolic execution.
///
/// @dev `Context` embeds an internal function pointer (`VM.dispatch`), so it is not
///      ABI-encodable and cannot be passed across an external call. As in `XYCSwapHarness`,
///      the harness therefore accepts the individual registers as scalars and assembles the
///      `Context` in memory.
///
///      `ctx.vm` is left zero-initialised, which is safe here for the same reason it is safe
///      in `XYCSwapHarness`: `_peggedSwapGrowPriceRange2D` never calls `ctx.runLoop()` and
///      never dispatches, so the null function pointer is never invoked. It reads exactly
///      four context fields — `ctx.query.isExactIn`, `ctx.query.tokenIn`,
///      `ctx.query.tokenOut` (`PeggedSwap.sol:139-140`, consumed by
///      `PeggedSwapArgsBuilder.parseRatesAndBalances` at `:76-78`) and `ctx.swap` — so all
///      four are exposed as parameters. The token addresses matter: their *ordering*
///      selects which of `rateLt`/`rateGt` applies and which of `x0`/`y0` is the input-side
///      normaliser, which is a known vulnerability class in this codebase and the subject
///      of the direction-symmetry properties in the spec.
///
///      The whole `SwapRegisters` struct is returned rather than a single amount, so that
///      register-isolation properties (`amountNetPulled` untouched, balances not mutated)
///      are expressible.
contract PeggedSwapHarness is PeggedSwap {
    /// @notice `_peggedSwapGrowPriceRange2D` with every register and both token addresses
    ///         under the caller's control.
    /// @dev The fully general entry point. Use it when a property needs to observe or vary
    ///      a register the narrower wrappers pin to zero — in particular `amountNetPulled`,
    ///      and the "wrong" amount register that trips the recompute guards at
    ///      `PeggedSwap.sol:157` (exact-in) and `:194` (exact-out).
    function run(
        bool isExactIn,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountNetPulled,
        address tokenIn,
        address tokenOut,
        bytes calldata args
    )
        external
        pure
        returns (SwapRegisters memory)
    {
        Context memory ctx;
        ctx.query.isExactIn = isExactIn;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;
        ctx.swap.amountNetPulled = amountNetPulled;

        _peggedSwapGrowPriceRange2D(ctx, args);

        return ctx.swap;
    }

    /// @notice Exact-input direction: the taker fixes `amountIn`, the VM computes `amountOut`.
    /// @dev `amountOut` and `amountNetPulled` enter as zero, i.e. the register state a
    ///      well-formed program presents to the instruction.
    function exactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        address tokenIn,
        address tokenOut,
        bytes calldata args
    )
        external
        pure
        returns (SwapRegisters memory)
    {
        Context memory ctx;
        ctx.query.isExactIn = true;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;

        _peggedSwapGrowPriceRange2D(ctx, args);

        return ctx.swap;
    }

    /// @notice Exact-output direction: the taker fixes `amountOut`, the VM computes `amountIn`.
    /// @dev `amountIn` and `amountNetPulled` enter as zero.
    function exactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        address tokenIn,
        address tokenOut,
        bytes calldata args
    )
        external
        pure
        returns (SwapRegisters memory)
    {
        Context memory ctx;
        ctx.query.isExactIn = false;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountOut = amountOut;

        _peggedSwapGrowPriceRange2D(ctx, args);

        return ctx.swap;
    }

    // =======================================================================
    // Surface 2 — the `isqrt` seam
    //
    //   TRUST BOUNDARY. Everything below this line is a *transcription* of
    //   `PeggedSwap._peggedSwapGrowPriceRange2D` (`:98-224`) together with the two
    //   `PeggedSwapMath` helpers it calls (`invariantFromReserves` `:39-50` and `solve`
    //   `:63-104`), with exactly one edit: each of the four `Math.sqrt(z)` call sites is
    //   replaced by `_isqrt(z, w)`, which does not compute a square root — it *checks* a
    //   caller-supplied witness against the defining property of the integer square root.
    //
    //   A property proven on `seamExactIn`/`seamExactOut` is therefore a theorem about
    //   this transcription, not about `PeggedSwap`'s bytecode, until the differential
    //   property in `PeggedSwapSpec` (section 9) closes the gap. Read §2.6 and §2.7 of
    //   `test/kontrol/analysis/SPEC-DESIGN.md` as part of this comment.
    //
    //   ## Why the seam exists
    //
    //   `Math.sqrt` is inlined straight-line code: seven data-dependent branches for the
    //   MSB estimate followed by six unrolled Newton steps over symbolic operands. Four
    //   call sites compose to roughly 2^28 paths, which is why every property whose proof
    //   must reason through a sqrt *value* is out of scope on Surface 1. Axioms about an
    //   `isqrt` symbol cannot help, because nothing in the instruction ever produces such a
    //   symbol — there is no seam for them to attach to. `_isqrt` is that seam.
    //
    //   ## What the seam is, precisely
    //
    //   `_isqrt(a, w)` reverts unless
    //
    //       w * w <= a   and   a < (w + 1) * (w + 1)
    //
    //   and otherwise returns `w`. Those two inequalities hold for exactly one `w` per `a`,
    //   namely `floor(sqrt(a))`, so the seam is both sound (it never returns a non-root)
    //   and complete (it accepts every root). It is *extensionally* equal to
    //   `Math.sqrt` — the residual assumption is only that OZ's `Math.sqrt` computes the
    //   same function, which is what the differential property tests.
    //
    //   Under Kontrol the payoff is that the two inequalities land in the path condition
    //   as symbolic-square comparisons, which is precisely the shape `lemmas.k` Section 7
    //   (`sq-monotonic`, `sq-monotonic-strict`, `sq-no-overflow`) was written for, and the
    //   `Math.sqrt` body is never executed.
    //
    //   ## Parameter, not `vm.randomUint()`
    //
    //   `SPEC-DESIGN.md` §2.6 offers three seam constructions. This is (a) — the witness is
    //   promoted to a harness parameter — rather than (b), a fresh `vm.randomUint()` symbol
    //   constrained by two `vm.assume`s. Four reasons, in decreasing order of importance:
    //
    //     1. **The properties need to name the witnesses.** `Math.sqrt` runs at four sites
    //        per path and the interesting facts are *relations between different sites* —
    //        `test_deadCode_invalidInputIsUnreachable_exactOut` is exactly the statement
    //        that the root at the `v1` site does not exceed the root at the `v` site. A
    //        `vm.randomUint()` symbol is anonymous: it exists inside the harness and cannot
    //        be mentioned, constrained or compared by a spec. A parameter can be.
    //
    //     2. **`uint128` is a free, exact bound.** `floor(sqrt(a)) < 2^128` for every
    //        `a < 2^256`, so `uint128` loses nothing, and per `SPEC-DESIGN.md` §1.2 the
    //        ABI-derived `#rangeUInt(128, W)` enters the *initial* constraint set at zero
    //        path cost. That bound is what lets every product below sit inside `unchecked`:
    //        no solc overflow check, and therefore **no symbolic `DIV` from the seam in the
    //        path condition** (solc's checked `mul` is `div(product, x) == y`). A
    //        `vm.randomUint()` draw is unbounded and would need either a third `vm.assume`
    //        or the checked-`mul` division.
    //
    //     3. **The harness stays `pure`.** No `forge-std` dependency, no cheatcode address
    //        in a contract that inherits the production instruction, and no change to
    //        `PeggedSwapSpec`'s `view` helpers — `vm.randomUint` is a non-`view` cheatcode
    //        and would force the whole call chain non-`view`.
    //
    //     4. **`forge test` stays meaningful.** `vm.assume(w * w <= a)` on a fresh 256-bit
    //        draw rejects essentially every fuzz sample, so under the fuzzer the spec would
    //        degrade to "too many rejects". Here a bad witness is a *revert* with a
    //        dedicated selector, which the spec's existing `try`/`catch` idiom already
    //        handles, and `witnessesExactIn`/`witnessesExactOut` hand the fuzzer witnesses
    //        that are correct by construction so the differential is not vacuous.
    //
    //   Construction (c), `vm.mockFunction` on an `ISqrt` oracle, was not used: it needs a
    //   refactor of production code to route the call through an external contract.
    // =======================================================================

    /// @notice The supplied witness is larger than `floor(sqrt(radicand))`.
    error PeggedSwapHarnessSqrtWitnessTooLarge(uint256 radicand, uint128 witness);

    /// @notice The supplied witness is smaller than `floor(sqrt(radicand))`.
    error PeggedSwapHarnessSqrtWitnessTooSmall(uint256 radicand, uint128 witness);

    /// @notice One witness per `Math.sqrt` call site on a single execution of the
    ///         instruction, plus the mode flag.
    ///
    /// @dev The four sites, in source order:
    ///
    ///        `u`    `PeggedSwapMath.sol:25`  `Math.sqrt(u * ONE)`  — invariant, input side
    ///        `v`    `PeggedSwapMath.sol:26`  `Math.sqrt(v * ONE)`  — invariant, output side
    ///        `mid`  `PeggedSwap.sol:167`     `Math.sqrt(u1 * ONE)` — exact-in capacity check
    ///               `PeggedSwap.sol:205`     `Math.sqrt(v1 * ONE)` — exact-out, the mirror
    ///        `disc` `PeggedSwapMath.sol:93`  `Math.sqrt(discriminant * ONE)` — `solve`
    ///
    ///      `solve` is called at most once per path (the exact-in capacity check picks one
    ///      of two `solve` calls, never both), and not at all when `linearWidth == 0`, so
    ///      one `disc` witness suffices and may be left unread.
    ///
    /// @param record When true, `_isqrt` calls the real `Math.sqrt` and the body writes the
    ///        results back into this struct instead of checking them. Set only by
    ///        `witnessesExactIn`/`witnessesExactOut`, and always from a literal, so under
    ///        Kontrol it is a concrete `0` on every seam path: the `JUMPI` is decided
    ///        without branching and the `Math.sqrt` body is unreachable.
    struct SqrtWitnesses {
        uint128 u;
        uint128 v;
        uint128 mid;
        uint128 disc;
        bool record;
    }

    /// @notice The seam. Checks that `witness == floor(sqrt(radicand))` and returns it.
    ///
    /// @dev The two `require`s are the characterising axioms of the integer square root,
    ///      stated so that both sides of each comparison are literal products of symbolic
    ///      terms — `W *Int W` and `(W +Int 1) *Int (W +Int 1)` — which is the shape
    ///      `lemmas.k` Section 7 matches on.
    ///
    ///      `unchecked` is safe and load-bearing. `witness < 2^128` holds by ABI decoding,
    ///      so `s * s < 2^256` cannot wrap (`sq-no-overflow` is the K-level statement of
    ///      exactly this) and neither can `2 * s`. Removing the checks removes solc's
    ///      `div(product, s) == s` guard, i.e. keeps a symbolic `DIV` out of the path
    ///      condition — see `test/kontrol/README.md`, "Avoid putting a symbolic division in
    ///      the path condition".
    ///
    ///      `(s + 1) * (s + 1)` wraps to `0` at the single point `witness == 2^128 - 1`,
    ///      where the true upper bound `radicand < 2^256` is vacuous. The `||` disjunct
    ///      restores completeness there. It short-circuits, so on every accepting path it
    ///      costs nothing; the extra branch it introduces lives only on the rejecting path,
    ///      which is a revert leaf.
    function _isqrt(uint256 radicand, uint128 witness, bool record) private pure returns (uint256 s) {
        if (record) {
            // `Math.sqrt(x)` and `Math.sqrt(x, Math.Rounding.Floor)` are the same function
            // (`Math.sol:601-606` adds the rounding correction only for `Ceil`), so one
            // recorder serves all four sites.
            return Math.sqrt(radicand);
        }

        s = uint256(witness);

        unchecked {
            require(s * s <= radicand, PeggedSwapHarnessSqrtWitnessTooLarge(radicand, witness));
            require(
                radicand < (s + 1) * (s + 1) || witness == type(uint128).max,
                PeggedSwapHarnessSqrtWitnessTooSmall(radicand, witness)
            );
        }
    }

    /// @notice Transcription of `PeggedSwapMath.invariant` (`:24-30`).
    function _seamInvariant(uint256 u, uint256 v, uint256 a, SqrtWitnesses memory wit) private pure returns (uint256) {
        uint256 sqrtU = _isqrt(u * PeggedSwapMath.ONE, wit.u, wit.record);
        uint256 sqrtV = _isqrt(v * PeggedSwapMath.ONE, wit.v, wit.record);
        if (wit.record) {
            wit.u = uint128(sqrtU);
            wit.v = uint128(sqrtV);
        }
        uint256 linearTerm = a * (u + v) / PeggedSwapMath.ONE;
        return sqrtU + sqrtV + linearTerm;
    }

    /// @notice Transcription of `PeggedSwapMath.invariantFromReserves` (`:39-50`).
    function _seamInvariantFromReserves(
        uint256 x,
        uint256 y,
        uint256 x0,
        uint256 y0,
        uint256 a,
        SqrtWitnesses memory wit
    )
        private
        pure
        returns (uint256)
    {
        uint256 u = x * PeggedSwapMath.ONE / x0;
        uint256 v = y * PeggedSwapMath.ONE / y0;
        return _seamInvariant(u, v, a, wit);
    }

    /// @notice Transcription of `PeggedSwapMath.solve` (`:63-104`).
    /// @dev Rounding directions untouched: the `a == 0` shortcut floors, `w` floors, `v`
    ///      floors. The `PeggedSwapMathNoSolution` `require` at `:95` is reproduced with the
    ///      library's own error, so `test_deadCode_noSolutionIsUnreachable_*` inspects the
    ///      same selector on the seam as on the real instruction.
    function _seamSolve(uint256 rightSide, uint256 a, SqrtWitnesses memory wit) private pure returns (uint256 v) {
        if (a == 0) {
            v = (rightSide * rightSide) / PeggedSwapMath.ONE;
            return v;
        }

        uint256 fourARightSide = 4 * a * rightSide / PeggedSwapMath.ONE;

        uint256 discriminant = PeggedSwapMath.ONE + fourARightSide;

        uint256 sqrtDiscriminant = _isqrt(discriminant * PeggedSwapMath.ONE, wit.disc, wit.record);
        if (wit.record) {
            wit.disc = uint128(sqrtDiscriminant);
        }

        require(sqrtDiscriminant >= PeggedSwapMath.ONE, PeggedSwapMath.PeggedSwapMathNoSolution());

        uint256 denominator = PeggedSwapMath.ONE + sqrtDiscriminant;

        uint256 w = 2 * rightSide * PeggedSwapMath.ONE / denominator;

        v = w * w / PeggedSwapMath.ONE;
    }

    /// @notice Transcription of `PeggedSwap._peggedSwapGrowPriceRange2D` (`:98-224`).
    /// @dev Reproduced statement for statement. The only edits are the three redirections
    ///      to the seamed helpers above; `parse` and `parseRatesAndBalances` are the real
    ///      library functions, and every guard, rounding direction and register write is
    ///      unchanged. Diff this against the source when either file moves.
    function _seamGrowPriceRange2D(Context memory ctx, bytes calldata args, SqrtWitnesses memory wit) private pure {
        PeggedSwapArgsBuilder.Args calldata config = PeggedSwapArgsBuilder.parse(args);

        uint256 x0_raw = ctx.swap.balanceIn;
        uint256 y0_raw = ctx.swap.balanceOut;

        require(x0_raw | y0_raw != 0, PeggedSwapBothBalancesZero());

        (uint256 rateIn, uint256 rateOut, uint256 x0_init, uint256 y0_init) = PeggedSwapArgsBuilder
            .parseRatesAndBalances(config, ctx.query.tokenIn, ctx.query.tokenOut);

        uint256 x0 = x0_raw * rateIn;
        uint256 y0 = y0_raw * rateOut;

        uint256 targetInvariant = _seamInvariantFromReserves(x0, y0, x0_init, y0_init, config.linearWidth, wit);

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, PeggedSwapRecomputeDetected());
            uint256 x1 = x0 + ctx.swap.amountIn * rateIn;

            uint256 u1 = x1 * PeggedSwapMath.ONE / x0_init;

            uint256 sqrtU1 = _isqrt(u1 * PeggedSwapMath.ONE, wit.mid, wit.record);
            if (wit.record) {
                wit.mid = uint128(sqrtU1);
            }
            uint256 invariantU1 = sqrtU1 + config.linearWidth * u1 / PeggedSwapMath.ONE;

            if (invariantU1 >= targetInvariant) {
                uint256 uMax = _seamSolve(targetInvariant, config.linearWidth, wit);
                uint256 x1Capped = Math.ceilDiv(uMax * x0_init, PeggedSwapMath.ONE);

                ctx.swap.amountIn = Math.ceilDiv(x1Capped - x0, rateIn);
                ctx.swap.amountOut = y0_raw;
            } else {
                uint256 rightSide = targetInvariant - invariantU1;
                uint256 v1 = _seamSolve(rightSide, config.linearWidth, wit);

                uint256 y1 = Math.ceilDiv(v1 * y0_init, PeggedSwapMath.ONE);

                ctx.swap.amountOut = (y0 - y1) / rateOut;
            }
        } else {
            require(ctx.swap.amountIn == 0, PeggedSwapRecomputeDetected());

            if (ctx.swap.amountOut > y0_raw) ctx.swap.amountOut = y0_raw;

            uint256 y1 = y0 - ctx.swap.amountOut * rateOut;

            uint256 v1 = y1 * PeggedSwapMath.ONE / y0_init;

            uint256 sqrtV1 = _isqrt(v1 * PeggedSwapMath.ONE, wit.mid, wit.record);
            if (wit.record) {
                wit.mid = uint128(sqrtV1);
            }
            uint256 invariantV1 = sqrtV1 + config.linearWidth * v1 / PeggedSwapMath.ONE;
            require(targetInvariant >= invariantV1, PeggedSwapMath.PeggedSwapMathInvalidInput());
            uint256 u1 = _seamSolve(targetInvariant - invariantV1, config.linearWidth, wit);

            uint256 x1 = Math.ceilDiv(u1 * x0_init, PeggedSwapMath.ONE);

            uint256 amountIn = Math.ceilDiv(x1 - x0, rateIn);

            if (amountIn == 0 && ctx.swap.amountOut != 0) {
                amountIn = 1;
            }

            ctx.swap.amountIn = amountIn;
        }
    }

    /// @dev Assembles the `Context` exactly as `exactIn`/`exactOut` do, so the only
    ///      difference between Surface 1 and Surface 2 is the seam.
    function _seamRun(
        bool isExactIn,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        uint256 amountOut,
        address tokenIn,
        address tokenOut,
        bytes calldata args,
        SqrtWitnesses memory wit
    )
        private
        pure
        returns (SwapRegisters memory)
    {
        Context memory ctx;
        ctx.query.isExactIn = isExactIn;
        ctx.query.tokenIn = tokenIn;
        ctx.query.tokenOut = tokenOut;
        ctx.swap.balanceIn = balanceIn;
        ctx.swap.balanceOut = balanceOut;
        ctx.swap.amountIn = amountIn;
        ctx.swap.amountOut = amountOut;

        _seamGrowPriceRange2D(ctx, args, wit);

        return ctx.swap;
    }

    /// @notice Exact-input direction, with the four square roots supplied as witnesses.
    /// @dev The Kontrol counterpart of `exactIn`. Reverts with
    ///      `PeggedSwapHarnessSqrtWitness{TooLarge,TooSmall}` on any witness that is not the
    ///      integer square root of its radicand; on every other input it is
    ///      indistinguishable from `exactIn`.
    function seamExactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        address tokenIn,
        address tokenOut,
        uint128 witnessU,
        uint128 witnessV,
        uint128 witnessMid,
        uint128 witnessDisc,
        bytes calldata args
    )
        external
        pure
        returns (SwapRegisters memory)
    {
        SqrtWitnesses memory wit = SqrtWitnesses(witnessU, witnessV, witnessMid, witnessDisc, false);
        return _seamRun(true, balanceIn, balanceOut, amountIn, 0, tokenIn, tokenOut, args, wit);
    }

    /// @notice Exact-output direction, with the four square roots supplied as witnesses.
    function seamExactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        address tokenIn,
        address tokenOut,
        uint128 witnessU,
        uint128 witnessV,
        uint128 witnessMid,
        uint128 witnessDisc,
        bytes calldata args
    )
        external
        pure
        returns (SwapRegisters memory)
    {
        SqrtWitnesses memory wit = SqrtWitnesses(witnessU, witnessV, witnessMid, witnessDisc, false);
        return _seamRun(false, balanceIn, balanceOut, 0, amountOut, tokenIn, tokenOut, args, wit);
    }

    /// @notice The witnesses `seamExactIn` will accept for these inputs.
    ///
    /// @dev Runs the *same* transcription with `record = true`, i.e. with the real
    ///      `Math.sqrt` at all four sites, and returns what it computed. Exists so the
    ///      differential property in `PeggedSwapSpec` can feed `seamExactIn` witnesses that
    ///      are correct by construction, which is what makes that property non-vacuous
    ///      under `forge test`.
    ///
    ///      Not a proof target: it contains the `Math.sqrt` body by design and is exactly
    ///      as expensive symbolically as the real instruction. Reverts wherever the real
    ///      instruction reverts, which is itself part of what the differential checks.
    ///
    ///      A site that is not reached on the taken path keeps its zero — `disc` when
    ///      `linearWidth == 0`, since `solve` returns before its `Math.sqrt`.
    function witnessesExactIn(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountIn,
        address tokenIn,
        address tokenOut,
        bytes calldata args
    )
        external
        pure
        returns (uint128 witnessU, uint128 witnessV, uint128 witnessMid, uint128 witnessDisc)
    {
        SqrtWitnesses memory wit = SqrtWitnesses(0, 0, 0, 0, true);
        _seamRun(true, balanceIn, balanceOut, amountIn, 0, tokenIn, tokenOut, args, wit);
        return (wit.u, wit.v, wit.mid, wit.disc);
    }

    /// @notice The witnesses `seamExactOut` will accept for these inputs.
    function witnessesExactOut(
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amountOut,
        address tokenIn,
        address tokenOut,
        bytes calldata args
    )
        external
        pure
        returns (uint128 witnessU, uint128 witnessV, uint128 witnessMid, uint128 witnessDisc)
    {
        SqrtWitnesses memory wit = SqrtWitnesses(0, 0, 0, 0, true);
        _seamRun(false, balanceIn, balanceOut, 0, amountOut, tokenIn, tokenOut, args, wit);
        return (wit.u, wit.v, wit.mid, wit.disc);
    }
}

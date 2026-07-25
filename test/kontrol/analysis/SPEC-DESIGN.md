# Designing specs and harnesses for Kontrol

How to write properties that are both **provable** and **meaningful**, and how to build the
harness that makes them so.

This is a working reference, not a tutorial. It is written against *our* suite — 192
properties across eight spec files, four of them proven — and every claim is either derived
from Kontrol's own source in the container
(`/home/user/.local/lib/python3.10/site-packages/kontrol/`), from KEVM's semantics, or from
something we did in this repo and can point at by `file:line`.

Read `PROOF-MAP.md` for what is proven, `FINDINGS.md` for what is true about the
instructions, `AGENT-PROTOCOL.md` for how work is dispatched, and `../README.md` for the
build/prove loop. This file covers only the question those three do not: *given the tool,
what is the right shape for a property?*

**Hard constraint for anyone acting on this document:** never run `kontrol build` or
`--rekompile`. The K definition is shared. Everything here can be validated with
`~/.foundry/bin/forge test` and by reading.

---

## Contents

0. [The mental model: what Kontrol does to your test](#0-the-mental-model)
1. [The cheatcode vocabulary under symbolic execution](#1-the-cheatcode-vocabulary)
2. [Harness design patterns](#2-harness-design-patterns)
3. [Writing properties that cannot be vacuous](#3-writing-properties-that-cannot-be-vacuous)
4. [Assumption discipline: five ways to constrain a domain](#4-assumption-discipline)
5. [Stating guards correctly](#5-stating-guards-correctly)
6. [Structuring a spec for provability](#6-structuring-a-spec-for-provability)
7. [What not to try to prove in Kontrol](#7-what-not-to-try-to-prove-in-kontrol)
8. [Patterns from published suites](#8-patterns-from-published-suites)
9. [HANDOFF](#handoff)

---

## 0. The mental model

Everything in this document follows from four facts about what `kontrol prove` actually
does. Get these wrong and you will write specs that look fine and prove nothing.

### 0.1 Test parameters become symbolic variables with a *type-derived* constraint

Kontrol builds the initial configuration by ABI-encoding one fresh symbolic variable per
test parameter, and attaching a range predicate derived from the declared type. From
`kontrol/solc_to_k.py:1031`:

```python
def _range_predicate_uint(term, type_label):
    if type_label.startswith('uint') and not type_label.endswith(']'):
        width = 256 if type_label == 'uint' else int(type_label[4:])
        ...
        return (True, KEVM.range_uint(width, term))
```

So `uint120 x` becomes `#rangeUInt(120, X)` **in the initial constraint set** — not a path
constraint discovered during execution, not a rejected sample. It is free. This is the
mechanism behind the rule in `AGENT-PROTOCOL.md` that narrow parameter types beat
`vm.assume` bounds, and it is worth internalising as the *first* tool you reach for.

Three consequences that are less obvious:

- `address` gets `#rangeAddress`, `bool` gets `#rangeBool`, `bytesN` gets `#rangeBytes(N, _)`.
- **`bytes` and `string` parameters get only `#rangeUInt(64, lengthBytes(B))`**
  (`solc_to_k.py:1006`). The *length* is symbolic up to `2^64`. That is why
  `PeggedSwapSpec.test_parse_argsLengthGuardIsExactlyBelow160` genuinely quantifies over the
  whole `bytes` domain — and also why any spec taking `bytes calldata` and indexing into it
  is more expensive than it looks. You can pin the length with the NatSpec tag
  `@custom:kontrol-bytes-length-equals` (see §4.5).
- There is no such thing as a "sample" here. Every property is a ∀ statement over the
  constrained domain, and the domain is exactly what the types and the assumptions say.

### 0.2 The constructor does not run; `setUp()` does

`run_constructor` defaults to `False` (`kontrol/options.py:365`) and our `kontrol.toml` sets
it explicitly. Kontrol loads `deployedBytecode` and starts from there. `setUp()` is executed
as a separate proof whose final state seeds every test proof in the contract.

`immutable` values live in `deployedBytecode` as **zero placeholders** plus an
`immutableReferences` map; the constructor substitutes them at deploy time. Under Kontrol
they are all `0`. We lost seven PeggedSwap properties to this — see §3.2 — and the fix that
worked is `internal pure` accessor functions, documented at `PeggedSwapSpec.t.sol:108-140`.

There are two tool-level alternatives, both worse for our case but worth knowing:

- `--run-constructor` — actually executes the constructor. Costs you the constructor's paths
  on every proof, and for a test contract that deploys a harness in `setUp()` it buys nothing
  the accessor doesn't.
- `--symbolic-immutables` — despite the name, this is a cut-point rule on `EVM.program.load`
  (`kevm_pyk/kevm.py:222`), i.e. it checkpoints where the deployed program is installed so
  that symbolic immutables are tractable. It converts silent-zero into symbolic, which *kills
  the vacuity* but generally leaves you with an unprovable goal. Use it to diagnose, not to
  fix.

**The honest fix is to make the value part of the runtime object.** `constant` where solc
allows it; `internal pure` accessor where it does not (solc rejects `constant bytes4 X =
Err.selector` with error 8349). Verify with:

```bash
python3 -c "import json;print(json.load(open('out/PeggedSwapSpec.t.sol/PeggedSwapSpec.json'))['deployedBytecode'].get('immutableReferences'))"
```

`None` or `{}` is the only acceptable answer.

### 0.3 The currency is *paths*, not instructions

Every `JUMPI` whose condition the solver cannot decide splits the KCFG. A proof's cost is
roughly (number of leaves) × (cost of discharging each leaf's constraint set). This reframes
almost every design decision:

- A symbolic `DIV` is expensive not because division is hard but because Solidity 0.8 emits a
  divide-by-zero check around it (`ISZERO; JUMPI; ...; REVERT`) and KEVM's `/Word` splits on
  `W1 ==Int 0` (`kontrol/kdist/kontrol_lemmas.md:39-40`). One division = one guaranteed
  branch plus an opaque `/Int` term in every downstream constraint.
- `Math.sqrt` costs ~128 paths per call (7 data-dependent branches for the MSB estimate),
  which is why four of them compose to ~2^28 (`FINDINGS.md`, "PeggedSwap — abstract
  `Math.sqrt` or do not start").
- `Math.mulDiv` forks into a 512-bit Newton-inverse path per call site because KEVM cannot
  decide `high == 0` without the `mul512` collapse lemma.
- A loop with `k` iterations where each iteration's extra branches all *terminate* the loop
  is a caterpillar with `O(k)` leaves. A loop with two *continuing* arms is `2^k`. This is
  exactly the difference between `PiecewiseLinearScale.runLoop` (tractable at `--bmc-depth
  51`) and `Power.pow` (65 536 leaves at 16 bits). `FINDINGS.md` has both.

The design consequence: **spend your harness budget on keeping expensive machinery off the
path**, not on making assertions cleverer.

### 0.4 Assertions are cheatcodes, and the proof obligation is "no leaf is failing"

`assertEq(uint256,uint256)` etc. compile to a call to the cheat address, which Kontrol
handles in `kdist/assert.md` by setting a `failed` flag. The proof target is: every leaf
either reverted-as-expected or ended `EVMC_SUCCESS` with `failed == false`.

This has a sharp edge that we half-documented and got the reason wrong. `assertEq(bytes
memory, bytes memory)` in modern forge-std delegates to `vm.assertEq(bytes,bytes)`
(`node_modules/forge-std/src/StdAssertions.sol:178`), and Kontrol implements that as
(`kdist/assert.md`, rule `cheatcode.call.assertEq.Dtype`):

```
#let ARG1_VALUE = #asWord(#range(ARGS, 32 +Int ARG1_START, ARG1_LEN)) #in
#let ARG2_VALUE = #asWord(#range(ARGS, 32 +Int ARG2_START, ARG2_LEN)) #in
  #assert_eq ARG1_VALUE ARG2_VALUE ...
```

and `#asWord(WS) => chop(Bytes2Int(WS, BE, Unsigned))` (`evm-semantics/evm-types.md:355`).

So under Kontrol, `assertEq(bytes, bytes)` compares the two arrays' **low-order 32 bytes,
with the lengths discarded**. For a 36-byte revert payload — selector plus one argument word
— it compares the argument and *ignores the selector entirely*. Two different errors carrying
the same argument compare equal.

`PeggedSwapSpec.t.sol:259-262` reaches the right conclusion ("deliberately *not*
`assertEq(bytes, bytes)`") from the wrong premise. The keccak claim describes
`assertEq0`/`checkEq0` (`StdAssertions.sol:694-696`), which is a different function we do not
use. **Correct the comment**: the real reason is `#asWord` truncation, which is worse than a
hash-injectivity assumption — it is silently, concretely unsound as a bytes comparison. The
assembly `bytes4` extraction at `PeggedSwapSpec.t.sol:263` is right, and now for a better
reason.

---

## 1. The cheatcode vocabulary

Authoritative source: `kontrol/kdist/cheatcodes.md` (2040 lines) and `kdist/assert.md`.
Everything below is read off the K rules, with the selector table at
`cheatcodes.md:1908-1975` telling you what is implemented.

### 1.1 The whole implemented set, and its cost

| Cheatcode | K rule | Effect under symbolic execution | Path cost |
|---|---|---|---|
| `vm.assume(bool)` | `cheatcode.call.assume` | `#assume(ARGS ==K #bufStrict(32,1))` — adds a constraint | **Zero by itself.** The cost is in *evaluating the argument*, which is ordinary EVM code. |
| `vm.randomUint()` | `cheatcode.call.randomUint256` | fresh `?WORD`, `0 <= ?WORD < 2^256` | Zero. One new existential. |
| `vm.randomUint(bits)` | `cheatcode.call.randomUintWidth` | fresh `?WORD < 2^bits` (**bits**) | Zero. |
| `vm.randomUint(min,max)` | `cheatcode.call.randomUint256Range` | fresh `?WORD`, `min <= ?WORD <= max` | Zero. The cheapest bounded symbol there is. |
| `vm.randomBool()` / `kevm.freshBool()` | `cheatcode.call.freshBool` | fresh `?WORD` with `#rangeBool` | Zero at creation; branches when you use it. |
| `vm.randomAddress()` / `kevm.freshAddress()` | `foundry.call.freshAddress` | fresh address, `ensures #rangeAddress(?WORD) andBool ?WORD =/= #address(FoundryTest) andBool ?WORD =/= #address(FoundryCheat)` | Zero — **and it pre-excludes the two builtin addresses that a symbolic `address` parameter does not.** See §1.3. |
| `vm.randomBytes(n)` / `kevm.freshBytes(n)` | `cheatcode.call.freshBytes` | fresh `?BYTES` with `lengthBytes = n` | Zero. |
| `vm.randomBytes4()` / `randomBytes8()` | — | fresh 4/8-byte string | Zero. |
| `kevm.freshUInt(uint8 w)` | `cheatcode.call.freshUInt` | fresh `?WORD < 2^(8*w)` — **`w` is BYTES, `0 < w <= 32`** | Zero. |
| `kevm.symbolicStorage(a)` / `setArbitraryStorage(a)` | `cheatcode.call.symbolicStorage` | `<storage> _ => ?STORAGE`, `<origStorage>` too | Zero at the call; every later `SLOAD` yields a symbolic value and slot arithmetic drags in keccak reasoning. Expensive downstream. |
| `vm.copyStorage(from,to)` | `cheatcode.call.copyStorage` | copies both `storage` and `origStorage` | Zero. |
| `kevm.infiniteGas()` | `cheatcode.call.infiniteGas` | `<gas> => #gas(?_VGAS)` | Zero. **On by default** (`usegas: False`). |
| `kevm.setGas(n)` | `cheatcode.call.setGas` | `<gas> => n`, `<callGas> => 0` | Zero, but re-introduces concrete gas accounting downstream. |
| `kevm.forgetBranch(a, op, b)` | `cheatcode.call.abstract` | `#forget(a, op, b)` — **removes** a path constraint | Negative cost: it discards information to unblock simplification. Deliberately unsound if you drop something the goal needs. |
| `kevm.allowCallsToAddress(a)` | `foundry.allowAllCallsToAddress` | whitelists `a` for calls | Zero. A *frame condition*: any call elsewhere halts with `KONTROL_WHITELISTCALL`. |
| `kevm.allowCalls(a, data)` | `foundry.allowCalls` | whitelists `(a, calldata prefix)` | Zero. |
| `kevm.allowChangesToStorage(a, slot)` | `foundry.allowStorageSlotToAddress` | whitelists `{a\|slot}` **and switches the whitelist on** (`#addStorageSlotToWhitelist` sets `isStorageWhitelistActive => true`) | Zero. Any other `SSTORE` halts with `KONTROL_WHITELISTSTORAGE`. |
| `vm.expectRevert()` / `(bytes)` / `(bytes4)` | `cheatcode.call.expectRevert.{1,2}` | arms `<expectedRevert>` at the current call depth; checked at the next call/create boundary | Zero, but see §5.1 — the bare form matches **any** revert data. |
| `vm.expectStaticCall` / `expectDelegateCall` / `expectRegularCall(address,uint256,bytes)` / `expectCreate` / `expectCreate2` | `cheatcode.call.expect*` | arms `<expectedOpcode>`; the next matching `*CALL`/`CREATE*` must match address and calldata prefix | Zero. |
| `vm.expectEmit(...)` (4 overloads) | `cheatcode.call.expectEmit` | topic/data matching on the next log | Zero. |
| `vm.mockCall(a, data, retdata)` | `cheatcode.call.mockCall` | intercepts `CALL*` to `a` whose calldata has prefix `data`, returns `retdata` without executing | **Removes** the callee's entire path contribution. The single biggest lever for external calls. |
| `vm.mockFunction(callee, target, data)` | `cheatcode.call.mockFunction` | runs `target`'s **code** at `callee`'s address/storage | Same lever, but the substitute is a contract you write — so it can be symbolic. |
| `vm.deal / etch / warp / roll / fee / chainId / coinbase / label / getNonce / setNonce / store / load / addr / computeCreateAddress / sign / prank / startPrank / stopPrank / toString / ffi` | various | as in Foundry | Zero, except `load`/`store` which touch storage and `ffi` which returns a fresh symbol unless `--ffi`. |

**Declared but NOT implemented** (they appear only in the selector table at
`cheatcodes.md:1981-2030`, with no `#cheatcode_call` rule, so they fall through to
`cheatcode.call.owise` and halt the proof with `CHEATCODE_UNIMPLEMENTED`):

`expectCall(address,bytes)`, `expectCall(address,uint256,bytes)`, `expectNoCall()`,
`expectRegularCall(address,bytes)`, `mockCall(address,uint256,bytes,bytes)`,
`clearMockedCalls()`, `record()`/`accesses(address)`, `recordLogs()`/`getRecordedLogs()`,
`snapshot()`/`revertTo()`, every `env*`, `setEnv`, `getCode(string)`, `broadcast*`, all file
IO, all fork cheats, `deriveKey`. Also absent from the table entirely and therefore
unimplemented: `vm.assumeNoRevert()`, `vm.expectPartialRevert`, the gas-snapshot family.

This matters practically: a spec that reaches for `vm.expectCall` to state "the instruction
must call the oracle" will pass `forge test` and die under Kontrol with an unimplemented
cheatcode. Use `kevm.expectRegularCall(address,uint256,bytes)` or `allowCallsToAddress`
instead.

**Availability.** `kontrol-cheatcodes` is not in our `node_modules` and not in
`remappings.txt`, so `kevm.*` is currently unreachable from our specs. The `vm.random*`
family *is* reachable — it is in `forge-std`'s `Vm.sol`
(`node_modules/forge-std/src/Vm.sol:1945-1972`) and Kontrol implements it symbolically. If we
need the `kevm.*` cheats we can declare the interface ourselves; they are ordinary calls to
`address(uint160(uint256(keccak256("hevm cheat code"))))`.

### 1.2 The five that actually matter for us

**`vm.assume`.** The one everyone reaches for and the one that most often stalls a proof —
but not for the reason people assume. The cheatcode itself is free; it appends a constraint.
The cost is that the *expression* is compiled Solidity that runs before the call. If the
expression contains a division, a `mulDiv`, a `sqrt`, or an external call, all of that lands
on the path **and** the resulting term lands in the path condition, where it poisons every
downstream simplification. Our canonical failure:

```solidity
vm.assume(amountIn <= type(uint256).max / balanceOut);   // XYCSwapSpec, earlier revision
```

`balanceOut` is symbolic, so KEVM applies `_ /Word W1 => 0 requires W1 ==Int 0` /
`W0 /Word W1 => W0 /Int W1 requires W1 =/=Int 0` (`kontrol_lemmas.md:39-40`) — a branch — and
then carries an opaque `maxUInt256 /Int BALANCE_OUT` in every later constraint. Four nodes,
no progress in five minutes. The `try`/`catch` replacement (§4.4) removed both the branch and
the term, and *widened* the theorem.

**`vm.randomUint(min, max)`.** Underused. It is the only primitive that gives you a bounded
symbolic value at zero path cost *and* still runs under the fuzzer, where Foundry implements
it as a pseudo-random draw in range. Compare the three ways to say "`sqrtPriceMin` is in
`[1, 2^56]`":

```solidity
// 1. vm.assume — one path constraint under Kontrol, ~100% sample rejection under forge
uint256 sqrtPriceMin; vm.assume(sqrtPriceMin >= 1 && sqrtPriceMin <= 2**56);

// 2. narrow type + arithmetic — free under Kontrol, no rejection under forge  (what we do)
function f(uint56 minRaw) { uint256 sqrtPriceMin = 1 + uint256(minRaw); }

// 3. vm.randomUint(min,max) — free under Kontrol, no rejection under forge, and the
//    bound is written where a reader looks for it
uint256 sqrtPriceMin = vm.randomUint(1, 2**56);
```

(2) is what `XYCConcentrateSpec._priceBounds` (`:543-550`) does and it is fine. (3) is
strictly more readable when the bound is not a power of two, because it does not force you to
invent a `uint56` and an offset and then *explain* them in a docstring. Adopt it for bounds
that are not naturally a type width.

**`vm.mockFunction`.** The seam we have been missing. `PROOF-MAP.md` ranks the `isqrt`
abstraction as the single highest-value blocked item, and correctly notes that axioms alone
cannot fire because `Math.sqrt` is inlined straight-line code and nothing introduces an
`isqrt` symbol. `mockFunction` is one way to introduce one — see §2.6.

**`kevm.allowChangesToStorage`.** Irrelevant today (every instruction under test is `pure`),
but it is the right tool the moment Tier 3 starts. It expresses a *frame condition* — "these
are the only slots that may change" — which is a class of property `assertEq` cannot state
without enumerating the whole storage layout. Note the activation semantics: the first call
switches the whitelist on globally, so you must enumerate *all* legitimate writes in one go.

**`kevm.forgetBranch`.** The escape hatch for a stalled proof. It deletes a path constraint
of the form `op1 <op> op2`. Legitimate use: you branched on `x < y` to establish something,
you have used it, and the constraint is now only making the solver's life harder. Illegitimate
use: forgetting the constraint the goal depends on, which turns a hard proof into a vacuous
one silently. If you use it, say so in the docstring and in the handoff, at the same
prominence as a domain narrowing.

RV's own test (`kontrol/src/tests/integration/test-data/test/ForgetBranch.t.sol`) shows the
semantics sharply — after forgetting `x > 200`, a subsequent `if (x > 200)` **branches again**:

```solidity
vm.assume(x > 200);
kevm.forgetBranch(x, KontrolCheatsBase.ComparisonOperator.GreaterThan, 200);
if (x > 200) { y = 21; } else { y = 42; }   // both arms now feasible
```

Note also the enum: `{ Equal, NotEqual, LessThanOrEqual, LessThan, GreaterThanOrEqual, GreaterThan }`.

### 1.3 Symbolic addresses are more expensive than they look

Not a cheatcode, but it belongs here because it is the most common accidental cost in a spec
and we pay it in four properties.

When an `address` is symbolic, KEVM must branch on whether that account already exists in the
`<accounts>` cell. RV's Node Refutation guide is explicit:

> when we prank on an address, Kontrol needs to know whether this address already exists in
> the `<accounts>` cell or if it's a new address. As a result, it creates one branch for the
> case where the address is new, and three other branches corresponding to the cases where
> `addr` is one of the three addresses already present. … in real-world contracts, this
> non-deterministic branching has the potential to increase by several times the running time
> of symbolic execution, as the same test will have to execute in each branch, and in most
> cases the specific address is unlikely to make a difference.

Our test contracts have at least three live accounts by the time a test runs: the test
contract, the cheat address, and the harness deployed in `setUp()`. So a free `address
tokenIn` parameter multiplies the whole proof by four.

`XYCConcentrateSpec.test_full_exactIn_revertsWhenAmountOutAlreadySet` (`:568`),
`test_full_exactOut_revertsWhenAmountInAlreadySet` (`:587`) and `test_full_cannotDrainPool`
(`:616`) all take free symbolic `tokenIn`/`tokenOut`, and their docstrings say why — the
theorem must cover both orientations. That is a good reason, so keep the properties, but be
aware you are paying ~4× for it and add the disequalities:

```solidity
vm.assume(tokenIn  != address(this) && tokenIn  != address(harness) && tokenIn  != VM_ADDRESS);
vm.assume(tokenOut != address(this) && tokenOut != address(harness) && tokenOut != VM_ADDRESS);
```

`kontrol-cheatcodes` ships this as `KontrolCheats.notBuiltinAddress(address)`, hard-coding the
two builtins (`0x7109…12D` cheat address and `0x7FA9…496` test address). `vm.randomAddress()`
excludes them by construction, which is a real argument for using it instead of a parameter
when you do not need the address to be part of the ABI-level quantification.

Where only the *ordering* matters, use two concrete addresses, as
`XYCConcentrateSpec.TOKEN_LO/TOKEN_HI` (`:91-92`) and `PeggedSwapSpec` (`:105-106`) do, and
run the property twice in the two orientations. Two cheap proofs beat one four-way-branched
proof. The file docstring at `XYCConcentrateSpec:87-92` already draws exactly this
distinction; make it the default and use symbolic addresses only where the guard must hold in
both orientations *and* the orientation cannot be fixed by a second property.

---

## 2. Harness design patterns

A harness is not test scaffolding. It is **part of the specification**: it fixes what is
quantified over, what is observable, and how much of the real instruction is actually being
verified. Every harness in this repo should be readable as a statement of scope.

### 2.1 Exposing an `internal` function

The base pattern, and the reason all our harnesses inherit rather than wrap:

```solidity
contract XYCSwapHarness is XYCSwap {
    function exactIn(uint256 balanceIn, uint256 balanceOut, uint256 amountIn, bytes calldata args)
        external pure returns (uint256 amountOut) { ... }
}
```

Inheritance, not composition: `_xycSwapXD` is `internal`, so a wrapper contract could not
call it, and copying it would be a transcription (§2.7). Mark the entrypoint `pure` or `view`
wherever the instruction allows — it lets the spec function be `view`, which keeps `setUp`'s
state out of the frame and makes the `try`/`catch` form legal.

### 2.2 `Context` is not ABI-encodable — assemble it in memory

`VM` embeds `function(Context memory, uint256, bytes calldata) internal dispatch`
(`src/libs/VM.sol:24`). An internal function pointer is a code offset; it has no ABI type. So
`Context` cannot cross an external call and the harness must take the registers as scalars
and build the struct:

```solidity
Context memory ctx;
ctx.query.isExactIn = true;
ctx.swap.balanceIn = balanceIn;
...
_xycSwapXD(ctx, args);
amountOut = ctx.swap.amountOut;
```

This is not a workaround, it is a feature: it makes the *initial register state* an explicit
part of the quantification. `XYCSwapHarness.exactInWithAmountOut` (`:53`) exists precisely to
put `ctx.swap.amountOut` under the spec's control so the recompute guard can be exercised;
had `Context` been ABI-encodable we would have got that for free and probably never thought
about it.

### 2.3 When leaving `ctx.vm` zero-initialised is safe — and when it is not

`XYCSwapHarness` leaves `ctx.vm` zero. The docstring (`:12-15`) states the condition:
`_xycSwapXD` reads only `ctx.query.isExactIn` and `ctx.swap`, never dispatches, so the null
function pointer is never invoked.

**It is unsafe the moment the instruction dispatches.** A zero internal function pointer in
Solidity jumps to offset 0, which under the via-IR pipeline lands in the dispatcher preamble
and produces an arbitrary revert — under the fuzzer you would see a confusing failure; under
Kontrol you would prove a theorem about an instruction that always reverts.

The check is mechanical, and worth doing rather than asserting. For any instruction you are
about to harness:

```bash
grep -n 'runLoop\|\.dispatch\|setNextPC\|program()\|takerArgs()\|tryChopTakerArgs' src/instructions/<X>.sol
```

Empty output means zero-init is safe. Non-empty means §2.4. In this repo the instructions
that reach the VM half are `MinRate`, `Balances`, `FeeExperimental`, `Decay`, `Fee`,
`Invalidators`, `TWAPSwap`, `Controls` and `Extruction`.

`PiecewiseLinearScaleHarness:18-25` records the same check having been done by reading, which
is the right habit — the fact is in the harness, next to the decision it justifies, not in a
review comment.

### 2.4 The stub-dispatch pattern

`MinRateHarness` is our worked example, and it is the pattern to copy for every instruction
that calls `ctx.runLoop()`.

```solidity
function _writeSwapAmounts(Context memory ctx, uint256, bytes calldata args) internal pure {
    ctx.swap.amountIn  = uint256(bytes32(args[0:32]));
    ctx.swap.amountOut = uint256(bytes32(args[32:64]));
}

function _bootstrap(Context memory ctx, bytes calldata program) private pure {
    ctx.vm.programPtr = CalldataPtrLib.from(program);
    ctx.vm.dispatch   = _writeSwapAmounts;
}
```

Three things make this work, and all three are load-bearing:

1. **The stub makes `runLoop`'s output a free symbolic pair.** `MinRate` consumes
   `(swapAmountIn, swapAmountOut)`; the stub reads them straight out of program bytes that
   the spec controls. So the theorem quantifies over *every* possible inner-program result,
   which is stronger than modelling any particular inner program.
2. **The real `runLoop` still executes.** This is not a transcription — the calldata
   slicing, the `pcs` advance, the `argsLength` byte read all run for real. You get the
   instruction's actual interaction with the loop, minus the loop's contents.
3. **There is exactly one function of `dispatch`'s type in the contract**
   (`MinRateHarness:32-34`), so the indirect `JUMP` has a single concrete destination and the
   prover does not branch over jump targets. This is the whole reason `../README.md` says
   verifying the run loop itself is a separate project. **If you add a second
   `internal`-function-pointer-typed function to a harness, you have doubled the branching at
   every dispatch.** Keep stub harnesses to one stub.

If you need more than one inner-program behaviour, parameterise the *stub's args*, not the
number of stubs. `MinRateHarness` does exactly this: the program encoding at `:36-41` carries
both amounts in the instruction's args block.

### 2.5 Return whole structs, so register isolation is expressible

`XYCSwapHarness.exactIn` returns `uint256 amountOut`. `MinRateHarness.requireMinRate` and
`XYCConcentrateHarness.exactInLeg` return `SwapRegisters memory`. The second shape is
strictly better and should be the default.

Returning the whole register file lets you state the properties that are otherwise
inexpressible:

- **Register isolation** — `MinRateSpec.test_require_leavesEveryRegisterUntouched` (`:376`),
  `test_adjust_leavesBalanceRegistersUntouched` (`:570`),
  `BaseFeeAdjusterSpec.test_exactIn_touchesOnlyAmountOut` (`:538`). "The instruction writes
  `amountOut` and nothing else" is a real safety property in a register machine where
  instructions compose, and it is the kind of thing a refactor breaks silently.
- **Cross-leg equalities** — `XYCConcentrateSpec.test_clampedExactIn_equalsExactOutAtFullBalance`
  (`:395`) compares two full register files.
- **Differential properties** — §2.7 needs both sides' registers.

Add an **observation flag** when a branch is not otherwise visible.
`XYCConcentrateHarness._pricingLegs` returns `bool clamped` (`:71`), which changes no
arithmetic but makes the partial-fill branch nameable. Without it,
`test_exactIn_clampedOutputIsExactlyBalanceOut` and
`test_exactIn_unclampedLeavesAmountInUntouched` could not be stated at all, and
`test_exactIn_clampIsReachable_witness` could not prove the hypothesis reachable. An
observation flag is the cheapest anti-vacuity device there is: **one bool per interesting
branch.**

Cost: the extra return value is a `MSTORE` and a wider return buffer. Nothing.

### 2.6 The oracle-seam pattern (for `isqrt`, `mulDiv`, `pow`)

`PROOF-MAP.md` blocker #1: axioms about `isqrt` cannot fire because `Math.sqrt` is inlined
and no `isqrt` symbol is ever introduced. Correct — and the fix is a *harness* change, not a
lemma change. You need a seam where the value is produced by something the prover treats as
opaque.

Three ways to build one, in increasing order of fidelity and cost:

**(a) Promote the value to a parameter.** This is what `XYCConcentrateHarness.exactInLeg`
does with the virtual reserves (`:103-115`), and it is the reason Tier A is provable today.
Cheapest, most permissive (the parameter ranges over values the real code could never
produce), and requires a differential property to close (§2.7).

**(b) Constrain a fresh symbol in the harness.** Replace the call with a fresh symbolic value
plus the characterising axioms:

```solidity
// Kontrol-only. Not runnable under `forge test` — assume rejects ~every sample.
function _isqrt(uint256 a) internal view returns (uint256 r) {
    r = vm.randomUint();                       // fresh ?WORD under Kontrol
    vm.assume(r * r <= a);                     // isqrt(a)^2 <= a
    vm.assume(a - r * r < 2 * r + 1);          // a < (isqrt(a)+1)^2
}
```

The two assumptions are exactly the characterising pair from `FINDINGS.md`, "Lemmas these
instructions will need". They are *symbolic squares*, which is what `lemmas.k` Section 7 was
written for. No `Math.sqrt` body, no 128 paths, no six Newton `DIV`s.

**(c) `vm.mockFunction` an external oracle.** Refactor the harness so the value comes from
`ISqrt(oracle).isqrt(x)`, deploy a concrete oracle for `forge test` and a symbolic one for
Kontrol, and swap with `vm.mockFunction(oracle, symbolicOracle, abi.encodeWithSelector(ISqrt.isqrt.selector))`.
More machinery than (b); the advantage is that the *same* harness runs in both modes.

All three are **trust boundaries** and must be declared as such. (b) and (c) assume the
axioms rather than proving them, so every downstream result is conditional on OZ's
`Math.sqrt` satisfying `r^2 <= a < (r+1)^2` — which is true, is provable once as its own
project, and is a far smaller assumption than "we did not verify this instruction at all".
State it in the spec docstring, in `PROOF-MAP.md`, and in the handoff. Do not let it become
invisible.

### 2.7 The transcription harness is a trust boundary

`XYCConcentrateHarness._pricingLegs` (`:72-98`) is a hand transcription of
`XYCConcentrate.sol:143-159`. Every Tier A property is therefore a theorem about the
transcription, not about the instruction — a fact the harness docstring states plainly
(`:52-55`) and which `FINDINGS.md` repeats. That honesty is the right default. What makes it
*work* is the discharge:

```solidity
function test_diff_exactIn_fullMatchesLegs(...) public view {
    (, uint256 vIn, uint256 vOut) = harness.virtualReserves(TOKEN_LO, TOKEN_HI, balanceIn, balanceOut, args);
    try harness.full(TOKEN_LO, TOKEN_HI, true, balanceIn, balanceOut, amountIn, 0, args)
        returns (SwapRegisters memory expected)
    {
        (SwapRegisters memory actual,) = harness.exactInLeg(balanceOut, amountIn, 0, vIn, vOut);
        assertEq(actual.amountIn,  expected.amountIn,  "...");
        assertEq(actual.amountOut, expected.amountOut, "...");
    } catch { }
}
```

Four things about this that generalise to any transcription harness:

1. **Register-for-register, not summary-value.** Comparing only `amountOut` would miss the
   `:148` overwrite of `amountIn`. Compare everything the instruction can write.
2. **The transcription call is inside the `try`.** If `full` succeeded, the leg is running
   identical arithmetic on identical operands and must also succeed; a revert there is a real
   discrepancy, not a case to skip. `XYCConcentrateSpec:722-724` says exactly this. Getting
   this backwards — putting both in the `try` — would let a leg that reverts on every input
   pass.
3. **Both orientations, both legs.** `test_diff_exactIn_*` runs `TOKEN_LO → TOKEN_HI`,
   `test_diff_exactOut_*` runs the mirror (`:751-754`). A differential that only exercises
   one arm of an internal branch discharges only that arm.
4. **The verification of the split is itself two-sided.** The harness author checked
   structurally (no call, no `using`, no function pointer can reach `_computeL` from the
   legs) *and* by gas measurement — the legs' maximum cost 1 327 is below `full`'s minimum
   1 862, and `_computeL` cannot fit in the gap (`FINDINGS.md`, "A transcription harness is a
   trust boundary"). That is a genuinely good technique: an independent, quantitative check
   that the expensive code really is off the path, using a tool (`forge test --gas-report`)
   that costs seconds. **Repeat it for every future transcription harness.**

**The rule.** A transcription harness with no differential property is a spec that measures
your typing accuracy. Write the differential property *at the same time as* the
transcription, mark it as the completion criterion in `PROOF-MAP.md`, and treat every result
on the transcribed surface as provisional until it closes. This is exactly what
`PROOF-MAP.md` says for XYCConcentrate, and it should be policy rather than a note about one
instruction.

### 2.8 Three surfaces, three trust levels

`XYCConcentrateHarness`'s structure (`:18-55`) is the right general shape and deserves to be
the house pattern:

| Surface | What it is | Provable today | What it is for |
|---|---|---|---|
| `exactInLeg` / `exactOutLeg` | transcription, expensive machinery as parameters | yes | the arithmetic properties |
| `virtualReserves` | transcription of the plumbing, calling the **real** expensive function | no (`mul512`) | properties about intermediate values the instruction only holds in locals |
| `full` | the instruction, unmodified | no | guards, and grounding the other two |

The middle surface is the one people forget. Orientation properties — "the `Ceil` rounding
follows the *input* side, not the trade direction"
(`XYCConcentrateSpec.test_orientation_offsetsFollowTokenRoleNotSwapDirection`, `:681`) — are
statements about locals. You cannot phrase them on the scalar legs and you cannot observe
them through `full`. Exposing the locals is the only way, and it is worth a whole surface.

---

## 3. Writing properties that cannot be vacuous

A property that cannot fail is worse than no property, because it reads as evidence. This
section is the checklist plus the reasoning behind each item.

**The tool will not help you here.** There is no `--check-vacuity`, no warning, and no
documented signal that a proof was trivially satisfied. Kontrol *does* have a notion of
vacuity — the Rule Application guide describes marking a symbolic state vacuous when applying
a rule's `ensures` makes the path condition unsatisfiable — but it surfaces it as a *desirable*
outcome for infeasible branches ("add these lemmas and … the invalid branch will be marked as
vacuous"), never as a risk that your assumptions killed the whole goal. Anti-vacuity is
entirely the spec author's job, and it is the job this section is about.

### 3.1 The failure mode we shipped: upper bounds do not pin an implementation

From `XYCSwapSpec.t.sol:21-33`, written after the fact and worth quoting because it is the
clearest statement of the problem in the repo:

> The four exact-in properties below (`cannotDrainPool`, `roundsInFavourOfMaker`,
> `zeroInputYieldsZeroOutput`, `constantProductNeverDecreases`) are all *upper* bounds on
> `amountOut`, or consequences of one. Each is sound, but jointly they are satisfied by an
> implementation that returns `0` unconditionally.

Three of those four were **proven**. The proof was correct. The specification was not.

The general shape: safety properties are almost always one-sided ("never more than", "never
less than", "never decreases"), and one-sided bounds are satisfied by the degenerate
implementation that saturates in the safe direction. A quote function returning `0`
satisfies every maker-protection property in a swap spec. A fee function returning
`type(uint256).max` satisfies every "the maker is compensated" property.

### 3.2 The failure mode that was worse: vacuous *negative* assertions

Seven PeggedSwap properties reported **PASSED** having proved nothing, because
constructor-set `immutable` selectors read as `0x00000000` under Kontrol (§0.2) and the
assertions were of the form `assertTrue(_selectorOf(err) != SEL)`. With `SEL == 0` and
`_selectorOf` returning a real selector, the comparison is trivially true.

Note the asymmetry, which is what makes this class dangerous: **a positive assertion fails
loudly, a negative one passes silently.** Any time you write `assertTrue(x != C)` or
`assertFalse(...)`, ask what happens if `C` is zero, if the value is zero, if the branch is
unreachable. If the answer is "it passes", you need a companion witness.

`PROOF-MAP.md` blocker #5 records the residual form of this and it is still live:
`_selectorOf` (`PeggedSwapSpec.t.sol:263-270`) returns `bytes4(0)` when `err.length < 4`.
Every path that reverts with empty revert data — an `assert`-style invalid opcode, an
out-of-gas, a call to a non-contract — therefore yields `0`, and every `!=` assertion against
it is vacuously true. The fix is to make emptiness explicit rather than encoding it as a
value:

```solidity
function _selectorOf(bytes memory err) internal pure returns (bool has, bytes4 s) { ... }
```

and have `_assertGuard` require `has` on the branch where a selector is expected. Until that
lands, the eight `assertTrue(_selectorOf(...) != ...)` sites in `PeggedSwapSpec.t.sol`
(`:442`, `:536`, `:712`, `:801`, `:1020`, `:1037`, `:1073`, and the pair at `:960`/`:989`)
are at risk.

### 3.3 Two-sided bounds

The direct fix for §3.1. For any rounded quantity, state both the bound and the tightness:

```solidity
// XYCSwapSpec.test_exactIn_isExactlyTheFloor — with N = amountIn*balanceOut, d = balanceIn+amountIn
assertLe(amountOut * d, N, "output must not exceed the exact curve value");
assertLt(N - amountOut * d, d, "output must not fall a wei short of the floor");
```

Together these say `amountOut == floor(N/d)` exactly, with no division anywhere in the
assertion. The second is the one that refutes the always-zero implementation.

**Note the form choice, because it is a real technique.** The obvious upper bound is
`N < (amountOut + 1) * d`. That product is one the *instruction never forms*, so nothing
about the instruction having succeeded bounds it, and at full `uint256` width the assertion
becomes a statement about `chop(...)` rather than about the curve — which is why
`XYCConcentrateSpec.test_exactIn_isExactlyTheFloor` (`:256`) has to drop to `uint120`. The
subtraction form `N - amountOut * d < d` uses only terms the instruction already evaluated
(`XYCSwapSpec.t.sol:150-159` enumerates them), so it holds over the **whole** `uint256`
domain with no narrowing.

**Rule: prefer an assertion phrased in terms the instruction already computed.** It is the
difference between a theorem about `uint256` and a theorem about `uint120`, for free.

### 3.4 Concrete witnesses

A universally quantified property can be vacuous or true of a degenerate implementation. A
witness cannot. Ours:

```solidity
function test_exactIn_quoteIsReachable_witness() public view {
    uint256 amountOut = harness.exactIn(1000, 200, 10_000, "");
    assertEq(amountOut, 181, "exact-in must quote the floor of the curve value");
    assertGt(amountOut, 0,   "a non-zero input at a non-empty pool must quote a non-zero output");
    assertLt(amountOut, 200, "and still not drain the pool: cannotDrainPool is not vacuous here");
    assertLt(amountOut * 11_000, 2_000_000, "the flooring is strict at this point");
}
```

Four assertions from one concrete input, each killing a different degenerate implementation:
always-zero, drains-the-pool, rounds-to-nearest, rounds-up. Cost under Kontrol: a single path
with no symbolic arithmetic — `XYCConcentrateSpec.test_exactIn_clampIsReachable_witness` is
the same shape and proves in about a minute.

Pick the witness point deliberately:

- **the division must not be exact** — `2_000_000 / 11_000 = 181.81…`, so flooring is
  distinguishable from rounding;
- **the two rounding directions must differ by a wei** — `test_exactOut_quoteIsReachable_witness`
  picks `ceil(101_000/99) = 1021` against `floor = 1020` (`:255-275`);
- **the branch you care about must fire** —
  `test_exactIn_clampIsReachable_witness` asserts `clamped == true` first.

**Witnesses are cheap and we have too few.** Seven across 192 properties. Every spec should
have at least one per interesting branch.

### 3.5 Reachability witnesses for `try` bodies and conditional branches

This is the vacuity class specific to the `try`/`catch` idiom that §4.4 recommends, and it is
the price of that idiom.

`try harness.f(...) returns (...) { assert } catch { }` is trivially true if the call always
reverts. So is `if (clamped) { assert }` if `clamped` is never true. So is
`if (!ok && shouldFire) { assertEq(...) }` if the two never coincide. Every one of these is a
material implication whose hypothesis you must independently show reachable.

Our count of these hypotheses:

| Spec | `catch` blocks | Reachability witnesses |
|---|---|---|
| `PowerSpec` | 20 | 4 |
| `PeggedSwapSpec` | 16 | 0 |
| `XYCConcentrateSpec` | 13 | 1 |
| `PiecewiseLinearScaleSpec` | 8 | 0 |
| `XYCSwapSpec` | 6 | 2 |
| `MinRateSpec` | 1 | 0 |

That table is the single best argument in this document. Sixty-four `catch` blocks, seven
witnesses.

The discharge is mechanical, so there is no excuse:

```solidity
/// @notice The success path of `test_exactIn_cannotDrainPool` is reachable.
function test_exactIn_successPathIsReachable_witness() public view {
    uint256 amountOut = harness.exactIn(1000, 200, 10_000, "");
    assertGt(amountOut, 0);           // the try body ran, on a non-degenerate value
}
```

One concrete call per `try`-shaped property family (not per property — one witness usually
covers a whole section, as `test_exactIn_quoteIsReachable_witness` does for the four exact-in
properties in `XYCSwapSpec`). Say in the witness docstring *which* properties it
de-vacuifies, and say in each of those properties' docstrings which witness covers them.
`XYCConcentrateSpec:180-186` does this and should be the template.

### 3.6 Mutation-testing your own spec

The only empirical check that a property has content. The protocol:

1. Copy the instruction (or harness) to a scratch file. **Never edit a file you do not own**
   — see `AGENT-PROTOCOL.md`.
2. Introduce one behavioural mutation.
3. `~/.foundry/bin/forge test --match-path 'test/kontrol/<X>Spec.t.sol'`.
4. Record which properties failed. Restore, `cmp` to confirm.

The mutation catalogue for arithmetic instructions, in rough order of value:

| Mutation | What it should kill |
|---|---|
| `return 0` from the quote leg | every one-sided upper bound; only exactness and witnesses survive |
| `/` → `Math.ceilDiv` (or the reverse) | rounding-direction properties, exactness, wei-apart witnesses |
| swap two arguments of a `mulDiv`/`ceilDiv` | orientation properties |
| `<` → `<=` on a guard | boundary properties (`atMinClampBoundary`, `justAbove`, `justBelow`) |
| delete a `require` | biconditional guard properties; **not** `vm.expectRevert` ones |
| `require` → `require(false)` | the *negative* half of a biconditional guard |
| write an extra register | register-isolation properties |
| clamp before instead of after the quotient | `test_clampedExactIn_equalsExactOutAtFullBalance` |

**Report which mutants each property killed.** A property that killed nothing is not yet a
property — it is a comment with an `assert` in it. `FINDINGS.md` records that two of three
spec passes did this; it should be three of three, and the result should be in the handoff.

`BaseFeeAdjusterSpec`'s clamp-boundary triple (`test_exactIn_atMinClampBoundary` /
`justAbove` / `justBelow`, `:445-489`) is the pattern to imitate for guards: three properties
that between them kill every off-by-one mutation of a comparison.

### 3.7 Non-vacuity checklist

Run this against every property before declaring it done.

- [ ] Does the assertion mention a value the implementation **produced**, or only values the
      test supplied? (`assertEq(x, x)` in disguise.)
- [ ] Is there an implementation — `return 0`, `revert()`, `return input` — that satisfies it
      trivially? If yes, name the companion property or witness that refutes it.
- [ ] If it is inside `try { … } catch { }`: which test shows the `try` body is reached?
- [ ] If it is inside `if (cond) { … }`: which test shows `cond` is reachable, with
      non-degenerate values?
- [ ] If it asserts `x != C` or uses `assertFalse`: what if `C` is zero, or the value is zero,
      or the branch never runs?
- [ ] Does any constant in the assertion come from an `immutable` or a state variable with an
      initialiser? (Under Kontrol it is `0`. §0.2.)
- [ ] Does the assertion compare `bytes`? (`assertEq(bytes,bytes)` truncates to 32 bytes under
      Kontrol; `assertEq0` rests on keccak injectivity. Extract a `bytes4` instead. §0.4.)
- [ ] Are the assumptions jointly satisfiable, and does the satisfying region contain
      *interesting* points and not just the boundary?
- [ ] Which mutant does it kill? Name one.

---

## 4. Assumption discipline

There are five ways to constrain a domain. They differ in cost under the prover, cost under
the fuzzer, and — crucially — in whether they *narrow the theorem*.

### 4.1 The comparison

| Mechanism | Cost under Kontrol | Cost under `forge test` | Narrows the theorem? |
|---|---|---|---|
| Narrow parameter type (`uint120`) | free — initial constraint (`#rangeUInt(120, X)`) | free — fuzzer generates in range | **yes**, and permanently |
| `vm.randomUint(min,max)` | free — `min <= ?WORD <= max` on a fresh existential | free — in-range draw | **yes** |
| `@custom:kontrol-precondition` | free — added to the initial CTerm | **none — the fuzzer ignores it** | yes under Kontrol only |
| Saturating ternary (`x > MAX ? MAX : x`) | one branch, both arms feasible; union covers the whole valid range | free — no rejection | **no**, if the map is onto the valid set |
| `vm.assume(p)` | one path constraint **plus the full cost of evaluating `p`** | rejects samples; can exhaust the budget | yes |
| `try` / `catch` | branch already present in the code | free | **no — it widens** |

### 4.2 Narrow types first

The default. Free on both sides. Its one weakness is that the bound must be a byte-width
multiple, which sometimes forces contortions: `XYCConcentrateSpec._priceBounds` (`:543`)
takes `uint56 minRaw, uint64 spread` and computes `1 + minRaw`, `ONE + spread` because the
bounds it wants are `[1, 2^56]` and `[ONE, ONE + 2^64]`. That is fine, but it needs eight
lines of docstring to explain, which is a signal that `vm.randomUint(1, 2**56)` would read
better.

Always document *why* the width: `XYCSwapSpec.test_exactOut_isExactlyTheCeiling`
(`:192-198`) derives `uint120` from `N < 2^240` and `amountIn*d <= N + d - 1 < 2^240 + 2^120`.
A width without an arithmetic justification is a guess.

### 4.3 Saturating ternaries — our best under-advertised finding

```solidity
function _validWidth(uint256 v) internal pure returns (uint256) {
    return v > MAX_LINEAR_WIDTH ? MAX_LINEAR_WIDTH : v;
}
```

`PeggedSwapSpec.t.sol:207-218` explains it exactly right and the reasoning deserves to be
generalised:

> Preferred over `vm.assume` for two reasons: the fuzzer would reject essentially every
> sample of `linearWidth <= 5000e27` drawn from `uint256`, and under Kontrol a ternary splits
> into two branches whose union still covers the whole valid range symbolically — so unlike a
> narrower fuzz type (`uint96 linearWidth`, say) nothing is lost.

Both halves are right and the second is the subtle one. `vm.assume(v <= MAX)` keeps the
symbolic variable and adds `V <=Int MAX`: one leaf, whole range. `_validWidth(v)` produces two
leaves — `V <= MAX ⊢ v` and `V > MAX ⊢ MAX` — whose union is the same range. You pay one
extra leaf and get a fuzzer that never rejects a sample. When the valid region is a tiny
fraction of `uint256`, as here (`5000e27 / 2^256 ≈ 10^-46`), that trade is overwhelmingly
correct: without it the fuzz mode of the spec is dead, and the fuzz mode is where you iterate.

**Two cautions.**

*The map must be onto the valid set.* `_validWidth` is: every `w <= MAX` is `_validWidth(w)`.
`_nonZero(v) = v == 0 ? 1 : v` is: every non-zero `v` is a fixed point. But a saturating map
that folds a large region onto one point loses coverage *of that region's interior* if the
region is itself valid. Check surjectivity onto the domain you claim.

*The saturation point becomes over-weighted under the fuzzer.* `_validWidth` maps ~100% of
`uint256` draws to exactly `MAX_LINEAR_WIDTH`. Under Kontrol that is fine — the other leaf
covers the interior symbolically — but under `forge test` you are effectively testing one
point. If a spec is going to live mostly in fuzz mode, pair the ternary with a narrow-type
variant that samples the interior. `PeggedSwapSpec` gets away with it because it is
Kontrol-first.

### 4.4 `try`/`catch` — the one that *widens*

The finding that started this document, and it is worth stating in its strongest form.

```solidity
// before: 4 nodes, no progress in 5 minutes
vm.assume(balanceIn > 0);
vm.assume(balanceOut > 0);
vm.assume(amountIn <= type(uint256).max / balanceOut);
uint256 amountOut = harness.exactIn(balanceIn, balanceOut, amountIn, "");
assertLt(amountOut, balanceOut);

// after: proves
try harness.exactIn(balanceIn, balanceOut, amountIn, "") returns (uint256 amountOut) {
    assertLt(amountOut, balanceOut);
} catch { }
```

The second is **strictly stronger**. The first quantifies over a sub-domain carved out by
three assumptions; the second quantifies over every `uint256` triple, with reverting inputs
satisfying it vacuously. And it is faster, because the branch that used to come from the
symbolic `DIV` in the assumption is replaced by branches the instruction was going to take
anyway.

Use it whenever a property is only interesting on the success path. Which is most of them.

**The three rules that keep it honest:**

1. **Cover the revert path separately.** `try`/`catch` says nothing about reverting inputs.
   `XYCSwapSpec` pairs its four `try`-shaped properties with three dedicated revert
   properties (`:329`, `:338`, `:352`). Without those, "the instruction always reverts"
   satisfies the whole file.
2. **Show the body is reached.** §3.5. This is the part we are not doing.
3. **Decide deliberately what goes inside the `try`.** A second call placed inside is claimed
   only to hold when the first succeeded; placed outside, it must succeed unconditionally.
   `XYCConcentrateSpec:391-394` and `:722-724` both explain their choice, and the choices are
   opposite — correctly, because the arguments differ. Copying one without re-deriving the
   argument is how a differential property becomes vacuous.

Also: `catch` with no parameter discards the revert data. If you want the selector, use
`catch (bytes memory err)` and the `_tryExactIn`/`_assertGuard` shape from
`PeggedSwapSpec.t.sol:287-337`, which is our best helper design and should be lifted into
every spec that inspects reverts.

### 4.5 `@custom:kontrol-precondition` — the one we are not using

Kontrol parses NatSpec on test functions and turns Solidity expressions into initial-state
constraints. From `kontrol/solc_to_k.py:551`:

```python
parse_annotations(devdoc.get('custom:kontrol-precondition', None), self)
```

and `kontrol/natspec.py:94-118` maps a Solidity expression AST onto K operators
(`+ - * / % ** < <= > >= == != && || ! & | ^ << >> ~` → `_+Int_`, `_/Int_`, …), resolving
identifiers to the method's parameters and `block.timestamp` / `msg.sender` / `msg.value` to
the corresponding cells. Comma-separated for several:

```solidity
/// @custom:kontrol-precondition balanceIn > 0, balanceOut > 0, amountIn < 2 ** 128
function test_exactIn_constantProductNeverDecreases(uint256 balanceIn, uint256 balanceOut, uint256 amountIn) ...
```

This is `vm.assume` with the evaluation cost removed: the constraint goes into the initial
CTerm rather than being computed by EVM code. For our three-assume
`test_exactIn_constantProductNeverDecreases` (`XYCSwapSpec.t.sol:303-305`) that removes three
`ISZERO/JUMPI` pairs and three constraints-discovered-late.

The sibling tags are `@custom:kontrol-bytes-length-equals` and
`@custom:kontrol-array-length-equals` (`solc_to_k.py:418`), formatted as
`name: length,name2: length,`. These pin the symbolic length of a `bytes` parameter, which
otherwise ranges over `[0, 2^64)` (§0.1) — directly useful for `PiecewiseLinearScaleSpec` and
the `PeggedSwap` parse guards where a fixed-shape args block is intended.

**Two catches, both sharp.**

*First: `forge test` ignores NatSpec entirely.* A property narrowed only by a precondition tag
runs *unnarrowed* under the fuzzer, so the two modes prove different theorems and the fuzzer
may fail on inputs the proof excluded. Two acceptable disciplines: use it only for constraints
that are *also* enforced structurally (a redundant hint to the prover, safe in both modes); or
use it as the sole narrowing and say so loudly. The first is safer.

*Second, and this is a vacuity trap: an unsupported construct is silently ignored.* RV's CSE
guide states it plainly — "Note that NatSpec preconditions with unsupported constructs will be
ignored." Unsupported today: array and mapping access, nested struct member access (only
global member access like `block.timestamp` works), and storage-slot offsets for packed slots.
So `@custom:kontrol-precondition args.length >= 160` does nothing at all, and does it quietly.

**Always verify the tag landed** by grepping the prove log for the confirmation line Kontrol
emits per accepted precondition (`kontrol/natspec.py:99`):

```
INFO ... kontrol.natspec - Adding NatSpec precondition: <pretty-printed constraint>
```

No line, no constraint. This is the same class of failure as a lemma that never fires, and it
gets the same treatment: verify the artefact, do not trust the source.

Related: the CSE guide notes that `vm.assume` is *unavailable* outside `Test` contracts during
compositional symbolic execution, so `@custom:kontrol-precondition` is the only way to
constrain a summarised function's own domain. If we ever turn on `cse = true` — which
`FINDINGS.md` suggests trying for `mulDiv`/`sqrt` — this becomes the primary mechanism, and an
*unconstrained* summary is actively harmful: it covers the reverting branches too, and RV's
guide shows exactly that making the caller's proof fail.

Either way, a precondition tag is a **domain narrowing** and must be declared like one.

### 4.6 When `vm.assume` is still right

- The condition is a cheap comparison of parameters: `vm.assume(amountOut < balanceOut)`.
  One constraint, no arithmetic, and the fuzzer rejects ~half. Fine.
- The condition mentions a value only available *after* a call, so no type or tag can express
  it: `PiecewiseLinearScaleSpec.test_value_unscaleIsMinimal` (`:203`) does
  `vm.assume(unscaled > 0)` on the result of `harness.unscaleValue`. There is no alternative.
- You want the fuzzer to reject, because the excluded region is genuinely tiny and you would
  rather see `rejected too many inputs` than silently test one saturated point.

**Never** put a `DIV`, `MOD`, `MULMOD`, `EXP`, `sqrt`, `mulDiv` or an external call inside a
`vm.assume`. If the bound needs one, restate it multiplicatively (`a * b <= MAX` instead of
`a <= MAX / b` — note this is *not* equivalent when the product overflows, which is precisely
why `try`/`catch` is better than either).

---

## 5. Stating guards correctly

A guard is a `require`. There are exactly two things to prove about it: it fires when the
condition holds, and it does **not** fire when the condition does not. Almost every guard
test in the wild proves neither.

### 5.1 `vm.expectRevert` proves only that *a* revert happened

From `cheatcodes.md:1622-1626`:

```k
rule #matchReason(REASON, _)   => true requires REASON ==K .Bytes
rule #matchReason(REASON, OUT) => REASON ==K #range(OUT, 4, lengthBytes(OUT) -Int 4)
                                  requires REASON =/=K .Bytes
```

A bare `vm.expectRevert()` sets `<expectedReason>` to `.Bytes`, and `#matchReason` then
returns `true` for **any** revert data whatsoever. The property "this input reverts" is
satisfied by an arithmetic panic, an out-of-gas, an invalid opcode, or the guard you meant.

That is exactly the failure this kind of test exists to exclude.
`XYCSwapSpec.t.sol:320-328` says it best:

> A bare `vm.expectRevert()` cannot distinguish "the guard fired" from "the arithmetic
> panicked on a division by zero" — which is precisely the failure this test exists to rule
> out, so the bare form is close to vacuous here.

We have six bare `vm.expectRevert()` calls left: `LimitSwapSpec.t.sol:105`, `:114`, `:120`,
`:147`, and `PowerSpec.t.sol:362`. The `PowerSpec` one is *deliberate and documented* —
"which panic fires is not uniform, which the next two properties pin exactly" (`:352-356`) —
and that is the correct way to use the bare form: as an explicitly weaker statement with
sharper companions immediately following. The four `LimitSwapSpec` ones are undocumented and
should be tightened.

Even the named form, `vm.expectRevert(abi.encodeWithSelector(E.selector, a, b))`, proves only
one direction. It says *these* inputs revert with *this* payload. It says nothing about
whether other inputs also revert with it — a `require(false)` at the top of the function
satisfies every `vm.expectRevert` test in a file.

### 5.2 State guards as biconditionals

The two-sided form. Ours, and it is good:

```solidity
/// A guard fires *exactly* on its condition:
///   - the call succeeded  => the condition did not hold;
///   - the call reverted   => it reverted with this selector iff the condition held.
function _assertGuard(bool shouldFire, bool ok, bytes memory err, bytes4 sel, string memory message)
    internal pure
{
    if (ok) {
        assertFalse(shouldFire, message);
    } else {
        assertTrue((_selectorOf(err) == sel) == shouldFire, message);
    }
}
```

`PeggedSwapSpec.t.sol:282-293`. The `== shouldFire` is the whole point: it is an *iff*, so a
guard that reverted unconditionally fails it. Its docstring says so explicitly.

Note what the `else` branch tolerates: the call reverted, `shouldFire` is false, and it
reverted with a *different* selector. That is right — the property is about this guard, and
other failures on the same input are other guards' business. Keep guard properties
single-subject; conjoining them makes the negative direction unprovable for reasons that have
nothing to do with the guard.

The calling shape:

```solidity
(bool ok, bytes memory err,) = _tryExactIn(balanceIn, balanceOut, amountIn, TOKEN_LO, TOKEN_HI, data);

bool shouldFire = data.length < 160;
_assertGuard(shouldFire, ok, err, _selArgsLength(), "args-length guard must fire exactly below 160 bytes");

if (!ok && shouldFire) {
    assertEq(_errorArg(err, 0), data.length, "guard must report the actual args length");
}
```

`PeggedSwapSpec.test_parse_argsLengthGuardIsExactlyBelow160` (`:351-368`). Three claims in
nine lines: the guard fires iff the length is short, it reports the offending value, and —
implicitly, via the `ok` branch — a long-enough `args` gets past it. `shouldFire` is computed
from the *same symbolic input* the harness received, so this is a genuine biconditional over
the whole `bytes` domain, not a case split the author chose.

**When you cannot state the biconditional**, say why. The two
`PeggedSwapSpec.*recomputeGuardFiresWithExactSelector` properties need a domain narrowing
because the guard sits after an arithmetic block that is not total over `uint256`
(`:220-235`); the *negative* direction of both is stated over the full domain. Splitting a
biconditional into a narrowed positive half and an unnarrowed negative half is a good move and
should be the standard response to "the positive direction needs preconditions".

### 5.3 Extract `bytes4` in assembly; never compare `bytes`

§0.4 established why: `assertEq(bytes,bytes)` is `#asWord` equality under Kontrol, which
truncates to 32 bytes and ignores length, and `assertEq0` is keccak equality, which under
KEVM rests on hash injectivity of an uninterpreted function.

```solidity
function _selectorOf(bytes memory err) internal pure returns (bytes4 s) {
    if (err.length < 4) return bytes4(0);
    assembly ("memory-safe") {
        s := and(mload(add(err, 0x20)), 0xffffffff00000000000000000000000000000000000000000000000000000000)
    }
}

function _errorArg(bytes memory err, uint256 i) internal pure returns (uint256 w) {
    if (err.length < 4 + 32 * (i + 1)) return 0;
    assembly ("memory-safe") { w := mload(add(err, add(0x24, mul(0x20, i)))) }
}
```

`PeggedSwapSpec.t.sol:263-280`. A `bytes4` comparison compiles to a word compare; a `uint256`
argument comparison likewise. No keccak on any proof path, no `#asWord` truncation, and the
arguments are checkable individually — which is what lets `_errorArg` pin "the guard reports
`x0` and `y0` in that order" (`:400-401`).

Same reasoning applies to the panic selector. `PeggedSwapSpec._selPanic()` returns the literal
`0x4e487b71` rather than `bytes4(keccak256("Panic(uint256)"))`, because the hash is only
folded away by the optimiser and an unfolded one would put a `KECCAK256` on every path
(`:173-178`). And it is pinned against the hash by a dedicated property,
`test_panicSelectorIsTheAbiPanicSelector`. That is the right shape: use the cheap form
everywhere, prove the cheap form equals the meaningful form exactly once.

### 5.4 The `_selectorOf` zero trap

Already flagged in §3.2 and in `PROOF-MAP.md` blocker #5, restated here because it is a
*guard-stating* bug specifically.

`_selectorOf` returns `bytes4(0)` for revert data shorter than four bytes. Combine that with
a negative assertion:

```solidity
assertTrue(_selectorOf(err) != _selNoSolution(), "PeggedSwapMathNoSolution must be unreachable");
```

and every path that reverts with **empty** revert data satisfies it vacuously. Empty revert
data is not exotic: `assert()`-style invalid opcode, out-of-gas, a call into an address with
no code, and any `revert()` with no argument all produce it.

Worse, this is the *same* vacuity that the `immutable` bug produced, reintroduced by a
different route — a sentinel value that collides with a legitimate comparison target. That
pattern (encode "absent" as `0`, then compare against something that can also be `0`) is the
root cause both times.

Fix it by making absence a separate channel:

```solidity
function _selectorOf(bytes memory err) internal pure returns (bool present, bytes4 s) { ... }
```

then `_assertGuard` asserts `present` before comparing on the branch where a selector is
expected, and the "must be unreachable" properties become
`assertTrue(!present || s != _selNoSolution())` — which is honest — plus a separate property
saying the path in question never reverts empty.

### 5.5 Guards on the revert *path* versus guards on the revert *data*

Three distinct claims, often conflated:

| Claim | How to state it | What it misses |
|---|---|---|
| "these inputs revert" | `vm.expectRevert()` | anything about *why* |
| "these inputs revert with error `E(a,b)`" | `vm.expectRevert(abi.encodeWithSelector(...))` | whether other inputs also do |
| "the call reverts with `E` **iff** `cond`" | `_assertGuard` biconditional | nothing — this is the property |

Write the third. Write the second only when the payload matters and the biconditional is
already covered. Write the first only with a comment saying which sharper property covers the
same ground, as `PowerSpec.t.sol:352-362` does.

---

## 6. Structuring a spec for provability

### 6.1 Property ordering: cheapest first, always

`../README.md` says it and it is the highest-return process rule in the repo: *prove the
cheapest property first, to validate the harness shape in a minute rather than an hour into
the hardest goal.* Concretely, order a spec file so that the reading order is also a sensible
proving order:

1. **Concrete witnesses.** One path, no symbolic arithmetic. If a witness does not prove, the
   harness is wrong and nothing else in the file matters.
2. **Guards that revert before any arithmetic.** `PeggedSwapSpec`'s four `parse_*` properties
   "reach no arithmetic, so they are the cheapest proofs in the file: no `Math.sqrt` is
   executed on any path they explore" (`:339-344`).
3. **Degenerate-input properties.** `zeroInputYieldsZeroOutput` — one multiplication by zero,
   which the simplifier eats.
4. **One-sided bounds with `try`/`catch`.** No assumption arithmetic.
5. **Two-sided exactness.** Needs the products to be well-behaved, hence the narrowings.
6. **Cross-leg and differential properties.** Two calls, so two copies of the arithmetic.
7. **Anything reaching the expensive machinery.**

`PeggedSwapSpec`'s handoff already groups its 31 properties A–F by sqrt cost
(`PROOF-MAP.md`, "PeggedSwap — 0 / 31") and that grouping is more valuable than the file
order. **Put the cost group in the property's docstring**, so the next agent does not have to
reconstruct it.

### 6.2 Name properties so `--mt` can select a group

`--match-test` is a regex over the full signature. Our naming already exploits this —
`test_exactIn_*`, `test_exactOut_*`, `test_full_*`, `test_diff_*`, `test_parse_*`,
`test_witness_*`, `test_unguarded_*` — so `kontrol prove --mt 'XYCConcentrateSpec\.test_diff_'`
runs exactly the trust-boundary discharge. Keep it. Two additions worth adopting:

- a `_witness` suffix (we use it inconsistently: `XYCSwapSpec` suffixes,
  `PowerSpec` prefixes with `test_witness_`). Pick one. **Suffix**, so the subject sorts
  first.
- a cost tag in the *docstring*, not the name — names are also the interface to
  `PROOF-MAP.md` and should stay stable.

### 6.3 Isolate expensive machinery behind harness parameters

Restating §2.6(a) as a structural rule: **anything the prover cannot handle should be a
parameter, and the parameterisation should be visible in the property's signature.**

```solidity
function test_exactIn_cannotDrainPool(
    uint256 balanceOut, uint256 amountIn,
    uint256 virtualBalanceIn, uint256 virtualBalanceOut   // <- `_computeL` is not on the path
) public view
```

A reader of `XYCConcentrateSpec` can tell Tier A from Tier B by the parameter list alone. That
is worth more than a section comment, because parameter lists survive copy-paste and section
comments do not.

The corollary: **do not add a parameter you are not going to quantify over.** A parameter that
is always passed `0` in every property is dead weight in the calldata and one more symbolic
variable for the solver.

### 6.4 Split one property into a bounded case and a revert case

The single most common productive refactor. A property of the form "the result is `f(x)`" is
usually two properties:

- on the success path, the result is `f(x)`, stated with `try`/`catch` over the **whole**
  domain;
- the reverting inputs are exactly `g(x)`, stated as a biconditional guard.

Together they are stronger than the original *and* each half is cheaper, because neither
carries the other's preconditions. `XYCSwapSpec` is built this way: four `try`-shaped pricing
properties plus three guard properties, and the file docstring (`:80-88`) explains that the
`try` form "quantifies over every `uint256` triple rather than over a sub-domain, so nothing
is narrowed to make the proof close".

The second productive split is **positive half narrowed, negative half not** (§5.2).

The third is **by branch**: `XYCConcentrateSpec` states `isExactlyTheFloor` on the unclamped
branch (forcing `balanceOut = type(uint256).max` so the clamp cannot fire, `:263`) and
`clampedExactIn_equalsExactOutAtFullBalance` on the clamped one. Two clean proofs beat one
proof with a case analysis inside it, because the prover's case analysis is not the one you
wrote.

### 6.5 Put the reference semantics in the file docstring

Every one of our specs opens with the instruction's semantics transcribed as pseudocode
(`XYCSwapSpec.t.sol:11-19`, `XYCConcentrateSpec.t.sol:12-35`). This is not documentation
politeness. It is the artefact a reviewer diffs against the source to check that the spec is
about the right function, and it is where the "what is provable today and what is not" split
belongs (`XYCConcentrateSpec.t.sol:52-74`). Keep doing it, and keep citing `file:line` into
`src/`.

`FINDINGS.md` records repeatedly that the code contradicts its own documentation. **Derive
from source. Cite line numbers. Never cite the whitepaper.**

### 6.6 Loop-bounded proofs: check the bound is *complete*

`--bmc-depth N` normally yields a result valid only up to `N` unrollings. It yields an
*unconditional* result when the path entering iteration `N+1` is infeasible, which the prover
will close as vacuous. `PiecewiseLinearScale` is in this happy case: `runLoop` reads
`argsLength` as a single byte (`src/libs/VM.sol:131`) so the segment count is at most 50, and
`--bmc-depth 51` is complete (`FINDINGS.md`, "PiecewiseLinearScale — tractable, and the bound
is *complete*").

**The check is not optional and it is easy to forget:** after the run, confirm no reachable
`bounded` leaves remain. A bounded leaf means the theorem is "…for programs with at most 50
segments", which may be fine but must be *stated*, not discovered later.

### 6.7 Housekeeping that keeps results trustworthy

- **Edit → build → prove.** A spec edit is invisible to the prover until the coordinator
  rebuilds; the definition contains compiled *bytecode*. `../README.md` "Build".
- **Verify the lemmas actually compiled in.** `grep -c '<label>' out/kompiled/definition.kore`.
  A stale `out/kompiled/requires/lemmas.k` survives `--rekompile` silently. This is why every
  rule in `lemmas.k` carries a unique label.
- **Prefer `kontrol remove-node` to `--reinit`.** `--reinit` re-explores `setUp` too.
- **Record every narrowing in two places**: a code comment at the definition site, and the
  handoff. `XYCSwapSpec.t.sol:192-198` and `XYCConcentrateSpec.t.sol:283-296` are the models —
  both give the arithmetic that justifies the width, not just the width.
- **`kontrol list` shows only the latest proof version.** Older versions (`:0`, `:1`, …) are
  still on disk under `out/proofs` and are selectable with `--version`. A "PASSED" you
  remember may belong to a superseded version of the spec.
- **When you add a lemma to kill a branch, delete the `split` node too.** Otherwise both
  branches persist and the dead one simplifies to `#Bottom` — the proof still works but the
  KCFG is misleading and slower.

### 6.8 Knobs worth knowing, in the order you should reach for them

Our `kontrol.toml` is coordinator-owned, so this is advisory, but the reasoning should be
recorded somewhere and this is the place.

| Knob | What it buys | What it costs |
|---|---|---|
| `--optimize-performance N` | bundles `assume-defined`, `maintenance-rate 64`, `smt-timeout 120000`, `smt-retry-limit 0`, `max-depth 100000`, `max-iterations 10000`, `no-stack-checks`, `max-frontier-parallel N` | undoes our deliberate checkpointing (see below) and discards up to 64 iterations of work on a crash |
| `--max-frontier-parallel N` | parallel exploration *within* one proof | memory |
| `--smt-tactic '(check-sat-using qfnra-nlsat)'` | RV's recommendation for non-linear arithmetic — which is exactly what a constant-product curve is | can be slower on linear goals |
| `--smt-timeout` ↑ | fewer spurious "unknown"s | wall clock |
| `--step-timeout N` | on timeout the backend halves the execution depth and retries — the right tool for a proof that hangs inside one giant step | none |
| `--generate-counterexample` | emits a Solidity contract with concrete counterexample values for each failing node | only on failure |
| `--no-fail-fast` | the complete failure picture instead of the first one | explores branches you may not care about |
| `kontrol minimize-proof <proof> --merge` | node merging: "pushes splits down" through the KCFG, arbitrary branch reduction | experimental |
| `--lemmas <file>.k:<MODULE>` | load rules at prove time with **no rebuild** | none — this is the fast loop, use it always |

Two of these interact with decisions already made in `kontrol.toml` and should not be changed
casually:

- **`max-depth = 2000` with `break-on-basic-blocks`** is a deliberate deviation from RV's
  template (`max-depth = 25000`, all breaks off). The trade is documented in `../README.md`
  and it is the right one for a shared machine where crashes happen: frequent checkpoints make
  `kontrol list` a live progress signal and localise a stall to one basic block. Raise it only
  for proofs known to close quickly.
- **`no-stack-checks = true`** is in our config and in RV's own generated template, and it is
  an *assumption*, stated verbatim by RV as: "Assumes running Solidity-compiled bytecode
  cannot result in a stack overflow/underflow." True for solc output, but it is a trust
  boundary and belongs in the assumption ledger next to the keccak axioms.

Also worth noting: RV's `kontrol init` template sets **`run-constructor = true`**, the opposite
of ours. Ours is `false` and that is what produced the immutable-reads-as-zero vacuity (§0.2).
With the `internal pure` accessor fix in place, `false` remains the right choice — it is
cheaper — but the divergence from the vendor default should be a conscious, documented one
rather than an inherited one.

**`--workers` sizing, from RV:** at most `(M - 8) / 8` on a machine with `M` GB of RAM.
`AGENT-PROTOCOL.md` caps us at 3 per agent for a different reason (16 shared cores); both
bounds apply.

---

## 7. What not to try to prove in Kontrol

Kontrol proves statements about EVM bytecode with integer arithmetic and an SMT solver. Four
classes of property are outside that, and recognising them early is worth days.

### 7.1 Real-number curve algebra

`FINDINGS.md`: the exact-arithmetic invariant `(r/p)(b/p)^e = (B/p)^E` for `Power.pow` "holds
only as an **inequality** `pow(B,E,p) <= p*(B/p)^E` once the floors are present; a matching
lower bound is a real numerical-analysis lemma, not a rewriting exercise." Likewise the
`XYCConcentrate` price-bound claim, where flooring `L` at five independent places means the
implementation under-approximates the true root and `P ∈ [P_min, P_max]` does not
automatically survive.

The tell: the property is stated over the reals or the rationals and the implementation works
in floored integers. Kontrol cannot reason about the real-valued object at all; it can only
reason about the integer expression in front of it.

**What to do instead.** Three options, in order of preference:

1. **Restate as an integer inequality with an explicit `ε`.** `FINDINGS.md` already
   prescribes this: prove `bGt*1e18 <= L*Δ + ε` with a *derived* `ε`, not `ε = 0`. The value
   of the spec is then the derivation of `ε`, and that derivation is where the numerical
   analysis lives.
2. **Prove the order properties instead of the closed form.** For `Power`: `pow(B,0,p) = p`,
   `pow(p,E,p) = p`, `pow(0,E,p) = 0` for `E > 0`, `B <= p ⇒ pow(B,E,p) <= p`, monotonicity in
   `E`. Each is an induction on `bitlength` using only monotonicity of `floor`, with no
   exponentials anywhere — and the fourth alone discharges the `DutchAuction` decay-direction
   claim. `PowerSpec` is built this way and it is the right call.
3. **Do the real-number part in a proof assistant, or on paper with a CAS at 120 digits**, and
   feed Kontrol only the integer consequence. `FINDINGS.md`'s `[measured]` results —
   "`amountOut` can land 1 wei *above* `floor(exact)`" — came from exactly this workflow, and
   they saved us from writing three false properties.

**Never port a zero-slack rounding property without checking it.** "Rounding always favours
the maker" is *false* for `PeggedSwap` and the provable form is ±1 wei.

### 7.2 Anything that needs gas while gas is off

Gas is disabled by default (`usegas: False`) and `kevm.infiniteGas` is applied automatically,
so `<gas>` is `#gas(?_VGAS)` — an unconstrained symbol. Any property whose *content* is a gas
comparison is not merely unproven, it is unstatable.

`PROOF-MAP.md` excludes `test_argsLength_underThirteenBytesNeverTerminates` from
`kontrol prove` for exactly this reason: it witnesses a non-terminating loop via a gas cap,
and with gas off the proof would never converge. That exclusion, with its reason recorded, is
the correct handling — an **X with a reason** in the proof map, not a quietly failing proof.

Options when you do need gas:

- `--use-gas` with `--schedule CANCUN`. Viable for tier-1 straight-line instructions where gas
  along a path is a constant. Not viable once there are loops.
- The KCFG-leaf technique from `../README.md`: prove functional equivalence with gas off, use
  `kontrol get-model` on each leaf to get a concrete witness, then measure gas concretely on
  each witness. Because the leaves are exhaustive, this gives complete path coverage of gas
  without symbolic gas. This is a genuinely good idea and we should use it more.
- For non-termination specifically: state it as "the loop exit condition is unreachable" —
  a statement about the *guard*, not about gas — and prove it as a reachability property.
  `FINDINGS.md`'s "Update" section already derives the right characterisation (`++num == 0` is
  as unreachable as `++num == 2**256-1`, and ten is the smallest terminating `args.length`).
  That is provable; "it runs out of gas" is not.

### 7.3 Loops with a genuinely unbounded trip count

If the trip count is a symbolic value with no structural bound, `--bmc-depth N` gives you a
theorem about the first `N` iterations and nothing else. That is sometimes acceptable, but say
so.

Distinguish three cases, because two of them are fine:

- **Structurally bounded** — `PiecewiseLinearScale`, trip count ≤ 50 because `argsLength` is a
  byte. `--bmc-depth 51` is *complete*. Prove it (§6.6).
- **Bounded but exponential in leaves** — `Power.pow`, trip count ≤ 16 for `DutchAuction` but
  the `exponent & 1` branch has two *continuing* arms so leaves grow as `2^bitlength`. "BMC
  is nominally the right tool and practically hopeless" (`FINDINGS.md`). Prove order
  properties plus small-exponent witnesses. And note the highest-leverage option is to
  **change the code**: a constant-trip-count branchless `pow` has exactly one execution path.
- **Genuinely unbounded** — no structural bound at all. Do not start. Either add a bound to
  the code or state a bounded theorem and label it bounded.

### 7.4 Things that route through an uninterpreted function

KEVM treats `keccak256` as uninterpreted, and then *axiomatises* it. From
`kontrol/kdist/keccak.md`, verbatim:

> In reality, cryptographic hash functions like `keccak` are not injective. They are designed
> to be collision-resistant … but not impossible. This assumption reflects that hypothesis in
> the context of formal verification, making it more tractable.

and, for the rule that a symbolic `keccak` never equals a concrete value:

> The underlying hypothesis that justifies it is that the storage slots of a given mapping are
> presumed to be disjoint from slots of other mappings and also the non-mapping slots of a
> contract.

So a property whose truth depends on hash injectivity is not *proven* by Kontrol, it is
*assumed* by Kontrol. That is a perfectly reasonable engineering assumption and it is exactly
why `assertEq0` is unusable as a spec device (§0.4), why `_selPanic()` is a literal rather
than a hash (§5.3), and why symbolic storage on a mapping-heavy contract is expensive.
`kontrol build --no-keccak-lemmas` turns the axioms off, at which point nothing about
mappings is provable at all.

The same shape applies to `Math.sqrt`, `Math.mulDiv` and `Math.mul512` *until a lemma exists*
— with the difference that those are genuinely interpretable and the lemma is a finite amount
of work. The distinction to keep in your head:

- **Uninterpretable in principle** (keccak) → abstract, and record the assumption.
- **Uninterpreted for now** (`isqrt`, `mul512`) → either write the lemma, or build the oracle
  seam (§2.6) and record the assumption *until* the lemma lands.

Both cases produce a trust boundary. The second one has an expiry date; make sure
`PROOF-MAP.md` says which is which.

### 7.5 The whole VM through the dispatcher

`ContextLib.runLoop` dispatches through an internal function pointer. Symbolically executing
through it forces the prover to branch over every possible jump destination, i.e. over every
instruction in the opcode table. `../README.md` "Scope" is right that this is a separate,
much harder project, and the stub-dispatch pattern (§2.4) is the correct scope reduction.

What you *can* do at the VM level, and should eventually: prove that each instruction
preserves a register invariant, and compose those results by hand. Register-isolation
properties (§2.5) are precisely the lemmas such a composition argument needs, which is a
second reason to write them.

---

## 8. Patterns from published suites

Kontrol has a real corpus now. The most instructive suites are **Lido Dual Governance**
(`lidofinance/dual-governance/test/kontrol/`, ~5 600 lines, RV engagement, with a 456-line
published report), **Term Finance × Yearn v3**
(`term-finance/yearn-v3-term-vault-contracts/src/test/kontrol/`, which found real
high-severity bugs), **Morpho** (`runtimeverification/_kaas_morpho`), **MakerDAO DSS**
(`runtimeverification/kontrol-dss-2024`), **Wormhole**
(`wormhole-foundation/wormhole/ethereum/forge-test/rv-helpers/`), and **Solady**
(`runtimeverification/kontrol-solady`). Optimism's pausability suite is the famous one but is
not the most instructive — it uses no Kontrol-specific cheatcodes at all.

Below: the patterns worth stealing, in the order I would adopt them.

### 8.1 ★ The `Mode.{Assume, Try, Assert}` invariant combinator

Lido's `test/kontrol/KontrolTest.sol`, copied verbatim into Term Finance and Octant. It is the
de facto standard Kontrol idiom and the single best thing in the corpus:

```solidity
enum Mode { Assume, Try, Assert }

function _establish(Mode mode, bool condition) internal pure returns (bool) {
    if (mode == Mode.Assume) { vm.assume(condition); return true; }
    else if (mode == Mode.Try) { return condition; }
    else { assert(condition); return true; }
}
```

You then write each invariant **once** as `_someInvariant(Mode mode, State s)` and reuse it as
a precondition (`Assume`), a branch-free probe (`Try`), or a postcondition (`Assert`). That is
what makes inductive "the invariant is preserved" proofs writable at all, and it removes the
commonest way to prove nothing: assuming an invariant the setup already establishes, thereby
weakening the theorem silently.

**Why it matters for us.** We restate the same predicate in several places today.
`assertLe(swap.amountOut, balanceOut)` appears in `XYCConcentrateSpec` at `:131`, `:150` and
`:638` — twice on the transcribed leg and once on the real instruction. `_assertGuard`
(`PeggedSwapSpec.t.sol:287`) is a hand-rolled special case of the same idea. Factoring these
into `Mode`-parameterised predicates would let a single `_noDrainInvariant(Mode, …)` serve as
Tier A postcondition, Tier B postcondition, and — once instruction composition is on the table
— precondition for the *next* instruction's proof. That last use is the point.

Term Finance's discipline on top of it is the part people get wrong
(`src/test/kontrol/RepoTokenListInvariants.t.sol`):

```solidity
// Our initialization procedure guarantees this invariant,
// so we assert instead of assuming
_establishNoDuplicateTokens(Mode.Assert);

// Assume that the invariants are satisfied before the function is called
_establishSortedByMaturity(Mode.Assume);
_establishNoMaturedTokens(Mode.Assume);
```

**Distinguish invariants your setup *establishes* (assert them — if you assume them you have
weakened the theorem and will never notice) from genuine induction hypotheses (assume them).**

### 8.2 ★ A loop invariant as a K rewrite rule — the escape from `--bmc-depth`

`runtimeverification/kontrol-dss-2024/src/invariant.md` is the only public worked example, and
it is directly the answer to `Power.pow`. It proves `sumToN(n) == n*(n+1)/2` for **all**
`n < 2^128`, with the README noting: *"Run the proof with `kontrol`. Note the absence of
`--bmc-depth`."*

The method: state the loop's whole effect as a claim about the machine at the loop's `JUMPI`,

```k
claim [gauss-claim]:
  <k> ( JUMPI 775 bool2Word ( N <=Int I ) => JUMP 775 ) ~> #pc [ JUMPI ] ~> #execute ~> _CONT </k>
  <program> #binRuntime </program>
  <wordStack> ( I => N ) : ( I *Int (I +Int 1) /Int 2 => N *Int (N +Int 1) /Int 2 ) : 0 : N : WS </wordStack>
  <pc> 745 </pc>
  requires 0 <=Int N andBool N <Int 2 ^Int 128 andBool 0 <=Int I andBool I <=Int N
```

prove it, then convert it to a rewrite rule. The conversion recipe is mechanical and stated in
the doc: *"every time you see a function behind a `=>`, move it to a requires clause"* — K
forbids functions on a rewrite rule's left-hand side, so `bool2Word(N <=Int I)` becomes
`CONDITION` with `requires CONDITION ==K bool2Word(N <=Int I)`, and `#binRuntime` becomes
`PROGRAM` with `requires PROGRAM ==K #binRuntime`. Give the rule `[priority(30)]` so it fires
before the ordinary loop unrolling.

**For `Power.pow` this is the real answer.** `FINDINGS.md` correctly says BMC is "nominally the
right tool and practically hopeless" at `2^bitlength` leaves, and proposes order properties
instead. Order properties are the right *interim* move. But a loop-invariant rule at the
`exponent & 1` `JUMPI` — carrying `result * base^exponent`'s floored analogue as the invariant —
collapses the whole loop into one edge and gives the closed form unconditionally. It is
substantially more work than a lemma, and it is the only technique that gets past `2^16`.

Note the suite also ships `maliciousSumToN` as a **negative control**: a variant the invariant
must *not* prove. Copy that habit — a loop-invariant rule that proves too much is the easiest
possible unsoundness to introduce.

### 8.3 ★ Frame conditions two ways

**Wormhole**, `ethereum/forge-test/rv-helpers/TestUtils.sol` — as Solidity modifiers, with a
*symbolic* slot:

```solidity
modifier symbolic(address contractAddress) {
    kevm.infiniteGas();
    kevm.symbolicStorage(contractAddress);
    _;
}

modifier unchangedStorage(address contractAddress, bytes32 storageSlot) {
    bytes32 initialStorage = vm.load(contractAddress, storageSlot);
    _;
    bytes32 finalStorage = vm.load(contractAddress, storageSlot);
    assertEq(initialStorage, finalStorage);
}
```

With `bytes32 storageSlot` as a **test parameter**, one proof establishes "this function
touches no storage at all". That is a frame condition in plain Solidity with no whitelist
cheatcode, and it is more elegant than enumerating slots.

**MakerDAO DSS**, `test/Token.t.sol` — the whitelist form, and the only real-world use of
`allowChangesToStorage` I could find:

```solidity
function testMintSuccess(address account, uint256 value) public totalSupplyIsSumOfAllBalances {
    vm.assume(account != address(0));
    kevm.allowChangesToStorage(address(token), TOTAL_SUPPLY_STORAGE_INDEX);
    kevm.allowChangesToStorage(address(token), SUMOFALLBALANCES_STORAGE_INDEX);
    bytes32 storageLocation = hashedLocation(account, BALANCES_STORAGE_INDEX);
    kevm.allowChangesToStorage(address(token), uint256(storageLocation));
    ...
}
```

The proof **fails** if the function writes any slot outside the declared set — an exact frame
condition, not an approximation.

**For us**, today's analogue is the register file, and we already do the enumerated version
(`MinRateSpec.test_require_leavesEveryRegisterUntouched:376`,
`BaseFeeAdjusterSpec.test_exactIn_touchesOnlyAmountOut:538`). The Wormhole trick generalises
it: since our harnesses return the whole `SwapRegisters`, a single property parameterised by a
symbolic register *index* would say "writes exactly register `k` and nothing else" in one
proof rather than five assertions. Worth doing when Tier 3 arrives and the whitelist cheats
become relevant for real storage.

### 8.4 ★ Convert every counterexample into a concrete regression test

Term Finance ships `src/test/kontrol/Counterexamples.t.sol`:

> Unit tests testing counterexamples for list invariants and other properties found during
> formal verification. These tests would fail before the issues were fixed, but should be
> passing after.

with a full prose reconstruction of the bug above each test (their case: an
`insertSorted` cycle causing gas-exhaustion).

**We have the raw material and are not doing this.** `FINDINGS.md` records executable witnesses
for at least four bugs — the `PeggedSwap` underflow (`balanceIn = 1e30 + 1, balanceOut = 1,
amountOut >= 1, x0 = y0 = 1e30, linearWidth = 0, rateLt = rateGt = 1, tokenIn < tokenOut`), the
`PiecewiseLinearScale` non-termination, the `DutchAuction` division by zero, and the
`unscaleValue` silent truncation. Only the last has a concrete test
(`PiecewiseLinearScaleSpec.test_value_unscaleSilentlyTruncatesAboveUint232:215`). The other
three live only as prose in `FINDINGS.md`, where nothing stops a "fix" from silently
un-fixing them.

`BUGS.md` should have a companion `test/kontrol/Counterexamples.t.sol` with one concrete test
per CONFIRMED entry. These cost nothing under Kontrol (single path, no symbolic arithmetic)
and they are the artefact that makes the analysis durable.

### 8.5 Record proof cost in the source

Morpho's `test/kontrol/RepayIntegrationTest.k.sol`:

```solidity
// 7m 40s, || 4, MR 24, SMT 5s
function testRepayAssets(uint256 amountSupplied, uint256 amountCollateral, ...) public {
```

Wall clock, worker count, maintenance rate and SMT timeout, per proof, in the diff. This is
§6.1's "put the cost group in the docstring" with a precedent and a better format. Adopt the
comment shape verbatim — it makes a proof-performance regression visible in code review, which
`PROOF-MAP.md` alone cannot do.

Lido's `kontrol.toml` has the complementary trick: proofs are selected by an explicit
`match-test` array, and expensive-or-done ones are **commented out inside the array** with
TOML's `#"…"`, so the list is a durable record of what is in the working set.

### 8.6 Production tuning, from Lido's `kontrol.toml`

The best public reference for a `prove` profile, and it is very different from ours:

```toml
[prove.default]
schedule                   = 'CANCUN'
max-depth                  = 100000
max-iterations             = 10000
workers                    = 1
max-frontier-parallel      = 6
maintenance-rate           = 128
assume-defined             = false
no-log-succ-rewrites       = true
no-stack-checks            = true
kore-rpc-command           = 'kore-rpc-booster --no-post-exec-simplify --equation-max-recursion 20 --equation-max-iterations 1000 --fallback-on Aborted'
smt-timeout                = 60000
smt-retry-limit            = 0
run-constructor            = false
```

Three things to notice:

- **`workers = 1` with `max-frontier-parallel = 6`.** They parallelise *within* one proof
  rather than across proofs. For a suite of a few very expensive proofs that is the right
  split; for our many-cheap-proofs shape, the opposite. Worth knowing the knob exists.
- **`smt-retry-limit = 0` with `smt-timeout = 60000`.** One long attempt rather than ten
  escalating ones. Our `smt-timeout = 5000` with the default retry limit of 10 is a different
  bet, and on non-linear goals theirs is probably better.
- **The custom `kore-rpc-command`.** `--no-post-exec-simplify`, bounded equation recursion and
  iterations, and `--fallback-on Aborted`. This is the flag set for goals where the simplifier
  itself is the bottleneck — which describes every one of our stalled `mulDiv`/`sqrt` proofs.
  Nothing else in the corpus sets it, and it is a cheap experiment.

Also confirmed as *shared conventions* rather than one-offs: `ethUpperBound = 2^96` and
`timeUpperBound = 2^35` ("takes us to year 3058") appear both in Lido's constants and in
Kontrol's built-in `KONTROL-AUX-LEMMAS`.

### 8.7 The `runLemma` / `doneLemma` self-testing lemma module

Used in six independent production suites (Lido, Term, Octant, Morpho, Wormhole, Solady). A
paired `-SPEC` module turns "does my simplification fire on this term?" into a one-step
provable claim:

```k
syntax StepSort ::= Int | Bool | Bytes | Map | Set
syntax KItem ::= runLemma ( StepSort ) | doneLemma( StepSort )
rule <k> runLemma(T) => doneLemma(T) ... </k>
```

```k
claim [slot-update-04]:
  <k> runLemma ( <the exact term that got stuck> ) => doneLemma ( true ) ... </k>
  requires 0 <=Int TIMESTAMP_CELL andBool TIMESTAMP_CELL <Int 2 ^Int 35
```

The claims are written against **the term Kontrol actually produced**, auto-generated variable
names and all (Morpho's are literally `VV2_priceCollateral_114b9705`). That is exactly the
discipline `AGENT-PROTOCOL.md` prescribes — "never write a lemma against the Solidity source"
— with the tooling to make it a unit-test loop instead of a six-hour re-run.

**Caveat, from RV's own docs:** running such a claim performs an *implication* check, so
`runLemma(A) => doneLemma(B)` passing does not prove `A` simplifies to `B` — it may simplify to
some `B'` that implies `B`. Useful, not conclusive.

Use `kontrol show '<Test>' --pending` to get the stuck term (Octant's lemma file documents
exactly this recipe in a comment above the rule it motivated).

### 8.8 Smaller patterns worth knowing

- **Override `bound()` to use `vm.assume`.** Morpho's `test/kontrol/BaseTest.k.sol`:
  ```solidity
  function bound(uint256 x, uint256 min, uint256 max) internal pure virtual override returns (uint256) {
      vm.assume(x >= min); vm.assume(x <= max); return x;
  }
  ```
  Foundry's real `bound()` wraps modularly, producing a symbolic `modInt` that poisons every
  downstream query. This override let Morpho reuse its whole Foundry suite verbatim. We do not
  use `bound()` — **keep it that way**, and if anyone adds it, add this override with it.

- **Public wrapper for `vm.expectRevert` on `internal` functions.** Solady's
  `test/FixedPointMathLib.k.sol`: *"Public wrapper for mulWad since Kontrol doesn't support
  vm.expectRevert for internal calls."* Our harness architecture already does this by
  construction (§2.1) — which is one more reason the harness-per-instruction shape is right.

- **Cross-multiplied ratio invariants.** Octant states "price per share never decreases" as
  `postAssets * preSupply >= preAssets * postSupply` rather than `a/b >= c/d`. Independent
  convergence on exactly our multiplicative-form technique (§3.3), for the same reasons.

- **Exhaustive selector-dispatch proof.** DSS's `testCallback(bytes4 functionSelector)` assumes
  the selector differs from each known one, then `vm.expectRevert`s the call — proving there is
  no hidden entrypoint in the deployed bytecode. **Directly applicable to `SwapVM`'s opcode
  table**: a property over a symbolic `uint8 opcode`, asserting that every value outside
  `OpcodeList` reverts, is impossible to fuzz and cheap to prove.

- **Symbolic-length data structures via `while (kevm.freshBool() != 0)` + `bmc-depth`.**
  Term's `_initializeRepoTokenList` builds a linked list of *every* length from 0 to
  `bmc-depth`, each node with fully symbolic storage. Not needed for our register machine, but
  it is the answer if we ever verify over a program of symbolic length.

- **Havocking models instead of `mockCall`.** Term's `RepoToken` model re-havocs its own
  storage and returns `kevm.freshBool()` from every mutating call. Strictly stronger than
  `vm.mockCall`, which pins the dependency to one concrete answer. The right shape for
  `Extruction` and the external fee provider when Tier 3 arrives.

- **Generated storage constants.** `kontrol setup-storage src/Contract` emits
  `<C>StorageConstants.sol` from the solc storage layout (requires `extra_output =
  ['storageLayout']` in `foundry.toml`). Lido hand-rolled this with a shell script; it is now a
  subcommand. Irrelevant while our instructions are `pure`; mandatory for Tier 3.

### 8.9 Replay a recorded deployment instead of fighting the constructor

Optimism's contribution, and now first-class in the tool. Rather than making Kontrol run
constructors, **record** a real deployment and **replay** its state:

```solidity
vm.startStateDiffRecording();
// ... run the real deploy script ...
AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
```

```bash
kontrol prove --init-node-from-diff  path/to/state-diff.json   # from stopAndReturnStateDiff
kontrol prove --init-node-from-dump  path/to/state-dump.json   # from vm.dumpState
```

Both cheats are in our `forge-std` (`Vm.sol:722`, `:728`, `:2084`). The older hand-rolled form
is a generated "deployment summary" contract whose `setUp()` `vm.etch`es code and `vm.store`s
every slot — Kontrol runs `setUp()`, so the state arrives without a constructor.

Not needed today: our instructions are `pure` and our only deployment is
`new XYCSwapHarness()` in `setUp()`. It is the right answer the moment Tier 3 starts, because
it removes the whole class of "the spec's `setUp` and the real deploy script diverged".

### 8.10 Housekeeping conventions

- **`*.k.sol` for Kontrol-only proof contracts**, alongside `*.t.sol` for dual-mode ones —
  used by Octant, Morpho and Solady. Both are compiled, so both are in the K definition, but
  `forge test` and `kontrol prove` select disjoint sets by path. We will need this the moment
  the symbolic `isqrt` oracle exists (§2.6b), and adopting it now costs nothing.
- **A checked-in `run-kontrol.sh`.** RV recommends it, every serious suite has one, and their
  template starts with `pkill kore-rpc || true` — an orphaned RPC server from a killed proof
  will otherwise silently poison the next run. Ours would additionally wrap the docker
  invocation that every agent briefing currently repeats by hand.
- **CI that re-runs proofs on Kontrol upgrades.** RV's own `_kaas_morpho/process.md` documents
  auto-PRs on each Kontrol release. Our `flake.nix` tracks Kontrol's default branch rather than
  a pinned revision (`../README.md` notes this), which is the worst of both: proofs invalidate
  silently and nothing re-runs them.
- **An assumption ledger.** One list of what the enterprise assumes rather than proves: keccak
  injectivity and slot-disjointness (`keccak.md`'s own words: "a hypothesis made by the
  ecosystem"), `no-stack-checks = true`, every `[simplification]` in `lemmas.k` (RV's soundness
  criterion is `C1 ∧ … ∧ CN ⟹ (LHS ⟺ RHS)` — an equivalence, and nothing checks it), any
  `isqrt` axioms, and every open transcription differential.

### 8.11 The lemma-development loop, as RV teaches it

Our `AGENT-PROTOCOL.md` has the mechanics; this is the reasoning:

1. Proof fails on an implication check. Read the failing node, failure reason, path condition.
2. `kontrol view-kcfg`, or `kontrol show <test> --pending`, to find the stuck term.
3. Decode it by hand (`chop(x)` = `x mod 2^256`, `bool2Word`, `/Int`, `modInt`).
4. **Decide whether it is a bug or a reasoning gap.** RV's phrasing on the Solady case: *"we're
   not facing a bug in `mulWad`, but rather a reasoning gap in Kontrol."*
5. `git grep -rin 'rule bool2Word'` in `evm-semantics` — learn how KEVM already treats the
   function before adding a rule about it.
6. Write the lemma; test it with `--lemmas <file>.k:<MODULE>` (no rebuild) and a
   `runLemma`/`doneLemma` claim.
7. `kontrol remove-node` the stuck node and resume **without** `--reinit`.

Four mechanical facts about simplifications that a lemma author must know, from RV's
Simplifications guide: the LHS is matched **syntactically**; all-concrete functions are
evaluated **before** any simplification; simplification is **bottom-up and repeated to
fixpoint** (so `X +Int Y => Y +Int X` hangs); default priority is 50, and you go above or below
to control canonicalisation order. Plus `preserves-definedness` is *required* whenever either
side mentions a partial function like `/Int` or `modInt`.

Solady's lemma file adds the hygiene rule that makes a library maintainable — normalise every
comparison so the concrete side is on the left and the operator is `<Int`/`<=Int`:

```k
rule X >=Int Y => Y <=Int X [simplification, concrete(Y)]
rule X  >Int Y => Y  <Int X [simplification, concrete(Y)]
```

This collapses the number of distinct term shapes the rest of the library has to match. Our
`lemmas.k` has grown to seven sections; it is worth adding a canonicalisation section at the
top before it grows further.

---

## HANDOFF

### A. Checklist before declaring a spec done

Run all of it. It takes under an hour and it is the difference between a proof and a
decoration.

**Harness**

- [ ] Every entrypoint is `pure`/`view` if the instruction allows it.
- [ ] `ctx.vm` zero-init justified: `grep -n 'runLoop\|\.dispatch\|setNextPC\|program()\|takerArgs()\|tryChopTakerArgs' src/instructions/<X>.sol` is empty. If not, stub-dispatch (§2.4).
- [ ] At most **one** function of `dispatch`'s type in the harness.
- [ ] Entrypoints return the whole `SwapRegisters`, not a scalar (§2.5).
- [ ] One observation flag per interesting internal branch.
- [ ] If any code is transcribed: the differential property exists, compares register-for-register, covers both legs and both orientations, and the split is verified twice — structurally *and* by `forge test --gas-report` (§2.7).
- [ ] Any abstraction seam (parameterised value, fresh symbol, mock) is named as a trust boundary in the harness docstring, in the spec docstring, and in `PROOF-MAP.md`.

**Vacuity**

- [ ] Every one-sided bound has a two-sided or witness companion (§3.1, §3.3).
- [ ] Every `try { … } catch { }` family has a reachability witness, and the two docstrings cross-reference (§3.5).
- [ ] Every `if (cond) { assert }` has a witness that `cond` is reachable with non-degenerate values.
- [ ] No assertion depends on an `immutable` or an initialised state variable. `immutableReferences` in the artefact is `None`/`{}` (§0.2).
- [ ] No `assertEq(bytes, bytes)`, no `assertEq0`. Selectors extracted as `bytes4` in assembly (§0.4, §5.3).
- [ ] No sentinel value that can collide with a legitimate comparison target (the `_selectorOf` → `0` trap, §5.4).
- [ ] Mutation-tested. **Name the mutant each property killed** in the handoff (§3.6).

**Assumptions**

- [ ] No `DIV`, `MOD`, `MULMOD`, `EXP`, `sqrt`, `mulDiv` or external call inside any `vm.assume`.
- [ ] Every bound is a narrow type, a `vm.randomUint(min,max)`, or a saturating ternary — unless there is a stated reason it cannot be.
- [ ] Every width has an arithmetic derivation in its docstring, not just a number.
- [ ] Symbolic `address` parameters justified, and paired with disequalities against the test contract, the cheat address and the harness (§1.3).
- [ ] Any `@custom:kontrol-precondition` verified to have landed, by grepping the prove log for `Adding NatSpec precondition` (§4.5).
- [ ] Every narrowing recorded in **two** places: the definition site and the handoff.

**Guards**

- [ ] No bare `vm.expectRevert()` without a comment naming the sharper property that covers the same ground (§5.1).
- [ ] Each guard has a biconditional property, or an explicit note on why only one direction is stated (§5.2).
- [ ] Error *arguments* checked, not just the selector, wherever the error carries data.

**Process**

- [ ] `~/.foundry/bin/forge test --match-path 'test/kontrol/<X>Spec.t.sol'` green.
- [ ] Properties ordered cheapest-first, with a cost note per property (§6.1).
- [ ] Reference semantics quoted in the file docstring, cited to `src/…:line`, derived from source not documentation.
- [ ] If `--bmc-depth` is used: no reachable `bounded` leaves remain, or the theorem is explicitly labelled bounded (§6.6).
- [ ] Handoff written with the `AGENT-PROTOCOL.md` template, including domains narrowed and mutants killed.

### B. The properties in our suite I judge weakest, beyond those already known

Ordered by risk × cost-to-fix. None of these are in `PROOF-MAP.md`'s existing lists.

**B1. `BaseFeeAdjusterSpec` will stall on ten symbolic-division assumptions — the exact pattern we already diagnosed.**

`BaseFeeAdjusterSpec.t.sol` is 25 properties, Track A, never attempted under Kontrol. Ten of
them carry a `vm.assume` whose divisor is symbolic:

| Line | Assumption | Divisor |
|---|---|---|
| 243, 312, 556 | `amountOut <= type(uint256).max / increase` | `increase = min(WAD+q, 2*WAD-maxPriceDecay)` — symbolic |
| 273, 344, 410, 592 | `amountIn <= type(uint256).max / decay` | symbolic |
| 380, 449, 464, 479 | `amountOut <= type(uint256).max / cap` | `cap = 2*WAD - maxPriceDecay` — symbolic |

(`:204`, `:205`, `:693`, `:694`, `:723` divide by `WAD`, a constant — those fold and are fine.)
`XYCSwapSpec` stalled at four nodes on **one** such assumption. Ten of them, plus the mirrored
`try`-less structure — `BaseFeeAdjusterSpec` has zero `try`/`catch` blocks — means this file is
currently unprovable as written, and nobody has found out yet because it has never been run.

*Fix, and it is mechanical.* `increase`, `decay` and `cap` are all bounded by `2*WAD ≈ 2e18 <
2^61`. So narrowing `amountOut`/`amountIn` to `uint192` makes every product total by
construction, deletes all ten assumptions, costs nothing under the fuzzer, and *widens* nothing
that matters (the excluded region is `[2^192, 2^256)` of a token amount). Where the full domain
is genuinely wanted, use the `try`/`catch` form instead.

**B2. `MinRateSpec._assumeMulSafe` puts a symbolic division into 22 properties.**

`MinRateSpec.t.sol:88-90`:

```solidity
function _assumeMulSafe(uint256 a, uint256 b) internal pure {
    vm.assume(a == 0 || b <= type(uint256).max / a);
}
```

Twenty-two call sites (`:109`–`:651`). Same diagnosis as B1, same fix and it is even cleaner
here: every divisor is a `uint64` rate, so declaring the amount parameters `uint192` makes
`amount * rate < 2^256` unconditionally and the helper can be deleted outright. `MinRateSpec`
is 29 properties and this touches most of them.

Also `MinRateSpec.test_require_revertsOnComparisonOverflow` (`:365`) uses
`vm.assume(swapIn > type(uint256).max / rateGt)` — a symbolic division *and* the boundary is
the interesting part, so it cannot be replaced by a narrower type. Restate it multiplicatively
or as a concrete witness at the boundary.

**B3. `LimitSwapSpec` is the weakest file in the suite.**

Nine properties. Four bare `vm.expectRevert()` (`:105`, `:114`, `:120`, `:147`) with no
docstring justification, so each proves only "something reverted" (§5.1) — and `:105` is the
direction-mismatch guard, which is a *security* property, so "it reverted for some reason"
is not an acceptable statement of it. One symbolic-division assumption (`:46`). Zero
`try`/`catch`, so every pricing property is confined to the assumed sub-domain. Zero
witnesses.

The exactness picture is half-done and the missing half is the dangerous one:
`test_exactOut_roundingIsTight` (`:71`) pins the exact-out leg two-sidedly, but the exact-in
leg has only `test_exactIn_roundsInFavourOfMaker` (`:43`), which is one-sided, and
`test_exactIn_zeroInputYieldsZeroOutput` (`:86`), which an always-zero quote also satisfies.
So the exact-in leg of `LimitSwap` is currently pinned no more tightly than `XYCSwap`'s was
before the rewrite that this whole document is downstream of.

It is also the cheapest file to fix, because `XYCSwapSpec` is now a complete worked template
for exactly this instruction shape. **Highest value-per-hour item in the suite.**

**B4. `PowerSpec` has 20 `catch` blocks and no witness that any of them is reached.**

Its four witnesses (`:614`, `:641`, `:652`, `:662`) are all about the `DutchAuction` decay
collapse — i.e. they witness the *reverting/zero* regime, not the success path of the order
properties. So `test_bound_neverExceedsPrecision` (`:195`), `test_mono_nonIncreasingInExponent`
(`:282`) and `test_mono_nonDecreasingInBase` (`:321`) are, as stated, satisfied by a `pow` that
reverts on every input. Given that `FINDINGS.md` records `pow` *does* revert on large swathes
of its domain, this is a live risk rather than a theoretical one.

Worse, the *exactness* properties are `try`-shaped too. All five `test_unroll_exponent*`
(`:551`–`:594`) — the properties that pin `pow`'s closed form at concrete small exponents — are
`try { assertEq(...) } catch { }` with symbolic `base` and `precision`. They are the strongest
statements in the file and every one of them is discharged by the `catch` on the whole domain
where `pow` reverts, which per `FINDINGS.md` is large.

The one genuine witness is `test_unitPrecision_concretePowers` (`:485`) — fully concrete,
four hand-computed values, no `try`. That is exactly the right shape, and it is the only one.
But it fixes `precision == 1`, which is the degenerate case where no flooring happens at all,
so it does not witness the success path of anything that matters.

*Fix, cheap:* add one fully concrete witness per group at a **production precision** — e.g.
`pow(9e17, 8, 1e18)` with the value worked by hand — and cross-reference it from the `try`-shaped
properties' docstrings. Four or five lines, and it converts eight properties from
possibly-vacuous to grounded.

**B5. `PiecewiseLinearScaleSpec`'s "never expands" family is one-sided.**

`test_value_scaleNeverExpands` (`:152`), `test_scaleIn_neverExpandsBalanceIn` (`:292`),
`test_scaleOut_neverExpandsBalanceOut` (`:310`), `test_scaleIn_neverExpandsForAnyLengthArgs`
(`:328`). All are `result <= input`. All are satisfied by returning `0`.
`test_value_maximalScaleIsTheIdentity` (`:166`) and `test_interp_isTheExactFloorOfTheBlend`
(`:546`) pin `scaleValue`, so the *value* half is covered — but nothing pins `scaleIn`'s
output, and `scaleIn` is the instruction. Add a two-sided
`scaleBalanceIn(b, args) == scaleValue(b, scaleOf(args))` property, or a concrete witness with
a hand-computed non-zero result.

**B6. `XYCConcentrateSpec.test_full_cannotDrainPool` is at risk of being vacuous *and* is known unprovable.**

`PROOF-MAP.md` already notes it "cannot be closed by Section 6 even in principle" because its
price bounds are free `uint256`s. The additional observation is that its `try` body may never
be reached at all: with `sqrtPriceMin`/`sqrtPriceMax` fully unconstrained, `_computeL` panics
on most of the domain, so `full` reverts and the property is discharged by the `catch`. Even if
the `mul512` lemma lands, it could prove PASSED having verified nothing. It needs a
reachability witness before it is worth any prover time.

**B7. `PeggedSwapSpec`'s eight negative selector assertions are still exposed via `_selectorOf` → 0.**

`PROOF-MAP.md` blocker #5, restated with the sites: `:442`, `:536`, `:712`, `:801`, `:1020`,
`:1037`, `:1073`, plus the two `_selectorOf(errLo) == _selectorOf(errHi)` comparisons at `:960`
and `:989` — which are *equalities* and so are satisfied when **both** are `0`, i.e. when both
mirrored configurations revert with empty data. The `deadCode_*` and `directionSymmetry_*`
groups are the ones at risk. Fix per §5.4.

**B8. The `assertEq(bytes,bytes)` rationale in `PeggedSwapSpec.t.sol:259-262` is wrong.**

Not a weak property, but a wrong reason recorded in the most-copied helper block in the repo.
The keccak claim describes `assertEq0`/`checkEq0`; `assertEq(bytes,bytes)` delegates to
`vm.assertEq`, which Kontrol implements as `#asWord` equality — truncating to the low 32 bytes
and discarding lengths. The conclusion (do not use it) is right; the reason should be corrected
before it propagates into another spec.

### C. Patterns worth adopting

Ordered by value. The first four are from published suites and are the ones I would act on
first.

**C0. The `Mode.{Assume, Try, Assert}` invariant combinator** (Lido; copied by Term Finance and
Octant). Write each invariant once, reuse it as precondition, probe and postcondition. It is
the de facto standard Kontrol idiom, it subsumes our hand-rolled `_assertGuard`, it removes the
duplication between `XYCConcentrateSpec`'s Tier A and Tier B statements of the same predicate,
and it is the prerequisite for ever composing per-instruction results into a VM-level argument.
Adopt with Term Finance's discipline attached: **assert the invariants your setup establishes,
assume only genuine induction hypotheses.** (§8.1)

**C0b. A `Counterexamples.t.sol` regression file** (Term Finance). `FINDINGS.md` and `BUGS.md`
carry executable witnesses for at least four bugs and only one has a concrete test. Each is a
single-path proof that costs nothing and makes the analysis durable. This is the highest
value-per-line item in the whole list. (§8.4)

**C0c. A loop invariant as a K rewrite rule** (MakerDAO DSS `src/invariant.md`). The only
technique that gets `Power.pow` past `2^bitlength` leaves, and the only public worked example
of it. Substantial work, but it is the difference between order properties and the closed form.
Ship a negative control alongside it, as they do. (§8.2)

**C0d. Record proof cost in the source** (Morpho): `// 7m 40s, || 4, MR 24, SMT 5s` above each
proof. Makes a performance regression visible in review, which `PROOF-MAP.md` cannot. (§8.5)

1. **`vm.randomUint(min, max)` for non-power-of-two bounds.** Free under Kontrol
   (`min <= ?WORD <= max` on a fresh existential), in-range under the fuzzer, and it puts the
   bound where a reader looks for it instead of behind a `uint56` + offset construction. Already
   in our `forge-std`. (§1.1, §4.2)

2. **`vm.randomAddress()` instead of a symbolic `address` parameter** where the address need
   not be part of the ABI quantification — it excludes the cheat and test addresses by
   construction, which is two of the four account-branching cases from §1.3. And add
   `notBuiltinAddress`-style disequalities where a symbolic address is genuinely needed.

3. **`@custom:kontrol-precondition`**, with the log-line verification. Removes assumption
   *evaluation* cost entirely. Becomes mandatory if we ever enable `cse`, because `vm.assume`
   is unavailable to summarised functions. (§4.5)

4. **`--lemmas <file>.k:<MODULE>`** — already in `AGENT-PROTOCOL.md`, but it deserves to be the
   *default* loop rather than a tip. Seconds instead of a rebuild, and it is the only way an
   agent can iterate on lemmas at all given the no-build constraint.

5. **`--smt-tactic '(check-sat-using qfnra-nlsat)'`** — RV's own recommendation for non-linear
   arithmetic. Every property in this repo is a non-linear integer goal (`a*b <= c*d`). This is
   a one-flag experiment on a stalled proof and nobody has tried it.

6. **`--step-timeout N`** — on timeout the backend halves the execution depth and retries.
   Precisely the tool for the `PeggedSwap` sqrt goals and `XYCConcentrate` Tier B, which stall
   inside one enormous step rather than failing.

7. **`kontrol minimize-proof <proof> --merge`** — node merging "pushes splits down" through the
   KCFG. Experimental, but the `Power` `2^bitlength` leaf explosion is exactly the shape it
   targets.

7b. **Lido's `kore-rpc-command`**: `kore-rpc-booster --no-post-exec-simplify
   --equation-max-recursion 20 --equation-max-iterations 1000 --fallback-on Aborted`, with
   `smt-retry-limit = 0` and a long `smt-timeout`. Nothing else in the corpus sets it, and it
   targets exactly our failure mode — goals where the simplifier itself is the bottleneck.
   A cheap experiment on a stalled `mulDiv`/`sqrt` proof. (§8.6)

8. **Record-and-replay deployment state** (`vm.startStateDiffRecording` /
   `stopAndReturnStateDiff` → `kontrol prove --init-node-from-diff`). Not needed now; the right
   answer for Tier 3, and it removes the whole class of "the spec's `setUp` and the real deploy
   script diverged". (§8.9)

9. **A `*.k.sol` naming convention for Kontrol-only proof contracts** (Octant, Morpho,
   Solady), adopted before we need it, so the symbolic `isqrt` oracle has somewhere to live
   that `forge test` does not see. (§8.10)

10. **A checked-in `run-kontrol.sh`** wrapping the docker invocation and the flag set, with
    `pkill kore-rpc || true` first. Removes the most common cause of a wasted agent run, and an
    orphaned `kore-rpc` from a killed proof will otherwise poison the next one silently. (§8.10)

11. **An assumption ledger.** One list, in `PROOF-MAP.md` or beside `lemmas.k`, of everything
    the enterprise assumes rather than proves: keccak injectivity and slot-disjointness,
    `no-stack-checks = true`, every `[simplification]` in `lemmas.k`, any `isqrt` axioms, and
    every open transcription differential. RV's soundness criterion for a simplification is
    `C1 ∧ … ∧ CN ⟹ (LHS ⟺ RHS)` — an equivalence, not an implication — and nothing checks it,
    so each rule is an assertion we are making. (§8.10)

12. **A canonicalisation section at the top of `lemmas.k`** (Solady): normalise every
    comparison so the concrete side is on the left and the operator is `<Int`/`<=Int`
    (`rule X >=Int Y => Y <=Int X [simplification, concrete(Y)]`). This collapses the number of
    distinct term shapes every later rule must match, and `lemmas.k` is now seven sections deep
    — the right moment to add it is before it grows further. (§8.11)

13. **An exhaustive opcode-dispatch proof** (MakerDAO DSS's `testCallback(bytes4)`). Over a
    symbolic `uint8 opcode`, assert that every value outside `OpcodeList` reverts. Impossible
    to fuzz, cheap to prove, and it is a genuine security property of the VM rather than of one
    instruction. (§8.8)

14. **The `runLemma` / `doneLemma` self-testing lemma module** — six independent production
    suites use it, with claims written against the term Kontrol actually produced,
    auto-generated variable names and all. It turns our "dump the node, write the rule, re-run"
    loop into a unit test. Note RV's caveat: it is an implication check, so passing does not
    prove the simplification is exact. (§8.7)

### D. The single highest-value structural change

`PROOF-MAP.md` ranks the `isqrt` abstraction as blocker #1 and correctly diagnoses why axioms
alone cannot fire: `Math.sqrt` is inlined, so nothing introduces an `isqrt` symbol. **The
missing piece is a harness seam, not a lemma** (§2.6). A fresh symbolic value plus the two
characterising assumptions —

```solidity
r = vm.randomUint();
vm.assume(r * r <= a);
vm.assume(a - r * r < 2 * r + 1);
```

— introduces the symbol, keeps `Math.sqrt`'s ~128 paths and six Newton `DIV`s off the
execution path entirely, and lands squarely on `lemmas.k` Section 7 (symbolic squares), which
is already compiled in and unexercised. It unblocks PeggedSwap Groups E/F and XYCConcentrate
Tier B in one move.

It is a trust boundary — the axioms are assumed, not proven — and must be declared as one. But
"conditional on OZ `Math.sqrt` satisfying `r² ≤ a < (r+1)²`" is a far smaller assumption than
"this instruction was never verified", and discharging it against OZ's implementation is a
well-scoped separate project rather than a blocker.

### E. Corrections to the hand-in

- **`PeggedSwapSpec.t.sol:259-262`** — the stated reason for avoiding `assertEq(bytes,bytes)`
  (keccak comparison) describes `assertEq0`, not `assertEq`. The real behaviour under Kontrol
  is `#asWord` truncation to the low 32 bytes with lengths discarded, which is worse. See §0.4
  and B8.
- **`../README.md` "Current status"** says 71 properties across four instructions. There are
  now **192** across eight spec files, all green under `forge test` (verified this session:
  `192 tests passed, 0 failed`). `PROOF-MAP.md` says `Power` is "spec not yet written" —
  `PowerSpec.t.sol` exists with 31 properties.
- **`../README.md` "Running proofs"** documents `--reinit` as the remedy for stale results. RV's
  own guidance is the opposite where possible: `kontrol remove-node <test> <node>` then resume
  *without* `--reinit`. The README's "Traps" section already says this; the flag table should
  point at it.
- **`kontrol.toml` `run-constructor = false`** diverges from RV's own `kontrol init` template,
  which sets `true` — though Lido's production config also sets `false`, so the divergence is
  from the template rather than from practice. Ours is the right choice given the accessor fix,
  but it is the direct cause of the seven vacuous PeggedSwap passes and should be a documented
  decision rather than an inherited default.
- **`kontrol.toml` `no-stack-checks = true`** is an assumption ("running Solidity-compiled
  bytecode cannot result in a stack overflow/underflow"), inherited from RV's template. It is
  almost certainly fine and it is also undeclared.

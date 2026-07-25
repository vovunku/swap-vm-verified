# Example program — permissioned swap by taker balance

The program the Phase 1 go/no-go theorem is stated about. Taken from
[`docs/PROGRAMS.md`](../../docs/PROGRAMS.md) §4 "SwapVM Programs with Conditional Flow",
Example A — an institutional gate: only takers holding a required token or NFT may fill.

It is a *reference* program, which is the point: makers copy these.

## Source form

```solidity
Program program;
bytes memory bytecode = bytes.concat(
    program.build(Opcode.OnlyTakerTokenBalanceNonZero,
        ControlsArgsBuilder.buildTokenBalanceNonZero(gateToken)),
    program.build(Opcode.StaticBalances,
        BalancesArgsBuilder.build([uint256(1_000e18), uint256(2_000e18)])),
    program.build(Opcode.LimitSwap, LimitSwapArgsBuilder.build(tokenIn, tokenOut))
);
```

## Encoding

`ProgramBuilder.build` is one line — `abi.encodePacked(opcode, args.length.toUint8(), args)`
— so a program is `[opcode:1][argsLen:1][args:argsLen]` repeated. Nothing else.

Opcodes and argument layouts, read from the implementation rather than assumed:

| Instruction | Opcode | Args | Layout | Source |
|---|---|---|---|---|
| `OnlyTakerTokenBalanceNonZero` | `0x23` | 20 | `address token` | `Controls.sol:45`, `:140` |
| `StaticBalances` | `0x90` | 64 | `uint256 balanceA, uint256 balanceB` | `Balances.sol:16` |
| `LimitSwap` | `0x53` | 1 | `bool makerDirectionLt` | `LimitSwap.sol:19` |

Note `LimitSwap`'s args are **one byte**, not two addresses — `build(tokenIn, tokenOut)`
encodes only `tokenIn < tokenOut`. Worth stating because the catalogue snippet reads as though
the tokens are stored.

## Concrete instance

With `gateToken = 0x00000000000000000000000000000000000000aA`, balances `1000e18` / `2000e18`,
and `makerDirectionLt = true`:

```
23 14 00000000000000000000000000000000000000aa
90 40 00000000000000000000000000000000000000000000003635c9adc5dea00000
      000000000000000000000000000000000000000000000006c6b935b8bbd40000
53 01 01
```

Flat, 91 bytes:

```
231400000000000000000000000000000000000000aa9040000000000000000000000000000000000000000000000
03635c9adc5dea00000000000000000000000000000000000000000000000000006c6b935b8bbd400000530101
```

Byte budget: `22 + 66 + 3 = 91`.

## The theorem

Not about this instance. About every program that starts this way:

> For any program `P = 0x23 0x14 G ++ TAIL`, where `G` is a 20-byte address and `TAIL` is an
> arbitrary byte string, execution with a taker holding zero balance of `G` never reaches
> `<status> Settled`.

`TAIL` stays **symbolic**. That is what makes this worth more than the scenario tests in
`test/invariants/`, which can only sample particular tails — and it is the shape of claim
1inch's own guidance calls for when it says instruction ordering is security-critical and that
invariants must hold "for the full composed program".

The theorem needs **no arithmetic**. It is entirely about control flow reaching the gate
before anything else, which is why it is the right first target.

## Conformance obligation

Before the theorem means anything, the same 91 bytes must produce identical registers under
`krun` and under the real VM driven by Foundry, for at least:

- taker holding zero `G` — both revert with `TakerTokenBalanceIsZero`
- taker holding some `G`, exact-in — identical `amountIn`/`amountOut`
- truncated program (91st byte removed) — both revert with `RunLoopExceedProgramLength`

## Status

| | |
|---|---|
| Semantics | not written |
| Conformance | not written |
| Theorem | not attempted |
| Instruction refinement | `ADMITTED` ×3 — see [`../axioms.md`](../axioms.md) |

The theorem, once proved, holds **modulo those three admissions**. It is not a claim about the
bytecode deployed at `0x8fdd04dbf6111437b44bbca99c28882434e0958f`. See `PLAN.md` §0.

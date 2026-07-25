SwapVM — decode loop
====================

The configuration and fetch/decode/dispatch loop mirroring `src/libs/VM.sol:118-150`, plus the
three instruction rules added in Phase 1 (`0x23`, `0x90`, `0x53`).

`Settled` is declared in `Status` but **no rule produces it** — settlement happens outside
`runLoop`. Any claim phrased as "never reaches `Settled`" is therefore vacuous; state the
revert reason instead.

```k
module SWAPVM-SYNTAX
  imports INT-SYNTAX
  imports BYTES-SYNTAX
endmodule

module SWAPVM
  imports SWAPVM-SYNTAX
  imports INT
  imports BOOL
  imports BYTES
  imports MAP
  imports LIST
  imports STRING
```

Status is a three-way outcome. The revert *reason* is an opaque string — enough to state
"reverts with `RunLoopExceedProgramLength`" without modelling ABI error encoding (`PLAN.md`
D5).

```k
  syntax Status ::= "Running" | "Settled" | Reverted ( String )
```

Configuration
-------------

Mirrors the `Context` struct. `<balances>` maps `token |-> holder |-> amount` and exists only
to give the taker-gate instruction something to read; it is the abstraction boundary for
external effects (`PLAN.md` D4).

```k
  configuration
    <swapvm>
      <k> #run </k>
      <program> $PGM:Bytes </program>
      <pc> 0 </pc>
      <swap>
        <balanceIn>  0 </balanceIn>
        <balanceOut> 0 </balanceOut>
        <amountIn>   $AMOUNTIN:Int </amountIn>
        <amountOut>  $AMOUNTOUT:Int </amountOut>
        <netPulled>  0 </netPulled>
      </swap>
      <query>
        <isExactIn> $EXACTIN:Bool </isExactIn>
        <tokenIn>   $TOKENIN:Int </tokenIn>
        <tokenOut>  $TOKENOUT:Int </tokenOut>
        <taker>     $TAKER:Int </taker>
      </query>
      <balances>     $BALANCES:Map </balances>
      <invalidators> .Map </invalidators>
      <status>    Running </status>
      <trace>      .List  </trace>
    </swapvm>
```

Control
-------

`#exec` is where instruction rules will attach. `#revert` is terminal: it clears the
continuation so nothing further executes, exactly as a Solidity revert unwinds.

```k
  syntax KItem ::= "#run"
                 | #exec ( Int , Bytes )
                 | #revert ( String )
```

The loop
--------

`VM.sol` reads one word at `programBytes.offset + pcs` and takes the top byte as the opcode
and the next as the args length:

```solidity
opcode     := shr(248, word)
argsLength := and(shr(240, word), 0xff)
pcs        := add(pcs, 2)
args.offset := add(programBytes.offset, pcs)
args.length := argsLength
pcs        := add(pcs, argsLength)
```

so byte `pc` is the opcode and byte `pc+1` is the length. Termination is `while (pcs < length)`.

```k
  // The loop ends when the program counter reaches the end. This is `while (pcs < length)`
  // falling through, NOT a Stop instruction.
  rule <k> #run => .K ... </k>
       <pc> PC </pc>
       <program> PGM </program>
       <status> Running </status>
    requires PC >=Int lengthBytes(PGM)
```

The bound check is `VM.sol:143` — `if (pcs > length) revert RunLoopExceedProgramLength`.
It fires *after* `pcs` has advanced past the args, so an instruction whose declared args run
off the end reverts rather than reading out of bounds. Two ways to trip it: the two-byte
header itself does not fit, or the args do not.

**`pc` must be advanced before the check, not after.** Conformance caught this: the first
version of these rules reverted with `pc` still at the instruction start, and the real VM
reports the *advanced* value — `(91, 90)` where this model said `88`. Both reverted, and with
the same reason, so only a test that inspects the revert arguments distinguishes them. It
matters for any theorem stated about revert data.

The header-does-not-fit arm reads the length byte from beyond the program. On the real VM that
is `calldataload` past the end, which yields zero padding, so `argsLength` is `0` and `pcs`
lands on `PC +Int 2`.

```k
  rule <k> #run => #revert("RunLoopExceedProgramLength") ... </k>
       <pc> PC => PC +Int 2 </pc>
       <program> PGM </program>
       <status> Running </status>
    requires PC <Int lengthBytes(PGM)
     andBool PC +Int 2 >Int lengthBytes(PGM)

  rule <k> #run => #revert("RunLoopExceedProgramLength") ... </k>
       <pc> PC => PC +Int 2 +Int PGM [ PC +Int 1 ] </pc>
       <program> PGM </program>
       <status> Running </status>
    requires PC +Int 2 <=Int lengthBytes(PGM)
     andBool PC +Int 2 +Int PGM [ PC +Int 1 ] >Int lengthBytes(PGM)
```

The ordinary step: decode, dispatch, advance. `pc` is advanced *before* `#exec` so that an
instruction which writes `pc` — a jump — overwrites the advanced value, which is what
`ctx.vm.nextPC = pcs; ... ; pcs = ctx.vm.nextPC` does in the Solidity.

```k
  rule <k> #run => #exec ( PGM [ PC ] , substrBytes ( PGM , PC +Int 2 , PC +Int 2 +Int PGM [ PC +Int 1 ] ) ) ~> #run ... </k>
       <pc> PC => PC +Int 2 +Int PGM [ PC +Int 1 ] </pc>
       <program> PGM </program>
       <status> Running </status>
    requires PC +Int 2 <=Int lengthBytes(PGM)
     andBool PC +Int 2 +Int PGM [ PC +Int 1 ] <=Int lengthBytes(PGM)
```

Reverting discards the rest of the computation.

```k
  rule <k> #revert(MSG) ~> _ => .K </k>
       <status> _ => Reverted(MSG) </status>
```

Instructions
------------

Phase 1 implements three, enough for the permissioned-swap program in
`programs/permissioned-swap.md`. Each mirrors its Solidity source; see `PHASE1.md` for the
side-by-side.

`<balances>` is keyed by `bal(token, holder)` and is the abstraction boundary for external
ERC-20 state (`PLAN.md` D4).

```k
  syntax KItem ::= bal ( Int , Int )

  syntax Int ::= #balanceOf ( Map , Int , Int ) [function, total]
  rule #balanceOf(B, TOKEN, HOLDER) => {B [ bal(TOKEN, HOLDER) ] orDefault 0}:>Int
    requires isInt(B [ bal(TOKEN, HOLDER) ] orDefault 0)
  rule #balanceOf(_, _, _) => 0 [owise]
```

### `0x23` OnlyTakerTokenBalanceNonZero — `Controls.sol:140-144`

A pure guard: reads the taker's balance of the 20-byte token in `args` and reverts if zero.
Writes no registers.

```k
  rule <k> #exec ( 35 , ARGS ) => .K ... </k>
       <query> ... <taker> TAKER </taker> ... </query>
       <balances> B </balances>
    requires lengthBytes(ARGS) ==Int 20
     andBool #balanceOf(B, Bytes2Int(ARGS, BE, Unsigned), TAKER) >Int 0

  rule <k> #exec ( 35 , ARGS ) => #revert("TakerTokenBalanceIsZero") ... </k>
       <query> ... <taker> TAKER </taker> ... </query>
       <balances> B </balances>
    requires lengthBytes(ARGS) ==Int 20
     andBool #balanceOf(B, Bytes2Int(ARGS, BE, Unsigned), TAKER) <=Int 0
```

### `0x90` StaticBalances — `Balances.sol:37-47`

Guards that both balance registers are still zero, then writes the pair **oriented by token
order**: swapped when `tokenIn >= tokenOut`. Both branches are modelled — omitting one would
make the semantics wrong for half of all token pairs.

```k
  rule <k> #exec ( 144 , ARGS ) => .K ... </k>
       <balanceIn>  0 => Bytes2Int(substrBytes(ARGS,  0, 32), BE, Unsigned) </balanceIn>
       <balanceOut> 0 => Bytes2Int(substrBytes(ARGS, 32, 64), BE, Unsigned) </balanceOut>
       <tokenIn> TIN </tokenIn> <tokenOut> TOUT </tokenOut>
    requires lengthBytes(ARGS) ==Int 64 andBool TIN <Int TOUT

  rule <k> #exec ( 144 , ARGS ) => .K ... </k>
       <balanceIn>  0 => Bytes2Int(substrBytes(ARGS, 32, 64), BE, Unsigned) </balanceIn>
       <balanceOut> 0 => Bytes2Int(substrBytes(ARGS,  0, 32), BE, Unsigned) </balanceOut>
       <tokenIn> TIN </tokenIn> <tokenOut> TOUT </tokenOut>
    requires lengthBytes(ARGS) ==Int 64 andBool TIN >=Int TOUT

  rule <k> #exec ( 144 , ARGS ) => #revert("SetBalancesExpectZeroBalances") ... </k>
       <balanceIn> BIN </balanceIn> <balanceOut> BOUT </balanceOut>
    requires lengthBytes(ARGS) ==Int 64
     andBool notBool ( BIN ==Int 0 andBool BOUT ==Int 0 )
```

### `0x53` LimitSwap — `LimitSwap.sol:_limitSwap1D`

Args are a **single byte**: `makerDirectionLt`, which must agree with the taker's direction.

```k
  syntax Bool ::= #makerDirLt ( Bytes ) [function, total]
  rule #makerDirLt(ARGS) => ARGS [ 0 ] =/=Int 0 requires lengthBytes(ARGS) >Int 0
  rule #makerDirLt(_)    => false               [owise]
```

The quote goes through named symbols per `PLAN.md` D2, so that weakening to axioms later is
deleting the defining rule rather than restructuring. Floor on exact-in, ceiling on exact-out —
both round toward the maker. `#ceilDiv` mirrors OpenZeppelin's `Math.ceilDiv`, which is
`a == 0 ? 0 : (a - 1) / b + 1`.

```k
  syntax Int ::= limitQuoteOut ( Int , Int , Int ) [function]
               | limitQuoteIn  ( Int , Int , Int ) [function]
               | #ceilDiv      ( Int , Int )       [function]

  rule limitQuoteOut(AIN,  BIN, BOUT) => AIN *Int BOUT /Int BIN            requires BIN >Int 0
  rule limitQuoteIn (AOUT, BIN, BOUT) => #ceilDiv(AOUT *Int BIN, BOUT)     requires BOUT >Int 0

  rule #ceilDiv(0, _) => 0
  rule #ceilDiv(A, B) => ( A -Int 1 ) /Int B +Int 1  requires A =/=Int 0 andBool B >Int 0
```

The guards first: both balances non-zero, directions agree, and the output register not
already set.

```k
  rule <k> #exec ( 83 , _ ) => #revert("LimitSwapRequiresBothBalancesNonZero") ... </k>
       <balanceIn> BIN </balanceIn> <balanceOut> BOUT </balanceOut>
    requires BIN <=Int 0 orBool BOUT <=Int 0

  rule <k> #exec ( 83 , ARGS ) => #revert("LimitSwapDirectionMismatch") ... </k>
       <balanceIn> BIN </balanceIn> <balanceOut> BOUT </balanceOut>
       <tokenIn> TIN </tokenIn> <tokenOut> TOUT </tokenOut>
    requires BIN >Int 0 andBool BOUT >Int 0
     andBool ( #makerDirLt(ARGS) =/=Bool ( TIN <Int TOUT ) )
```

Then the two pricing directions.

```k
  rule <k> #exec ( 83 , ARGS ) => .K ... </k>
       <isExactIn> true </isExactIn>
       <amountIn> AIN </amountIn>
       <amountOut> AOUT => limitQuoteOut(AIN, BIN, BOUT) </amountOut>
       <balanceIn> BIN </balanceIn> <balanceOut> BOUT </balanceOut>
       <tokenIn> TIN </tokenIn> <tokenOut> TOUT </tokenOut>
    requires BIN >Int 0 andBool BOUT >Int 0 andBool AOUT ==Int 0
     andBool ( #makerDirLt(ARGS) ==Bool ( TIN <Int TOUT ) )

  rule <k> #exec ( 83 , ARGS ) => #revert("LimitSwapRecomputeDetected") ... </k>
       <isExactIn> true </isExactIn>
       <amountOut> AOUT </amountOut>
       <balanceIn> BIN </balanceIn> <balanceOut> BOUT </balanceOut>
       <tokenIn> TIN </tokenIn> <tokenOut> TOUT </tokenOut>
    requires BIN >Int 0 andBool BOUT >Int 0 andBool AOUT =/=Int 0
     andBool ( #makerDirLt(ARGS) ==Bool ( TIN <Int TOUT ) )

  rule <k> #exec ( 83 , ARGS ) => .K ... </k>
       <isExactIn> false </isExactIn>
       <amountIn> AIN => limitQuoteIn(AOUT, BIN, BOUT) </amountIn>
       <amountOut> AOUT </amountOut>
       <balanceIn> BIN </balanceIn> <balanceOut> BOUT </balanceOut>
       <tokenIn> TIN </tokenIn> <tokenOut> TOUT </tokenOut>
    requires BIN >Int 0 andBool BOUT >Int 0 andBool AIN ==Int 0
     andBool ( #makerDirLt(ARGS) ==Bool ( TIN <Int TOUT ) )

  rule <k> #exec ( 83 , ARGS ) => #revert("LimitSwapRecomputeDetected") ... </k>
       <isExactIn> false </isExactIn>
       <amountIn> AIN </amountIn>
       <balanceIn> BIN </balanceIn> <balanceOut> BOUT </balanceOut>
       <tokenIn> TIN </tokenIn> <tokenOut> TOUT </tokenOut>
    requires BIN >Int 0 andBool BOUT >Int 0 andBool AIN =/=Int 0
     andBool ( #makerDirLt(ARGS) ==Bool ( TIN <Int TOUT ) )
```

Malformed arguments on a MODELLED opcode
----------------------------------------

**This closes a real soundness hole.** The instruction rules above all constrain
`lengthBytes(ARGS)`, but the Solidity constrains nothing: `address(bytes20(args))` and
`bytes32(args)` right-zero-pad short arguments and truncate long ones, with no revert. So
`0x23 0x13` followed by 19 bytes gate-checks a *different address* on chain, while every rule
above fails to match — and the instruction would fall through to the `[owise]` no-op below,
**silently deleting a security gate from the model while it stays live in production**.

A review confirmed this by execution: K produced `Running` with `#unknown(35, ...)` in the
trace where the real VM enforces the gate.

Modelling the pad-and-truncate semantics properly is Phase 2 work. Until then these rules make
the gap **loud instead of silent** — a proof touching such an instruction fails rather than
succeeding on a fiction. That is the safe direction to be wrong in.

```k
  rule <k> #exec ( 35 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
    requires lengthBytes(ARGS) =/=Int 20

  rule <k> #exec ( 144 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
    requires lengthBytes(ARGS) =/=Int 64
```

`0x53` needs no such rule: its rules place no constraint on the argument length, and
`#makerDirLt` is total — matching `uint8(bytes1(args)) != 0`, which yields `false` on empty
arguments.

Unknown opcodes
---------------

Every opcode without a rule above. Rather than getting stuck — which is indistinguishable from
a bug in the loop — an unknown opcode is a no-op that records itself in the trace. This is what
made the Phase 0 decode loop testable before any instruction existed, and it is the twin of the
recording stub in `test/conformance/RunLoopConformance.t.sol`.

**It remains a soundness hazard, and the mitigation is narrower than it looks.** A program
using an unmodelled opcode appears to execute here, while production reverts `UnknownOpcode`
(`src/opcodes/Opcodes.sol:101`). Every theorem must therefore either fix the whole program
concretely, or be stated so that unmodelled opcodes cannot affect the conclusion. The Phase 1
gate theorem is the latter — it reverts before the tail is ever decoded.

Note what the rules immediately above buy: previously this hazard covered *modelled* opcodes
too, whenever their argument length was non-canonical. It is now confined to genuinely
unmodelled opcodes, which is a much smaller and more visible surface.

```k
  rule <k> #exec ( OP , ARGS ) => .K ... </k>
       <trace> ... .List => ListItem(#unknown(OP, ARGS)) </trace>
    [owise]

  syntax KItem ::= #unknown ( Int , Bytes )

endmodule
```

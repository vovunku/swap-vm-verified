SwapVM — decode loop
====================

Phase 0 of `PLAN.md`: the configuration and the fetch/decode/dispatch loop, mirroring
`src/libs/VM.sol:118-150`. **No instruction rules yet** — a program of unknown opcodes runs to
completion doing nothing, which is what makes the decode loop testable in isolation.

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
        <amountIn>   0 </amountIn>
        <amountOut>  0 </amountOut>
        <netPulled>  0 </netPulled>
      </swap>
      <query>
        <isExactIn> true </isExactIn>
        <tokenIn>   0 </tokenIn>
        <tokenOut>  0 </tokenOut>
        <taker>     0 </taker>
      </query>
      <balances>     .Map </balances>
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

The bound check is `VM.sol:142` — `if (pcs > length) revert RunLoopExceedProgramLength`.
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

Unknown opcodes
---------------

**Phase 0 only.** With no instruction rules written, every opcode is unknown. Rather than
getting stuck — which is indistinguishable from a bug in the loop — an unknown opcode is a
no-op that records itself in the trace. Each instruction rule added in Phase 1 takes priority
over this, and this rule is deleted once the opcode set is complete.

```k
  rule <k> #exec ( OP , ARGS ) => .K ... </k>
       <trace> ... .List => ListItem(#unknown(OP, ARGS)) </trace>
    [owise]

  syntax KItem ::= #unknown ( Int , Bytes )

endmodule
```

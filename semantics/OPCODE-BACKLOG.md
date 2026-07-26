# Opcode semantics backlog

Authoritative list of SwapVM opcodes **dispatched in production** (`src/opcodes/Opcodes.sol`)
but **not yet modelled** in the K semantics (`semantics/swapvm.md`). 47 opcodes are wired to
handlers; 3 are modelled (`0x23`, `0x53`, `0x90`); the other 44 are below.

Unmodelled opcodes currently fall through to the `[owise]` no-op (`swapvm.md:349-351`) which
records `#unknown(OP, ARGS)` in the trace. Production reverts `UnknownOpcode`
(`src/opcodes/Opcodes.sol:101`) for the reserved slots, but executes the handler for everything
below — so each entry here is a **live soundness hazard**: a program using one appears to execute
in K while production either runs real logic or reverts. See `swapvm.md:330-346`.

## Status legend

- **modelled** — has K rules (in `swapvm.md` for the original 3; in `semantics/opcodes/<name>.k` as a sibling module for the rest)
- **conformance-verified** — modelled AND has concrete K claims + Solidity tests showing K↔production agreement (the real verification; see `test/conformance/InstructionConformance.t.sol` and `semantics/proofs/*-concrete.k`)
- **in-progress** — a subagent owns it
- **unmodelled** — not started

## 0x00–0x0f · Core control flow

| Hex | Opcode | Handler | Source | Status |
|-----|--------|---------|--------|--------|
| `0x00` | Stop | `Controls._stop` | `Controls.sol:90-93` | modelled |
| `0x01` | Revert | `Controls._revert` | `Controls.sol:85-87` | conformance-verified |
| `0x02` | Salt | `Controls._salt` | `Controls.sol:73` | conformance-verified |
| `0x03` | Jump | `Controls._jump` | `Controls.sol:79-82` | conformance-verified |
| `0x04` | Extruction | `Extruction._extruction` | `Extruction.sol:90-115` | modelled |

## 0x20–0x3f · Conditions & access guards

| Hex | Opcode | Handler | Source | Status |
|-----|--------|---------|--------|--------|
| `0x20` | Deadline | `Controls._deadline` | `Controls.sol:131-134` | conformance-verified |
| `0x23` | OnlyTakerTokenBalanceNonZero | `Controls._onlyTakerTokenBalanceNonZero` | `Controls.sol:140-144` | **modelled** |
| `0x24` | OnlyTakerTokenBalanceGte | `Controls._onlyTakerTokenBalanceGte` | `Controls.sol:161-166` | conformance-verified |
| `0x25` | OnlyTakerTokenSupplyShareGte | `Controls._onlyTakerTokenSupplyShareGte` | `Controls.sol:171-178` | conformance-verified |
| `0x26` | OnlyTxOriginTokenBalanceNonZero | `Controls._onlyTxOriginTokenBalanceNonZero` | `Controls.sol:152-156` | conformance-verified |
| `0x2b` | PrivateOrder | `Whitelist._privateOrder` | `instructions/Whitelist.sol` | conformance-verified |
| `0x2c` | WhitelistCoequal | `Whitelist._whitelistCoequal` | `instructions/Whitelist.sol` | conformance-verified |
| `0x2d` | WhitelistSequential | `Whitelist._whitelistSequential` | `instructions/Whitelist.sol` | conformance-verified |
| `0x30` | JumpIfDirection | `Controls._jumpIfDirection` | `Controls.sol:96-103` | conformance-verified |
| `0x31` | JumpIfTokenIn | `Controls._jumpIfTokenIn` | `Controls.sol:109-115` | conformance-verified |
| `0x32` | JumpIfTokenOut | `Controls._jumpIfTokenOut` | `Controls.sol:121-127` | conformance-verified |

## 0x40–0x4f · Invalidators & epochs

| Hex | Opcode | Handler | Source | Status |
|-----|--------|---------|--------|--------|
| `0x40` | InvalidateBit | `Invalidators._invalidateBit1D` | `instructions/Invalidators.sol` | unmodelled |
| `0x41` | InvalidateTokenIn | `Invalidators._invalidateTokenIn1D` | `instructions/Invalidators.sol` | unmodelled |
| `0x42` | InvalidateTokenOut | `Invalidators._invalidateTokenOut1D` | `instructions/Invalidators.sol` | unmodelled |
| `0x48` | ValidateSeriesEpoch | `SeriesEpochManager._validateSeriesEpochXD` | `instructions/SeriesEpochManager.sol` | unmodelled |

## 0x50–0x6f · Swap curves

| Hex | Opcode | Handler | Source | Status |
|-----|--------|---------|--------|--------|
| `0x50` | XYCSwap | `XYCSwap._xycSwapXD` | `instructions/XYCSwap.sol` | unmodelled |
| `0x51` | XYCConcentrateSwap | `XYCConcentrate._xycConcentrateGrowLiquidity2D` | `instructions/XYCConcentrate.sol` | unmodelled |
| `0x53` | LimitSwap | `LimitSwap._limitSwap1D` | `instructions/LimitSwap.sol` | **modelled** |
| `0x54` | LimitSwapFullAmount | `LimitSwap._limitSwapOnlyFull1D` | `instructions/LimitSwap.sol` | unmodelled |
| `0x58` | PeggedSwap | `PeggedSwap._peggedSwapGrowPriceRange2D` | `instructions/PeggedSwap.sol` | unmodelled |

## 0x70–0x8f · Fees

| Hex | Opcode | Handler | Source | Status |
|-----|--------|---------|--------|--------|
| `0x70` | FlatFeeAmountIn | `Fee._flatFeeAmountInXD` | `instructions/Fee.sol` | unmodelled |
| `0x71` | ProtocolFeeAmountIn | `Fee._protocolFeeAmountInXD` | `instructions/Fee.sol` | unmodelled |
| `0x72` | AquaProtocolFeeAmountIn | `Fee._aquaProtocolFeeAmountInXD` | `instructions/Fee.sol` | unmodelled |
| `0x73` | ProgressiveFeeIn | `FeeExperimental._progressiveFeeInXD` | `instructions/FeeExperimental.sol` | unmodelled |
| `0x74` | DynamicProtocolFeeAmountIn | `Fee._dynamicProtocolFeeAmountInXD` | `instructions/Fee.sol` | unmodelled |
| `0x75` | AquaDynamicProtocolFeeAmountIn | `Fee._aquaDynamicProtocolFeeAmountInXD` | `instructions/Fee.sol` | unmodelled |
| `0x80` | FlatFeeAmountOut | `FeeExperimental._flatFeeAmountOutXD` | `instructions/FeeExperimental.sol` | unmodelled |
| `0x81` | ProtocolFeeAmountOut | `FeeExperimental._protocolFeeAmountOutXD` | `instructions/FeeExperimental.sol` | unmodelled |
| `0x82` | AquaProtocolFeeAmountOut | `FeeExperimental._aquaProtocolFeeAmountOutXD` | `instructions/FeeExperimental.sol` | unmodelled |
| `0x83` | ProgressiveFeeOut | `FeeExperimental._progressiveFeeOutXD` | `instructions/FeeExperimental.sol` | unmodelled |

## 0x90–0xaf · Balances tuning

| Hex | Opcode | Handler | Source | Status |
|-----|--------|---------|--------|--------|
| `0x90` | StaticBalances | `Balances._staticBalancesXD` | `instructions/Balances.sol:37-47` | **modelled** |
| `0x91` | DynamicBalances | `Balances._dynamicBalancesXD` | `instructions/Balances.sol` | unmodelled |
| `0x94` | DutchAuctionBalanceIn | `DutchAuction._dutchAuctionBalanceIn1D` | `instructions/DutchAuction.sol` | unmodelled |
| `0x95` | DutchAuctionBalanceOut | `DutchAuction._dutchAuctionBalanceOut1D` | `instructions/DutchAuction.sol` | unmodelled |
| `0x98` | PiecewiseLinearScaleBalanceIn | `PiecewiseLinearScale._piecewiseLinearScaleBalanceIn1D` | `instructions/PiecewiseLinearScale.sol` | unmodelled |
| `0x99` | PiecewiseLinearScaleBalanceOut | `PiecewiseLinearScale._piecewiseLinearScaleBalanceOut1D` | `instructions/PiecewiseLinearScale.sol` | unmodelled |
| `0x9c` | Decay | `Decay._decayXD` | `instructions/Decay.sol` | unmodelled |
| `0x9d` | TWAPSwap | `TWAPSwap._twap` | `instructions/TWAPSwap.sol` | unmodelled |

## 0xb0–0xcf · Rates tuning

| Hex | Opcode | Handler | Source | Status |
|-----|--------|---------|--------|--------|
| `0xb0` | RequireMinRate | `MinRate._requireMinRate1D` | `instructions/MinRate.sol` | unmodelled |
| `0xb1` | AdjustMinRate | `MinRate._adjustMinRate1D` | `instructions/MinRate.sol` | unmodelled |
| `0xb4` | BaseFeeAdjuster | `BaseFeeAdjuster._baseFeeAdjuster1D` | `instructions/BaseFeeAdjuster.sol` | unmodelled |

## Out of scope for this backlog

- `0x10`–`0x1f` debug opcodes (`PrintSwapRegisters` etc.) — wired only into the `*Debug`
  opcode sets, not the production dispatcher.
- All reserved `_xx` slots — revert `UnknownOpcode` on chain, no handler to model.
- The entire `0xd0`–`0xff` range is unallocated or reserved (`OpcodeList.sol:235-285`).

## Count

- 18 modelled (3 in `swapvm.md` + 15 in `semantics/opcodes/`), 28 unmodelled-but-dispatched = 46 dispatched total, ~164 reserved.
- When a subagent lands an opcode, flip its row to **modelled**. The core control flow family's rules live in sibling modules (`SWAPVM-STOP`, `SWAPVM-REVERT`, `SWAPVM-SALT`, `SWAPVM-JUMP`, `SWAPVM-EXTRUCTION`) that must be wired into `lemmas.k` via `requires` + `imports`; see `opcodes/README.md` (TODO) or each opcode's `.md` for the recipe.

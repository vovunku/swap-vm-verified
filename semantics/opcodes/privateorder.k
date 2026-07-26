requires "../swapvm.md"

// 0x2b PrivateOrder — Whitelist.sol:103-110.
//
// Adds the rule to the SWAPVM semantics. K v7 does not allow reopening `module SWAPVM`
// across files (it reports "Module SWAPVM differs from previous declaration"), so this
// file defines a sibling module SWAPVM-PRIVATEORDER that imports SWAPVM and adds the
// rules. Integration is via `requires "opcodes/privateorder.k"` plus
// `imports SWAPVM-PRIVATEORDER` from the main module (semantics/lemmas.k) — see
// privateorder.md "Integration".
//
// WHAT THE OPCODE DOES. A pure equality gate:
//   uint80 sender       = wrapToPackedAddress(ctx.query.taker);  // = uint80(uint160(taker))
//   uint80 allowedTaker = args.parsePrivateOrder();              // = shr(176, calldataload(..))
//   require(sender == allowedTaker, WhitelistInvalidTaker());
// It compares the taker's address TRUNCATED TO ITS LOW 80 BITS against the 10-byte packed
// arg. No external reads, no uninterpreted functions, no loops. Structurally a gate like
// 0x23 (swapvm.md:177-194), but the predicate is `packed(taker) == packed(arg)` instead of
// `balance > 0`.
//
// THE 80-BIT PACKING — FIDELITY POINT (Whitelist.sol:88-95). Only the low 80 bits
// (low 10 bytes) of the taker's address are compared: `uint80(uint160(taker))` discards
// the high 80 bits. Two addresses that share their low 10 bytes are INDISTINGUISHABLE to
// this opcode — both pass identically. This is a DELIBERATE collision-resistance
// trade-off documented at Whitelist.sol:88-95: mining an 80-bit address collision costs
// millions of GPU-years, and the van Oorschot–Wiener birthday attack — though it can find
// 80-bit collisions efficiently — requires the attacker to CONTROL BOTH accounts, so a
// whitelist bypass is not a security break (the attacker is authorising themself). The K
// model FAITHFULLY preserves this truncation: it computes `TAKER modInt (2 ^Int 80)`,
// making the low-80-bit equivalence a first-class fact a spec can reason about. This is
// not a fidelity gap to close but a property to preserve.
//
// The decode rule in swapvm.md (143-149) has already consumed the [opcode:1][argsLen:1]
// header and advanced <pc> by `2 + argsLen` BEFORE #exec fires, exactly mirroring
// `pcs := add(pcs, 2); ... pcs := add(pcs, argsLength)` in VM.sol:133-138. This opcode
// neither reads nor writes <pc> beyond that (no `setNextPC` call), so the rules inherit
// the already-advanced value and leave it — the same posture as the 0x23 gate, Revert
// (opcodes/revert.k), Salt (opcodes/salt.k), Deadline (opcodes/deadline.k), Gte
// (opcodes/gte.k), and TxOrigin (opcodes/txorigin.k). The opcode is a pure conditional
// halt: it either reverts (clearing <k>) or is a no-op pass-through (leaves #run in <k>).
//
// ARM SELECTION — why the direct two-arm form works here, no Bool predicate needed.
// The opcode compares `TAKER modInt (2 ^Int 80)` (a decidable arithmetic term) against
// `Bytes2Int(ARGS, BE, Unsigned)` (a 10-byte big-endian read, also decidable) for
// EQUALITY. Equality between two terms — symbolic or concrete — is decidable in the K
// Haskell backend, so a spec premise `(TAKER modInt 2^80) =/=Int PACKED` refutes the PASS
// arm and selects the REVERT arm directly, exactly as `#balanceOf(...) ==Int 0` selects
// the 0x23 REVERT arm (swapvm.md:189-193). The Deadline/Gte/SupplyShare arm-selection
// limitation (which forces those opcodes into a Bool-predicate form) ONLY affects
// inequalities against SYMBOLIC values; it does not apply to ==/=/=. The brief's
// modelling section directs the direct form first; this file honours that. No fallback
// `#takerMatchesPacked` Bool predicate is needed.
//
// PAD-AND-TRUNCATE SOUNDNESS HAZARD (swapvm.md:301-324). The Solidity constrains nothing
// about `args.length`: `parsePrivateOrder` does `shr(176, calldataload(args.offset))`,
// which reads 32 bytes from `args.offset` and shifts right by 176 bits — on a SHORT args
// this reads into the following calldata (right-padded with whatever comes next), and on
// a LONG args it silently takes the first 10 bytes. There is NO revert for a wrong
// length. If the model only handled the canonical 10-byte case and let the others fall
// through to the `[owise]` no-op (swapvm.md:349-351), every such instance would be
// SILENTLY DELETED from the model while staying live in production — the worst failure
// direction (sound but wrong). The third rule reverts loudly with
// `"UNMODELLED-ARGS-LENGTH"` so a proof touching such an instruction fails rather than
// succeeds on a fiction. Same pattern as opcodes 0x23 / 0x90 in swapvm.md:319-324 and the
// twins in opcodes/jump.k:50-54, opcodes/txorigin.k:123-124, opcodes/deadline.k:121-126,
// opcodes/gte.k:142-148, and opcodes/supplyshare.k:184-191.

module SWAPVM-PRIVATEORDER
  imports SWAPVM

  // Canonical 10-byte case, PASS arm. Solidity:
  //   uint80 sender       = uint80(uint160(ctx.query.taker));
  //   uint80 allowedTaker = args.parsePrivateOrder();
  //   require(sender == allowedTaker, WhitelistInvalidTaker());
  // (Whitelist.sol:105-110, helpers at 20-24 and 81-85). The require passes — the taker's
  // low 80 bits equal the packed arg — and the function returns normally. The opcode is a
  // no-op at the register level: reads no register (only `<taker>`), writes no register,
  // no `setNextPC`. The continuation #run is left in <k> and the loop proceeds to decode
  // the next instruction. Like the 0x23 gate (and unlike Salt/Deadline/Gte on their PASS
  // arms), this opcode IS a halt on the REVERT arm but NOT on this arm; a positive claim
  // covering the REVERT arm leaves the tail unconsumed (#revert discards the
  // continuation), and a positive claim covering this arm would have to terminate
  // concretely — same composition shape as 0x23.
  //
  // `TAKER modInt (2 ^Int 80)` is the faithful model of `uint80(uint160(taker))`: it
  // discards every bit above bit 79, exactly as the Solidity cast does. The packed arg is
  // `Bytes2Int(ARGS, BE, Unsigned)` — under `lengthBytes(ARGS) ==Int 10` this is the exact
  // 10-byte big-endian read matching `shr(176, calldataload(args.offset))` on a canonical
  // 10-byte args, and the round-trip lemma (lemmas.k:64-67) rewrites
  // `Bytes2Int(Int2Bytes(10, PACKED, BE), BE, Unsigned) => PACKED` under
  // `0 <=Int PACKED <Int 2^80`.
  rule <k> #exec ( 43 , ARGS ) => .K ... </k>
       <query> ... <taker> TAKER </taker> ... </query>
    requires lengthBytes(ARGS) ==Int 10
     andBool (TAKER modInt (2 ^Int 80)) ==Int Bytes2Int(ARGS, BE, Unsigned)

  // Canonical 10-byte case, REVERT arm. The taker's low 80 bits do NOT equal the packed
  // arg. `#revert(MSG) ~> _ => .K` (swapvm.md:154-156) clears the continuation and sets
  // <status> Reverted(MSG), so the loop never resumes and an arbitrary symbolic tail in
  // the program cannot affect the conclusion. Mirrors the 0x23 REVERT arm
  // (swapvm.md:189-193) with the equality-flipped predicate and the
  // `"WhitelistInvalidTaker"` selector (Whitelist.sol:100, 109) in place of
  // `"TakerTokenBalanceIsZero"`.
  rule <k> #exec ( 43 , ARGS ) => #revert("WhitelistInvalidTaker") ... </k>
       <query> ... <taker> TAKER </taker> ... </query>
    requires lengthBytes(ARGS) ==Int 10
     andBool (TAKER modInt (2 ^Int 80)) =/=Int Bytes2Int(ARGS, BE, Unsigned)

  // Non-canonical args: Solidity right-pads short and truncates long without reverting
  // (`shr(176, calldataload(args.offset))` reads past a short args into following
  // calldata), which is a soundness hazard (swapvm.md:301-324). Revert loudly here so a
  // proof cannot silently succeed on an unmodelled length. Mirrors opcodes 0x23 / 0x90 in
  // swapvm.md:319-324 and the twins in opcodes/jump.k:50-54, opcodes/txorigin.k:123-124,
  // opcodes/deadline.k:121-126, opcodes/gte.k:142-148, and opcodes/supplyshare.k:184-191.
  rule <k> #exec ( 43 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
    requires lengthBytes(ARGS) =/=Int 10
endmodule

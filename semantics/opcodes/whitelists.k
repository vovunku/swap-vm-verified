requires "../swapvm.md"

// 0x2c WhitelistCoequal — Whitelist.sol:112-129.
// 0x2d WhitelistSequential — Whitelist.sol:131-167.
//
// Adds both Whitelist opcode rules to the SWAPVM semantics. K v7 does not allow
// reopening `module SWAPVM` across files (it reports "Module SWAPVM differs from previous
// declaration"), so this file defines a SINGLE sibling module SWAPVM-WHITELISTS that imports
// SWAPVM and adds the rules for BOTH opcodes. Integration is via `requires "opcodes/whitelists.k"`
// plus `imports SWAPVM-WHITELISTS` from the main module (semantics/lemmas.k) — see
// whitelists.md "Integration". One module, two opcodes: this avoids double-reopening
// SWAPVM and matches how the brief scopes the deliverable.
//
// WHAT THE OPCODES DO.
//
// 0x2c WhitelistCoequal: a conditional jump over a variable-length list of packed addresses.
//   uint80 sender = wrapToPackedAddress(ctx.query.taker);   // uint80(uint160(taker))
//   bytes calldata list = args.slice(2);                    // 10-byte packed entries
//   for (i = list.length / 10; i-- > 0; )
//     if (sender == list.parseWhitelistCoequalIx(i)) { ctx.vm.nextPC = pc; return; }
//   // (else fall through, no revert)
// Outcomes: JUMP (taker in list) or FALL THROUGH (not in list). Never reverts.
//
// 0x2d WhitelistSequential: a time-aware sequentially-growing whitelist. Three outcomes:
//   - JUMP if the taker's packed bits match an entry UNLOCKED at the current timestamp.
//   - REVERT "WhitelistAllowedTimeViolation" if not the unlocked taker but a window is still
//     exclusive (or before `start`).
//   - FALL THROUGH if the taker is not whitelisted AND every window has expired.
//
// THE LOOP IS INTRACTABLE TO MODEL LITERALLY (the load-bearing decision for this file).
//
// Both opcodes' main control flow is a `while (i-- > 0)` (0x2c) or `while (i < length)`
// (0x2d) loop over a variable-length byte array, parsing packed 10-byte (0x2c) or
// 2-byte-duration + 10-byte-address (0x2d) entries. The Solidity length `list.length / 10`
// (or `/ 12`) is itself SYMBOLIC once `ARGS` is symbolic — the K prover would have to unfold
// the loop an unknown number of times against a list of unknown length and unknown contents,
// which the Haskell backend cannot reduce to a closed form. The same intractability affected
// Extruction (opcodes/extruction.k), where the unmodellable surface was an arbitrary external
// call; here the unmodellable surface is the byte-level list parse. Per PLAN.md D4
// (cross-referenced in opcodes/extruction.md "The abstraction boundary (PLAN.md D4)"), the
// honest direction is to abstract the OUTCOME of the loop as a Bool predicate and prove
// STRUCTURAL properties about it (which arm fires given which predicate holds), rather than
// pretending to model the iteration.
//
// The chosen predicate abstraction:
//
//   - `#coequalWhitelistContains(ARGS, PACKED)` — conceptually the result of the 0x2c loop,
//     i.e. PACKED matches some 10-byte entry in ARGS[2:]. The byte-level list parsing is
//     NOT modelled.
//   - `#sequentialWhitelistJumps(ARGS, PACKED)` — conceptually true iff the 0x2d loop
//     matches PACKED at the entry unlocked by `block.timestamp`. The time arithmetic
//     (`block.timestamp >= start`, `timeLeft -= duration`, the in-window revert) is INSIDE
//     this predicate, not modelled directly.
//   - `#sequentialWhitelistReverts(ARGS, PACKED)` — conceptually true iff the 0x2d loop
//     hits the in-window revert (either `block.timestamp < start` or
//     `timeLeft < duration` at some entry whose address != PACKED).
//
// FALL THROUGH for 0x2d is the negation of BOTH: a spec selects it by conjoining
// `notBool #sequentialWhitelistJumps(...)` and `notBool #sequentialWhitelistReverts(...)` —
// see the file header's "Fidelity gaps" note for why the mutual-exclusivity between the three
// outcomes is asserted by specs rather than enforced by K.
//
// WHY BOOLean predicates, not direct inequality — the arm-selection limitation.
//
// The K Haskell backend's SMT encoding does NOT propagate an inequality premise on an
// uninterpreted-vs-symbolic comparison into a refutation of the opposite arm of a multi-arm
// rule. This was established empirically by the Deadline subagent (opcodes/deadline.md:125-156)
// and re-confirmed by Gte (opcodes/gte.md "Arm selection") and SupplyShare
// (opcodes/supplyshare.md "Arm selection"): the gate rule at swapvm.md:177-194 splits on
// `#balanceOf(...) >Int 0` vs `<=Int 0` and a spec premise `#balanceOf(...) ==Int 0` selects
// the REVERT arm — but ONLY because the comparison is to a CONSTANT (0). The identical shape
// comparing an uninterpreted function to a SYMBOLIC value (e.g. `#blockTimestamp() >Int DL`)
// does not exclude the opposite arm.
//
// The fix — the SAME fix Deadline, Gte, and SupplyShare adopted — is to abstract the branch
// condition itself into a free Bool predicate and split on THAT. A spec premise
// `#coequalWhitelistContains(...)` (implicitly `==Bool true`) selects the JUMP arm exactly as
// `#deadlineExceeded(DL)` selects Deadline's REVERT arm; `notBool #coequalWhitelistContains(...)`
// selects the FALL-THROUGH arm. Same for `#sequentialWhitelistJumps/Reverts`. The predicates
// are kept as independent uninterpreted symbols (no simplification rule defining them in terms
// of the bytes or the timestamp) so the arm-selection condition stays a single atomic Bool the
// SMT solver can decide on.
//
// `#blockTimestamp()` is declared here as well, mirroring opcodes/deadline.k:78 — the D4
// abstraction for the chain's `block.timestamp`. The 0x2d rule does NOT branch on this symbol
// directly (per the limitation above); it appears ONLY inside `#sequentialWhitelistJumps/
// Reverts` conceptually. It is kept as a separate uninterpreted symbol so a spec MAY reason
// about the timestamp directly (e.g. `requires #blockTimestamp() >Int 0`) when needed, and so
// that two specs that pin the same concrete timestamp agree on its value.
//
// THE 80-BIT PACKING — FIDELITY POINT (Whitelist.sol:88-95, 81-85). Both opcodes compute
// `sender = uint80(uint160(ctx.query.taker))` — the taker's address TRUNCATED TO ITS LOW 80
// BITS. The K model FAITHFULLY preserves this via `TAKER modInt (2 ^Int 80)`, the same shape
// used by the 0x2b twin (opcodes/privateorder.k:92-95). Two addresses sharing their low 10
// bytes are INDISTINGUISHABLE to these opcodes; this is a deliberate collision-resistance
// trade-off documented in Whitelist.sol:88-95 and preserved by the model, not a gap to close.
// The packed taker is passed to every whitelist predicate as `TAKER modInt (2 ^Int 80)`.
//
// <pc> OVERWRITE vs INHERIT. Both opcodes' JUMP arms overwrite `<pc>` with the uint16 read
// from ARGS[0:2] (mirroring `ctx.vm.nextPC = pc; pcs = ctx.vm.nextPC` — swapvm.md:138-140),
// exactly like Jump (opcodes/jump.k). The FALL-THROUGH and REVERT arms inherit the
// decode-advanced `<pc>` and leave it (FALL THROUGH) or clear `<k>` (REVERT) — the same
// posture as Salt, Deadline, Gte, and the 0x2b PASS/REVERT arms.
//
// PAD-AND-TRUNCATE SOUNDNESS HAZARD (swapvm.md:301-324). The Solidity constrains nothing
// about `args.length`: `args.slice(2)` (0x2c) and `args.slice(7)` (0x2d) silently produce
// whatever the bytes happen to be, and the integer division `list.length / 10` (or `/ 12`)
// silently ignores a trailing partial entry. A SHORT args reads a DIFFERENT list than the
// maker encoded (right-zero-padded by Solidity's calldata semantics), and an OFF-PITCH args
// (e.g. 13 bytes for 0x2c, which `length / 10` truncates to one 10-byte entry plus 3 ignored
// bytes) reads a list whose trailing partial is silently dropped. Neither case reverts on
// chain. If the model only handled the canonical-pitch case and let the rest fall through to
// the `[owise]` no-op (swapvm.md:349-351), every such Whitelist would be SILENTLY DELETED from
// the model while staying live in production — the worst failure direction (sound but wrong).
//
// The structural length constraints below — `lengthBytes(ARGS) >=Int 2 andBool
// (lengthBytes(ARGS) -Int 2) modInt 10 ==Int 0` for 0x2c, and `lengthBytes(ARGS) >=Int 7
// andBool (lengthBytes(ARGS) -Int 7) modInt 12 ==Int 0` for 0x2d — admit exactly the args
// lengths whose payload is a whole number of packed entries after the fixed header. Anything
// else reverts loudly with `"UNMODELLED-ARGS-LENGTH"`, mirroring opcodes 0x23 / 0x90 in
// swapvm.md:319-324 and the twins in opcodes/jump.k:50-54, opcodes/deadline.k:121-126,
// opcodes/gte.k:142-148, opcodes/supplyshare.k:184-191, opcodes/txorigin.k:123-124, and
// opcodes/privateorder.k:115-116. A proof touching such a Whitelist fails rather than
// succeeds on a fiction.
//
// NOTE on the `>=Int` lower bound vs `==Int`. The header for 0x2c is 2 bytes (pc) and the
// payload is `N * 10` bytes; a 0-byte payload (N = 0) is LEGAL on chain — it makes the
// whitelist always-empty and the loop never matches, so the opcode FALLS THROUGH. The model
// admits this: `lengthBytes(ARGS) >=Int 2` admits the 2-byte empty case. Same for 0x2d:
// `lengthBytes(ARGS) >=Int 7` admits the 7-byte case (pc + start, no entries), which on chain
// means "no taker is ever whitelisted; revert iff before `start + 0`, otherwise fall through".
// An `==Int 12`/`==Int 7+12k` upper-bound-style constraint would WRONGLY exclude the empty
// list, which is a real on-chain configuration. The `>=` lower bound plus the `modInt` pitch
// constraint are the faithful shape.

module SWAPVM-WHITELISTS
  imports SWAPVM

  // The current block timestamp, as an uninterpreted total function. This is the PLAN.md D4
  // abstraction boundary for the chain's `block.timestamp` environment input, mirroring the
  // declaration in opcodes/deadline.k:78. No defining rule: its value is fixed-but-unknown,
  // constrained only by spec premises. The 0x2d rule below does NOT branch on this symbol
  // directly — it appears only conceptually inside `#sequentialWhitelistJumps/Reverts` — but
  // the declaration lets a spec reason about the timestamp when needed.
  syntax Int ::= #blockTimestamp () [function, no-evaluators]

  // True iff (TAKER modInt 2^80) matches some packed entry in ARGS[2:]. The result of the
  // 0x2c while loop, abstracted. The byte-level list parsing (`args.slice(2)`,
  // `list.parseWhitelistCoequalIx(i)`, the `i--` iteration) is NOT modelled; this predicate
  // encapsulates its outcome. A spec premise `#coequalWhitelistContains(ARGS, TAKER modInt 2^80)`
  // selects the JUMP arm; its negation selects the FALL-THROUGH arm.
  syntax Bool ::= #coequalWhitelistContains ( Bytes , Int ) [function, no-evaluators]

  // True iff the 0x2d loop matches (TAKER modInt 2^80) at the entry unlocked by
  // `block.timestamp`. Conceptually:
  //   block.timestamp >= start
  //   && exists k: start + Σ_{j<k} duration[j] <= block.timestamp
  //                       < start + Σ_{j<=k} duration[j]
  //              && sender == allowedTaker[k]
  // The start-vs-timestamp comparison, the duration arithmetic, the in-window revert, and the
  // byte-level list parsing are ALL INSIDE this predicate — not modelled directly. A spec
  // premise `#sequentialWhitelistJumps(ARGS, TAKER modInt 2^80)` selects the JUMP arm.
  syntax Bool ::= #sequentialWhitelistJumps ( Bytes , Int ) [function, no-evaluators]

  // True iff the 0x2d loop hits the in-window revert — either `block.timestamp < start`, OR
  // at some entry whose address != (TAKER modInt 2^80) we have `timeLeft < duration` and the
  // require fires. Same encapsulation boundary as #sequentialWhitelistJumps. A spec premise
  // `#sequentialWhitelistReverts(ARGS, TAKER modInt 2^80)` selects the REVERT arm.
  //
  // MUTUAL EXCLUSIVITY: by Solidity control flow #sequentialWhitelistJumps and
  // #sequentialWhitelistReverts can never both hold (a JUMP returns before any REVERT can
  // fire, and a REVERT aborts before any later JUMP can match). This fact is NOT enforced by
  // K — the two predicates are independent uninterpreted symbols. A spec that selects one arm
  // must trust this exclusivity itself; see whitelists.md "Fidelity gaps".
  syntax Bool ::= #sequentialWhitelistReverts ( Bytes , Int ) [function, no-evaluators]

  // ------------------------------------------------------------
  // 0x2c WhitelistCoequal — args = 2 bytes pc + N*10 bytes packed addresses.
  // ------------------------------------------------------------

  // Canonical-pitch args, JUMP arm. The taker's low 80 bits are in the list: the loop
  // matches, `ctx.vm.nextPC = args.parseWhitelistCoequalPC()` (= uint16 of ARGS[0:2]), and
  // the function returns. The decode-advanced <pc> is OVERWRITTEN, mirroring Jump
  // (opcodes/jump.k). The `Running` side condition guards against firing after a prior
  // Revert, matching the loop rule's own guard (swapvm.md:103) and the analogous guard on
  // every other opcode rule.
  rule <k> #exec ( 44 , ARGS ) => .K ... </k>
       <pc> _ => Bytes2Int(substrBytes(ARGS, 0, 2), BE, Unsigned) </pc>
       <query> ... <taker> TAKER </taker> ... </query>
       <status> Running </status>
    requires lengthBytes(ARGS) >=Int 2
     andBool (lengthBytes(ARGS) -Int 2) modInt 10 ==Int 0
     andBool #coequalWhitelistContains(ARGS, TAKER modInt (2 ^Int 80))

  // Canonical-pitch args, FALL-THROUGH arm. The taker's low 80 bits are NOT in the list:
  // the loop exits without matching, the function returns normally, and execution continues
  // at the decode-advanced <pc>. The opcode is a no-op at the register level on this arm —
  // reads only <taker>, writes no register, no `setNextPC`. Like Salt, Deadline, Gte, and
  // 0x2b on their PASS arms, this opcode is NOT a halt here: an arbitrary symbolic tail in
  // the program WILL be decoded after the Whitelist falls through.
  rule <k> #exec ( 44 , ARGS ) => .K ... </k>
       <query> ... <taker> TAKER </taker> ... </query>
       <status> Running </status>
    requires lengthBytes(ARGS) >=Int 2
     andBool (lengthBytes(ARGS) -Int 2) modInt 10 ==Int 0
     andBool notBool #coequalWhitelistContains(ARGS, TAKER modInt (2 ^Int 80))

  // Non-canonical args: Solidity silently reads a different list than the maker encoded
  // (right-pad on short args; ignored trailing partial on off-pitch args) without reverting,
  // which is the same pad-and-truncate soundness hazard documented at swapvm.md:301-324.
  // Revert loudly here so a proof cannot silently succeed on an unmodelled length. Mirrors
  // opcodes 0x23 / 0x90 in swapvm.md:319-324 and the twins throughout the sibling opcode
  // files.
  rule <k> #exec ( 44 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
       <status> Running </status>
    requires lengthBytes(ARGS) <Int 2 orBool (lengthBytes(ARGS) -Int 2) modInt 10 =/=Int 0

  // ------------------------------------------------------------
  // 0x2d WhitelistSequential — args = 2 bytes pc + 5 bytes start + N*(2 dur + 10 addr).
  // ------------------------------------------------------------

  // Canonical-pitch args, JUMP arm. The taker matches the entry unlocked at the current
  // block.timestamp. `ctx.vm.nextPC = pc` and the function returns. The decode-advanced <pc>
  // is OVERWRITTEN, mirroring Jump and the 0x2c JUMP arm above.
  rule <k> #exec ( 45 , ARGS ) => .K ... </k>
       <pc> _ => Bytes2Int(substrBytes(ARGS, 0, 2), BE, Unsigned) </pc>
       <query> ... <taker> TAKER </taker> ... </query>
       <status> Running </status>
    requires lengthBytes(ARGS) >=Int 7
     andBool (lengthBytes(ARGS) -Int 7) modInt 12 ==Int 0
     andBool #sequentialWhitelistJumps(ARGS, TAKER modInt (2 ^Int 80))

  // Canonical-pitch args, REVERT arm. Either `block.timestamp < start` OR the loop hit an
  // entry whose address != taker but whose duration has not yet elapsed (`timeLeft <
  // duration`). The Solidity revert is `WhitelistAllowedTimeViolation()` (Whitelist.sol:101,
  // 147, 163). `#revert(MSG) ~> _ => .K` (swapvm.md:154-156) clears the continuation.
  rule <k> #exec ( 45 , ARGS ) => #revert("WhitelistAllowedTimeViolation") ... </k>
       <query> ... <taker> TAKER </taker> ... </query>
       <status> Running </status>
    requires lengthBytes(ARGS) >=Int 7
     andBool (lengthBytes(ARGS) -Int 7) modInt 12 ==Int 0
     andBool #sequentialWhitelistReverts(ARGS, TAKER modInt (2 ^Int 80))

  // Canonical-pitch args, FALL-THROUGH arm. Neither JUMP nor REVERT: the loop iterates past
  // every entry without matching the taker, and `timeLeft >= duration` for every entry, so
  // every window has expired and execution continues normally at the decode-advanced <pc>.
  // Same no-halt posture as the 0x2c FALL-THROUGH arm.
  rule <k> #exec ( 45 , ARGS ) => .K ... </k>
       <query> ... <taker> TAKER </taker> ... </query>
       <status> Running </status>
    requires lengthBytes(ARGS) >=Int 7
     andBool (lengthBytes(ARGS) -Int 7) modInt 12 ==Int 0
     andBool notBool #sequentialWhitelistJumps(ARGS, TAKER modInt (2 ^Int 80))
     andBool notBool #sequentialWhitelistReverts(ARGS, TAKER modInt (2 ^Int 80))

  // Non-canonical args: same pad-and-truncate hazard as 0x2c. Revert loudly.
  rule <k> #exec ( 45 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
       <status> Running </status>
    requires lengthBytes(ARGS) <Int 7 orBool (lengthBytes(ARGS) -Int 7) modInt 12 =/=Int 0
endmodule

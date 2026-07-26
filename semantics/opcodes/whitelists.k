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
// silently ignores a trailing partial entry. An OFF-PITCH args (e.g. 13 bytes for 0x2c,
// which `length / 10` truncates to one 10-byte entry plus 3 ignored bytes) reads a list
// whose trailing partial is silently dropped — it does NOT revert on chain. If the model
// only handled the canonical-pitch case and let the rest fall through to the `[owise]`
// no-op (swapvm.md:349-351), every such Whitelist would be SILENTLY DELETED from the model
// while staying live in production — the worst failure direction (sound but wrong).
//
// GAS TRAP BELOW THE HEADER — the other regime (NOT "right-zero-padded"). An earlier version
// of this comment claimed short args are "right-zero-padded by Solidity's calldata
// semantics". That is FALSE below the header length and has been corrected. `Whitelist.sol`
// uses an unchecked `Calldata.slice` overload whose length argument is computed from
// `args.length` with no floor: for args SHORTER than the fixed header, the slice length
// underflows and the loop strides backward through ~2^255 empty iterations until the taker's
// whole gas budget is consumed — the contract does NOT terminate and does NOT revert with a
// named error. Boundaries reproduced in `test/kontrol/analysis/repro/WhitelistGasTrapRepro.t.sol`:
// 0x2c traps at `args.length <= 1`, 0x2d at `<= 6`; everything at or above the header
// terminates. (Per WhitelistGasTrapRepro.t.sol:247-253 the backward scan can additionally
// produce a SPURIOUS whitelist match and jump to `args[0:2]`.) The model's
// `UNMODELLED-ARGS-LENGTH` revert for sub-header lengths is therefore CONSERVATIVE — a proof
// fails rather than succeeding on a fiction — but it does NOT match the chain's out-of-gas.
// The recursive rework here is sound regardless: `#coequalContains` / `#seqOutcome` strictly
// shrink the list each step and are only invoked under a pitch-multiple guard, so they
// terminate unconditionally; on a malformed list they are STUCK, never divergent. That is
// the honest posture for the K side. The gas trap itself is a CONTRACT BUG, not something
// the K semantics should reproduce.
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
//
// 0x2d GUARD-ORDER DIVERGENCE (review §7; same class as the pc 88-vs-91 drift,
// swapvm.md:107-116). The K rules below check `lengthBytes(ARGS)` FIRST and revert
// `UNMODELLED-ARGS-LENGTH` for a non-canonical length. Solidity (`Whitelist.sol:141-166`)
// checks the time window FIRST: it reads `(start, pc)` from `args[0:7]` (:143), then — inside
// the `unchecked` block — `if (timeLeft < start) revert WhitelistAllowedTimeViolation()` (:147)
// BEFORE the list slice `args.slice(7)` at :150. There is NO args-length check in Solidity at
// all. So on the INTERSECTION — a non-canonical `args.length` AND `timeLeft < start` — both
// engines revert but with DIFFERENT reasons: Solidity gives `WhitelistAllowedTimeViolation`,
// K gives `UNMODELLED-ARGS-LENGTH`. Distinguishing input: `argsLen = 2` (below the 7-byte
// header) with a `start` read past `block.timestamp`. Both revert; only the reason differs,
// so a theorem phrased over the reason on this intersection is wrong, while one phrased over
// "reverts" holds. Same posture as the other reason-only divergences recorded in this tree.

module SWAPVM-WHITELISTS
  imports SWAPVM
  imports SWAPVM-DEADLINE       // for #blockTimestamp() — declared once in deadline.k to avoid parsing ambiguity

  // `#blockTimestamp()` is declared in opcodes/deadline.k:79 and brought into scope here via
  // `imports SWAPVM-DEADLINE` above. Declaring it again in this module caused a parsing
  // ambiguity in the integrated build (K qualified the two declarations as distinct symbols:
  // `#blockTimestamp()_SWAPVM-DEADLINE_Int` vs `..._SWAPVM-WHITELISTS_Int`). The 0x2d rules
  // below branch on this symbol DIRECTLY: the PRE-LOOP REVERT arm tests
  // `#blockTimestamp() <Int start` (mirroring Whitelist.sol:147), and the other three arms pass
  // `#blockTimestamp() -Int start` as the `timeLeft` argument to #seqOutcome. A concrete claim
  // fixes the timestamp via a premise (e.g. `requires #blockTimestamp() ==Int 10`) so the
  // recursion reduces to a concrete outcome.

  // ============================================================
  // BEGIN 0x2c scope (WhitelistCoequal subagent). DO NOT TOUCH the
  // `#sequential*` declarations or any `0x2d` rule below — those are
  // the WhitelistSequential subagent's write scope.
  // ============================================================
  //
  // #coequalContains(LIST, PACKED): does any 10-byte entry in LIST equal PACKED?
  //
  // A RECURSIVE FUNCTION that mirrors the Solidity `while (i-- > 0)` loop in
  // Whitelist.sol:120-128 faithfully. The previous form was an uninterpreted
  // Bool predicate `#coequalWhitelistContains(ARGS, PACKED)` with `[no-evaluators]`,
  // which made every symbolic claim tautological (the spec asserted the
  // predicate and the rule branched on it) and gave zero conformance evidence.
  // Replacing it with a `[function]` (definitional, evaluatable) makes CONCRETE
  // lists reduce to a concrete Bool — so the new concrete claims
  // (proofs/whitelistcoequal-concrete.k) verify the actual byte-level match
  // against Solidity for fixed inputs, exactly as gte-concrete.k verifies the
  // actual `>=Int` comparison. On SYMBOLIC lists the recursion is STUCK (neither
  // rule's `requires` reduces), which is the honest posture: no false symbolic
  // claim, no spurious `#Top`. The old symbolic spec/control pair
  // (whitelistcoequal-spec.k, -control.k) is DELETED in favour of the concrete
  // claims — see whitelists.md "What the K rules do".
  //
  // The recursion is on the LIST TAIL: at each step, compare the first 10 bytes
  // to PACKED and recurse on the rest. This mirrors the Solidity loop direction
  // (which counts `i` DOWN from `list.length / 10`), so the byte-level decision
  // matches on-chain evaluation order. The caller passes the post-header slice
  // `substrBytes(ARGS, 2, lengthBytes(ARGS))` so LIST always has length `N*10`
  // (the canonical-pitch constraint in the 0x2c rules below guarantees this);
  // the function therefore never sees a sub-multiple length and is total on its
  // domain.
  syntax Bool ::= #coequalContains ( Bytes , Int ) [function]

  // Base case: empty list, no entry matches. Mirrors `while (i-- > 0)` exiting
  // immediately when `list.length / 10 == 0`.
  rule #coequalContains(LIST, PACKED) => false
    requires lengthBytes(LIST) ==Int 0

  // Recursive case: at least one 10-byte entry remains. Compare the first
  // entry to PACKED and recurse on the rest. `Bytes2Int(substrBytes(LIST, 0, 10),
  // BE, Unsigned)` mirrors `list.parseWhitelistCoequalIx(i)` (bytes10 → uint80,
  // big-endian, unsigned) and `substrBytes(LIST, 10, lengthBytes(LIST))` is the
  // remaining list passed to the next iteration.
  rule #coequalContains(LIST, PACKED)
    => ( Bytes2Int(substrBytes(LIST, 0, 10), BE, Unsigned) ==Int PACKED )
       orBool #coequalContains(substrBytes(LIST, 10, lengthBytes(LIST)), PACKED)
    requires lengthBytes(LIST) >=Int 10
  // ============================================================
  // END 0x2c scope (declarations)
  // ============================================================

  // ============================================================
  // BEGIN 0x2d scope (WhitelistSequential subagent). The recursive
  // `#seqOutcome` function and outcome constants below model the
  // Solidity `while (i < length)` loop in Whitelist.sol:155-165
  // faithfully. The previous form was two uninterpreted Bool predicates
  // (`#sequentialWhitelistJumps`, `#sequentialWhitelistReverts`) with
  // `[no-evaluators]`, which made every symbolic claim tautological (the
  // spec asserted the predicate and the rule branched on it) and gave
  // zero conformance evidence — AND the actual time-aware loop was not
  // modelled at all. Replacing them with a `[function]` (definitional,
  // evaluatable) makes CONCRETE lists+timestamps reduce to a concrete
  // outcome — so the new concrete claims (proofs/whitelistsequential-
  // concrete.k) verify the actual byte-level + time-arithmetic behaviour
  // against Solidity for fixed inputs, exactly as gte-concrete.k verifies
  // the actual `>=Int` comparison and whitelistcoequal-concrete.k verifies
  // the 0x2c byte-level match. On SYMBOLIC lists the recursion is STUCK
  // (neither rule's `requires` reduces), which is the honest posture: no
  // false symbolic claim, no spurious `#Top`. The old symbolic spec/control
  // pair (whitelistsequential-spec.k, -control.k) is DELETED in favour of
  // the concrete claims — see whitelists.md "What the K rules do".
  // ============================================================

  // Outcome tags for #seqOutcome. Each is a 0-arity [function] that reduces
  // to a literal Int, so the four-arm rule's premise
  // `#seqOutcome(...) ==Int #wlJump()` is decidable after the recursion
  // reduces on concrete input. (CamelCase rather than SCREAMING_SNAKE_CASE because
  // the K default lexer for `#`-prefixed symbols does not accept underscores.)
  syntax Int ::= #wlJump ()        [function]
  syntax Int ::= #wlRevert ()      [function]
  syntax Int ::= #wlFallthrough () [function]
  rule #wlJump()        => 0
  rule #wlRevert()      => 1
  rule #wlFallthrough() => 2

  // #seqOutcome(LIST, TIMELEFT, PACKED): walks the Solidity loop body by body.
  //   LIST     = args.slice(7) — the post-header slice (12-byte entries only).
  //   TIMELEFT = block.timestamp - start (caller preconditions: ts >= start).
  //   PACKED   = TAKER modInt 2^80 — the taker's low 80 bits.
  //
  // Per entry (12 bytes): duration = Bytes2Int(LIST[0:2], BE, Unsigned),
  // allowedTaker = Bytes2Int(LIST[2:12], BE, Unsigned). This mirrors
  // `parseWhitelistSequentialIx` (Whitelist.sol:73-79): `duration := shr(240, word)`
  // is the high 16 bits = first 2 bytes of the entry; `allowedTaker :=
  // and(shr(160, word), 0xffff...ffff)` is bits [160, 256) = the next 10 bytes.
  // Solidity counts entries UP from i=0, matching the head-first recursion here.
  //
  // The recursion mirrors Whitelist.sol:155-165 EXACTLY:
  //   while (i < length) {
  //     (allowedTaker, duration) = list.parseWhitelistSequentialIx(i++);
  //     if (sender == allowedTaker) return JUMP;          // entry matches → JUMP
  //     if (timeLeft < duration)  return REVERT;          // window exclusive → REVERT
  //     timeLeft -= duration;                             // window expired, advance
  //   }
  //   return FALLTHROUGH;                                 // i == length
  //
  // The address-match check happens BEFORE the duration check, faithfully mirroring the
  // Solidity `if (sender == allowedTaker) {...return;}` preceding `if (timeLeft < duration)
  // revert` (Whitelist.sol:158-163). Reordering them would change the outcome when the
  // matching entry is past an expired-but-not-reverted window — a real divergence.
  syntax Int ::= #seqOutcome ( Bytes , Int , Int ) [function]

  // Base case: LIST exhausted (i == length in Solidity). FALL THROUGH — anyone may proceed.
  rule #seqOutcome(LIST, TIMELEFT, PACKED) => #wlFallthrough()
    requires lengthBytes(LIST) ==Int 0

  // Entry matches → JUMP. Mirrors `if (sender == allowedTaker) { ctx.vm.nextPC = pc; return; }`.
  // The address comparison happens BEFORE the duration check, matching Solidity order; the
  // TIMELEFT argument is not consulted here, exactly as in the source.
  rule #seqOutcome(LIST, TIMELEFT, PACKED) => #wlJump()
    requires lengthBytes(LIST) >=Int 12
     andBool Bytes2Int(substrBytes(LIST, 2, 12), BE, Unsigned) ==Int PACKED

  // Entry doesn't match AND window still exclusive → REVERT. Mirrors
  // `if (timeLeft < duration) revert WhitelistAllowedTimeViolation();`.
  rule #seqOutcome(LIST, TIMELEFT, PACKED) => #wlRevert()
    requires lengthBytes(LIST) >=Int 12
     andBool Bytes2Int(substrBytes(LIST, 2, 12), BE, Unsigned) =/=Int PACKED
     andBool TIMELEFT <Int Bytes2Int(substrBytes(LIST, 0, 2), BE, Unsigned)

  // Entry doesn't match AND window expired → advance. Mirrors `timeLeft -= duration;`
  // followed by the next loop iteration. Recurse on the 12-byte tail with the new TIMELEFT.
  rule #seqOutcome(LIST, TIMELEFT, PACKED)
    => #seqOutcome(substrBytes(LIST, 12, lengthBytes(LIST)),
                   TIMELEFT -Int Bytes2Int(substrBytes(LIST, 0, 2), BE, Unsigned),
                   PACKED)
    requires lengthBytes(LIST) >=Int 12
     andBool Bytes2Int(substrBytes(LIST, 2, 12), BE, Unsigned) =/=Int PACKED
     andBool TIMELEFT >=Int Bytes2Int(substrBytes(LIST, 0, 2), BE, Unsigned)
  // ============================================================
  // END 0x2d scope (declarations)
  // ============================================================

  // ------------------------------------------------------------
  // 0x2c WhitelistCoequal — args = 2 bytes pc + N*10 bytes packed addresses.
  // ------------------------------------------------------------
  //
  // BEGIN 0x2c scope (rules). The two canonical-pitch arms below branch on the
  // RECURSIVE `#coequalContains` function (declared above), which faithfully
  // evaluates the Solidity `while (i-- > 0)` loop on the post-header slice
  // `substrBytes(ARGS, 2, lengthBytes(ARGS))`. The previous uninterpreted
  // predicate `#coequalWhitelistContains(ARGS, ...)` made every symbolic claim
  // tautological; this form makes CONCRETE claims (gte-concrete.k shape)
  // genuine conformance evidence — see proofs/whitelistcoequal-concrete.k.

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
     andBool #coequalContains(substrBytes(ARGS, 2, lengthBytes(ARGS)), TAKER modInt (2 ^Int 80))

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
     andBool notBool #coequalContains(substrBytes(ARGS, 2, lengthBytes(ARGS)), TAKER modInt (2 ^Int 80))
  // END 0x2c scope (rules).

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
  //
  // BEGIN 0x2d scope (rules). The four canonical-pitch arms below branch on the
  // RECURSIVE `#seqOutcome` function (declared above), which faithfully
  // evaluates the Solidity `while (i < length)` loop on the post-header slice
  // `substrBytes(ARGS, 7, lengthBytes(ARGS))` with
  // `timeLeft = #blockTimestamp() -Int Bytes2Int(substrBytes(ARGS, 2, 7), BE, Unsigned)`.
  // The previous uninterpreted-predicate form made every symbolic claim
  // tautological; this form makes CONCRETE claims (gte-concrete.k shape)
  // genuine conformance evidence — see proofs/whitelistsequential-concrete.k.
  // A separate top-level arm handles `#blockTimestamp() <Int start` (the
  // pre-loop revert in Whitelist.sol:147) since #seqOutcome assumes ts >= start
  // (its TIMELEFT argument is `ts - start` and must be non-negative).

  // Canonical-pitch args, PRE-LOOP REVERT arm. block.timestamp < start: the very
  // first check in the Solidity body fires (Whitelist.sol:147), before the loop
  // is even entered. Mirrors `if (timeLeft < start) revert ...; timeLeft -= start;`.
  // Note: start is the 5-byte big-endian read at ARGS[2:7] (parseWhitelistSequentialStartPC
  // — Whitelist.sol:63-69: `ts := and(shr(200, word), 0xffffffffff)` is the middle 5 bytes).
  rule <k> #exec ( 45 , ARGS ) => #revert("WhitelistAllowedTimeViolation") ... </k>
       <query> ... <taker> TAKER </taker> ... </query>
       <status> Running </status>
    requires lengthBytes(ARGS) >=Int 7
     andBool (lengthBytes(ARGS) -Int 7) modInt 12 ==Int 0
     andBool #blockTimestamp() <Int Bytes2Int(substrBytes(ARGS, 2, 7), BE, Unsigned)

  // Canonical-pitch args, JUMP arm. ts >= start AND #seqOutcome returns #wlJump: the taker's
  // low 80 bits match an entry reached before timeLeft runs out. `ctx.vm.nextPC = pc` and the
  // function returns. The decode-advanced <pc> is OVERWRITTEN with the uint16 read at
  // ARGS[0:2], mirroring Jump (opcodes/jump.k) and the 0x2c JUMP arm above.
  rule <k> #exec ( 45 , ARGS ) => .K ... </k>
       <pc> _ => Bytes2Int(substrBytes(ARGS, 0, 2), BE, Unsigned) </pc>
       <query> ... <taker> TAKER </taker> ... </query>
       <status> Running </status>
    requires lengthBytes(ARGS) >=Int 7
     andBool (lengthBytes(ARGS) -Int 7) modInt 12 ==Int 0
     andBool #blockTimestamp() >=Int Bytes2Int(substrBytes(ARGS, 2, 7), BE, Unsigned)
     andBool #seqOutcome(substrBytes(ARGS, 7, lengthBytes(ARGS)),
                         #blockTimestamp() -Int Bytes2Int(substrBytes(ARGS, 2, 7), BE, Unsigned),
                         TAKER modInt (2 ^Int 80)) ==Int #wlJump()

  // Canonical-pitch args, IN-WINDOW REVERT arm. ts >= start AND #seqOutcome returns
  // #wlRevert: the loop hit an entry whose address != taker but whose duration has not yet
  // elapsed (`timeLeft < duration`). The Solidity revert is `WhitelistAllowedTimeViolation()`
  // (Whitelist.sol:163). `#revert(MSG) ~> _ => .K` (swapvm.md:154-156) clears the continuation.
  rule <k> #exec ( 45 , ARGS ) => #revert("WhitelistAllowedTimeViolation") ... </k>
       <query> ... <taker> TAKER </taker> ... </query>
       <status> Running </status>
    requires lengthBytes(ARGS) >=Int 7
     andBool (lengthBytes(ARGS) -Int 7) modInt 12 ==Int 0
     andBool #blockTimestamp() >=Int Bytes2Int(substrBytes(ARGS, 2, 7), BE, Unsigned)
     andBool #seqOutcome(substrBytes(ARGS, 7, lengthBytes(ARGS)),
                         #blockTimestamp() -Int Bytes2Int(substrBytes(ARGS, 2, 7), BE, Unsigned),
                         TAKER modInt (2 ^Int 80)) ==Int #wlRevert()

  // Canonical-pitch args, FALL-THROUGH arm. ts >= start AND #seqOutcome returns
  // #wlFallthrough: the loop iterated past every entry without matching the taker, with
  // `timeLeft >= duration` at every entry — every window has expired, so anyone may proceed.
  // Inherits the decode-advanced <pc>; same no-halt posture as the 0x2c FALL-THROUGH arm.
  rule <k> #exec ( 45 , ARGS ) => .K ... </k>
       <query> ... <taker> TAKER </taker> ... </query>
       <status> Running </status>
    requires lengthBytes(ARGS) >=Int 7
     andBool (lengthBytes(ARGS) -Int 7) modInt 12 ==Int 0
     andBool #blockTimestamp() >=Int Bytes2Int(substrBytes(ARGS, 2, 7), BE, Unsigned)
     andBool #seqOutcome(substrBytes(ARGS, 7, lengthBytes(ARGS)),
                         #blockTimestamp() -Int Bytes2Int(substrBytes(ARGS, 2, 7), BE, Unsigned),
                         TAKER modInt (2 ^Int 80)) ==Int #wlFallthrough()

  // Non-canonical args: same pad-and-truncate hazard as 0x2c. Revert loudly.
  rule <k> #exec ( 45 , ARGS ) => #revert("UNMODELLED-ARGS-LENGTH") ... </k>
       <status> Running </status>
    requires lengthBytes(ARGS) <Int 7 orBool (lengthBytes(ARGS) -Int 7) modInt 12 =/=Int 0
endmodule

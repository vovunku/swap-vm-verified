# Subagent protocol

How verification work is delegated. One agent, one file, one handoff.

The coordinator does not write specs or lemmas. It maintains `PROOF-MAP.md`, dispatches
agents, and acts on their handoffs — merging a lemma, recording a closed proof, promoting a
bug in `BUGS.md`, or dispatching follow-up work.

## Rules

**One file per agent.** An agent owns exactly one spec *or* one harness *or* one analysis
document. Two agents never hold the same file. This is what makes the work parallel-safe;
`lemmas.k`, `kontrol.toml` and `foundry.toml` are coordinator-only for the same reason.

**Builds are serialized, proofs are not.** `kontrol build` mutates the single shared K
definition and only the coordinator runs it. Any number of agents may run `kontrol prove`
concurrently against a stable definition, capped at `--workers 3` each.

**A spec edit needs only `forge build`.** Contract bytecode is *not* in the K definition —
`prove.py` reads it from the Foundry artifacts at prove time. So an agent that edits its own
spec can rebuild and prove it itself, in seconds, without disturbing anyone:

    FOUNDRY_PROFILE=kontrol forge build --build-info --extra-output storageLayout \
      evm.bytecode.generatedSources evm.deployedBytecode.generatedSources

`kontrol build` is only needed when `lemmas.k` changes, and remains coordinator-only.

**Every agent ends with a HANDOFF section.** That is the unit of work the coordinator acts
on. An agent that made no progress still writes one, saying what blocked it — a blocked
handoff naming the obstacle is worth more than a plausible-sounding non-result.

---

## Template

Copy, fill the four bracketed fields, delete the sections that do not apply.

````
[TASK — one sentence: which file, and whether the goal is writing a spec or closing proofs.]

## ENVIRONMENT — read this first, it is the most common cause of a wasted run

Kontrol is NOT on the host. The toolchain and the built K definition live inside a running
Docker container named `kontrol`, in a COPY of the repo at `/home/user/swap-vm-verified/`.
The host has no `kontrol` binary and no `out/kompiled`. Every Kontrol command takes this
wrapper:

    docker exec -u user -w /home/user/swap-vm-verified -e HOME=/home/user \
      -e FOUNDRY_PROFILE=kontrol \
      -e PATH=/home/user/.local/bin:/home/user/.foundry/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      kontrol bash -c "kontrol <subcommand> ... 2>&1 | tail -20"

Because it is a COPY and not a bind mount, host-side edits are invisible to the prover until
the coordinator rebuilds. To get a scratch lemma file in:

    docker cp <file>.k kontrol:/home/user/swap-vm-verified/<file>.k
    docker exec kontrol bash -c "chown user:user /home/user/swap-vm-verified/<file>.k"

Foundry on the host is at `~/.foundry/bin/forge`, not on `PATH`.

## HARD CONSTRAINTS

- **NEVER run `kontrol build` or `--rekompile`.** It mutates the shared definition and would
  clobber every other agent. Only the coordinator builds.
- `kontrol prove --workers 3` maximum. Several agents share 16 cores.
- Do NOT edit `lemmas.k`, `kontrol.toml`, `foundry.toml`, or any file outside the one you own.
- Do NOT run git commands.
- Your file: **[FILE]**. Do not create or edit others.

## HAND-IN — read in this order

1. `test/kontrol/analysis/PROOF-MAP.md` — current status of every property.
2. `test/kontrol/analysis/FINDINGS.md` — established semantics. **Do not re-derive what is
   already there, and do not contradict it without evidence.** It records several properties
   that are FALSE and must not be written, and several claims where the code contradicts its
   own documentation.
3. `test/kontrol/README.md` — workflow and the Traps section.
4. `lemmas.k` — the shared library. Read the section comments; they record which term shapes
   the compiler actually produces.
5. [ANY FILE-SPECIFIC HAND-IN: prior handoffs, the instruction source, sibling specs for style.]

## METHOD — the rules that were learned the hard way

**Never write a lemma against the Solidity source.** Derive the term shape from what KEVM
actually produces. Confirmed examples: `a - 1` compiles to `add(a, not(0))` so KEVM sees
`chop(A +Int maxUInt256)`, never a subtraction; `a > 0` compiles to `ISZERO; ISZERO` so KEVM
sees `bool2Word(notBool (A ==Int 0))`, never `bool2Word(0 <Int A)`; `mul512`'s branch is
`eq(_2, _1)` and the term `high == 0` never appears at all. Lemmas written against the
predicted shape silently never fire.

**Dump the node before writing anything.** `kontrol show --node <id> '<Test>'` and read the
real term. Then write the rule, test it with the fast loop, iterate.

**The fast lemma loop.** `--lemmas <file>.k:<MODULE>` loads rules at prove time with NO
rebuild — seconds instead of minutes. The file takes NO `requires "kontrol.md"` line and the
module imports `KONTROL-MAIN` (not `KONTROL-BASE` as `lemmas.k` does):

    module MY_SCRATCH
        imports KONTROL-MAIN
        rule [unique-label]: <lhs> => <rhs> requires <cond> [simplification]
    endmodule

Name your file uniquely (`scratch-<instruction>.k`) so concurrent agents do not collide.

**Prefer `try`/`catch` to an assumption containing a division.** A symbolic `DIV` in the path
condition stalls the prover. `try harness.f(...) returns (...) { assert } catch {}` states
the same intent, quantifies over strictly MORE inputs, and proves. See README.

**Do not weaken a spec to make it pass.** Narrowing a domain buys a green checkmark by
shrinking the theorem. If you must narrow, say so in a code comment AND in the handoff.
Prefer narrow parameter *types* (`uint120`) over `vm.assume` bounds — Kontrol constrains an
ABI-decoded `uintN` directly, so it costs neither a rejected-sample budget nor a path
constraint.

**Prove the cheapest property first** to validate the harness shape in a minute rather than
discovering a problem an hour into the hardest goal.

## VACUITY — a spec that cannot fail is worse than no spec

It reads as evidence. Two live traps:

- **Constructor-set state reads as ZERO under Kontrol.** `run-constructor = false`, so the
  prover loads `deployedBytecode` and never runs the constructor. An `immutable`, or any
  state variable with an initialiser, is zero. `setUp()` *does* run, so a harness assigned
  there is fine. The dangerous half is asymmetric: a positive assertion fails loudly, but a
  negative one (`assertTrue(x != SEL)`) is trivially true when `SEL == 0` and reports PASSED
  having proved nothing. Use `constant`, or an `internal pure` accessor.
- **Upper bounds alone do not pin an implementation.** A quote function returning `0`
  unconditionally satisfies every "never exceeds" property. Pair them with a two-sided
  exactness property and at least one fully concrete witness.

If you write properties, mutation-test them: break the implementation in a scratch copy,
confirm your assertions fail, restore it and verify with `cmp`. Report which mutants each
property killed. A property that killed nothing is not yet a property.

## HANDOFF — required, and it is the deliverable

End your report with a section titled `HANDOFF` containing:

- **Status table** — every property in your file with its final state: PASSED, FAILED,
  stalled-at-N-nodes, not-attempted, or excluded-with-reason.
- **Per stalled proof** — the node id, the ACTUAL blocking term you dumped, and what would
  close it. Not a guess at what might be wrong.
- **Lemmas that worked** — exact K text, ready to merge. The highest-value part of the report.
- **Domains narrowed** — each one, and why.
- **New findings** — any bug or unguarded path not already in `BUGS.md`, with its evidence
  level (CONFIRMED / SOURCE / MODELLED — see `BUGS.md`) and a witness if you have one.
- **Corrections** — anything in the hand-in you found to be wrong. These have repeatedly been
  the most valuable output; say so plainly rather than working around it silently.
- **What you would do next**, if you had more time.
````

---

## Coordinator actions on a handoff

| Handoff contains | Action |
|---|---|
| A proof closed | Update `PROOF-MAP.md`. |
| A working lemma | Merge into `lemmas.k`, rebuild centrally, verify the label lands in `out/kompiled/definition.kore`, re-dispatch the blocked proofs. |
| A spec edit | Rebuild centrally, then dispatch a proving agent for that file. |
| A new bug | Add to `BUGS.md` at the evidence level the agent justified. Promote to CONFIRMED only on an executed witness. |
| A correction to `FINDINGS.md` | Amend it. Wrong shared knowledge propagates to every later agent. |
| A blocked run | Fix the obstacle — usually a briefing gap — and re-dispatch with the correction. |
| A vacuity risk | Record it, and treat every affected result as unproven until re-run. |

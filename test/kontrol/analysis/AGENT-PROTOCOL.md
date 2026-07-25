# Subagent protocol

How verification work is delegated. One agent, one file, one handoff.

The coordinator does not write specs or lemmas. It maintains `PROOF-MAP.md`, dispatches
agents, and acts on their handoffs — merging a lemma, recording a closed proof, promoting a
bug in `BUGS.md`, or dispatching follow-up work.

## Rules

**Reaping orphans: use the parent-liveness test, NOT `pkill`.** A `kore-rpc-booster` is always
a direct child of the `kontrol` process using it, so `PPid == 1` means its client is gone.
`pkill -9 -f kore-rpc-booster` destroys every agent's in-flight work; this does not:

    for pid in $(pgrep -f kore-rpc-booster); do
      [ "$(awk '/^PPid:/{print $2}' /proc/$pid/status)" = "1" ] && kill -9 "$pid"
    done

The leak is ongoing, not fixed: a measurement found 15 orphans burning 407% CPU and 14.5 GB,
and six more accumulated within an hour. Reap before trusting any timing.


**One file per agent.** An agent owns exactly one spec *or* one harness *or* one analysis
document. Two agents never hold the same file. This is what makes the work parallel-safe;
`lemmas.k`, `kontrol.toml` and `foundry.toml` are coordinator-only for the same reason.

> **The coordinator has broken this rule three times** — `PiecewiseLinearScale`, `PowerSpec`,
> and `XYCConcentrate`. Each time, both agents discovered the collision only after they had
> been proving into the same directories for a while, and roughly 20 minutes per side went to
> detecting and working around it. A second agent on a file is worse than no agent: they race
> the same proof store and one will kill the other's run.
>
> Intent is not the failure mode here — *tracking* is. The dispatcher believes it knows which
> agents are live and is wrong, usually because an agent from an earlier subsession is still
> running. So the check must be mechanical, and it must look at the machine rather than at
> memory. **Before dispatching onto a spec, run this and confirm the spec name is absent:**
>
>     docker exec kontrol ps -eo pid,ppid,etime,args --no-headers \
>       | grep -E 'kontrol prove|\.sh$' | grep -v grep
>
> This catches the case a live-agent list cannot: a detached `nohup` chain whose agent session
> has already ended, which keeps proving for hours with no agent attached to it. The
> `XYCConcentrate` collision was exactly that shape.

**Every agent writes lemmas, into its OWN file.** Proving is not the only deliverable; a
lemma is worth more than a proof, because it transfers. Each agent owns
`test/kontrol/lemmas/scratch-<Instruction>.k` and writes every rule it discovers there. Never
edit `lemmas.k` — that is the shared library and only the coordinator merges into it. Two
agents writing rules at the same time cannot collide, because they are writing to different
files; integration is a coordinator step that happens later, on evidence.

Module names must be unique too, or two `--lemmas` loads in the same container clash:

    module SCRATCH-PEGGEDSWAP
        imports KONTROL-MAIN
        rule [pegged-unique-label]: <lhs> => <rhs> requires <cond> [simplification]
    endmodule

**A rule is only reportable if you saw it FIRE.** "I added the rule and the proof passed" is
not evidence — the proof may have passed for another reason, and a rule written against a
predicted term shape silently never matches. Establish firing one of two ways: node count or
runtime changes materially with the rule and not without it, or the label appears under
`APPLIED` in a `--haskell-log-dir` run. Report which method you used. Rules banked without
this have already turned out to be inert.

**`--lemmas` cannot test every rule.** pyk accepts six rule attributes and hard-errors on
`preserves-definedness`, so any rule whose LHS contains a partial symbol (`/Int`, `%Int`,
`modInt`) cannot go through the fast loop at all. Do not conclude such a rule is useless —
put it in your scratch file, mark it `NEEDS-REBUILD`, and say so in the handoff. The
coordinator tests it centrally. `mul512-high-zero` sat dead in `lemmas.k` for exactly this
reason: it was missing `preserves-definedness`, so the Booster discarded it *before matching*.

**Builds are serialized, proofs are not.** `kontrol build` mutates the single shared K
definition and only the coordinator runs it. Any number of agents may run `kontrol prove`
concurrently against a stable definition, capped at `--workers 3` each.

**A spec edit needs only `forge build`.** Contract bytecode is *not* in the K definition —
`prove.py` reads it from the Foundry artifacts at prove time. So an agent that edits its own
spec can rebuild and prove it itself, in seconds, without disturbing anyone:

    FOUNDRY_PROFILE=kontrol forge build --build-info --extra-output storageLayout \
      evm.bytecode.generatedSources evm.deployedBytecode.generatedSources

`kontrol build` is only needed when `lemmas.k` changes, and remains coordinator-only.

**If a proof will not progress, try `--config-profile inspect` before blaming a lemma.** The
default profile's settings were measured on one long-straight-edged property and do NOT
generalise: on a branchy instruction body a node that would not expand at all under the
default expanded in three minutes under `inspect`. This is the first diagnostic step.

**Do not run `--haskell-log-entries DebugApplyEquation,DebugTerm` while other agents work.**
One such run held 47-52 GB across two boosters, drove the box to load 34 with swap exhausted,
and got its sibling OOM-killed. Take the machine alone for it, or don't run it.

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

Your scratch file is `test/kontrol/lemmas/scratch-<Instruction>.k` and it is yours alone —
see the lemma-ownership rule above. Copy it into the container with `docker cp`; the prover
reads the container's copy, not the host's.

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
  stalled-at-N-nodes, not-attempted, or excluded-with-reason. Derive it from the proof store,
  not from `PROOF-MAP.md` — the map has been found to undercount by 10 on a single spec, and
  `kontrol list` costs 2-4 minutes and ~2.6 GB. A leaf is closed iff it is target, terminal,
  covered, vacuous or bounded; reading `proof.json` + `kcfg/kcfg.json` gives the same verdicts
  in under a second.
- **Per stalled proof** — the node id, the ACTUAL blocking term you dumped, and what would
  close it. Not a guess at what might be wrong.
- **Lemmas** — the full contents of your `scratch-<Instruction>.k`, ready to merge. This is
  the highest-value part of the report, and it is expected even if no proof closed. For each
  rule give: the dumped term it was written against, the evidence that it FIRED, and whether
  it is `NEEDS-REBUILD` (contains a partial symbol, so `--lemmas` could not test it).
  Rules you tried that did NOT fire are also worth reporting, with the shape you expected
  versus the shape KEVM actually produced — that comparison is what stops the next agent
  repeating the attempt.
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
| A scratch lemma file | Review each rule for firing evidence. Merge the ones that fired into `lemmas.k` under the right section, rebuild centrally, verify each label lands in `out/kompiled/definition.kore`, re-dispatch the blocked proofs. Keep rules that fired but are not yet needed — they cost nothing and transfer. |
| A `NEEDS-REBUILD` rule | The agent could not test it (`--lemmas` rejects `preserves-definedness`). Merge it *with* that attribute and A/B it centrally; do not bank it as working on the agent's word. |
| A spec edit | Rebuild centrally, then dispatch a proving agent for that file. |
| A new bug | Add to `BUGS.md` at the evidence level the agent justified. Promote to CONFIRMED only on an executed witness. |
| A correction to `FINDINGS.md` | Amend it. Wrong shared knowledge propagates to every later agent. |
| A blocked run | Fix the obstacle — usually a briefing gap — and re-dispatch with the correction. |
| A vacuity risk | Record it, and treat every affected result as unproven until re-run. |

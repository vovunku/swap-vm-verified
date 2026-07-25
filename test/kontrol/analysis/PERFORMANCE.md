# Making Kontrol proofs faster

A working reference for this repository, written against the installed toolchain rather than
against the documentation. Where source and documentation disagree, the disagreement is
called out explicitly and **source wins** — several published defaults are simply wrong for
the build we are running.

**Environment this was written against.** Container `kontrol`, image
`runtimeverificationinc/kontrol:ubuntu-jammy-1.0.255`; `kontrol` 1.0.255, `kframework`
7.1.337, `kevm_pyk` 1.0.921; 16 cores, 125 GB RAM, `pids.max` 154371. Kontrol 1.0.255 is the
current upstream `master` HEAD, so there is no newer release to move to. Everything below
runs inside the container:

```
docker exec -u user -w /home/user/swap-vm-verified -e HOME=/home/user \
  -e FOUNDRY_PROFILE=kontrol \
  -e PATH=/home/user/.local/bin:/home/user/.foundry/bin:/usr/bin:/bin \
  kontrol bash -c "<command>"
```

Commands below are given as the inner `<command>`.

Source paths are absolute inside the container and are shortened as:

* `$K = /home/user/.local/lib/python3.10/site-packages`
* so `$K/kontrol/prove.py`, `$K/pyk/proof/reachability.py`, and so on.

---

## Contents

1. [The cost model — where the time actually goes](#1-the-cost-model)
2. [Diagnosis before tuning](#2-diagnosis-before-tuning)
3. [Every performance-relevant flag, with source-verified defaults](#3-every-performance-relevant-flag)
4. [`--cse` in depth, and the `bytes calldata` bug](#4---cse-in-depth)
5. [Booster vs plain Haskell backend](#5-booster-vs-plain-haskell-backend)
6. [Path explosion — the four blockers we actually have](#6-path-explosion)
7. [Concurrency and memory](#7-concurrency-and-memory)
8. [Caching and incrementality](#8-caching-and-incrementality)
9. [What RV recommends that we are not doing](#9-what-rv-recommends-that-we-are-not-doing)
10. [Measurements on this machine](#10-measurements-on-this-machine)
11. [HANDOFF](#handoff)

---

## 1. The cost model

Everything else follows from this. A Kontrol proof is a Python loop (`APRProver.advance_proof`
/ `parallel_advance_proof`) driving a separate `kore-rpc-booster` process over JSON-RPC. One
iteration of the loop is:

1. **Optionally** an `implies` request (subsumption check against the target).
2. One `execute` request carrying the *entire* KEVM configuration as Kore JSON, and getting
   the entire resulting configuration back.
3. A `write_proof_data()` to disk.

Four consequences that matter more than any flag:

**(a) The `implies` check is usually skipped.** `$K/pyk/proof/reachability.py:861`:

```python
# Subsumption is checked if and only if the target node
# and the current node are either both terminal or both not terminal
if is_terminal == target_is_terminal:
```

Kontrol's target K cell is `#halt ~> CONTINUATION` (`$K/kontrol/prove.py:1387`), which
`KEVMSemantics.is_terminal` classifies as terminal (`$K/kevm_pyk/kevm.py:97-111`). So mid-execution
frontier nodes are *not* terminal, `is_terminal != target_is_terminal`, and no `implies` RPC
is issued. **This means `--fast-check-subsumption` has almost nothing to save on our proofs**,
and it also means the per-iteration cost is dominated by `execute`, not by the SMT solver
being asked "are we done yet".

**(b) The configuration is huge, and it is serialized on every round trip.** Measured: a
single node of `PeggedSwapSpec.test_bothBalancesZeroGuardFiresWhenBothZero(...):1` occupies
**~250 KB** as JSON on disk (`out/proofs/<id>/kcfg/nodes/1.json` is 254,802 bytes); the
simpler `XYCSwapSpec` nodes are 130–145 KB. That is what crosses the RPC boundary in each
direction, gets parsed, gets simplified post-execution, and gets re-serialized.

**Therefore: the number of `execute` round trips is a first-order cost driver, and every
`--break-on-*` flag directly multiplies it.** Cut-point rules make the backend *return early*.
`--break-on-basic-blocks` turns "one `execute` covering 1200 EVM steps" into "roughly one
`execute` per basic block", i.e. hundreds of round trips over the same ground.

**(c) `--optimize-kcfg` then throws the resulting nodes away.** `$K/pyk/kcfg/kcfg.py:589-601`:

```python
case Step(cterm, depth, next_node_logs, rule_labels, _):
    node_id = node.id
    next_node = self.create_node(cterm)
    # Optimization for steps consists of on-the-fly merging of consecutive edges and can
    # be performed only if the current node has a single predecessor connected by an Edge
    if (
        optimize_kcfg
        and (len(predecessors := self.predecessors(target_id=node.id)) == 1)
        and isinstance(in_edge := predecessors[0], KCFG.Edge)
    ):
        # The existing edge is removed and the step parameters are updated accordingly
        self.remove_edge(in_edge.source.id, node.id)
        node_id = in_edge.source.id
        depth += in_edge.depth
        ...
        self.remove_node(node.id)
```

Our `kontrol.toml` sets `break-on-basic-blocks = true` *and* `optimize-kcfg = true`. The
comment in that file says the break flags exist so that "`kontrol list` node counts become a
live progress signal" and "a crash costs one small node". **Neither is achieved.** Evidence
from the current proof store:

| proof | wall | nodes | edges (source → target, depth) |
|---|---|---|---|
| `PiecewiseLinearScaleSpec.test_value_scaleNeverExpands(uint256,uint24):0` | 2219 s | 4 | `1→12 d=421`, `12→38 d=1207` |
| `XYCSwapSpec.test_exactIn_constantProductNeverDecreases(...):0` | 598 s | 12 | last edge `44→151 d=3319` |
| `XYCSwapSpec.test_exactOut_roundsInFavourOfMaker(...):2` | — | 16 | last edge `64→161 d=2911` |

Edges of depth 1207 and 3319 exist *despite* `break-on-basic-blocks` and `max-depth = 2000`,
because `optimize-kcfg` re-merged every basic block back into one edge as it went. So we paid
~1200 round trips to build the first proof's second edge and then deleted all ~1200
intermediate nodes. Checkpoint granularity is exactly what it would have been with the break
flags off; only the round-trip count differs.

(One nuance in `optimize-kcfg`'s favour: crash *recovery* is not harmed, because the newest
node is always kept and written to disk. What is lost is intermediate history and the
progress signal — and what is paid for is the round trips.)

**(d) Rewrite-trace logging is on by default, and it is not cheap.** `$K/kontrol/options.py:78`,
`RpcOptions.default()` sets `'log_succ_rewrites': True`. That makes every `execute` request
carry `log-successful-rewrites: true` (`$K/pyk/kore/rpc.py:1128`), so the backend accumulates
and returns a log entry for **every rewrite rule application** in the step, and `APRProof`
stores them all in `proof.json` under `logs`.

Measured on the A/B of §10.2 — the *same proof*, the *same final KCFG*, the two arms only
differing in the break flags:

| | arm A (break-on-basic-blocks) | arm B |
|---|---|---|
| `proof.json` | **22.5 MB** | 0.91 MB |
| rewrite-log entries in it | **150,180** across 87 nodes | 6,096 across 2 nodes |
| `kcfg/nodes/` (4 surviving nodes) | 484 KB | 484 KB |

And with `maintenance-rate = 1` (the default, and ours) that `proof.json` is **rewritten from
scratch on every proof iteration**. Arm A did ~89 iterations against a file growing towards
22.5 MB — on the order of a gigabyte of disk writes for one 4-node proof, all of it discarded
data. `--optimize-performance` turns rewrite logging off first thing and raises
`maintenance-rate` to 64; we do neither.

**Summary of the model.** Time ≈ (number of `execute` round trips) × (serialize + rewrite +
post-exec simplify + deserialize + log payload) + (SMT time inside branch decisions) + (path
count × everything). Flags can move the first term by a large constant factor. Only
specification and lemma work moves the third.

---

## 2. Diagnosis before tuning

You cannot tell SMT-bound from rewriting-bound from path-explosion-bound by staring at
`kontrol list`. Here is how to tell, cheapest first.

### 2.1 Path-explosion-bound — read the KCFG shape

Free, no re-running. The proof store is plain JSON:

```
python3 - <<'EOF'
import json, os
d = 'out/proofs/test%kontrol%PeggedSwapSpec.test_bothBalancesZeroGuardFiresWhenBothZero(uint256,uint256,uint256,uint256,uint256,uint256):1'
k = json.load(open(os.path.join(d, 'kcfg', 'kcfg.json')))
print('nodes', len(k['nodes']), 'edges', len(k.get('edges', [])),
      'splits', len(k.get('splits', [])), 'covers', len(k.get('covers', [])),
      'vacuous', len(k.get('vacuous', [])), 'stuck', len(k.get('stuck', [])))
for e in k.get('edges', []):
    print('  edge', e['source'], '->', e['target'], 'depth', e['depth'])
EOF
```

Read it like this:

* **many `splits`, short edges** → path-explosion-bound. The PeggedSwap guard proof above has
  **31 splits, 64 edges, 128 nodes** — that is the `Math.sqrt` MSB cascade, and no flag will
  fix it. Go to §6.
* **few nodes, one enormous edge** → rewriting-bound or SMT-bound inside a straight line.
  `test_value_scaleNeverExpands` is 4 nodes / 1628 total steps / 2219 s ≈ 1.4 s per EVM step,
  which is far above the ~0.1 s/step the cheap proofs achieve. Go to §2.3.
* **`vacuous` leaves** → good; those are branches the path condition killed.
* **`stuck` leaves** → the backend could not make progress. Usually a missing lemma or an
  unevaluated function; go to §2.3 and look for `Abort`.

`kontrol show <test> --node <id>` and `kontrol view-kcfg <test>` are the interactive versions.
For a stuck node, `kontrol show <test> --node <id> --minimize` is the standard first move —
it prints the term KEVM actually produced, which is what a new lemma must be written against
(the `ceilDiv` note in `FINDINGS.md` is exactly this workflow).

**A free round-trip counter.** `kcfg.json`'s `next` field is the next node id to be allocated,
and it is **not** decremented when `optimize-kcfg` deletes a node. So `next` minus the id the
proof started from is very close to the number of `execute` calls the proof has made — the
thing §1 says is the dominant cost, readable with no instrumentation and no re-running:

```
python3 -c "import json;k=json.load(open('out/proofs/<id>/kcfg/kcfg.json'));print('allocated', k['next']-1, 'surviving', len(k['nodes']))"
```

A large gap between `allocated` and `surviving` is the signature of the problem in §1(c). In
the A/B of §10.2 the same proof read `allocated 101 / surviving 4` under the current settings
and `allocated 8 / surviving 4` under the proposed ones.

### 2.2 SMT-bound — count Z3 time directly

**The precise instrument is `proxy > timing` in a log bundle (§2.3); read this section for the
zero-setup approximations.**

Every `kore-rpc-booster` spawns exactly one `z3` child. Compare their CPU time:

```
ps -eo pid,ppid,time,rss,comm | grep -E 'kore-rpc|z3'
```

If the `z3` child's cumulative CPU time is a significant fraction of its parent's, the proof
is SMT-bound. On this machine right now the ratio is small — e.g. `z3` at 30 minutes elapsed
holding 38 MB RSS next to a `kore-rpc-booster` holding 2.2 GB — which says our proofs are
**rewriting- and path-bound, not SMT-bound**. That is important: raising `--smt-timeout` will
not help proofs that are not waiting on Z3. (It does help the specific case of a *branch
condition* Z3 cannot decide, which is what stalled the symbolic `DIV`; see §6.1.)

The definitive version is a solver transcript:

```
kontrol prove --match-test '<Test>' --max-iterations 3 \
  --kore-rpc-command 'kore-rpc-booster --solver-transcript /tmp/z3.smt2'
```

`--solver-transcript` is a real `kore-rpc-booster` option (verified from `kore-rpc-booster --help`
in this image). Note `KoreServer.close()` sends `SIGINT` instead of `SIGTERM` when
`--solver-transcript` appears in the command, precisely so the transcript is flushed
(`$K/pyk/kore/rpc.py:1355-1360`).

**`--kore-rpc-command` composition is verified.** `_cli_args()` builds
`<your command words> <definition.kore> --module … --server-port … <smt/log args>`, i.e. your
extra flags land *before* the positional definition file. `kore-rpc-booster` accepts that
ordering — checked directly:

```
$ kore-rpc-booster --fallback-on Aborted --no-post-exec-simplify --interim-simplification 50 \
    /nonexistent/definition.kore --module KONTROL-MAIN --server-port 0 \
    --llvm-backend-library /nonexistent/interpreter.so
[proxy] Loading definition from /nonexistent/definition.kore, main module "KONTROL-MAIN"
user error (dlopen: /nonexistent/interpreter.so: cannot open shared object file: ...)

$ kore-rpc-booster --bogus-flag /nonexistent/definition.kore --module M --server-port 0
Invalid option `--bogus-flag'
```

It got past option parsing and failed only on the missing files, and it rejects unknown flags
loudly — so a typo will not be silently ignored. You do **not** need to repeat
`--llvm-backend-library`: `BoosterServer._extra_args()` appends it for you as long as the
booster path is in use. So `--kore-rpc-command 'kore-rpc-booster <extra flags>'` is a safe way
to reach every booster option Kontrol does not expose.

### 2.3 Rewriting-bound — the Haskell log bundles

This build has two flags that are not in RV's published documentation and that you should use:

```
--haskell-log-dir DIR         # the ON switch
--haskell-log-entries A,B,C   # which entry families to request
```

Semantics, from `$K/pyk/cterm/symbolic.py:116-157`:

> `*Which*` entries to request when logging is on; this populated default is not itself a
> switch — logging stays off until `haskell_log_dir` is set (or a per-call flag enables it).
> [...] The switch: when set, every RPC requests the per-request `haskell-logging` bundle and
> the captured entries are written to `<haskell_log_dir>/<request_id>.jsonl` (one JSON value
> per line).

So `--haskell-log-entries` alone does **nothing**; you must pass `--haskell-log-dir`. The
default entry set is pyk's curated list, `$K/pyk/cterm/symbolic.py:49-60`:

```python
HASKELL_LOGGING_ENTRIES: Final = (
    # Kore engine: equation attempt/application plus the term index that resolves their hashes.
    'DebugAttemptEquation',
    'DebugApplyEquation',
    'DebugTerm',
    # Booster: proxy/fallback decisions, detail, aborts, simplification, and rewrite steps.
    'Proxy',
    'Detail',
    'Abort',
    'Simplify',
    'Rewrite',
)
```

Kontrol's `RpcOptions` defaults `haskell_log_entries` to exactly this tuple
(`$K/kontrol/options.py:81`), so in practice you only override it to *narrow* the set.

What the entries mean:

| entry | produced by | tells you |
|---|---|---|
| `DebugAttemptEquation` | Kore | every equation/lemma **tried** — the denominator for "is my lemma even being attempted?" |
| `DebugApplyEquation` | Kore | every equation that actually **fired** — the numerator |
| `DebugTerm` | Kore | the term index that resolves the hashes appearing in the two above |
| `Proxy` | booster proxy | which engine (booster vs kore) served the request, and why it switched |
| `Detail` | booster | rule file:line for the rule under consideration |
| `Abort` | booster | **the booster gave up and fell back to Kore** — the single most valuable entry |
| `Simplify` | booster | simplification/evaluation steps |
| `Rewrite` | booster | rewrite steps |

Separately, the *server* has its own log-level vocabulary, which is **different** and easy to
confuse with the above. From `kore-rpc-booster --help` in this image:

> `-l,--log-level LEVEL   Log level: debug, info (default), warn, error, or a custom level:
> Aborts, Rewrite, RewriteKore, RewriteSuccess, Simplify, SimplifyKore, SimplifySuccess,
> Depth, SMT, ErrorDetails, EquationWarnings, TimeProfile, Timing, KoreCalls`

Note `Aborts` (server level) vs `Abort` (RPC entry) — not interchangeable.

#### What the bundles actually contain

**This is verified, not inferred — I ran it on this machine.** The entry *names* above are what
pyk *requests*; what lands in the file is the booster's own **context-tagged** format, one JSON
object per line:

```json
{"context": ["booster","simplify","term","term","simplification","detail"],
 "message": "SWAPVM-LEMMAS.mul-no-overflow"}
{"context": ["booster","simplify","term","term","simplification","match","failure","continue"],
 "message": "Values differ:\"1157920892373161...truncated\" \"4294967296\""}
{"context": ["proxy","timing"],
 "message": {"kore-time": 4.345181395, "method": "SimplifyM", "time": 4.448500718}}
{"context": ["proxy","abort","detail"],
 "message": "Kore simplification: Diff (< before - > after)\n<syntactic difference only>"}
{"context": ["booster","simplify","smt"],
 "message": "Successfully initialised SMT solver with SMTOptions {transcript = Nothing, timeout = 300, retryLimit = Just 10, tactic = Nothing, args = []}"}
```

Read it as a path: `booster|kore|proxy` (which engine) → phase (`simplify`, `execute`,
`rewrite`) → `term <hash>` → `simplification|function|rewrite <rule>` → outcome
(`detail`, `match`, `success`, `failure`, `continue`, `abort`). The `detail` line names the
rule (a label if the rule has one, otherwise `file : (line, col)`); the line **immediately
after** it gives that rule's outcome.

Three lines above are individually load-bearing:

* **`proxy > timing`** is per-request wall clock *with the Kore share broken out*:
  `{"kore-time": 4.345, "method": "SimplifyM", "time": 4.449}` — 98% of that request was spent
  in the slow legacy engine. **This single field is the SMT-bound / rewriting-bound /
  fallback-bound discriminator you were looking for**, and it comes for free with
  `--haskell-log-dir` — no `--kore-rpc-command -l Timing` needed.
* **`proxy > abort > detail`** confirms a fallback happened and says what the Kore pass changed.
* The SMT init line is a live readout of the effective SMT settings — here `timeout = 300,
  retryLimit = Just 10`, confirming pyk's defaults from §3.3 rather than the docs' "1000ms".

#### Recipe: is my lemma being attempted, and is it firing?

This is `PROOF-MAP.md` blockers 2 and 3 ("does `mul512` collapse fire in practice", "does
`ceilDiv` normalisation fire in practice"), and it needs no rebuild.

```
# isolate ONE request — a whole proof produces thousands of 1.4 MB bundles
kontrol simplify-node --haskell-log-dir /tmp/hlog '<Test>' <node-id>
#   ...or, mid-proof:
# kontrol prove --match-test '<Test>' --max-iterations 1 --max-depth 200 \
#   --haskell-log-dir /tmp/hlog --workers 1
```

```
python3 - <<'EOF'
import json, glob, collections
lines = [json.loads(l) for f in glob.glob('/tmp/hlog/*.jsonl') for l in open(f) if l.strip()]
ctx = lambda e: ' > '.join(x if isinstance(x, str) else list(x)[0] for x in e.get('context', []))

att, app = collections.Counter(), collections.Counter()
for i, e in enumerate(lines):
    m = e.get('message')
    if isinstance(m, str) and m.startswith('SWAPVM-LEMMAS.'):
        att[m] += 1
        if i + 1 < len(lines) and 'success' in ctx(lines[i + 1]):
            app[m] += 1
for k, v in att.most_common():
    print(f'{v:4d} attempted {app.get(k, 0):4d} applied   {k}')

print('--- engine time ---')
for e in lines:
    if ctx(e) == 'proxy > timing': print('   ', e['message'])
print('--- aborts / fallbacks ---')
for e in lines:
    if 'abort' in ctx(e): print('   ', ctx(e), '::', str(e.get('message'))[:120])
print('--- why rules failed to match ---')
c = collections.Counter(e['message'][:90] for e in lines
                        if isinstance(e.get('message'), str) and 'failure' in ctx(e))
for k, v in c.most_common(10): print(f'{v:5d}  {k}')
EOF
```

Real output from one `simplify` request on an `XYCSwapSpec.setUp()` node (1977 log lines,
1.4 MB):

```
   5 attempted    0 applied   SWAPVM-LEMMAS.mul-no-overflow
   5 attempted    0 applied   SWAPVM-LEMMAS.sq-no-overflow
   5 attempted    0 applied   SWAPVM-LEMMAS.add-no-overflow
   ... 20 labels, 0 applied ...
--- engine time ---
    {'kore-time': 4.345, 'method': 'SimplifyM', 'time': 4.449}
--- aborts / fallbacks ---
    proxy > abort > detail :: Kore simplification: Diff (< before - > after)
--- why rules failed to match ---
  467  equation did not match term:  unimplemented matching case
   12  Values differ:"1157920892373161...truncated" "4294967296"
   11  Uncertain about definedness of rule due to: non-total symbol LblnewAddr
```

**How to interpret it, and this is the whole point:**

* **A label that does not appear at all** = the rule's LHS never matched anything in the term.
  The rule is written against a shape KEVM does not produce. Fix: `kontrol show --node
  <id> --minimize`, read the real term, restate the rule. (`mul512-high-zero` and
  `ceildiv-oz-*` are absent from the sample above simply because a `setUp` node contains no
  `MULMOD` and no `ceilDiv` — run the same recipe on an `XYCConcentrateSpec` node to get the
  answer that matters.)
* **Appears, `attempted > 0`, `applied = 0`** = the LHS matched but the rule did not fire.
  The adjacent failure message says why, and the three messages above are the three canonical
  causes: `equation did not match term` (structural), `Values differ` (a concrete guard did
  not hold), `Uncertain about definedness of rule due to: non-total symbol <X>` (**missing
  `preserves-definedness`, or the symbol needs `[total]`** — this is the booster-abort case
  from §5.2, seen live).
* **`applied > 0`** = it fires; if the proof is still slow, the bottleneck is elsewhere.
* **`kore-time / time` close to 1** = the request was served by the slow engine. Chase the
  abort reason, not the SMT timeout.

### 2.4 `--bug-report`

`--bug-report NAME` writes a `NAME.tar` containing the Kore definition, the LLVM definition,
server version strings, the exact server command line, and every RPC request/response pair
(`$K/pyk/kore/rpc.py:1415-1428`, `BoosterServer._populate_bug_report`). Two uses:

* it is what RV will ask for if you file an issue;
* it is an exact, replayable record of *how many* requests a proof made and how big each was —
  a direct measurement of §1's round-trip count. Every request and response is added as a
  separate tar member (`$K/pyk/kore/rpc.py:371-385`), so
  `tar tf NAME.tar | grep -c '_request.json'` is an exact RPC counter, and
  `tar tvf NAME.tar | grep _request.json` gives you their sizes.

Cost: it writes every request and response to disk. Expect it to dominate a short proof's
runtime and to produce gigabytes on a long one. Use with `--max-iterations`.

### 2.5 Cheap always-on instrumentation

`proof.json` records `execution_time` (accumulated across resumed runs,
`$K/pyk/proof/reachability.py:630`). A one-liner over the proof store gives you a ranked
"where has our time gone" table with no re-running at all — this is how the table in §10 was
produced.

---

## 3. Every performance-relevant flag

Defaults below are read from source, not from `--help`. Three source files hold them:
`$K/pyk/cli/args.py` (`ParallelOptions`, `SMTOptions`), `$K/kevm_pyk/cli.py`
(`ExploreOptions`, `KProveOptions`), `$K/kontrol/options.py` (`RpcOptions`, `ProveOptions`).

### 3.0 The one flag to read first: `--optimize-performance N`

`$K/kontrol/options.py:434-450`, `ProveOptions.apply_optimizations`, called from
`ProveOptions.__init__` **after** the TOML and CLI values are merged, so it *overrides* them:

```python
if self.optimize_performance is not None:
    self.assume_defined = True
    self.log_succ_rewrites = False
    self.max_frontier_parallel = self.optimize_performance
    self.maintenance_rate = 64
    self.smt_timeout = 120000
    self.smt_retry_limit = 0
    self.max_depth = 100000
    self.max_iterations = 10000
    self.stack_checks = False
```

Two things to note.

* **Documentation disagreement.** The upstream PR that introduced this flag (kontrol#774)
  describes `--smt-timeout 32000`. The installed source sets **120000**. Source wins.
* It does **not** touch any `--break-on-*` flag or `--optimize-kcfg`, so a TOML that turns
  break-on-basic-blocks on will still turn it on. That is the single most important thing
  `--optimize-performance` does *not* fix for us.

Using it is the fastest way to get most of §3's wins at once — but note the **CLI trap**:
there is no `--no-break-on-basic-blocks` flag. The usage line offers `--break-on-calls` /
`--no-break-on-calls` but only `--break-on-basic-blocks` (a `store_true`). **Once
`break-on-basic-blocks = true` is in `kontrol.toml`, no command line can turn it off.** You
must either edit the TOML or point at a different one:

```
# works: a config file that does not set break-on-basic-blocks
kontrol prove --match-test 'XYCSwapSpec.test_exactIn_cannotDrainPool' \
  --config-file kontrol-fast.toml --optimize-performance 4 --workers 2

# does NOT do what it looks like: break-on-basic-blocks is still on, from the TOML
kontrol prove --match-test '...' --optimize-performance 4 --no-break-on-calls
```

Beyond that, understand the pieces before adopting the bundle: `assume_defined = True` is
flagged experimental and `stack_checks = False` is a soundness assumption (see §3.6).

### 3.1 Flags that change the number of round trips (biggest lever)

| flag | source default | our TOML | effect |
|---|---|---|---|
| `--max-depth N` | `1000` (`ExploreOptions`) | `2000` | max K steps the backend takes per `execute`. Branching cuts it short anyway. Higher = fewer round trips. |
| `--break-on-basic-blocks` | off | **on** | adds cut-point rule `EVM.end-basic-block` **and implies `--break-on-calls`** (`$K/kevm_pyk/kevm.py:199-219`). A round trip per basic block. |
| `--break-on-calls` | off | **on** | cut points on `EVM.call/callcode/delegatecall/staticcall/create*/end/return.*/precompile.*`. |
| `--break-on-jumpi` | off | off | cut points on `EVM.jumpi.true/false` — a round trip per conditional jump. |
| `--break-on-jump` | off | off | `EVM.jump`. |
| `--break-on-storage` | off | off | `EVM.sstore`, `EVM.sload`. |
| `--break-every-step` | off | off | `EVM.step` as a *terminal* rule. Help text says "(expensive)"; it is the debugging-only setting. |
| `--break-on-cheatcodes` | off | off | every rule in `FOUNDRY-CHEAT-CODES` and `KONTROL-ASSERTIONS` becomes a cut point (`$K/kontrol/prove.py:425-431`). |
| `--optimize-kcfg` | off | **on** | merges consecutive edges on the fly, deleting the intermediate node (§1c). |

Three cut points are **always** present regardless of flags —
`FOUNDRY-CHEAT-CODES.rename`, `FOUNDRY-CHEAT-CODES.cheatcode.call.ffi`,
`FOUNDRY-ACCOUNTS.forget` (`$K/kontrol/foundry.py:120-123`) — because Kontrol implements those
as Python-side custom steps.

**When breaking helps.** When you genuinely need a node at a specific place: to inspect a
stuck state, to `merge-nodes` a fan-out, to `refute-node` a branch, or to give `section-edge`
somewhere to cut. In that case turn it on *for that proof*, not globally — and turn
`--optimize-kcfg` off at the same time, or the nodes you asked for will be deleted.

**When breaking hurts.** Always, on a proof you just want to close. Our straight-line
arithmetic proofs (`XYCSwap`, `PiecewiseLinearScale` value properties) are the worst case:
long stretches of pure computation chopped into hundreds of requests.

**Recommended:**

```toml
# fast mode — default
max-depth             = 100000
break-on-basic-blocks = false
break-on-calls        = false
optimize-kcfg         = true

# inspection mode — when a specific proof is stuck
# max-depth           = 200
# break-on-basic-blocks = true
# optimize-kcfg       = false
```

Keep these as two TOML *profiles* (`[prove.fast]` / `[prove.inspect]`, selected with
`--config-profile`); profile inheritance from `[prove.default]` is implemented at
`$K/pyk/cli/pyk.py:601-608`.

### 3.2 Flags that change the payload per round trip

| flag | source default | effect |
|---|---|---|
| `--no-log-rewrites` | logging is **ON** (`log_succ_rewrites: True`) | stops the backend returning a log entry per applied rewrite rule. Pure win unless you are reading rule traces. |
| `--log-fail-rewrites` | off | logs *failed* rule applications too. Debugging only; very expensive. |
| `--booster-only-simplify` | off | skips the Kore simplification pass after Booster. See §5. |
| `--auto-abstract-gas` | off | replaces the `<gas>`/`<refund>` cells with fresh variables when infinite gas is on (`$K/kevm_pyk/kevm.py:155-176`). |
| `--use-gas` | gas is **off** (`'usegas': False`, `$K/kontrol/options.py:363`) | turning it on is a large slowdown and creates branches. Leave off. |

**TOML gotcha, verified.** The TOML key you want is `log-rewrites = false`, **not**
`no-log-rewrites = true`. Key→attribute resolution (`$K/pyk/cli/pyk.py:626-637` plus
`$K/kontrol/cli.py:77-102`) maps a key through `from_option_string()` and otherwise just
replaces `-` with `_`:

* `log-rewrites` → `log_succ_rewrites` ✅ (explicit mapping in `RpcOptions.from_option_string`)
* `no-log-rewrites` → `no_log_rewrites` → prefix-stripped to `log_rewrites` ❌ — an attribute
  nothing reads. `Options.__init__` sets unknown keys silently, so this fails with no warning.

(For contrast, `no-stack-checks = true` *does* work: it resolves to `no_stack_checks`, gets
prefix-stripped to `stack_checks`, and is negated to `False`.)

`--auto-abstract-gas` is worth nothing to us as things stand: gas is already off, and
`abstract_node` only fires on an `infGas(...)` term. Keep it off; it costs an extra
bottom-up traversal per node for no benefit.

### 3.3 SMT flags

| flag | source default | booster binary default | our TOML |
|---|---|---|---|
| `--smt-timeout` | `300` ms (`$K/pyk/cli/args.py:293-304`) | `125` ms | `5000` |
| `--smt-retry-limit` | `10` | `3` | *unset → 10* |
| `--smt-tactic` | `None` | none (plain `check-sat`) | unset |

**Documentation disagreement:** RV's "debugging failing proofs" page states "The default
timeout is 1000ms". Neither the pyk default (300) nor the server's own default (125) is 1000.
Source wins; do not reason from the docs' number.

The retry mechanism scales the timeout on each retry. With `smt-timeout = 5000` and the
default `smt-retry-limit = 10`, a single undecidable query can burn a very long time before
being declared `Unknown` — and undecidable queries are exactly what a symbolic `DIV` or a
symbolic square produces. **This is a real misconfiguration in our TOML:** we raised the
timeout without lowering the retry limit.

Prefer one long attempt over many scaling ones (this is also what `--optimize-performance`
does, and what kontrol#716 concluded):

```toml
smt-timeout     = 120000
smt-retry-limit = 0
```

`--smt-tactic` takes a raw Z3 S-expression. `'(check-sat-using qfnra-nlsat)'` is RV's
documented suggestion for non-linear arithmetic, which is precisely the shape of
`PeggedSwapMath.sol:66` and `:103` (symbolic squares) and of the `mul512` obligations. Worth
an A/B on one PeggedSwap Group-B property:

```
kontrol prove --match-test 'PeggedSwapSpec.test_bothBalancesZero_zeroInputBalanceAlonePassesTheGuard' \
  --smt-tactic '(check-sat-using qfnra-nlsat)' --smt-timeout 120000 --smt-retry-limit 0
```

Caveat, and it is a real one: `nlsat` is a *decision* procedure for non-linear real
arithmetic and can be dramatically worse than the default portfolio on the mostly-linear
goals that make up the bulk of a proof. Measure, do not assume.

Not exposed by Kontrol but reachable through `--kore-rpc-command`: `--no-booster-smt`
(disable SMT inside the booster fast path but keep it for Kore), `--smt-arg`,
`--equation-max-iterations` (default 100), `--equation-max-recursion` (default 5),
`--equation-max-local-steps` (default 0 = restart-only). If a `[simplification]` rule is
suspected of looping, `--equation-max-iterations` is the knob, and the server log level
`EquationWarnings` is the symptom to look for.

### 3.4 Concurrency flags

| flag | source default | our TOML | what it actually creates |
|---|---|---|---|
| `--workers N` / `-j N` | `1` | `4` | N **OS processes**, each proving one test and each starting its **own** `kore-rpc-booster` (`$K/kontrol/prove.py:347-360`). Only used when `workers > 1 and len(tests) > 1`. |
| `--max-frontier-parallel N` | `1` | unset → 1 | N **threads inside one proof**, each with its own `KoreClient` to the *same* server. Also sets that server's `GHCRTS=-N<N>`. |
| `--force-sequential` | off | off | disables `parallel_advance_proof` entirely. |
| `--fail-fast` | **on** | **off** | stop exploring siblings once a branch fails. |
| `--step-timeout S` | `None` | unset | per-step wall-clock budget; on timeout, interrupt and **halve the execution depth**, then retry. |

The `--max-frontier-parallel` → RTS link is the non-obvious one and it matters a lot.
`$K/kontrol/prove.py:359` passes `haskell_threads=options.max_frontier_parallel` to
`FreshKoreServer`, and `$K/pyk/kore/rpc.py:1322-1330` turns that into:

```python
new_env['GHCRTS'] = ' '.join(part for part in [f'-N{self._haskell_threads}', new_env.get('GHCRTS')] if part)
```

with `self._haskell_threads = args.get('haskell_threads') or 1`. **So with our current
configuration every `kore-rpc-booster` runs with a single Haskell capability.** Four workers
× `-N1` = at most 4 of our 16 cores doing rewriting, plus 4 mostly-idle `z3` processes. A
proof with no branching gets exactly one core no matter what `--workers` says.

`--step-timeout` has a trap: it silently forces sequential execution.
`$K/kevm_pyk/utils.py:145-153`:

```python
# step_timeout is only enforced on the sequential `advance_proof` path;
# `parallel_advance_proof` does not wrap steps with the timeout budget.
if step_timeout is not None and not force_sequential:
    if max_frontier_parallel > 1:
        _LOGGER.warning(... 'ignoring max_frontier_parallel=... and running sequentially.')
    force_sequential = True
```

So `--step-timeout` and `--max-frontier-parallel` are mutually exclusive in effect. Use
`--step-timeout` as a *diagnostic* on a single stalling proof (it converts an infinite hang
into a visible sequence of depth-halving retries, which localises the offending step), not as
a production setting.

`--fail-fast = false` in our TOML is a deliberate debugging choice — it keeps exploring
sibling branches after one fails, so you see all the failures at once. It is also strictly
more work. Keep it off while a spec is being developed; turn it **on** for re-proof runs.

### 3.5 Bounded model checking

`--bmc-depth N` turns the proof into an `APRBMCProof`: at every node the semantics calls
`is_loop` (K cell matches a `JUMPI` at a loop head, `$K/kevm_pyk/kevm.py:131-135`) and walks
the shortest path back looking for `same_loop` nodes — same `PC`, `CALLDEPTH`, `PROGRAM`, same
jump target, same word-stack length (`:137-153`). Once more than `N` prior loop heads are
found, the node is marked `bounded` and dropped.

Costs: a `shortest_path_to_node` walk plus `same_loop` comparisons at every loop head, and a
`prior_loops_cache` carried in `proof.json`. kontrol#283 ("Checking `--bmc-depth` slows proofs
down over time") is exactly this cache growing. For `PiecewiseLinearScale`'s `--bmc-depth 51`
that is 51 comparisons at the last iteration — acceptable, but do not set `--bmc-depth` on
proofs that have no loop.

The completeness argument in `PROOF-MAP.md` is right and is worth restating operationally:
after the run, check `bounded` is empty.

```
python3 -c "import json;print(json.load(open('out/proofs/<id>/proof.json'))['bounded'])"
```

A non-empty `bounded` list means the result is bounded, not unconditional.

### 3.6 Soundness-adjacent speed flags

* **`--no-stack-checks`** (we have it on). Sets `<stackChecks> false` in the initial
  configuration (`$K/kontrol/prove.py:984`, `$K/kontrol/kdist/no_stack_checks.md`), which
  disables the `#stackUnderflow` / `#stackOverflow` guard on every opcode. That guard is a
  side condition on *every single EVM step*, so removing it is a broad win. The assumption —
  "Solidity-compiled bytecode cannot underflow/overflow the stack" — is sound for our
  harnesses. Keep.
* **`--assume-defined`** (off; `--optimize-performance` turns it on). Passes
  `assume-defined: true` on `implies` requests, using the Booster's implication check rather
  than Kore's (`$K/pyk/proof/reachability.py:822`). Help text says "experimental". Note that
  the *initial* node always gets an `assume_defined` pass with `booster_only_simplify=False`
  pinned regardless (`$K/kevm_pyk/utils.py:334-336`), because `#Ceil` must be discharged by
  Kore. Because we barely issue `implies` requests (§1a), the upside here is small for us.
* **`--symbolic-caller`**, **`--symbolic-immutables`**, **`--run-constructor`**: all *add*
  symbolic state and therefore branching. Leave off. We already have `run-constructor = false`.
  (`--enum-constraints` is the opposite sign — see §6.5 — but no current spec takes an enum.)
* **`--hevm`**: swaps Kontrol's success predicate for hevm's. Changes what is proven; not a
  performance flag.

### 3.7 Bookkeeping flags

* **`--maintenance-rate N`** (default **1**): iterations between `write_proof_data()` and
  status-bar updates. At 1 we rewrite `kcfg.json` (2.1 MB for the 128-node PeggedSwap proof)
  on *every* iteration. Each node is written once to its own `kcfg/nodes/<id>.json`
  (~250 KB), so the *incremental* per-iteration cost is the `kcfg.json` +
  `proof.json` rewrite. `--optimize-performance` uses
  64. The documented cost of raising it: "setting to >1 may result in work being discarded if
  proof is interrupted". 8–16 is a good compromise for us given the crash-resilience concern
  that motivated the current TOML.
* **`--minimize-proofs`** (off): runs `minimize_kcfg()` after the proof. Post-hoc tidying;
  no effect on proving time. Note `_run_cfg_group` minimizes unconditionally for
  `SUMMARY_CONFIG` proofs (`$K/kontrol/prove.py:466`).
* **`--counterexample-information`** (on): on failure, runs a `get-model` RPC per failing
  node. Cheap when there are 3 failing nodes, expensive when there are 128. Turn off with
  `--no-counterexample-information` when triaging a wide fan-out failure.
* **`--remove-old-proofs`**: `shutil.rmtree(proofs_dir)` if any test method's *contract*
  digest changed (`$K/kontrol/foundry.py:1015-1025`). Destructive; do not use on the shared
  store.

### 3.8 `--init-node-from-diff` / `--init-node-from-dump`

`--init-node-from-diff PATH` reads a JSON produced by `vm.stopAndReturnStateDiff()` (and
`--init-node-from-dump` one from `vm.dumpState()`), converts it into `<account>` cells, and
injects those into the initial configuration of every proof
(`$K/kontrol/__main__.py:186-195` → `recorded_state_to_account_cells` → `init_accounts`).

The performance angle: it lets you replace a symbolically-executed `setUp()` with a recorded
concrete state. Our `setUp()` proofs cost 47–110 s each and are re-run for every new spec
version — the store currently holds `XYCSwapSpec.setUp()` at versions 0,1,2,3,5. That is a few
hundred seconds of pure repetition. Note the two flags are mutually exclusive (an
`AssertionError` if both are given) and that this changes what the proof assumes about the
initial state — it is a modelling decision, not a free speedup.

The cheaper mitigation for the same problem is `--setup-version N` (§8).

---

## 4. `--cse` in depth

### 4.1 What it does

`--cse` is Compositional Symbolic Execution: prove each externally-called function once, in
isolation, as a *summary*, then reuse the summary at every call site instead of re-executing
the callee. RV's own description:

> "CSE addresses a fundamental challenge in symbolic execution: when a function calls external
> dependencies, the verification tool must explore all possible execution paths through those
> dependencies, leading to exponential path explosion and slow verification times."
> — docs.runtimeverification.com/kontrol/guides/kontrol-example/compositional-symbolic-execution

Mechanically (`$K/kontrol/prove.py:87-110`):

1. For each selected test, read `test.method.function_calls` — the list of external calls
   found by walking the method's solc AST (`find_function_calls`, `$K/kontrol/solc_to_k.py:1102`).
2. Recursively call `foundry_prove` on each of those callees with
   `config_type = SUMMARY_CONFIG`, `exact_match=True`.
3. Collect the resulting proof ids into `summary_ids`.
4. Run the top-level test with `subproof_ids = summary_ids`
   (`$K/kontrol/prove.py:674`). `APRProver` turns each passing subproof into rules at
   **priority 20** (`$K/pyk/proof/reachability.py:797`, `subproof.as_rules(priority=20, ...)`),
   i.e. above ordinary semantics rules, so they are tried first.
5. Summary proofs are always `minimize_kcfg()`-ed (`$K/kontrol/prove.py:466`).

`--include-summary <test>:<version>` is the manual form of the same thing: you produce the
summary yourself and name it. `--cse` and `--include-summary` are mutually exclusive
(`AttributeError` at `$K/kontrol/prove.py:76`).

### 4.2 What makes a function summarisable

* It must be an **external/public** call reached through a `MemberAccess` on a contract-typed
  expression. `find_function_calls` explicitly ignores calls whose receiver type resolves to
  `Vm`, `KontrolCheatsBase`, or `UnknownContractType` — which means `abi.encodePacked`, library
  `using for` calls that inline, and internal calls are invisible to CSE. **`Math.mulDiv` and
  `Math.sqrt` are internal library functions that solc inlines; CSE will never see them.**
  This is the crucial fact for us and it contradicts the hope recorded in `FINDINGS.md`
  ("Try `cse = true` in `kontrol.toml` first — compositional symbolic execution can summarise
  `mulDiv` and `sqrt` once"). It cannot, unless those functions are promoted to `external` on
  a wrapper contract.
* The contract must have `storageLayout` in the solc output, else Kontrol raises
  `RuntimeError` (`$K/kontrol/prove.py:96-99`). We are fine here: `Foundry.build` invokes
  `forge build --build-info --extra-output storageLayout evm.bytecode.generatedSources`
  (`$K/kontrol/foundry.py:630-637`), and `out/PiecewiseLinearScaleHarness.sol/PiecewiseLinearScaleHarness.json`
  does contain `storageLayout` — verified. No `foundry.toml` change is needed.
* Cheatcodes are not available while analysing a non-test function, so `vm.assume` cannot be
  used to constrain a summary. The documented substitute is **NatSpec preconditions**:

  ```solidity
  /// @custom:kontrol-precondition a <= 2**128 - 1,
  /// @custom:kontrol-precondition b <= 2**128 - 1,
  function mulDivExternal(uint256 a, uint256 b, uint256 d) external pure returns (uint256) { ... }
  ```

  Supported: standard operators, parameters, storage variables, globals (`msg.sender`,
  `block.timestamp`), literals with unit suffixes. **Not** supported: array/mapping access,
  nested struct access, packed-slot offsets.
* A summary of a function that branches N ways is N rules; it removes the *re-execution* cost
  but not the branching. RV pairs CSE with node merging for exactly this reason (§6.2b), and
  states the intent to "automatically apply node merging during CSE summary generation in
  future releases".

### 4.3 The `bytes calldata` bug — root-caused

**We hit this; it is real; it is not reported upstream.** (A search of
`runtimeverification/kontrol`, `evm-semantics`, `k` and `haskell-backend` issues found nothing
matching. The nearest neighbour is kontrol#375, "`kontrol prove` hangs while unable to stop
the server", also triggered by a `bytes[] calldata` parameter.)

The bug is **not** in the bracket-escaping code, which is fine. It is one line up, in
`find_function_calls` — `$K/kontrol/solc_to_k.py:1138-1143`:

```python
function_name = expression.get('memberName')
arg_types = expression['typeDescriptions'].get('typeString')
args = arg_types.split()[1] if arg_types is not None else '()'
...
value = f'{contract_type}.{function_name}{args}'
```

`typeString` for an external function is solc's rendering of the *function type*, and for
reference types it includes the data location. Confirmed against this repo's own build info
(`out/build-info/*.json`):

```
function (bytes calldata) view returns (uint256)
function (bytes calldata,uint256) pure returns (bytes calldata)
function (bytes calldata) pure returns (struct PeggedSwapArgsBuilder.Args calldata)
```

`'function (bytes calldata) view returns (uint256)'.split()` is
`['function', '(bytes', 'calldata)', 'view', 'returns', '(uint256)']`, so `[1]` is the
**truncated, unbalanced** `(bytes`. The recorded call becomes
`PiecewiseLinearScaleHarness.scaleOf(bytes` instead of `...scaleOf(bytes)`.

That string is then handed to `parse_test_version_tuple` and on to
`Foundry.matching_tests`, whose `_escape_brackets` escapes only `[ ] ( )`, giving
`PiecewiseLinearScaleHarness.scaleOf\(bytes` (the `.` is left unescaped, which is a separate
laxness), and, because summary proofs use `exact_match=True`, anchors it as
`(^|%)(...scaleOf\(bytes)$`. The regex is syntactically valid but the `$` anchor can never
match the real signature `...scaleOf(bytes)`, so `matching_tests` raises:

```
ValueError: Test identifiers not found: {'...scaleOf\\(bytes'}
```

**Scope.** This breaks CSE for *any* callee with a reference-typed parameter — `bytes`,
`string`, arrays, structs — in `memory` **or** `calldata`, and for any multi-word type name
(`struct Foo.Bar memory` truncates to `(struct`). It is not specific to `bytes calldata`.
`PiecewiseLinearScaleHarness` has three such functions
(`test/kontrol/harnesses/PiecewiseLinearScaleHarness.sol:58, 79, 105`), which is why we hit it
there.

**Workarounds, in order of preference.**

1. **Don't use `--cse` for those harnesses.** Given §4.2 (it cannot see inlined internal
   library calls anyway), CSE has little to offer this codebase. This is the honest answer.
2. **Give the summarised callee only value-typed parameters.** A wrapper
   `function scaleOfWords(uint256 w0, uint256 w1, ...) external` sidesteps the bug entirely,
   because `function (uint256,uint256) view returns (uint256)` splits correctly.
3. **Use `--include-summary` instead of `--cse`.** You name the callee yourself, so
   `find_function_calls` is never consulted for the top-level test. You still have to be able
   to name the callee in a form `matching_tests` accepts — the *real* signature works fine
   here, since the bug is in the derived string, not in the matcher.
4. If you must patch: `args = arg_types[arg_types.index('(') : arg_types.index(')') + 1]`
   handles the single-paren case; correct handling needs a paren-balancing scan because return
   types are also parenthesised. Patching a shared container install is not something to do
   casually — file it upstream instead. A minimal reproduction is:
   `'function (bytes calldata) view returns (uint256)'.split()[1] == '(bytes'`.

---

## 5. Booster vs plain Haskell backend

### 5.1 What is running

With `--use-booster` (the default; `$K/kontrol/options.py:77`), Kontrol starts
`kore-rpc-booster` and passes it the LLVM shared library from `out/kompiled/llvm-library`
(`$K/pyk/kore/rpc.py:1517`, `--llvm-backend-library <dir>/interpreter.so`). That binary is a
**proxy** hosting three engines:

* the **LLVM interpreter** (compiled native code) for fully *concrete* subterms;
* the **booster** rewriter (Haskell, fast paths, syntactic matching) for symbolic terms;
* a full **legacy Kore** engine for everything the booster gives up on.

RV's own description of the split:

> "During simplification, the term is traversed bottom up and any concrete sub-terms are sent
> to the LLVM backend to be evaluated... The symbolic parts of a term are handled directly by
> the booster."
> — haskell-backend `docs/2024-10-18-booster-description.md`

`--no-use-booster` starts plain `kore-rpc` with no LLVM library. It is strictly slower for us
and exists only to isolate a suspected booster bug.

### 5.2 When the booster aborts

Per-rule abort conditions, quoted from the same RV design document:

> "The rule application routine may reach an exception condition, in which case the whole
> rewriting step is aborted, i.e. no other rules will be attempted, causing a full-stop.
> These **abort conditions** include:
> - indeterminate matching of the rule's left-hand side and the current configuration
> - internal error during matching, likely indicating a bug in the matcher
> - a non-preserving-definedness rule, i.e. a rule which has partial symbols on the RHS and no
>   `preserves-definedness` attribute
> - unknown constraint in `ensures`"

Three of those are directly under our control:

* **Indeterminate matching** — typically an unevaluated function symbol under the rule's LHS.
  A symbolic `DIV` sitting in a term is a textbook case.
* **Definedness** — this is why `lemmas.k`'s convention of adding `preserves-definedness`
  matters, and it is a *performance* convention, not only a hygiene one. A `[simplification]`
  rule whose RHS contains a partial symbol (a division, say) and *lacks*
  `preserves-definedness` makes the booster abort and hand the whole step to Kore. RV's own
  measured claim for the booster is ">2.5× speedup [...] on a range of foundry test cases"
  (RV May 2023 update), so an abort costs at least that much, on that step, every time. Every
  rule in `lemmas.k` Sections 4–7 that introduces or preserves a `/Int` should carry the
  attribute; several already do, and the ones that do not are worth an audit.
* **`concrete(...)`-guarded rules meeting symbolic arguments** produce
  `Concreteness constraint violated: term has variables` — not an abort as such, but a
  guaranteed non-application. `lemmas.k`'s Section 1 comment already identifies this as the
  reason KEVM's own `*Int` transfer rules never fire for us.

At the whole-request level, the proxy re-executes with Kore whenever the booster halts for a
reason in `--fallback-on`. **Default (verified from `kore-rpc-booster --help` in this image):**

```
--fallback-on REASON1,REASON2...
     Halt reasons for which requests should be re-executed with kore-rpc
     (default: Branching,Stuck,Aborted)
```

So by default *every branch point in our proofs is re-executed by the slow engine* to
double-check the booster's answer. For proofs whose whole problem is branch count — PeggedSwap
Group D at ~2^28, `Power.pow` at 2^16 — that is a large multiplier. `--fallback-on Aborted`
(dropping `Branching` and `Stuck`) is worth an experiment via:

```
kontrol prove --match-test 'PeggedSwapSpec.test_bothBalancesZero_zeroInputBalanceAlonePassesTheGuard' \
  --kore-rpc-command 'kore-rpc-booster --fallback-on Aborted'
```

*Caveat, and take it seriously:* the fallback is not purely a performance device — the booster's
branch analysis is weaker than Kore's, and dropping `Branching` from the fallback set means
accepting the booster's branching decisions unchecked. Kontrol deliberately does not expose
`--fallback-on` on `kontrol prove` (`kevm_pyk`'s `RPCOptions` has the field, Kontrol's
`RpcOptions` does not), which is a hint about how experimental RV considers it. Treat any
result obtained this way as provisional until reproduced with the default.

### 5.3 Seeing it happen

Use §2.3 with the entry set narrowed:

```
kontrol prove --match-test '<Test>' --max-iterations 5 \
  --haskell-log-dir /tmp/hlog --haskell-log-entries Abort,Proxy,Detail --workers 1
```

`Abort` tells you the booster gave up; `Proxy` tells you which engine served the request *and
how long each took*; `Detail` gives the rule's label or file:line.

**We are already falling back, and I can name one reason.** In the single `simplify` request I
captured (§2.3), the bundle contained:

```
proxy > timing      :: {"kore-time": 4.345, "method": "SimplifyM", "time": 4.449}
proxy > abort > detail :: Kore simplification: Diff (< before - > after)
   11×  Uncertain about definedness of rule due to: non-total symbol LblnewAddr
```

98% of that request ran in the legacy Kore engine, and the definedness message is the third
abort condition from §5.2, live. `newAddr` is KEVM's address-derivation function, so this
particular one is upstream's to fix — but the *shape* of the finding is what matters: run the
same capture on a `PeggedSwapSpec` or `XYCConcentrateSpec` node and any
`non-total symbol Lbl<something-from-lemmas.k>` that shows up is a `preserves-definedness`
attribute we are missing, and each one is a step handed to the slow engine.

A run where most requests carry an `Abort` and a `kore-time / time` near 1 is a run where the
booster is contributing nothing — at which point the fix is a lemma or an attribute, not a flag.

### 5.4 `--booster-only-simplify`

Sets `booster-only: true` on `execute` / `simplify` / `implies` requests
(`$K/pyk/kore/rpc.py:1130`, `1154`, `1174`). Help text: "Skip the Kore simplification pass
after Booster; assume_defined still uses Kore for `#Ceil` evaluation."

The trade is: you skip a full Kore simplification of the post-execution state on every
request, which is often the single most expensive part of a step — at the cost of terms
staying larger and less normalised, which can *compound* into a bigger configuration and worse
later steps. RV's design notes describe exactly this failure mode for aggressive
simplification-deferral:

> "the configuration ends up growing at an enormous rate as these thunks build up and can
> cause failure when the simplifier runs out of memory, trying to simplify such a huge
> configuration term."

The mitigation for that is `--interim-simplification N` (booster option, reachable only via
`--kore-rpc-command`), which forces a pattern-wide simplification every N steps. So the
sensible experiment is the pair, not `--booster-only-simplify` alone:

```
kontrol prove --match-test 'XYCSwapSpec.test_exactIn_cannotDrainPool' \
  --booster-only-simplify \
  --kore-rpc-command 'kore-rpc-booster --interim-simplification 50'
```

Two safety notes, both from source:
* The initial-node definedness pass pins `booster_only_simplify=False` regardless
  (`$K/kevm_pyk/utils.py:334-336`) — `#Ceil` must go through Kore.
* Under-simplified terms mean lemmas may not match, because a lemma is written against the
  *normalised* term. If Section 5/6 of `lemmas.k` starts failing to fire, suspect this flag.

---

## 6. Path explosion

This is our actual bottleneck, and §3's flags do not touch it. Ranked by what would help us
most.

### 6.1 The symbolic `DIV` that stalls indefinitely

We worked around this with `try`/`catch`, which removed the division. That is a
specification-level change and it is the right instinct, but here is what was happening and
what the alternatives are.

A `DIV` with both operands symbolic in the *path condition* means Z3 is being asked a
non-linear integer question at every subsequent branch. With `smt-timeout = 5000` and the
default `smt-retry-limit = 10`, each such question is retried up to ten times with a
*scaling* timeout (the CLI help is explicit: "Number of times to retry SMT queries with
scaling timeouts"; the exact multiplier is not documented and I did not measure it) before
returning `Unknown` — and `Unknown` typically means the booster aborts the step and Kore
re-runs it. That is how a proof "stalls indefinitely" without any single component hanging.

**Confirm the diagnosis before acting on it.** Run one bounded step with `--haskell-log-dir`
(§2.3) and look at `proxy > timing`. If `kore-time / time` is near 1, the cost is the *Kore
fallback*, not Z3, and the fix is a lemma or a `preserves-definedness` attribute; if the two
diverge and the wall time is a multiple of `smt-timeout`, it really is the solver.

Options, in increasing order of invasiveness:

1. `smt-retry-limit = 0` with one large `smt-timeout`. Converts an unbounded scaling ladder
   into one bounded attempt. Do this regardless.
2. `--smt-tactic '(check-sat-using qfnra-nlsat)'` — the goal is genuinely non-linear.
3. A `[simplification]` lemma that discharges the specific shape. `lemmas.k` Section 4 already
   does this for `div-mul-le`, `div-le-self`, `div-monotonic`, `div-lt-is-zero`. The workflow
   is: `kontrol show <test> --node <stuck-id> --minimize`, read the term KEVM actually
   produced, write the rule against *that*.
4. `vm.assume` the divisor away, or restructure the harness so the division never enters the
   path condition — which is what `try`/`catch` achieved. Record it as domain narrowing.
5. `kontrol.forgetBranch(op1, op, op2)` — a Kontrol cheatcode that **removes a path
   constraint** (`$K/kontrol/kdist/cheatcodes.md:1310-1323`, implemented Python-side as the
   `FOUNDRY-ACCOUNTS.forget` custom step, `$K/kontrol/foundry.py:190+`). This is the surgical
   version of (4): you let the constraint be created, then drop it once it has served its
   purpose. It is *unsound in general* — you are deleting a fact — so it needs the same
   justification comment as a lemma.

### 6.2 `Math.sqrt`: 7 MSB branches × 6 Newton steps, ~2^28 for four calls

Measured shape of what this costs us today:
`PeggedSwapSpec.test_bothBalancesZeroGuardFiresWhenBothZero(...):1` — **128 nodes, 31 splits,
64 edges, 2084 s** for what is nominally a guard check. 128 = 2^7, exactly the MSB cascade.

Flags will not fix a 2^28. Three things will:

**(a) `kontrol merge-nodes` — the highest-leverage tool we are not using.**

```
kontrol merge-nodes 'PeggedSwapSpec.test_bothBalancesZeroGuardFiresWhenBothZero' \
  --node 543 --node 544 --node 545 --node 546 ...
```

`$K/kontrol/foundry.py:1222-1267`: it anti-unifies the chosen nodes into one more general
node, then creates a **Cover** edge from each original node to it. Covered nodes stop being
pending, so exploration continues from the single merged node. Preconditions checked:
`K_CELL`, `PROGRAM_CELL`, `PC_CELL`, `CALLDEPTH_CELL` must agree across the nodes (or they must
be `same_loop`) — which is exactly true for the 128 leaves where `Math.sqrt` returns, since
they differ only in the value on the stack and in the path condition.

The cost, and it is real: `anti_unify(keep_values=True)` keeps the discarded information as a
**disjunction** (`$K/pyk/cterm/cterm.py:215-227`), built pairwise. Merging 128 nodes produces
one node with a 128-way disjunctive path condition, which is then handed to Z3 at every
subsequent branch. So merging trades node count for constraint complexity. It is the right
trade when the properties are discharged from the path condition alone — i.e. **PeggedSwap
Group D**, which `PROOF-MAP.md` describes as "correct with zero axioms, the risk is path
count". It is the wrong trade for Group E, which needs sqrt-*value* reasoning.

To use it you must first *have* nodes at the sqrt exit — which means running that proof with
`--break-on-basic-blocks` (or `--break-on-jumpi`) and `--optimize-kcfg = false`. This is the
one place the current TOML's break settings would earn their keep, if `optimize-kcfg` were not
deleting the nodes.

**(b) `kontrol minimize-proof <test> --merge`** is the automatic version:
`KCFGMinimizer.merge_nodes` (`$K/pyk/kcfg/minimize.py:179-220`) finds `A -Split-> A_i -Edge-> B_i`
patterns where the `B_i` are mergeable and rewrites them into a single merged edge followed by
a split. `is_mergeable` for KEVM is "same `<statusCode>` and same `<program>`"
(`$K/kevm_pyk/kevm.py:253-274`) — i.e. all success paths merge with each other and all revert
paths merge with each other. RV's note: "Node merging is especially powerful during CSE, where
the same summary is being reused across multiple execution paths." It is post-hoc, so it
shrinks a finished KCFG rather than preventing the explosion; `merge-nodes` mid-proof is the
one that prevents it.

**(c) The abstraction seam, which `PROOF-MAP.md` already identifies as blocker #1.** Nothing
in Kontrol can introduce an `isqrt` symbol into inlined straight-line code. The seam has to be
built: a harness parameter `sqrtDisc` with `vm.assume(sqrtDisc*sqrtDisc <= disc)` and
`vm.assume(disc < (sqrtDisc+1)*(sqrtDisc+1))`. That is a specification decision and a trust
boundary, and it belongs in `FINDINGS.md`, not here — but it is the only thing that turns 2^28
into 1.

### 6.3 `Math.mulDiv`'s 512-bit fork

`Math.sol:209` decides `high == 0`. If KEVM cannot decide it, both arms are live and the
512-bit arm contains a Newton modular inverse. `lemmas.k` Section 6 exists to collapse this
and is, per `PROOF-MAP.md`, "compiled in but unexercised".

**Determine whether it fires before writing more of it.** §2.3 answers this directly:

```
kontrol prove --match-test 'XYCConcentrateSpec.test_exactIn_partialFillNeverChargesMoreThanOffered' \
  --max-iterations 3 --haskell-log-dir /tmp/mul512 --workers 1
# then grep the bundles for the rule label
grep -l 'mul512-high-zero' /tmp/mul512/*.jsonl | wc -l
```

`DebugAttemptEquation` present but `DebugApplyEquation` absent for that label means the rule is
being tried and its `requires` is not discharged. Absent entirely means the LHS never matches —
which is the case `PROOF-MAP.md` already anticipates ("check whether KEVM presents `MULMOD` as
`chop((X *Int Y) modInt maxUInt256)`").

Note that `--lemmas` (§9.1) lets you iterate on this **without a rebuild**, which changes the
economics of this loop completely.

### 6.4 `Power.pow`'s two continuing arms

`2^bitlength` leaves, up to 65536 for `DutchAuction`. `--bmc-depth` bounds the *trip count*,
which is not the problem — the trip count is already bounded by 16.

What actually applies:

* **`merge-nodes` at the top of each loop iteration.** The two arms of `exponent & 1` rejoin
  at the same PC with the same call depth, so they satisfy the merge precondition. Merging
  after every iteration keeps the frontier at 1 instead of doubling, turning 2^16 into 16
  merges — at the price of a growing disjunction. This is precisely the `same_loop` case that
  `foundry_merge_nodes` special-cases (`$K/kontrol/foundry.py:1249`).
* **Order properties instead of the closed form**, as `FINDINGS.md` already prescribes.
* **Changing the code** to a branchless constant-trip-count `pow`, which `FINDINGS.md` calls
  the highest-leverage option and which is right: one execution path, no merging, no BMC.

### 6.5 General branch hygiene RV recommends

From the debugging-failing-proofs and node-refutation guides:

* **Symbolic addresses branch on account existence.** Any symbolic `address` forces a branch on
  whether it is already in the `<accounts>` cell. Fix with
  `vm.assume(addr != address(this)); vm.assume(addr != address(vm));` and so on for every
  pre-existing account. Relevant to any spec taking an address parameter.
* **`&&` and `||` are branch points** in Solidity because they short-circuit. Rewriting
  `a && b` as `a & b` for `bool`s (where side-effect-free) removes a branch.
* **`--enum-constraints`** adds constraints for enum-typed arguments and storage slots.
  *Inferred:* it costs a few constraints and should remove branches over out-of-range enum
  values. None of our current specs takes an enum, so this is speculative; noted for
  completeness.
* **Refutation workflow** for a branch you believe is infeasible but cannot yet discharge:
  `kontrol refute-node <test> <id>` pauses that branch and creates a refutation subproof; you
  prove the rest, then come back. RV flags that refutation "has known soundness issues"
  (haskell-backend#3605) and cannot currently be discharged independently — so treat a proof
  with live refutations as incomplete, and record them.
* **`kontrol split-node <test> <node> "<K condition>"`** converts a non-deterministic branch
  into a deterministic split on a condition you supply, which is what makes `refute-node`
  usable on the resulting arms.
* **`kontrol section-edge <test> <edge> --sections N`** cuts one long edge into N intermediate
  nodes *after the fact*. This is the cheap way to get inspection granularity without having
  run the whole proof with `--break-on-*`. Use it instead of re-proving with break flags on.

---

## 7. Concurrency and memory

### 7.1 The topology

| knob | unit | who owns the RAM |
|---|---|---|
| `--workers N` | N Python processes (one test each) | each ~1.0–1.3 GB RSS (measured on this box) |
| … each starts | 1 `kore-rpc-booster` | ~1.0–2.3 GB RSS (measured; grows with proof size) |
| … which starts | 1 `z3` | ~35–40 MB RSS (measured) |
| `--max-frontier-parallel M` | M threads inside one proof, one shared server | server heap grows; also sets that server's `GHCRTS=-N M` |

So the process count is `N × 3` and the memory is roughly `N × (2.0 … 3.6 GB)`. Measured
snapshot from this machine with three concurrent Kontrol invocations running:
`kore-rpc-booster` at 2280 MB, 1431 MB, 1204 MB, 1050 MB, 996 MB, 987 MB, 979 MB, 978 MB;
`kontrol` Python processes at 1.0–1.3 GB each; `z3` at 34–39 MB each.

### 7.2 RV's memory bound

The only quantitative guidance RV publishes is in the Kontrol cheatsheet, and it is
memory-only — cores do not appear in it:

> `--workers $n` — "Sets the number of parallel processes run by the prover. It should be at
> most `(M - 8) / 8` in a machine with `M` GB of RAM."

For our 125 GB that gives **workers ≤ 14**. That is a *ceiling*, not a target: with 16 cores
and `-N1` servers, 14 workers would leave 14 cores busy and no headroom, and our measured RSS
is well under the 8 GB/worker the formula budgets. RV's own worked example and their
`run-kontrol.sh` template both hardcode `workers=2`.

**Our practical bound is cores, not memory**, and the core accounting is the thing to get
right: total rewriting parallelism is `workers × max_frontier_parallel`, because each server
only gets `-N max_frontier_parallel` capabilities. With `workers = 4, max-frontier-parallel = 1`
we use at most 4 of 16 cores. Options:

* `workers = 4, max-frontier-parallel = 4` → up to 16 rewriting threads across 4 servers.
  Best when proofs branch (our PeggedSwap/XYCConcentrate work).
* `workers = 8, max-frontier-parallel = 2` → 16 threads across 8 servers, ~16–28 GB.
  Best when running many independent proofs that each branch a little.
* `workers = 14, max-frontier-parallel = 1` → RV's ceiling, best only for many straight-line
  proofs.

Given multiple agents share this box, coordinate: the sum of `workers × max-frontier-parallel`
across all concurrent Kontrol invocations should stay ≤ 16, or everyone's wall-clock numbers
become meaningless (see §10 for how badly this bit the measurement below).

### 7.3 The defunct `kore-rpc` processes

**Investigated: this is a container-init artifact, not a Kontrol leak, and it is harmless.**

Observed: 158 zombies at the time of writing, across `kore-rpc-booster`, `kore-rpc`, `kontrol`,
`z3`, `pkill`, `timeout`, `tail`. Every one has `PPID 1`.

```
ps -p 1 -o pid,ppid,stat,args
    PID    PPID STAT COMMAND
      1       0 Ss   sleep infinity
```

The container's PID 1 is `sleep infinity`, which never calls `wait()`. When a process's parent
dies, the orphan is reparented to PID 1; if it then exits, nothing reaps it and it stays a
zombie forever. This is the classic Docker "PID 1 has no reaper" problem, not a bug in Kontrol
or in the Haskell backend.

Does it matter?

* **Memory: no.** A zombie has already released its address space. `<defunct>` entries hold a
  `task_struct` and a PID slot, a few KB total.
* **PID exhaustion: no.** `/sys/fs/cgroup/pids.max` is 154371 and we are at ~223 live PIDs.
  158 zombies is 0.1% of the budget.
* **As a signal: yes.** Zombies with `PPID 1` mean Kontrol runs are being killed without their
  parent reaping them — `SIGKILL`, `pkill`, container-level `docker exec` teardown. Each such
  kill also abandons whatever proof progress had not yet been written to disk, and (worse) can
  leave a *live* orphaned `kore-rpc-booster` holding 1–2 GB. Check for that specifically:

  ```
  ps -eo pid,ppid,stat,rss,comm | awk '$2==1 && $3!~/Z/ && $5~/kore-rpc/'
  ```

  It came back empty on this box, so we are not currently leaking live servers.

For completeness: there *was* a genuine upstream leak — haskell-backend#3959, "Z3 zombie
processes during long proofs", root-caused to "lazy I/O delaying the process termination until
server shut-down" and fixed in July 2024, well before this image. RV's own performance harness
still runs `killall kore-rpc-booster` between runs as a matter of routine, and RV's
`run-kontrol.sh` template starts with `pkill kore-rpc || true`. That is a reasonable habit for
us too — but do it *between* runs, not while other agents' proofs are live.

The proper fix, if anyone rebuilds the container: run it with `--init` (or PID 1 = `tini`),
which reaps orphans automatically.

---

## 8. Caching and incrementality

### 8.1 What `kontrol build` caches, and what invalidates it

`out/digest` is a JSON file with four kinds of entry (`$K/kontrol/kompile.py:121-145`,
`$K/kontrol/foundry.py:613-628`, `$K/kontrol/solc_to_k.py:625-646`):

| key | contents | recomputed from |
|---|---|---|
| `kompilation` | hash of the concatenated `--require` K files + the generated `foundry.k` | `lemmas.k`, `foundry.k` |
| `build-options` | `hash_str(str(options))` over **all** `BuildOptions` | the entire `[build.*]` TOML section |
| `kontrol` | the Kontrol version string | the installed version |
| `foundry` | hash of every contract's digest | every compiled contract |
| `methods.<qname>.method` | `hash(signature + AST + storage_digest + contract_digest)` | per test method |
| `methods.<qname>.contract` | the parent contract's digest | per contract |

`should_rekompile()` returns true if `--rekompile`, or the timestamp is missing, or
`kompilation`/`build-options` changed, or the Kontrol version changed.

**The trap: `build-options` is a hash of `str(options)`, which includes every build option —
`verbose`, `debug`, `regen`, everything.** Flipping `verbose = true` in `[build.default]`
forces a full rekompile of the shared definition. Given the standing instruction not to run
`kontrol build`, treat `[build.default]` in `kontrol.toml` as frozen.

### 8.2 What invalidates a *proof*

This is the one that is costing us the most and it is not obvious.
`Contract.Method.digest` (`$K/kontrol/solc_to_k.py:642-646`):

```python
@cached_property
def digest(self) -> str:
    ast = json.dumps(self.ast, sort_keys=True) if self.ast is not None else {}
    contract_digest = self.contract_digest if not self.is_setup else {}
    return hash_str(f'{self.signature}{ast}{self.contract_storage_digest}{contract_digest}')
```

`contract_digest` is `hash(name + the entire contract JSON)`
(`$K/kontrol/solc_to_k.py:843-845`). **So a test method's digest depends on the whole contract
it lives in.** Adding one property to `XYCSwapSpec.t.sol` changes the contract JSON, which
changes `contract_digest`, which changes the digest of *every* test method in that file, which
makes `resolve_proof_version` return `free_proof_version(test)` — a fresh version — for all of
them. Every previously-proven property in that file restarts from scratch.

The store bears this out: `XYCSwapSpec.setUp()` exists at versions 0, 1, 2, 3, 5;
`test_exactIn_cannotDrainPool` at 0, 1, 2, 3, 4; `test_exactIn_roundsInFavourOfMaker` at
0, 1, 2, 3. Only the highest version of each has any work in it. This is very likely most of
the explanation for "19 properties need `--reinit`" and "awaiting rebuild" in `PROOF-MAP.md`.

Note the asymmetry: `setUp()` is exempt from `contract_digest` (`if not self.is_setup else {}`),
so setUp proofs survive contract edits — but they get re-run anyway because
`resolve_setup_proof_version` bumps them when the *test* version is bumped, unless you say
otherwise.

**Practical consequences.**

1. **Split spec files.** One contract per property group, so adding a property to the
   `PeggedSwap` guard group does not invalidate the arithmetic group. This is the single
   biggest incrementality win available and it costs nothing but file moves.
2. **Freeze a spec file before starting long proofs on it.** Batch all edits, then prove.
3. **Reuse the setUp proof explicitly:** `--setup-version N` — "Instead of reinitializing the
   test setup together with the test proof, select the setup version to be reused during the
   proof." At 47–137 s per setUp and five stale versions of `XYCSwapSpec.setUp()`, this is
   free minutes.
4. Kontrol *warns* about the halfway case and it is worth watching for in logs:
   `"Test {test} was not reinitialized because it is up to date, but the contract it is a part
   of has changed."`

### 8.3 Resuming rather than restarting

* **Default behaviour is resume.** Without `--reinit`, `kontrol prove` loads the existing KCFG
  and continues from the pending frontier. If `proof.passed`, it returns immediately without
  starting a server at all (`$K/kontrol/prove.py:325-336`).
* **`--reinit` is a scalpel you should almost never reach for.** It calls
  `free_proof_version()`, creating a *new* version and leaving the old one on disk (so it
  wastes space rather than reclaiming it). It is also incompatible with an explicit
  `--version`.
* **The lemma-fix workflow avoids `--reinit` entirely**, and RV documents it: after adding a
  lemma, `kontrol remove-node <test> <bad-node-id>` to prune the subtree that the missing
  lemma produced, then plain `kontrol prove` to resume. Everything before that node is kept.
  With `--lemmas` (§9.1) this loop needs no rebuild either.
* **`--maintenance-rate`** sets how much work a crash discards. At 64 you lose up to 64
  iterations; at 1 you lose ~1 but pay a `kcfg.json` rewrite every iteration.
* Proof state lives in `out/proofs/<id>/{proof.json, kcfg/kcfg.json, kcfg/nodes/*.json}` and is
  plain JSON. It is safe to read while a proof runs; it is **not** safe for two processes to
  write the same proof id. If you want to experiment, do what §10 did: build an alternate
  Foundry root whose `out/` symlinks everything except `proofs/`.

---

## 9. What RV recommends that we are not doing

### 9.1 `--lemmas` — add simplification rules without rebuilding

This is the most important item in this section, because the standing constraint is that
nobody may run `kontrol build --rekompile` on the shared definition.

```
--lemmas <file>:<MODULE-NAME>
```

`$K/kontrol/foundry.py:654-668` parses the file, extracts the named module, **rejects it if it
contains any non-`KRule` sentence**, and returns it. `$K/kontrol/prove.py:456` passes it to
`run_prover` as `extra_module`, and `legacy_explore` calls
`csymbolic.add_module(extra_module, name_as_id=True)` (`$K/kevm_pyk/utils.py:400-401`), which
issues an `add-module` JSON-RPC request against the *running server*
(`$K/pyk/kore/rpc.py:1200-1215`). Subsequent `execute` requests name that module.

**Net effect: new `[simplification]` rules take effect on the next `kontrol prove`, with no
`kontrol build`, no `--rekompile`, and no impact on other agents.** `--extra-module` is the
deprecated alias. **Verified end to end on this machine** — see §10.2 for the exact commands.

Constraints, two of which cost me a failed attempt:

* **Rules only.** `load_lemmas` raises `ValueError: Supplied lemmas module contains non-Rule
  sentences` for anything else — no `syntax`, no `configuration`.
* **No `requires` line.** `load_lemmas` runs
  `kprove <file> --definition out/kompiled -I <kdist>/kontrol/base --dry-run --allow-rules`,
  and that include directory contains only the *compiled* definition, no `.md` sources. A
  `requires "kontrol.md"` (copied from `lemmas.k`) fails with
  `[Error] Critical: Could not find file: kontrol.md`.
* **`imports KONTROL-MAIN`**, as `--help` says — not `KONTROL-BASE`.

This turns "write a lemma → rebuild the shared definition → wait → find out it did not fire"
into a loop measured in minutes. Combined with §2.3 (did the rule get attempted? did it fire?)
it is the right way to attack `PROOF-MAP.md` blockers 2 and 3.

Suggested working pattern: keep `lemmas.k` as the stable, compiled-in library; keep a scratch
`test/kontrol/lemmas-wip.k` with module `SWAPVM-LEMMAS-WIP`, iterate there with
`--lemmas test/kontrol/lemmas-wip.k:SWAPVM-LEMMAS-WIP`, and promote rules into `lemmas.k` only
once they are known to fire (and re-measure after promoting — see the HANDOFF question about
priority).

### 9.2 `section-edge` instead of re-proving with break flags

`kontrol section-edge <test> <source>,<target> --sections N` cuts an existing edge into N
pieces. This is the "I need nodes here" answer that does not require having run the whole
proof with `--break-on-basic-blocks`. We are currently paying for global break flags to get an
inspection capability we could get on demand.

### 9.3 `refute-node` / `split-node` / `unrefute-node`

Documented RV workflow for a branch you believe is infeasible:

1. If the branching is non-deterministic, `remove-node` then `split-node` to turn it into a
   deterministic split on a condition you supply.
2. `refute-node` the arms you believe are dead — they stop being explored.
3. Finish the live branches.
4. Come back: add a lemma and `unrefute-node`, or add a `vm.assume` and restart.

We are not using any of this. For PeggedSwap Group E (`deadCode_*`), where the claim *is* that
a branch is unreachable, it is the natural fit. Caveat already noted: refutation subproofs
carry a known soundness issue and cannot currently be discharged, so a proof with live
refutations is not finished.

### 9.4 `minimize-proof --merge` after every wide proof

Cheap, post-hoc, shrinks the on-disk KCFG and makes `kontrol show` usable. Our 47 MB /
128-node PeggedSwap proof is a candidate.

### 9.5 NatSpec preconditions

`/// @custom:kontrol-precondition <expr>` constrains a function's inputs *without* a
cheatcode, which is the only way to constrain a CSE summary. Also usable to narrow a harness's
domain declaratively. `$K/kontrol/natspec.py` implements it. Unsupported: array/mapping
access, nested struct access, packed-slot offsets.

### 9.6 Things RV recommends that we already do correctly

Recorded so nobody "fixes" them: gas off (`usegas` defaults to `False` and we do not pass
`--use-gas`); `--no-stack-checks` on; `run-constructor = false`; booster on; `-O2` at build
time; `schedule = CANCUN` pinned to match `evm_version`; a shared `lemmas.k` with labelled,
commented, `preserves-definedness`-annotated rules. The `lemmas.k` header convention of
grepping `out/kompiled/definition.kore` for a rule label to confirm it compiled in is a good
habit and it works — verified: `mul-bound-transfer` 4 hits, `mul512-high-zero` 8,
`ceildiv-oz-raw` 2, `sq-monotonic` 4.

Also confirmed present in the compiled definition: `EVM-OPTIMIZATIONS` (18 hits,
`optimized.push` 8), the hand-written fused opcode rules. **Not** present: KEVM's per-opcode
`summaries/` module (`div-summary.k`, `mulmod-summary.k`, …) — Kontrol's `kontrol.md` does not
import it. That is upstream's choice, not ours to change, but it is worth knowing those exist
(evm-semantics#2776/#2778) in case they land in a future Kontrol.

---

## 10. Measurements on this machine

**Read these with the contention caveat.** The box was running other agents' Kontrol
invocations throughout (load average 12–22 on 16 cores). A `setUp()` proof that costs 47–55 s
in the shared store cost 110–138 s in the isolated experiment root — a ~2.5× contention
factor. Absolute numbers are therefore inflated. The A/B ratios are not: the arms were run
interleaved, twice each, and the structural counters (nodes allocated, bytes written) are
exactly reproducible.

### 10.1 Where our time has gone so far

Top of the existing proof store by recorded `execution_time` (sum: **10,017 s** across all
proofs):

| s | nodes | proof |
|---|---|---|
| 2219.5 | 4 | `PiecewiseLinearScaleSpec.test_value_scaleNeverExpands(uint256,uint24):0` |
| 2084.5 | 128 | `PeggedSwapSpec.test_bothBalancesZeroGuardFiresWhenBothZero(...):1` |
| 1646.1 | 4 | `PeggedSwapSpec.test_knownUnderflow_exactOutAtLargeReserves():0` |
| 598.2 | 12 | `XYCSwapSpec.test_exactIn_constantProductNeverDecreases(...):0` |
| 478.4 | 4 | `XYCSwapSpec.test_exactIn_revertsOnZeroBalanceIn(uint256,uint256):1` |
| 474.8 | 4 | `XYCConcentrateSpec.test_exactIn_clampIsReachable_witness():0` |
| 452.1 | 4 | `PiecewiseLinearScaleSpec.test_value_maximalScaleIsTheIdentity(uint232):0` |
| 411.8 | 4 | `XYCSwapSpec.test_exactIn_zeroInputYieldsZeroOutput(uint256,uint256):2` |
| … | | |
| **831.5 total** | 3 each | **14** `setUp()` proofs across 5 spec files (`XYCSwapSpec.setUp()` alone exists at versions 0,1,2,3,5) |

Two readings:

* The two most expensive proofs are of *different kinds*. `scaleNeverExpands` is 4 nodes and
  1628 rewrite steps — pure straight-line cost, i.e. round trips and rewriting.
  `bothBalancesZeroGuardFires` is 128 nodes / 31 splits — pure path explosion. They need
  different fixes, and no single flag helps both.
* **831.5 s (8.3% of all proving time to date) went into `setUp()`, of which ~484 s is
  superseded versions** — only the latest version per spec file is live (109.6 + 63.1 + 62.4 +
  57.3 + 55.0 = 347.4 s). §8.2 explains why the versions pile up; `--setup-version` and
  smaller spec files fix it.

### 10.2 A/B: the `--break-on-*` cost

Method: an isolated Foundry root at `/home/user/perf-exp` (inside the container; **still there,
delete it when you no longer want it**) whose `out/` symlinks the real `kompiled/`, contract
artifacts and `build-info`, with a **private empty `proofs/`** and a copied `digest`. Same
definition, same lemmas, zero interference with the shared store — this is the pattern to
reuse for any future timing experiment:

```
R=/home/user/swap-vm-verified; E=/home/user/perf-exp
rm -rf $E; mkdir -p $E/out
for f in $(ls -A $R     | grep -vE '^(out|proofs|digest|tmp)$'); do ln -s $R/$f     $E/$f;     done
for f in $(ls -A $R/out | grep -vE '^(proofs|digest|tmp)$');     do ln -s $R/out/$f $E/out/$f; done
mkdir -p $E/out/proofs; cp $R/out/digest $E/out/digest
kontrol prove --foundry-project-root $E --config-file $E/A.toml --match-test '...'
```

Test:
`XYCSwapSpec.test_exactIn_zeroInputYieldsZeroOutput(uint256,uint256)` (a known-passing,
4-node, straight-line proof). `--workers 1`, `reinit = true` on both arms. Only three settings
differ:

| | A (current `kontrol.toml`) | B (proposed) |
|---|---|---|
| `max-depth` | 2000 | 100000 |
| `break-on-basic-blocks` | true | false |
| `break-on-calls` | true | false |
| everything else | identical (`smt-timeout 5000`, `optimize-kcfg true`, `no-stack-checks true`, `schedule CANCUN`) | |

**Result — two independent runs of each arm**, interleaved (A, B, A, B) so that neither arm
got a systematically quieter machine:

| | A run 1 | A run 2 | B run 1 | B run 2 | mean ratio |
|---|---|---|---|---|---|
| `setUp()` proof, `execution_time` | 137.9 s | 109.2 s | 67.2 s | 55.6 s | **2.0×** |
| test proof, `execution_time` | **784.8 s** | **749.4 s** | **87.3 s** | **75.8 s** | **9.4×** |
| whole invocation, wall clock | 944 s | 877 s | 168 s | 143 s | **5.9×** |
| node ids allocated by the test proof | 89 | 89 | 4 | 4 | — |
| `proof.json` | 22.53 MB | 22.53 MB | 0.91 MB | 0.92 MB | **24×** |
| rewrite-log entries stored | 150,180 | 150,180 | 6,096 | 6,126 | **25×** |
| final KCFG | \*| \* | \* | \* | identical |
| verdict | PASSED | PASSED | PASSED | PASSED | identical |

\* all four: 4 nodes, edges of depth 363 and 3270.

The structural columns are **exactly** reproducible across runs (89/89 vs 4/4 allocations,
22.53 MB vs 0.91 MB) — only the timings carry machine noise, and they agree to within 5%.

The "node ids allocated" row is the direct measurement of §1's round-trip count: the KCFG's
`next` counter went from 13 to 102 in arm A (89 nodes created) but only from 5 to 9 in arm B
(4 created). Arm A made roughly **89 backend `execute` calls to cover 3270 EVM steps** — about
37 steps per round trip, i.e. basic-block granularity — and then `optimize-kcfg` deleted 88 of
the 89 nodes, leaving the *same* two-edge KCFG that arm B produced in 4 calls.

So the cost of `break-on-basic-blocks` here is not "extra nodes" (there are none at the end);
it is **~85 redundant round trips, each serializing and deserializing a ~140 KB configuration
and each triggering a post-execution simplification pass.** That is the 9×.

**A second, compounding cost showed up in the on-disk artefacts.** The two arms' proof
directories:

| | arm A | arm B |
|---|---|---|
| proof directory total | **23 MB** | 2.0 MB |
| `proof.json` | **22.5 MB** | 0.91 MB |
| rewrite-log entries stored in it | **150,180** (87 nodes) | 6,096 (2 nodes) |
| `kcfg/kcfg.json` | 602 KB | 608 KB |
| `kcfg/nodes/` (4 surviving files) | 484 KB | 484 KB |

Those 150,180 entries are the `log-successful-rewrites` trace (§1d) — one per applied rewrite
rule, kept because `log_succ_rewrites` defaults to `True`. With `maintenance-rate = 1` that
22.5 MB file is rewritten on every one of the ~89 iterations. **So arm A also wrote roughly a
gigabyte to disk for a proof whose useful output is 484 KB of nodes.** Turning the break flags
off shrinks this 25× on its own; adding `log-rewrites = false` removes the remainder.

Caveats, stated plainly:

* **One test.** Two repetitions per arm, and the structural columns are exactly reproducible,
  so the effect is not noise — but the *multiplier* will vary by proof. Expect the largest
  gains on straight-line arithmetic proofs (`PiecewiseLinearScale` value properties,
  `XYCSwap`) and smaller ones on branch-dominated proofs, where the branch count forces round
  trips regardless of the flags.
* **The box was contended** (load average 12–22 on 16 cores) by other agents' proofs
  throughout. That inflates all absolute numbers — the same `setUp()` costs 47–55 s in the
  shared store — but the arms were interleaved, so the ratio is not an artefact of it.
* **The `setUp()` row is a second, independent instance of the same effect** (2.0×), not a
  controlled variable: both arms proved `setUp()` under the same config difference.
* **This says nothing about correctness.** All four runs produced the same KCFG and the same
  verdict, which is exactly what should happen: cut-point rules change *where the prover stops
  to save state*, not what it computes.
* **Someone rebuilt the shared definition mid-experiment.** `out/kompiled/*` was rewritten at
  22:44–22:47 and `out/digest` at 22:58 — between run 1 (A 22:23–22:39, B 22:39–22:42) and
  runs 2 (A 22:41–22:56, B 22:56–22:59), by another agent, not by anything in this section.
  The experiment root symlinks `out/kompiled`, so runs 2 used the *new* definition. That the
  structural counters came out identical across the boundary (89/89 and 4/4 allocations,
  22.53 MB twice, 150,180 log entries twice) is reassuring but was luck, not design. **If you
  repeat this, check `ls -la out/kompiled/timestamp` before and after** — a mid-run rebuild
  can also invalidate a proof you are in the middle of.

**Independent confirmation that `--lemmas` works without a rebuild.** Also verified on this
machine: a rule-only module loaded at prove time via `add-module` and applied to a real node.

```
# module must have NO `requires` line (the include dir holds only the compiled
# definition, so `requires "kontrol.md"` fails with `Could not find file: kontrol.md`)
cat > lemmas-wip.k <<'EOF'
module SWAPVM-LEMMAS-WIP
    imports KONTROL-MAIN
    rule [wip-probe-add-zero]: X +Int 0 => X [simplification]
endmodule
EOF

kontrol simplify-node --lemmas lemmas-wip.k:SWAPVM-LEMMAS-WIP 'XYCSwapSpec.setUp()' 12 --version 0
```

This ran to completion and printed the simplified term. No `kontrol build`, no `--rekompile`,
no effect on the shared definition. The one gotcha is the `requires` line: `load_lemmas` invokes
`kprove <file> --definition out/kompiled -I <kdist>/kontrol/base --dry-run --allow-rules`, and
that include directory contains only the *compiled* definition — no `.md` sources — so any
`requires` in the WIP module fails to resolve. Import `KONTROL-MAIN` (as `--help` says) and
omit `requires` entirely.

---

## CORRECTION (verified against a real node)

Two claims in this document were too strong and were corrected by a later run:

1. **`merge-nodes` does NOT require re-running with `--break-on-jumpi` and
   `optimize-kcfg = false`.** Branch nodes at a `JUMPI` survive `optimize-kcfg = true` with
   all break flags off, because `optimize-kcfg` merges *linear chains*, not splits. A loop-head
   node was dumped from `PowerSpec.test_witness_decayStaysZeroAfterCollapse:0` node 26 matching
   `is_loop` exactly, produced under the fast config. The entry cost estimated here was too
   pessimistic — `merge-nodes` on a loop head is available today.

2. **`--bmc-depth` is more useful than "it bounds the trip count, which is not the problem"
   suggests.** BMC also terminates exploration of the *branch tree*, which is what makes the
   `uint8`/`uint16`-exponent properties reachable. `decayStaysZero` was converging normally at
   146 nodes with `bounded: 0` when its run was stopped.

Also confirmed here: **a `kontrol prove` launched with `nohup … &` inside a tool call is
SIGKILLed when that call returns** — the log ends in a bare `Killed`, which reads exactly like
an OOM and is not one. Use `setsid nohup … & disown`.

## HANDOFF

### Top 5 changes, ranked by expected speedup

**1. Turn off `--break-on-basic-blocks` / `--break-on-calls` and raise `--max-depth`.**

*Measured over two runs per arm: **9.4×** on the proof's own execution time, **5.9×** on wall
clock, **24×** on proof-directory size, with an identical resulting KCFG and the same PASSED
verdict every time (§10.2).* This is by a wide margin the biggest win on this list and it is a
three-line change to `kontrol.toml`.

*Evidence.* Cut-point rules make the backend return early, so each basic block becomes its own
`execute` round trip carrying a 140–250 KB configuration in each direction (§1). We then delete
every node those round trips produced, because `optimize-kcfg = true` merges consecutive edges
on the fly (`$K/pyk/kcfg/kcfg.py:589-601`). The proof store proves the deletion is happening:
`test_value_scaleNeverExpands` has two edges of depth 421 and 1207 and
`test_exactIn_constantProductNeverDecreases` has one of depth 3319, all far beyond a basic
block and beyond `max-depth = 2000`. The stated goals in the `kontrol.toml` comment —
"`kontrol list` node counts become a live progress signal" and "a crash costs one small node" —
are not being achieved by these settings. The A/B in §10.2 measures the waste directly: the
same proof allocated **89** node ids under the current settings and **4** under the proposed
ones, and ended with the *same* two-edge KCFG either way.

*Keep the capability, on demand:* `kontrol section-edge <test> <edge> --sections N` cuts a long
edge into intermediate nodes after the fact, and a `[prove.inspect]` profile can turn the break
flags on (with `optimize-kcfg = false`) for one stuck proof.

**2. Adopt `--optimize-performance N` (or its pieces), and fix the core accounting.**

*Expected:* large, and it is one flag. Two of its components are measured below.

*Evidence.* `$K/kontrol/options.py:440-449` sets, in one go: `log_succ_rewrites = False`
(**measured: 150,180 rewrite-log entries and a 22.5 MB `proof.json` for a 4-node proof, §10.2**),
`maintenance_rate = 64` (**that 22.5 MB file is rewritten on every iteration at the default
rate of 1 — order of a gigabyte of writes for one proof**),
`smt_timeout = 120000` with `smt_retry_limit = 0` (see #3), `max_depth = 100000`,
`max_iterations = 10000`, `stack_checks = False` (we already have this), `assume_defined = True`.
Crucially it also sets `max_frontier_parallel = N`, and `max_frontier_parallel` is what sets the
server's `GHCRTS=-N` (`$K/kontrol/prove.py:359` → `$K/pyk/kore/rpc.py:1322-1330`). **Today every
one of our `kore-rpc-booster` processes runs with a single Haskell capability**, so
`workers = 4` uses at most 4 of 16 cores.

*Caveats:* it does **not** turn off the break flags, so #1 is still needed. `assume_defined` is
marked experimental, and buys us little because we barely issue `implies` requests (§1a) — drop
it if it misbehaves. If you prefer the pieces to the bundle, the TOML is:

```toml
log-rewrites          = false   # NOT `no-log-rewrites = true` — that key silently does nothing
maintenance-rate      = 16
max-frontier-parallel = 4
max-depth             = 100000
smt-timeout           = 120000
smt-retry-limit       = 0
```

**3. Fix the SMT retry ladder.**

*Expected:* removes a class of unbounded stalls; small on healthy proofs, unbounded on sick ones.

*Evidence.* We set `smt-timeout = 5000` and left `smt-retry-limit` at its default of **10**
(`$K/pyk/cli/args.py:293-304`), and retries use a *scaling* timeout. A single undecidable
query — exactly what a symbolic `DIV` or a symbolic square produces — therefore consumes
5 s + 10 s + 20 s + … before returning `Unknown`, after which the booster typically aborts the
step and Kore re-runs it. That is the mechanism behind "a symbolic `DIV` stalls the proof
indefinitely" with nothing visibly hung. kontrol#716 reached the same conclusion upstream
("only retry a Z3 query once with the doubled initial timeout and a very high initial
timeout"), and `--optimize-performance` encodes it as `120000 / 0`.

Also worth one experiment on a PeggedSwap Group-B property:
`--smt-tactic '(check-sat-using qfnra-nlsat)'`.

**4. Stop invalidating proofs: split the spec files and use `--setup-version`.**

*Expected:* eliminates repeated work rather than making work faster — but ~600 s of the 10,017 s
spent so far is re-run `setUp()`, and an unknown but larger amount is re-proved properties.

*Evidence.* `Contract.Method.digest` includes `contract_digest`, the hash of the entire contract
JSON (`$K/kontrol/solc_to_k.py:642-646` and `:843-845`). Adding one property to a spec file
therefore changes the digest of **every** test method in that file, and
`resolve_proof_version` allocates a fresh version for each. The store shows the damage:
`XYCSwapSpec.setUp()` at versions 0,1,2,3,5; `test_exactIn_cannotDrainPool` at 0,1,2,3,4;
`test_exactIn_roundsInFavourOfMaker` at 0,1,2,3. Of the 831.5 s spent on `setUp()` proofs,
**~484 s is superseded versions** (§10.1). `setUp()` is exempt from `contract_digest`
(`if not self.is_setup else {}`), so `--setup-version N` genuinely can reuse it.

Actions: one contract per property group; freeze a spec file before starting long proofs on it;
pass `--setup-version`; and when a lemma is added, prefer `kontrol remove-node <test> <id>`
followed by a plain resume over `--reinit`.

**5. Attack path explosion with `merge-nodes`, and stop expecting `--cse` to help.**

*Expected:* the only thing that touches the 2^28 / 2^16 problems at all.

*Evidence for merging:* `foundry_merge_nodes` (`$K/kontrol/foundry.py:1222-1267`) anti-unifies
the selected nodes and covers the originals, so the frontier collapses to one node and
exploration continues. Its preconditions (`K_CELL`, `PROGRAM_CELL`, `PC_CELL`, `CALLDEPTH_CELL`
equal, or `same_loop`) are satisfied exactly at a `Math.sqrt` return and at a `Power.pow` loop
head. The measured shape of `PeggedSwapSpec.test_bothBalancesZeroGuardFiresWhenBothZero(...):1`
— 128 nodes, 31 splits, 2084 s — is 2^7, the MSB cascade, and is what merging is for. The
honest cost: `anti_unify(keep_values=True)` preserves the discarded facts as a pairwise-built
disjunction (`$K/pyk/cterm/cterm.py:215-227`), so merging 128 nodes yields one node with a
128-way disjunctive path condition. Right trade for PeggedSwap **Group D** (discharged from the
path condition alone); wrong trade for **Group E** (needs sqrt-value reasoning).

*Evidence against CSE:* `find_function_calls` (`$K/kontrol/solc_to_k.py:1121-1147`) only sees
external calls through a `MemberAccess` on a contract-typed receiver. `Math.mulDiv` and
`Math.sqrt` are internal library functions that solc inlines; CSE cannot see them at all. The
suggestion in `FINDINGS.md` that `cse = true` might summarise `mulDiv`/`sqrt` will not work as
written — it would require promoting them to `external` on a wrapper contract first, at which
point you have built the abstraction seam anyway and should just assume the characterising
axioms.

*Bonus, and possibly the best ROI on this list:* `--lemmas <file>:<MODULE>` adds
`[simplification]` rules to a **running** server via `add-module`
(`$K/kontrol/foundry.py:654-668` → `$K/kevm_pyk/utils.py:400` → `$K/pyk/kore/rpc.py:1200`), with
no `kontrol build` and no `--rekompile`. **Verified end to end on this machine** (§10.2): a
rule-only module loaded and applied to a real node. Given the standing prohibition on
rebuilding the shared definition, this is the difference between a lemma-iteration loop
measured in minutes and one that is blocked entirely. Pair it with `--haskell-log-dir` (§2.3)
to see whether a rule is attempted and whether it fires, which is precisely what
`PROOF-MAP.md` blockers 2 and 3 ask for. The one gotcha: the WIP module must have **no
`requires` line** and must `imports KONTROL-MAIN`.

### What in `kontrol.toml` is actively hurting us

| line | verdict |
|---|---|
| `break-on-basic-blocks = true` + `break-on-calls = true` | **Hurting most.** Measured **9.4×** on one proof, two runs per arm (§10.2): a round trip per basic block, for nodes that `optimize-kcfg` then deletes. Set both false; keep a `[prove.inspect]` profile for when you need nodes. Note there is **no `--no-break-on-basic-blocks` CLI flag**, so this can only be undone by editing the TOML or pointing `--config-file` elsewhere. |
| `max-depth = 2000` | **Hurting**, in combination with the above. Raise to 100000. |
| `optimize-kcfg = true` | **Fine on its own, self-defeating in combination.** It is the right default *without* the break flags. With them, the file's stated goals (progress signal, small crash cost) are not met. Pick one or the other, not both. |
| `smt-timeout = 5000` with `smt-retry-limit` unset (=10) | **Hurting.** Scaling retry ladder on undecidable goals. Use `120000` / `0`. |
| `workers = 4` with `max-frontier-parallel` unset (=1) | **Hurting.** Each server gets `GHCRTS=-N1`; we use ≤4 of 16 cores. Set `max-frontier-parallel = 4`, and coordinate the box-wide total with the other agents. |
| `log-rewrites` unset (=true) | **Hurting, measurably.** Every `execute` returns a log entry per applied rewrite rule and `APRProof` stores them: **22.5 MB / 150,180 entries of `proof.json` for a 4-node proof** (§10.2). Add `log-rewrites = false`. Do **not** write `no-log-rewrites = true` — verified to resolve to an attribute nothing reads. |
| `maintenance-rate` unset (=1) | **Hurting, and it multiplies the row above.** That 22.5 MB `proof.json` plus a 0.6 MB `kcfg.json` is rewritten *every iteration* — ~1 GB of disk writes for one proof. 8–16 keeps most of the crash resilience the file's comment is after. |
| `fail-fast = false` | **Deliberate and defensible while writing specs; hurting on re-proof runs.** Flip it per profile. |
| `counterexample-information = true` | **Fine, but** it runs a `get-model` per failing node. Add `--no-counterexample-information` when triaging a 128-leaf failure. |
| `cse = false` | **Correct.** Leave it. See §4. |
| `minimize-proofs = false` | **Correct** (it is post-hoc only). Consider `kontrol minimize-proof <test> --merge` manually after wide proofs. |
| `no-stack-checks = true`, `run-constructor = false`, `schedule = 'CANCUN'`, `o2 = true` | **Correct. Do not change.** |
| the whole `[build.default]` section | **Frozen.** `build-options` is `hash_str(str(options))` over *all* build options, so changing even `verbose` forces a rekompile of the shared definition. |

### Drop-in `[prove.*]` replacement

Two profiles, so the inspection capability the current file is trying to buy is available on
demand rather than paid for on every run. `[build.default]` is untouched — do not edit it.

```toml
[prove.default]                        # fast: use this for everything by default
foundry-project-root       = '.'
schedule                   = 'CANCUN'   # keep in sync with foundry.toml evm_version
reinit                     = false
cse                        = false      # see PERFORMANCE.md §4 — CSE cannot see inlined
                                        # internal library calls, and it crashes on any
                                        # callee with a bytes/string/array/struct parameter
run-constructor            = false
no-stack-checks            = true

# round trips: the dominant cost. Measured 9.0x on
# XYCSwapSpec.test_exactIn_zeroInputYieldsZeroOutput (PERFORMANCE.md §10.2).
max-depth                  = 100000
break-on-basic-blocks      = false
break-on-calls             = false
optimize-kcfg              = true

# payload per round trip
log-rewrites               = false      # NB: `no-log-rewrites = true` silently does nothing
maintenance-rate           = 16         # crash discards <=16 iterations

# SMT: one long attempt, not a scaling retry ladder
smt-timeout                = 120000
smt-retry-limit            = 0

# cores: total rewriting parallelism is workers x max-frontier-parallel,
# because each server is started with GHCRTS=-N<max-frontier-parallel>.
# Coordinate the box-wide sum with the other agents; 16 cores total.
workers                    = 4
max-frontier-parallel      = 4

failure-information        = true
counterexample-information = true
fail-fast                  = false      # true once a spec is stable and you are re-proving
minimize-proofs            = false

[prove.inspect]                        # slow: only when you need nodes at specific places
# inherits [prove.default]; overrides below
max-depth                  = 200
break-on-basic-blocks      = true
break-on-calls             = true
optimize-kcfg              = false      # otherwise the nodes you asked for are deleted again
workers                    = 1
max-frontier-parallel      = 1
```

Select with `--config-profile inspect`. Profile inheritance from `[prove.default]` is real
(`$K/pyk/cli/pyk.py:601-608`), so `[prove.inspect]` only needs the deltas.

### Questions I could not resolve

1. **Why does `test_value_scaleNeverExpands` need 2219 s for 1628 rewrite steps?** That is
   ~1.4 s per EVM step against ~0.1 s/step on comparable proofs, in a 4-node KCFG with no
   splits. It is either a specific lemma looping (visible as `EquationWarnings` /
   `DebugAttemptEquation` churn) or one very expensive SMT query in the middle of the second
   edge. §2.3 would answer it in one `--max-iterations`-bounded run; I did not spend the box
   time on it.
2. ~~Does `--kore-rpc-command` composition work?~~ **Resolved** — verified directly (§2.2):
   `kore-rpc-booster` accepts flags before the positional definition file and rejects unknown
   ones loudly. The remaining unknown is the *effect*, not the plumbing.
3. **Is dropping `Branching` from `--fallback-on` sound for us?** RV's default re-executes
   every branching request with Kore to check the booster's answer, and Kontrol deliberately
   does not expose the flag. The speedup could be large for our branch-heavy proofs; I cannot
   certify the soundness trade from the documentation available.
4. **Does a `--lemmas` module get *priority* over the compiled-in `SWAPVM-LEMMAS` rules?**
   Loading works (verified), but `add-module` rules and compiled-in `[simplification]` rules
   presumably share a priority space, so a WIP rule that overlaps a compiled-in one may or may
   not win. If you promote a rule from the WIP file into `lemmas.k`, re-measure rather than
   assuming the behaviour carries over.
5. **What exactly did the `--cse` failure print for us?** My reproduction is analytic — I
   confirmed `'function (bytes calldata) view returns (uint256)'.split()[1] == '(bytes'` and
   traced the resulting string through `matching_tests` to a `ValueError: Test identifiers not
   found`. If the failure you actually saw was a `re.error` rather than a `ValueError`, there
   is a second defect and it should be captured verbatim before filing upstream.
6. **Whether the box has ever leaked a *live* orphaned `kore-rpc-booster`.** None present now
   (checked: no non-zombie `kore-rpc*` with `PPID 1`), but 158 zombies means processes are being
   killed hard, and a live orphan would cost 1–2 GB silently. Worth a periodic check rather
   than a one-off.

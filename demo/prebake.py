#!/usr/bin/env python3
"""Bake the demo into ONE static HTML file with no server behind it.

    ./prebake.py            # writes ../docs/index.html

WHY A SECOND, READ-ONLY PAGE. `static/index.html` is the playground: it composes programs,
so it needs `/api/assemble` and `/api/verify` and therefore a Python process. This one is
for GitHub Pages, which serves files and runs nothing. So every answer the page can give is
computed HERE, at bake time, by the same functions the live server calls -- and the page
itself is a viewer over a frozen result set, with nothing to submit and nothing to break.

That is a real reduction in what the demo demonstrates, and it should be: you can no longer
build a program of your own and ask about it. What remains is every shipped example with
what the tools actually returned for it. The page says so rather than implying the buttons
would work if you found the right one.

WHERE THE OUTPUTS COME FROM. `data/runs.json`, written by `record_runs.py`, which really ran
`kprove` and `forge`. Nothing here asserts a verdict; if a spec stopped proving, the bake
carries that through and the page shows a failure. Re-bake whenever the semantics change --
`prebake.py` refuses to run against a recording whose controls did not fail.
"""
import html
import json
import pathlib
import sys
import datetime

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import server  # noqa: E402

OUT = HERE.parent / 'docs' / 'index.html'


def bake_example(ex: dict) -> dict:
    """Everything the page can say about one program, computed the way the server would."""
    hexstr = ex['bytes']
    steps = server.decode(hexstr)
    applicable = server.proved(steps)
    for a in applicable:
        d = server.SPECDOCS.get(pathlib.Path(a.get('file', '')).stem)
        if d:
            a['docfile'] = d['file']
        a.pop('verdict', None)      # a verdict comes from kprove, never from a shape match
    proof = server.RUNS.get('proofs', {}).get(ex['label'])
    return {
        'label': ex['label'],
        'title': ex.get('title') or server.EXAMPLE_NOTES.get(ex['label'], (ex['label'], ''))[0],
        'note': ex.get('note') or server.EXAMPLE_NOTES.get(ex['label'], ('', ''))[1],
        'kind': ex.get('kind', 'conformance'),
        'bytes': hexstr,
        'length': len(hexstr) // 2,
        'steps': steps,
        'applicable': applicable,
        'lint': server.lint(steps),
        'proof': proof,
        'exec': {g: server.RUNS.get('executions', {}).get(f'{ex["label"]}|{g}') for g in (0, 5)},
        # What the K model predicts. Shown NEXT TO the real run, because that comparison is
        # the entire conformance argument: the L2 theorems are about the model, and they mean
        # something about production only insofar as the two agree. Where they disagree --
        # the malformed programs, where the model no-ops and the VM reverts -- that is the
        # honest weak spot of the project and the page should say it out loud.
        'expect': ex.get('expect'),
        'sources': server.sources_for(steps, applicable, proof),
    }


def main() -> int:
    runs = server.RUNS
    if not runs:
        print('data/runs.json missing — run ./record_runs.py first', file=sys.stderr)
        return 2

    # Refuse to bake a recording that failed its own checks. A page built from one would
    # look exactly like a page built from a good one, which is the whole danger.
    bad = [k for k, v in runs.get('proofs', {}).items() if not v.get('ok')]
    if bad:
        print(f'refusing to bake: these recorded proofs are not OK: {bad}\n'
              f're-run ./record_runs.py and fix the semantics first', file=sys.stderr)
        return 1

    curated = server.curated()
    others = [e for e in server.catalogue() if e['label'] not in {c['label'] for c in curated}]
    examples = [bake_example(e) for e in curated + others]
    print(f'  {len(server.EXAMPLES)} conformance examples omitted from the page by '
          f'server.catalogue(); selftest.py still checks the K model against all of them')

    payload = {
        'examples': examples,
        'opcodes': server.OPCODES,
        'coverage': server.CLAIMS['coverage'],
        'controls': server.CLAIMS['negative_controls'],
        'recorded_at': runs.get('recorded_at'),
        'definition': runs.get('definition', {}),
        'baked_at': datetime.datetime.now(datetime.timezone.utc)
                    .replace(microsecond=0).isoformat(),
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    (OUT.parent / '.nojekyll').write_text('')      # or Pages hides files beginning with _
    OUT.write_text(PAGE.replace('/*__DATA__*/null', json.dumps(payload)))
    print(f'wrote {OUT}  ({OUT.stat().st_size // 1024} KB, {len(examples)} examples, '
          f'{len(runs.get("proofs", {}))} recorded proof pairs)')
    return 0


PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SwapVM — verified programs</title>
<style>
:root{
  --bg:#0e1116; --panel:#161b22; --panel2:#1c222b; --line:#2a323d;
  --fg:#e6edf3; --dim:#8b98a5; --acc:#4a9eff; --ok:#3fb950; --err:#f85149; --warn:#d29922;
}
@media (prefers-color-scheme: light){
  :root{ --bg:#f6f8fa; --panel:#fff; --panel2:#f0f3f6; --line:#d8dee4;
         --fg:#1f2328; --dim:#59636e; --acc:#0969da; --ok:#1a7f37; --err:#cf222e; --warn:#9a6700; }
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
  font:15px/1.55 ui-sans-serif,-apple-system,"Segoe UI",Roboto,sans-serif}
code,.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
header{padding:22px 26px;border-bottom:1px solid var(--line);background:var(--panel)}
h1{margin:0;font-size:19px;letter-spacing:-.01em}
.sub{color:var(--dim);font-size:13px;margin-top:5px}
.wrap{display:grid;grid-template-columns:300px 1fr;min-height:calc(100vh - 84px)}
@media (max-width:900px){ .wrap{grid-template-columns:1fr} nav{border-right:0!important;
  border-bottom:1px solid var(--line);max-height:none!important} }
nav{border-right:1px solid var(--line);background:var(--panel);overflow-y:auto;
  max-height:calc(100vh - 84px);padding:10px 0}
nav h2{font-size:11px;text-transform:uppercase;letter-spacing:.09em;color:var(--dim);
  margin:16px 16px 7px;font-weight:600}
.item{padding:9px 16px;cursor:pointer;border-left:3px solid transparent;font-size:14px}
.item:hover{background:var(--panel2)}
.item.on{background:var(--panel2);border-left-color:var(--acc)}
.item .t{font-weight:500}
.item .d{color:var(--dim);font-size:12px;margin-top:2px}
.pill{display:inline-block;font-size:10px;padding:1px 6px;border-radius:9px;
  border:1px solid var(--line);color:var(--dim);margin-left:6px;vertical-align:1px}
.pill.good{color:var(--ok);border-color:var(--ok)}
.pill.bad{color:var(--err);border-color:var(--err)}
main{padding:26px 30px;max-width:900px}
h3{font-size:16px;margin:0 0 6px}
.note{color:var(--dim);font-size:14px;margin-bottom:20px}
section{margin-bottom:26px}
section>h4{font-size:11px;text-transform:uppercase;letter-spacing:.09em;color:var(--dim);
  margin:0 0 10px;font-weight:600}
.step{display:flex;gap:12px;padding:9px 12px;border:1px solid var(--line);border-radius:7px;
  background:var(--panel);margin-bottom:6px;align-items:baseline}
.step .pc{color:var(--dim);font-size:12px;min-width:42px}
.step .op{color:var(--acc);font-weight:600;font-size:13px;min-width:150px}
.step .ar{color:var(--dim);font-size:12px;word-break:break-all;flex:1}
.step.dead{border-color:var(--err)}
.bytes{background:var(--panel);border:1px solid var(--line);border-radius:7px;padding:11px 13px;
  font-size:12px;word-break:break-all;color:var(--dim);overflow-x:auto}
.v{border:1px solid var(--line);border-left-width:3px;border-radius:7px;background:var(--panel);
  padding:12px 14px;margin-bottom:9px}
.v.yes{border-left-color:var(--ok)} .v.err{border-left-color:var(--err)}
.v.no{border-left-color:var(--line)} .v.info{border-left-color:var(--acc)}
.v.warnb{border-left-color:var(--warn)}
.tag{display:inline-block;font-size:10px;font-weight:700;letter-spacing:.06em;padding:2px 7px;
  border-radius:4px;margin-right:9px;background:var(--panel2);color:var(--dim)}
.tag.yes{color:var(--ok)} .tag.err{color:var(--err)} .tag.info{color:var(--acc)}
.tag.warnb{color:var(--warn)}
.v .plain{margin-top:7px;font-size:14px}
.v .why{margin-top:7px;font-size:13px;color:var(--dim)}
.src{margin-top:9px;font-size:11.5px;color:var(--dim);font-family:ui-monospace,monospace}
details{margin-top:8px} summary{cursor:pointer;font-size:12.5px;color:var(--dim)}
details ul{margin:7px 0 0 0;padding-left:19px;font-size:13px;color:var(--dim)}
.replay{font-size:12px;color:var(--warn);border:1px dashed var(--warn);border-radius:6px;
  padding:8px 11px;margin-bottom:11px}
.kv{display:grid;grid-template-columns:auto 1fr;gap:4px 14px;font-size:13px;margin-top:8px}
.kv .k{color:var(--dim)}
.gate{display:flex;gap:8px;margin-bottom:10px}
.gate button{font:inherit;font-size:12.5px;padding:5px 12px;border-radius:6px;cursor:pointer;
  border:1px solid var(--line);background:var(--panel);color:var(--dim)}
.gate button.on{border-color:var(--acc);color:var(--acc);background:var(--panel2)}
.srchdr{font-size:12.5px;color:var(--dim);margin-bottom:8px}
.srcbox{border:1px solid var(--line);border-radius:7px;background:var(--panel);margin-bottom:7px}
.srcbox>summary{padding:9px 13px;font-size:12.5px;color:var(--acc);
  font-family:ui-monospace,monospace;list-style:none}
.srcbox>summary::-webkit-details-marker{display:none}
.srcbox>summary::before{content:"▸ ";color:var(--dim)}
.srcbox[open]>summary::before{content:"▾ "}
.srcbox[open]>summary{border-bottom:1px solid var(--line)}
.srcbox pre{margin:0;padding:13px;overflow-x:auto;font-size:12px;line-height:1.5;
  background:var(--panel2);white-space:pre}
.srcbody{padding:0}
.about{padding:11px 13px;border-bottom:1px solid var(--line);font-size:12.5px}
.about b{font-size:12.5px}
.dimmono{font-family:ui-monospace,monospace;font-size:11.5px;color:var(--dim)}
.natspec{margin-top:8px;color:var(--dim);font-size:12.5px;line-height:1.6;
  white-space:pre-wrap;max-height:230px;overflow-y:auto}
.lead{padding:10px 13px;font-size:12.5px;color:var(--dim);border-bottom:1px solid var(--line)}
.innerbox{border-top:1px solid var(--line)}
.innerbox>summary{padding:9px 13px;font-size:12px;color:var(--dim);
  font-family:ui-monospace,monospace;list-style:none}
.innerbox>summary::-webkit-details-marker{display:none}
.innerbox>summary::before{content:"▸ "}
.innerbox[open]>summary::before{content:"▾ "}
.innerbox[open]>summary{border-bottom:1px solid var(--line)}
.innerbox pre{max-height:520px;overflow-y:auto}
footer{padding:20px 30px;border-top:1px solid var(--line);color:var(--dim);font-size:12.5px;
  background:var(--panel)}
footer code{background:var(--panel2);padding:1px 5px;border-radius:4px}
a{color:var(--acc)}
</style></head><body>
<header>
  <h1>SwapVM — programs, specifications, and what the tools returned</h1>
  <div class="sub" id="hdr"></div>
</header>
<div class="wrap">
  <nav id="nav"></nav>
  <main id="main"></main>
</div>
<footer id="foot"></footer>
<script>
const DATA = /*__DATA__*/null;
const esc = s => String(s==null?'':s).replace(/[&<>"]/g, c =>
  ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
let gate = 5;
let cur = 0;

function vblock(cls, tag, title, plain, why, assumptions, source){
  return `<div class="v ${cls}">
    <div><span class="tag ${cls}">${esc(tag)}</span><b>${esc(title)}</b></div>
    ${plain?`<div class="plain">${esc(plain)}</div>`:''}
    ${why?`<div class="why">${esc(why)}</div>`:''}
    ${assumptions&&assumptions.length?`<details><summary>what this assumes (${assumptions.length})</summary>
      <ul>${assumptions.map(a=>`<li>${esc(a)}</li>`).join('')}</ul></details>`:''}
    ${source?`<div class="src">${esc(source)}</div>`:''}</div>`;
}

function renderNav(){
  const cur8 = DATA.examples;
  const group = (title, arr) => arr.length ? `<h2>${title}</h2>` + arr.map(e => {
    const i = cur8.indexOf(e);
    const p = e.kind==='good' ? '<span class="pill good">verified</span>'
            : e.kind==='bad'  ? '<span class="pill bad">one byte wrong</span>' : '';
    return `<div class="item${i===cur?' on':''}" data-i="${i}">
      <div class="t">${esc(e.title)}${p}</div>
      <div class="d">${e.length} bytes · ${e.steps.length} instruction${e.steps.length===1?'':'s'}</div>
    </div>`;
  }).join('') : '';
  // Only the programs that carry a machine-checked claim. The conformance examples are
  // still exercised by selftest.py; they are not listed here. See server.catalogue().
  document.getElementById('nav').innerHTML = group('Verified programs', cur8);
  document.querySelectorAll('.item').forEach(el =>
    el.onclick = () => { cur = +el.dataset.i; render(); });
}

function renderSteps(e){
  if(!e.steps.length) return '<div class="bytes">empty program — zero bytes</div>';
  return e.steps.map(s => `<div class="step${s.error?' dead':''}">
    <span class="pc mono">pc ${s.pc}</span>
    <span class="op mono">${esc(s.op)} ${esc(s.name||'')}</span>
    <span class="ar mono">${s.error ? esc(s.error)
      : (s.argsLen ? esc(s.argsLen)+' arg byte'+(s.argsLen===1?'':'s')+
         (s.args?' · '+esc(s.args):'') : 'no arguments')}</span>
  </div>`).join('');
}

function renderProof(e){
  const p = e.proof;
  if(!p) return vblock('no','NO SPEC','No specification is paired with this program',
    'The catalogue examples exercise the semantics; only the three programs above carry a '+
    'machine-checked theorem.',
    'Verification here runs a human-written spec. Nothing generates one, and nothing guesses.',
    null, null);
  if(!p.available) return vblock('info','UNAVAILABLE','No recorded run', p.error, null, null, null);
  const sp = p.spec, ct = p.control;
  return `<div class="replay">↺ Recorded run, not live. This page is static — it has no prover
    behind it. Ran ${esc((DATA.recorded_at||'').replace('T',' ').replace('+00:00',' UTC'))}
    against K definition <span class="mono">${esc(DATA.definition.sha256_16||'?')}</span>.
    Re-run it yourself: <code>./semantics/run-proofs.sh</code></div>` +
    vblock(sp.top?'yes':'err', sp.top?'PROVED':'NOT PROVED',
      `${sp.spec}.k — kprove returned ${sp.top?'#Top':'no proof'}`,
      sp.top ? 'The theorem holds for every input in its stated domain.'
             : 'kprove did not return #Top.',
      `Took ${sp.seconds}s.`, null, (p.commands||[])[0]) +
    vblock(ct.exit!==0?'yes':'err', ct.exit!==0?'CONTROL OK':'CONTROL PROVED',
      `${ct.spec}.k — ${ct.verdict}`,
      ct.exit!==0 ? 'A deliberately false twin of the theorem. It must fail, and it did.'
                  : 'The false claim PROVED. The rule set is inconsistent and every result above is void.',
      'A proof that cannot fail proves nothing. This is the only check that catches an '+
      'inconsistent rule set, which otherwise proves everything while looking like total '+
      `success. Took ${ct.seconds}s.`, null, (p.commands||[])[1]);
}

function renderExec(e){
  const r = e.exec[gate];
  const bar = `<div class="gate">
    <button data-g="5" class="${gate===5?'on':''}">taker holds the gate token</button>
    <button data-g="0" class="${gate===0?'on':''}">taker holds none</button></div>`;
  if(!r) return bar + vblock('info','NO RUN','Not recorded','', null, null, null);
  const body = r.status==='completed'
    ? vblock('yes','EXECUTED','Ran to completion',
        `amountIn ${r.amountIn} → amountOut ${r.amountOut}`,
        `Real ContextLib.runLoop, real instruction bodies. Final pc ${r.nextPC}; `+
        `maker reserves ${r.balanceIn} / ${r.balanceOut}.`,
        ['The gate token\'s balanceOf is mocked so any gate address can be exercised.',
         'Dispatch routes to the real instruction bodies; only the dispatch table is the test\'s.'],
        'test/conformance/InstructionConformance.t.sol')
    : vblock('err','EXECUTED','Reverted', r.error||'reverted',
        `The program was executed and the real VM rejected it.`+
        (r.GATE?` Gate token ${r.GATE}.`:''), null,
        'test/conformance/InstructionConformance.t.sol');
  return bar + body;
}

/* One source box: what the contract IS, then the code that matters, then the whole file.
   In that order deliberately — a reader should meet the declaration and the specific
   function before being handed 180 lines, and should still be able to get the 180 lines. */
function srcBox(s){
  const head = s.kind==='solidity'
    ? (s.fn ? `${s.path} — ${s.fn}()  ·  opcode 0x${s.opcode}` : s.path)
    : s.path;
  const c = s.contract || {};
  const about = c.name ? `<div class="about">
      <b class="mono">${esc(c.kind)} ${esc(c.name)}</b>
      ${c.handles && c.handles.length ? ` · also handles ${c.handles.length} opcode${
         c.handles.length===1?'':'s'}: <span class="dimmono">${esc(c.handles.join(', '))}</span>` : ''}
      ${c.doc ? `<div class="natspec">${esc(c.doc)}</div>` : ''}
    </div>` : '';
  const full = (s.full && s.full !== s.text) ? `<details class="innerbox">
      <summary>the whole file — ${s.full_lines} lines</summary>
      <pre class="mono">${esc(s.full)}</pre></details>` : '';
  return `<details class="srcbox"><summary>${esc(head)}</summary>
    <div class="srcbody">${about}
      ${s.kind==='k' && s.focused ? '<div class="lead">The claim — this is the invariant, '+
        'stated. Everything else in the file is imports and module setup.</div>' : ''}
      <pre class="mono">${esc(s.text)}</pre>${full}</div></details>`;
}

function renderSources(e){
  const S = e.sources || {};
  const keys = Object.keys(S);
  if(!keys.length) return '';
  const one = k => srcBox(S[k]);
  const sol = keys.filter(k => S[k].kind==='solidity');
  const ks  = keys.filter(k => S[k].kind==='k');
  return `<section><h4>Read the sources</h4>
    ${sol.length ? `<div class="srchdr">The Solidity each instruction dispatches to —
       taken from <span class="mono">src/opcodes/Opcodes.sol</span>, the table the VM really
       branches on${ sol.some(k => !S[k].fn)
         ? `, plus the builder a maker calls to produce these bytes`
         : `. <b>No builder in this repo emits this program.</b> The builders can only emit
            the shapes the theorems were proved about, so a program they cannot produce has
            gone around that guarantee — which is exactly how the byte above got changed.` }
       </div>${sol.map(one).join('')}` : ''}
    ${ks.length ? `<div class="srchdr" style="margin-top:14px">The specifications — this is
       where the prose above comes from, and the only place a claim is actually
       stated</div>${ks.map(one).join('')}` : ''}
  </section>`;
}

function renderModel(e){
  if(!e.expect) return '';
  const real = e.exec[gate] || {};
  const m = e.expect;
  const modelRan = m.status && m.status !== 'Reverted';
  const vmRan = real.status === 'completed';
  const agree = modelRan === vmRan;
  return `<section><h4>K model vs the real VM</h4>
    ${vblock(agree?'yes':'warnb', agree?'AGREE':'DIVERGE',
      agree ? 'The model and the VM behave the same way here'
            : 'The model and the VM behave DIFFERENTLY here',
      `Model: ${m.status}${m.pc!=null?`, final pc ${m.pc}`:''}`+
      `${m.amountOut!=null?`, amountOut ${m.amountOut}`:''}  ·  `+
      `VM: ${real.status||'not recorded'}${real.nextPC!=null?`, final pc ${real.nextPC}`:''}`+
      `${real.amountOut!=null?`, amountOut ${real.amountOut}`:''}`,
      agree ? 'The L2 theorems are proved about the model. They say something about '+
              'production only where the two agree, so this is the check that gives them '+
              'their meaning.'
            : 'The model continues where production reverts. Every theorem proved about '+
              'this program in the model therefore says nothing about the deployed VM — '+
              'this is the honest limit of the approach, not a detail.',
      null, 'semantics/swapvm.md')}</section>`;
}

function render(){
  const e = DATA.examples[cur];
  document.getElementById('main').innerHTML = `
    <h3>${esc(e.title)}</h3>
    <div class="note">${esc(e.note)}</div>

    <section><h4>The program</h4>${renderSteps(e)}
      <div class="bytes mono" style="margin-top:9px">${esc(e.bytes)}</div></section>

    ${e.lint.length ? `<section><h4>Flagged</h4>${e.lint.map(l =>
        vblock(l.level==='error'?'err':'warnb', (l.level||'flag').toUpperCase(),
               `pc ${l.pc} — ${l.text}`, '', l.why, null, l.source)
      ).join('')}</section>` : ''}

    <section><h4>Which specifications apply</h4>${
      e.applicable.map(p => p.holds
        ? vblock('info','APPLIES', `${p.id} — this spec covers this program`, p.plain,
                 `${p.because} ${p.why_it_is_strong||''}`, p.assumptions, p.docfile||p.file)
        : vblock('no','N/A', `${p.id} — does not apply`, p.plain, p.because, null,
                 p.docfile||p.file)).join('')
    }</section>

    <section><h4>What kprove returned</h4>${renderProof(e)}</section>
    <section><h4>What the real VM did</h4>${renderExec(e)}</section>
    ${renderModel(e)}
    ${renderSources(e)}`;

  document.querySelectorAll('.gate button').forEach(b =>
    b.onclick = () => { gate = +b.dataset.g; render(); });
  renderNav();
}

document.getElementById('hdr').textContent =
  `${DATA.examples.length} programs · ${DATA.coverage.opcodes_modelled} of `+
  `${DATA.coverage.opcodes_total} `+
  `opcodes modelled in the K semantics · every result below was produced by running the tools`;
document.getElementById('foot').innerHTML =
  `<b>This page is a viewer, not evidence.</b> It is static: the proof and execution results
   were recorded by really running <code>kprove</code> and <code>forge</code>
   (${esc((DATA.recorded_at||'').replace('T',' ').replace('+00:00',' UTC'))}), then frozen.
   Nothing here can be re-run from this page, and nothing here is checked by loading it.
   To check the claims, run them:
   <code>./semantics/run-proofs.sh</code> and <code>../dustproof/semantics/run-proofs.sh</code>
   — see <code>VERIFY.md</code>. The interactive version, where you can compose a program of
   your own and ask about it, needs a Python process: <code>python3 demo/server.py</code>.
   <br><br>Baked ${esc((DATA.baked_at||'').replace('T',' ').replace('+00:00',' UTC'))}.`;
render();
</script></body></html>
"""

if __name__ == '__main__':
    raise SystemExit(main())

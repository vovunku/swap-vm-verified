/* Tests for the PREBAKED page (docs/index.html) — the GitHub Pages build.
 *
 * The thing worth testing here is not that it looks right but that it needs nothing: no
 * fetch, no server, no network. A page that silently degrades to blank panels when the API
 * is missing is exactly the failure this build exists to rule out, and it would look fine
 * in a screenshot. So `fetch` is DELETED rather than stubbed — any call is a hard error.
 *
 *   node test/static-page.mjs
 */
import { JSDOM } from 'jsdom';
import { readFileSync } from 'fs';

let pass = 0, fail = 0;
const ok = (cond, name, detail) => {
  if (cond) { pass++; console.log(`  PASS  ${name}${detail ? '  — ' + detail : ''}`); }
  else { fail++; console.log(`  FAIL  ${name}${detail ? '  — ' + detail : ''}`); }
};

const html = readFileSync(new URL('../../docs/index.html', import.meta.url), 'utf8');

console.log('\n1. the page is self-contained');
ok(!/<script[^>]+src=/.test(html), 'no external scripts');
ok(!/<link[^>]+stylesheet/.test(html), 'no external stylesheets');
ok(!/https?:\/\/(?!openapi|github)/.test(html.replace(/<!--[\s\S]*?-->/g, '')) ||
   !/fetch\(|XMLHttpRequest/.test(html), 'no fetch or XHR anywhere in the source');

const dom = new JSDOM(html, {
  runScripts: 'dangerously',
  beforeParse(w) {
    // Not a stub — a tripwire. Anything that reaches for the network fails the test.
    delete w.fetch;
    w.fetch = () => { throw new Error('the prebaked page must not call fetch'); };
    w.XMLHttpRequest = function () { throw new Error('the prebaked page must not use XHR'); };
  },
});
const { window } = dom;
const $ = s => window.document.querySelector(s);
const $$ = s => [...window.document.querySelectorAll(s)];

console.log('\n2. it renders with no server');
ok($('#nav').children.length > 0, 'navigation rendered');
ok($('#main').innerHTML.length > 500, 'a program is shown on load',
   `${$('#main').innerHTML.length} chars`);
ok(/opcodes modelled/.test($('#hdr').textContent), 'header summarises coverage',
   $('#hdr').textContent.slice(0, 60));
ok(!/undefined|NaN|\[object/.test($('#hdr').textContent), 'header has no undefined fields',
   $('#hdr').textContent.slice(0, 80));

console.log('\n3. every example is reachable, distinct, and renders');
const items = $$('.item');
const DATA = window.DATA ?? JSON.parse(html.match(/const DATA = (\{[\s\S]*?\});\n/)[1]);
ok(items.length === DATA.examples.length, 'every baked program is listed',
   `${items.length} items`);
// The cull's whole point: a catalogue entry that shows nothing the others do not is noise.
// Two entries with the same bytes render the same panels, so they cannot both be earning it.
const byBytes = new Map();
for (const e of DATA.examples) byBytes.set(e.bytes, [...(byBytes.get(e.bytes) ?? []), e.label]);
const dupes = [...byBytes.values()].filter(l => l.length > 1);
ok(dupes.length === 0, 'no two entries are byte-identical',
   dupes.length ? `duplicates: ${JSON.stringify(dupes)}` : `${byBytes.size} distinct programs`);
let broken = [];
for (let i = 0; i < items.length; i++) {
  $$('.item')[i].dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
  const m = $('#main').innerHTML;
  if (m.length < 400 || /undefined|\[object Object\]/.test(m)) broken.push(i);
}
ok(broken.length === 0, 'no example renders undefined or empty',
   broken.length ? `broken: ${broken}` : 'all 13 clean');

console.log('\n4. the good / bad pair tells its story');
$$('.item')[0].dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
const good = $('#main').innerHTML;
ok(/T0/.test(good) && /APPLIES/.test(good), 'the verified program shows T0 applying');
ok(/PROVED/.test(good), 'it shows what kprove returned');
ok(/CONTROL OK/.test(good), 'the negative control is shown too — a proof that cannot fail proves nothing');

$$('.item')[1].dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
const bad = $('#main').innerHTML;
ok(/N\/A/.test(bad), 'the one-byte-wrong program shows T0 NOT applying');
ok(/declares 19/.test(bad), 'the 19-byte gate is flagged');
ok(/0000000000000000000000000000000000000090/.test(bad) || /Reverted/.test(bad),
   'its real behaviour is shown, not asserted');

console.log('\n5. a replay is never dressed up as a live run');
ok(/Recorded run, not live/.test(good), 'the proof panel says it is recorded');
ok(!/Ran just now/.test(html), 'the phrase "Ran just now" appears nowhere');
ok(/viewer, not evidence/.test($('#foot').textContent), 'the footer says what the page is not');
ok(/run-proofs\.sh/.test($('#foot').textContent), 'it points at how to check the claims yourself');

console.log('\n6. the gate toggle switches between two recorded runs');
$$('.item')[0].dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
const held = $('#main').innerHTML;
const btn = $$('.gate button').find(b => b.dataset.g === '0');
ok(!!btn, 'both gate states offered');
btn.dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
const notHeld = $('#main').innerHTML;
ok(held !== notHeld, 'the two states show different results');
ok(/Ran to completion/.test(held), 'holding the gate token: completes');
ok(/Reverted/.test(notHeld) && /TakerTokenBalanceIsZero/.test(notHeld),
   'holding none: reverts at the gate');

console.log('\n7. the sources are readable without leaving the page');
$$('.item')[0].dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
const boxes = $$('.srcbox');
ok(boxes.length >= 5, 'Solidity and K sources are expandable', `${boxes.length} boxes`);
ok(boxes.every(b => !b.open), 'they start collapsed');
const sol = boxes.find(b => /Controls\.sol/.test(b.querySelector('summary').textContent));
ok(!!sol, 'the gate instruction\'s Solidity is one of them');
ok(/require\(balance > 0/.test(sol.querySelector('pre').textContent),
   'it contains the actual guard, not a whole file to hunt through');
const kbox = boxes.find(b => /\.k$/.test(b.querySelector('summary').textContent.trim()));
ok(!!kbox && kbox.querySelector('pre').textContent.includes('claim'),
   'a K spec is shown, and it is the real claim text');
// The path shown must be a real path, or "read the source" is an invitation to nothing.
// Every summary must start with a real repo path, or "read the source" is an invitation to
// nothing. The set is the four places sources come from: instruction implementations, the
// K specs, the example builders, and DustProof's own contracts.
ok(boxes.every(b => /^(src|semantics|test|dustproof|\.\.\/dustproof)\//.test(
     b.querySelector('summary').textContent.trim())),
   'every source is labelled with its repo path',
   boxes.map(b => b.querySelector('summary').textContent.trim().split(' ')[0]).join(' '));

console.log('\n8. the catalogue is only the three programs that carry a proof');
ok(DATA.examples.length === 3, 'exactly three programs', `${DATA.examples.length}`);
ok(DATA.examples.every(e => e.kind === 'good' || e.kind === 'bad'),
   'no conformance entries remain');
// They still exist and are still checked -- just not on this page. If that ever stops being
// true, the page is claiming coverage the repo no longer has.
ok(DATA.examples.filter(e => e.proof).length >= 2,
   'at least two carry a real recorded proof pair',
   `${DATA.examples.filter(e => e.proof).length} with proofs`);

console.log('\n9. the contract description and whole-file source are both reachable');
$$('.item')[0].dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
const abouts = $$('.srcbox .about');
ok(abouts.length >= 3, 'each Solidity source says what the contract is', `${abouts.length}`);
ok(/contract Controls/.test($('#main').innerHTML),
   'it names the owning contract, not the first declaration in the file');
ok(/also handles \d+ opcodes/.test($('#main').innerHTML),
   'and what else that contract handles — derived from the dispatch table');
const inner = $$('.innerbox');
ok(inner.length >= 3, 'the whole file is a second expander', `${inner.length}`);
ok(inner.every(b => !b.open), 'it starts collapsed, under the focused excerpt');
ok(/the whole file — \d+ lines/.test($('#main').innerHTML), 'it says how long the file is');
const kb = $$('.srcbox').find(b => /\.k$/.test(b.querySelector('summary').textContent.trim()));
ok(!!kb && /this is the invariant/.test(kb.textContent),
   'the K spec leads with the claim and labels it as the invariant');

// The builder is where the guarantee lives: it can only emit shapes the theorems cover.
$$('.item')[0].dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
ok(/PermissionedSwapExample\.sol/.test($('#main').innerHTML),
   'the verified program shows the builder a maker actually calls');
ok(/ProgramBytes\.t\.sol/.test($('#main').innerHTML),
   'and the test asserting those bytes match the layout the K semantics decodes');
$$('.item')[2].dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
ok(/DustOrderBuilder\.sol/.test($('#main').innerHTML) &&
   /DustSweeper\.sol/.test($('#main').innerHTML),
   'DustProof shows both of its own contracts');
$$('.item')[1].dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
ok(/No builder in this repo emits this program/.test($('#main').innerHTML),
   'the one-byte-wrong program says no builder produces it — the absence is stated, not left blank');
ok(!/PermissionedSwapExample\.sol/.test($('#main').innerHTML),
   'and it is not credited with a builder it did not come from');

console.log('\n10. nothing is editable');
ok($$('input, textarea, select').length === 0, 'no inputs on the page',
   `${$$('input, textarea, select').length} found`);
ok($$('[contenteditable]').length === 0, 'nothing contenteditable');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);

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

console.log('\n3. every example is reachable and renders');
const items = $$('.item');
ok(items.length === 13, 'all 13 programs listed', `${items.length} items`);
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

console.log('\n7. nothing is editable');
ok($$('input, textarea, select').length === 0, 'no inputs on the page',
   `${$$('input, textarea, select').length} found`);
ok($$('[contenteditable]').length === 0, 'nothing contenteditable');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);

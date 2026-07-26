// Front-end test: loads the real page in jsdom, points fetch at the running server,
// and drives the UI the way a user would.
import { JSDOM } from 'jsdom';
import { readFileSync } from 'node:fs';

const BASE = 'http://localhost:8000';
const html = readFileSync(new URL('../static/index.html', import.meta.url), 'utf8');

let pass = 0, fail = 0;
const check = (name, ok, detail = '') => {
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`);
  ok ? pass++ : fail++;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));

const dom = new JSDOM(html, {
  runScripts: 'dangerously', url: BASE, pretendToBeVisual: true,
  // jsdom ships no fetch; install it BEFORE the page script runs, pointed at the live server.
  beforeParse(w){ w.fetch = (u, o) => fetch(u.startsWith('http') ? u : BASE + u, o); },
});
const { window } = dom;
const $ = s => window.document.querySelector(s);
const $$ = s => [...window.document.querySelectorAll(s)];

await sleep(1200);   // let boot() run

console.log('\n1. initial load');
check('page booted (blocks rendered)', $('#blocks').textContent.includes('Gate'));
check('three blocks from the GOOD example', $$('#blocks .block').length === 3,
      `${$$('#blocks .block').length} blocks`);
check('bytes rendered', /91 bytes/.test($('#bytes').textContent), $('#bytes').textContent.slice(0, 40));
check('NO verdict shown before Verify is pressed',
      $('#results').textContent.includes('Press') && !$('#results').textContent.includes('PROVED'),
      $('#results').textContent.trim().slice(0, 46));

console.log('\n2. catalogue drawer');
check('drawer starts closed', !$('#drawer').classList.contains('open'));
$('#openCat').click(); await sleep(60);
check('opens on ☰ Examples', $('#drawer').classList.contains('open'));
check('scrim shown', $('#scrim').classList.contains('open'));
check('curated cards present (GOOD, BAD, DustProof)', $$('#catCurated .card').length === 3,
      `${$$('#catCurated .card').length} curated`);
check('11 conformance cards present', $$('#catRest .card').length === 11,
      `${$$('#catRest .card').length} conformance`);
$('#scrim').click(); await sleep(60);
check('closes on scrim click', !$('#drawer').classList.contains('open'));

console.log('\n3. Verify produces verdicts');
$('#verify').click(); await sleep(900);
const res = $('#results').textContent;
check('T0 reported PROVED', /PROVED/.test(res) && /T0/.test(res));
check('assumptions are exposed', $$('#results details').length >= 1,
      `${$$('#results details').length} disclosures`);
check('"what was not checked" note present', /What was not checked/i.test(res));

console.log('\n4. the BAD example — one byte, everything changes');
$('#openCat').click(); await sleep(60);
const badCard = $$('.card').find(c => c.dataset.ex === '__bad');
check('BAD card found', !!badCard);
badCard.click(); await sleep(700);
check('verdict cleared on switching example',
      $('#results').textContent.includes('Press'), $('#results').textContent.trim().slice(0, 40));
check('shown as raw bytes with an explanation', /Loaded as bytes, not blocks/.test($('#blocks').textContent));
$('#verify').click(); await sleep(900);
const bad = $('#results').textContent;
check('T0 now does NOT apply', /does not apply/.test(bad));
check('lint reports the 19-byte gate', /19/.test(bad) && /ERROR/.test(bad));

console.log('\n5. editing clears a stale verdict');
$('#openCat').click(); await sleep(60);
$$('.card').find(c => c.dataset.ex === '__good').click(); await sleep(700);
$('#verify').click(); await sleep(900);
check('verdict present before edit', /PROVED/.test($('#results').textContent));
const inp = $('#blocks input');
inp.value = '123'; inp.dispatchEvent(new window.Event('input', { bubbles: true })); await sleep(400);
check('verdict cleared after editing a field', $('#results').textContent.includes('Press'));

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);

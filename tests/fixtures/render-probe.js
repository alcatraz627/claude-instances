// Runs the transcript page's own prose and card helpers on sample inputs and
// prints one line per case: a drawn box becomes a callout, a code block is
// coloured only when it says what it is or is plainly a shell command, and a
// task notification's tags become labelled fields.
const fs = require('fs');
const path = require('path');

const html = fs.readFileSync(path.join(__dirname, '..', '..', 'lib', 'transcript-app.html'), 'utf8');
const cut = (from, to) => {
    const a = html.indexOf(from), b = html.indexOf(to, a + 1);
    if (a < 0 || b < 0) { console.log('MARKERS MISSING: ' + from); process.exit(0); }
    return html.slice(a, b);
};
const src = [
    cut('function boxCallouts(', 'function tidyMd('),
    cut('function shHTML(', 'function toolBody('),
    cut('const SHELL_LANGS', '/* ================= data'),
    cut('const FIELD_NAME', '/* What an event says in words'),
].join('\n');
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const api = new Function('esc', 'hljs', src + '; return { boxCallouts, colourBlock, hcardHTML };')(esc, undefined);

// a drawn box in a quote becomes a quoted callout, one line per boxed line
const box = api.boxCallouts('> ┌ Hook notes ─────\n> │ **env:** one\n> │ **git:** two\n> └──────');
const boxOk = box.includes('<span class="callout-h">Hook notes</span>') && box.includes('> **env:** one  ') && !box.includes('┌');

// which fenced blocks get coloured, and how
function block(lang, text) {
    const pre = { cls: [], dataset: {}, classList: { add(c) { pre.cls.push(c); } } };
    const code = { className: lang ? 'language-' + lang : '', textContent: text, innerHTML: esc(text), parentElement: pre, classList: { add() {} } };
    api.colourBlock(code);
    return pre.cls.includes('boxart') ? 'box' : pre.dataset.lang === 'shell' ? 'shell' : pre.dataset.lang ? 'lang' : 'plain';
}
const blocks = [
    block('', '/goal Every open fix PR is merged after a clean bot review, and the health check'),
    block('', 'gcloud services enable compute.googleapis.com --project clanky'),
    block('bash', 'echo hi'),
    block('', '┌ slack-automation ──\n│ 23 rows\n│ more\n└──'),
].join(',');

// a task notification: its tags become fields, its summary the body
const card = api.hcardHTML({ text: '<task-notification>\n<task-id>b0q</task-id>\n<status>completed</status>\n<summary>Done (exit code 0)</summary>\n</task-notification>', ts: '17:19' }, 'task');
const fields = [...card.matchAll(/<dt>([^<]+)<\/dt><dd>([^<]+)<\/dd>/g)].map(m => m[1] + '=' + m[2]).join(';');
const body = /data-raw="Done \(exit code 0\)"/.test(card) ? 'summary-body' : 'no-body';

console.log(`box:${boxOk ? 'callout' : 'broken'} blocks:${blocks} card:${fields} ${body}`);

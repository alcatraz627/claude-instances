// Runs the transcript page's own chapter builder on records from transcript.py
// (JSON file in argv[2]) and prints one line per chapter:
//   title [cmds=…] [h=kind:n,…] [div=kind]
const fs = require('fs');
const path = require('path');

const html = fs.readFileSync(path.join(__dirname, '..', '..', 'lib', 'transcript-app.html'), 'utf8');
const a = html.indexOf('function userParts(');
const b = html.indexOf('/* ================= masthead', a);
if (a < 0 || b < 0) { console.log('MARKERS MISSING'); process.exit(1); }
const records = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
records.forEach((r, i) => { r.seq = i + 1; });

const state = { records, chapters: [] };
new Function('state', html.slice(a, b) + '\nbuildChapters();')(state);

console.log(state.chapters.map(c => {
    const parts = [c.title];
    if (c.cmds && c.cmds.length) parts.push('cmds=' + c.cmds.map(x => x.label).join(','));
    const h = Object.entries(c.harness || {}).map(([k, n]) => `${k}:${n}`).join(',');
    if (h) parts.push('h=' + h);
    if (c.divider) parts.push('div=' + c.divider.kind);
    return parts.join(' ');
}).join(' | '));

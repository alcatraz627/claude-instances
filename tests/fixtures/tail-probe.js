// Runs the hub index's own card-tail code on records from transcript.py (JSON
// file in argv[2]) and prints an idle card's visible tail lines, then its
// "+N system" count: "g text | g text | +N".
const fs = require('fs');
const path = require('path');

const html = fs.readFileSync(path.join(__dirname, '..', '..', 'lib', 'hub-index.html'), 'utf8');
const a = html.indexOf('/* peek-tail lines */');
const b = html.indexOf('/* ---------------- peeks density', a);
if (a < 0 || b < 0) { console.log('MARKERS MISSING'); process.exit(1); }
const records = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
records.forEach((r, i) => { r.seq = i + 1; });

const esc = s => String(s);
const out = new Function('esc', 'records', html.slice(a, b) + `
    tails.s = { src: [], lastSeq: 0, loading: false };
    ingestTail('s', records);
    const s = { session_id: 's', state: 'idle' };
    const lines = tailLinesFor(s).map(l => l.g + ' ' + String(l.tx).replace(/<[^>]+>/g, ''));
    const n = typeof tailSysCount === 'function' ? tailSysCount(s) : 0;
    return lines.join(' | ') + ' | +' + n;`)(esc, records);
console.log(out);

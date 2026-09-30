// Runs the transcript page's own link detection on one sample line and prints
// each link it would make as "text => href", joined by " | ".
const fs = require('fs');
const path = require('path');

const html = fs.readFileSync(path.join(__dirname, '..', '..', 'lib', 'transcript-app.html'), 'utf8');
const a = html.indexOf('const LINK_RE');
const b = html.indexOf('function linkify(', a);
if (a < 0 || b < 0) { console.log('MARKERS MISSING'); process.exit(0); }
const sample = 'See https://github.com/x/y/pull/9. and /Users/me/Code/app/lib/scan.sh:120, ' +
    'then ~/.claude/rules/git.md or lib/hub-index.html; not D1a/D2b nor 3/4.';
const out = new Function('location', 'state', html.slice(a, b) + `
    const found = [];
    ${JSON.stringify(sample)}.replace(LINK_RE, m => {
        const text = m.replace(/[.,;:!?)\\]]+$/, '');
        found.push(text + ' => ' + linkTarget(text));
        return m;
    });
    return found.join(' | ');`)({ hostname: '127.0.0.1' }, { meta: { cwd: '/Users/me/Code/app' } });
console.log(out);

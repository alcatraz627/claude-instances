/* What the hub board and the transcript page share: tooltips, the hover copy
   button, and the palette picker. Loaded by both pages from /vendor/. */
"use strict";
window.HubShared = (() => {
    /* Palettes, each shown as a strip of its own colours. "native" (Graphite)
       is the page's :root; the rest live in hub-shared.css. */
    const PALETTES = [
        // each strip: dark ground, light ground, then its three accents (you, Claude, tools)
        { id: 'native',   name: 'Graphite', sw: ['#191a21', '#faf9f6', 'oklch(0.76 0.15 268)', 'oklch(0.76 0.14 180)', '#e2b05b'] },
        { id: 'paper',    name: 'Paper',    sw: ['#1b1916', '#f8f5ee', 'oklch(0.74 0.13 45)', 'oklch(0.77 0.08 140)', '#dcae63'] },
        { id: 'fjord',    name: 'Fjord',    sw: ['#1e222b', '#eef1f5', 'oklch(0.8 0.1 215)', 'oklch(0.8 0.13 155)', '#e4c07f'] },
        { id: 'dusk',     name: 'Dusk',     sw: ['#1a1724', '#faf5f0', 'oklch(0.74 0.16 295)', 'oklch(0.8 0.1 200)', '#eab86e'] },
        { id: 'terminal', name: 'Terminal', sw: ['#0e0f11', '#ffffff', 'oklch(0.83 0.14 85)', 'oklch(0.82 0.18 145)', '#f28b50'] },
    ];
    // palettes retired 2026-10-01, mapped to their nearest replacement
    const RENAMED = { tty: 'terminal', editorial: 'paper', product: 'native' };
    function savedPalette() {
        let s = 'native';
        try { s = localStorage.getItem('cc-skin') || 'native'; } catch (e) {}
        s = RENAMED[s] || s;
        return PALETTES.some(p => p.id === s) ? s : 'native';
    }
    function applyPalette(id) {
        id = RENAMED[id] || id;
        if (id === 'native') delete document.documentElement.dataset.skin;
        else document.documentElement.dataset.skin = id;
        try { localStorage.setItem('cc-skin', id); } catch (e) {}
        document.querySelectorAll('#vpSkin button').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.skin === id)));
    }
    function paletteButtons(host) {
        host.classList.add('vp-skins');
        host.classList.remove('vp-seg');
        host.innerHTML = PALETTES.map(p =>
            `<button data-skin="${p.id}" title="${p.name} palette"><span class="pv">${p.sw.map(c => `<i style="background:${c}"></i>`).join('')}</span>${p.name}</button>`).join('');
    }

    /* One size setting for both pages: 14.5 px is 1x. */
    const FS_DEFAULT = 14.5, FS_MIN = 12, FS_MAX = 18;
    function savedSize() {
        let v = NaN;
        try { v = parseFloat(localStorage.getItem('hx-fs')); } catch (e) {}
        // the transcript page once saved prose sizes up to 19 px
        return isNaN(v) ? FS_DEFAULT : Math.min(FS_MAX, Math.max(FS_MIN, v));
    }

    /* Tooltips. A title attribute moves to data-tip on first hover, so the
       browser's own tooltip never doubles ours. */
    let tip = null, tipFor = null, tipTimer = 0;
    function tipEl() {
        if (!tip) { tip = document.createElement('div'); tip.className = 'tip'; tip.setAttribute('role', 'tooltip'); document.body.appendChild(tip); }
        return tip;
    }
    function hideTip() { clearTimeout(tipTimer); tipFor = null; if (tip) tip.classList.remove('on'); }
    function placeTip(el) {
        const t = tipEl(), r = el.getBoundingClientRect();
        t.textContent = el.dataset.tip;
        t.style.left = '0px'; t.style.top = '0px';
        const w = t.offsetWidth, h = t.offsetHeight;
        let x = r.left + r.width / 2 - w / 2;
        x = Math.max(8, Math.min(innerWidth - w - 8, x));
        let y = r.bottom + 7;
        if (y + h > innerHeight - 8) y = r.top - h - 7;
        t.style.left = x + 'px'; t.style.top = y + 'px';
        t.classList.add('on');
    }
    document.addEventListener('pointerover', e => {
        const el = e.target.closest && e.target.closest('[title], [data-tip]');
        if (!el || el === tipFor) return;
        if (el.hasAttribute('title')) {
            const t = el.getAttribute('title');
            el.removeAttribute('title');
            if (t) el.dataset.tip = t;
        }
        if (!el.dataset.tip) return;
        hideTip();
        tipFor = el;
        tipTimer = setTimeout(() => { if (tipFor === el && el.isConnected) placeTip(el); }, 380);
    });
    document.addEventListener('pointerout', e => {
        if (tipFor && !(e.relatedTarget && tipFor.contains(e.relatedTarget))) hideTip();
    });
    addEventListener('scroll', hideTip, { passive: true, capture: true });
    document.addEventListener('pointerdown', hideTip, true);

    /* A copy button that appears over whichever block the pointer is on.
       One button moves around, rather than one per paragraph. */
    function blockCopy(selector, iconHTML) {
        const b = document.createElement('button');
        b.className = 'bcp'; b.innerHTML = iconHTML; b.dataset.tip = 'Copy';
        document.body.appendChild(b);
        let target = null;
        const hide = () => { b.classList.remove('on', 'ok'); target = null; };
        document.addEventListener('pointerover', e => {
            if (e.target.closest('.bcp')) return;
            const el = e.target.closest(selector);
            if (!el) { hide(); return; }
            if (el === target) return;
            target = el;
            const r = el.getBoundingClientRect(), cell = /^(TD|TH)$/.test(el.tagName) || el.tagName === 'PRE';
            const outside = !cell && r.right + 34 < innerWidth;
            b.style.top = (r.top + scrollY + (cell ? 4 : 1)) + 'px';
            b.style.left = (outside ? r.right + 8 : r.right - 28) + scrollX + 'px';
            b.classList.remove('ok');
            b.classList.add('on');
        });
        addEventListener('scroll', hide, { passive: true });
        b.addEventListener('click', e => {
            e.preventDefault(); e.stopPropagation();
            if (!target) return;
            const txt = target.innerText.replace(/⧉/g, '').trim();
            const done = () => { b.classList.add('ok'); setTimeout(() => b.classList.remove('ok'), 1100); };
            if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(txt).then(done, () => {});
            else {
                const ta = document.createElement('textarea'); ta.value = txt; ta.style.cssText = 'position:fixed;opacity:0';
                document.body.appendChild(ta); ta.select(); try { document.execCommand('copy'); } catch (err) {} ta.remove(); done();
            }
        });
    }

    return { PALETTES, savedPalette, applyPalette, paletteButtons, savedSize, FS_DEFAULT, FS_MIN, FS_MAX, blockCopy, hideTip };
})();

/* The menu bar's Claude mark, for the top bars: <svg><use href="#i-claude"/></svg> */
(() => {
    const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    s.setAttribute('aria-hidden', 'true'); s.style.cssText = 'position:absolute;width:0;height:0';
    s.innerHTML = '<symbol id="i-claude" viewBox="0 0 1200 1200"><path fill="#d97757" d="M 234 800.2 L 468.6 668.5 L 472.6 657.1 L 468.6 650.7 L 457.2 650.7 L 418 648.3 L 283.9 644.7 L 167.6 639.9 L 54.9 633.8 L 26.6 627.8 L 0 592.8 L 2.7 575.3 L 26.6 559.2 L 60.7 562.2 L 136.2 567.4 L 249.4 575.2 L 331.6 580 L 453.3 592.7 L 472.6 592.7 L 475.3 584.9 L 468.7 580 L 463.6 575.2 L 346.4 495.8 L 219.5 411.9 L 153.1 363.5 L 117.2 339.1 L 99.1 316.1 L 91.2 266 L 123.9 230.1 L 167.7 233.1 L 178.9 236.1 L 223.2 270.2 L 318 343.6 L 441.8 434.7 L 459.9 449.8 L 467.2 444.6 L 468.1 441 L 459.9 427.4 L 392.6 305.7 L 320.8 181.9 L 288.8 130.6 L 280.3 99.9 C 277.4 87.2 275.2 76.6 275.2 63.6 L 312.3 13.2 L 332.9 6.6 L 382.4 13.2 L 403.2 31.3 L 434 101.7 L 483.9 212.5 L 561.2 363.2 L 583.8 407.9 L 595.9 449.3 L 600.4 462 L 608.2 462 L 608.2 454.7 L 614.6 369.8 L 626.3 265.6 L 637.8 131.5 L 641.7 93.7 L 660.4 48.5 L 697.5 24 L 726.5 37.9 L 750.4 72 L 747.1 94.1 L 732.9 186.2 L 705.1 330.5 L 687 427.2 L 697.5 427.2 L 709.6 415.1 L 758.5 350.2 L 840.6 247.5 L 876.9 206.7 L 919.2 161.7 L 946.3 140.3 L 997.6 140.3 L 1035.4 196.4 L 1018.5 254.4 L 965.6 321.4 L 921.8 378.2 L 859 462.8 L 819.8 530.4 L 823.4 535.8 L 832.8 534.9 L 974.7 504.7 L 1051.3 490.9 L 1142.8 475.2 L 1184.2 494.5 L 1188.7 514.1 L 1172.5 554.3 L 1074.6 578.5 L 959.8 601.4 L 788.9 641.9 L 786.8 643.4 L 789.3 646.4 L 866.3 653.6 L 899.2 655.4 L 979.8 655.4 L 1129.9 666.6 L 1169.2 692.5 L 1192.7 724.3 L 1188.7 748.4 L 1128.3 779.2 L 1046.8 759.9 L 856.6 714.6 L 791.4 698.3 L 782.3 698.3 L 782.3 703.7 L 836.7 756.9 L 936.3 846.8 L 1061.1 962.8 L 1067.4 991.5 L 1051.4 1014.1 L 1034.5 1011.7 L 924.9 929.2 L 882.6 892.1 L 786.8 811.5 L 780.5 811.5 L 780.5 819.9 L 802.6 852.2 L 919.1 1027.4 L 925.1 1081.1 L 916.7 1098.6 L 886.5 1109.2 L 853.3 1103.1 L 785.1 1007.4 L 714.7 899.5 L 657.9 802.9 L 651 806.8 L 617.5 1167.7 L 601.8 1186.1 L 565.5 1200 L 535.3 1177 L 519.3 1139.9 L 535.3 1066.6 L 554.7 970.8 L 570.4 894.7 L 584.5 800.1 L 593 768.7 L 592.4 766.6 L 585.5 767.5 L 514.2 865.4 L 405.8 1011.9 L 320.1 1103.7 L 299.5 1111.8 L 263.9 1093.4 L 267.2 1060.4 L 287.1 1031.1 L 405.8 880.1 L 477.4 786.5 L 523.7 732.5 L 523.3 724.7 L 520.6 724.7 L 205.3 929.4 L 149.2 936.6 L 125 914 L 128 876.9 L 139.4 864.8 L 234.2 799.6 L 233.9 799.9 Z"/></symbol>';
    (document.body || document.documentElement).appendChild(s);
})();

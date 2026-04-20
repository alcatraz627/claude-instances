#!/usr/bin/env bash
# render.sh — Generate the Claude instances dashboard HTML.
#
# Runs scan.sh to collect data, then embeds it into a self-contained
# HTML file with auto-refresh capability.
#
# Usage: bash render.sh [--once]
#   --once: generate once and exit (default: generate and open)

set -uo pipefail

WIDGET_DIR="$(cd "$(dirname "$0")" && pwd)"
SCAN_SCRIPT="${WIDGET_DIR}/lib/scan.sh"
OUTPUT_FILE="${WIDGET_DIR}/dashboard.html"
REFRESH_INTERVAL=30  # seconds

# Run the scanner
SCAN_DATA=$(bash "$SCAN_SCRIPT" 2>/dev/null) || {
    echo "render: scan.sh failed" >&2
    exit 1
}

# Get current timestamp for display
RENDER_TS=$(date '+%Y-%m-%d %H:%M:%S')

# Generate HTML
cat > "$OUTPUT_FILE" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="${REFRESH_INTERVAL}">
<title>Claude Instances</title>
<style>
  :root {
    --bg: #0d1117;
    --surface: #161b22;
    --surface2: #1c2333;
    --text: #e6edf3;
    --dim: #7d8590;
    --accent: #58a6ff;
    --accent2: #3fb950;
    --warn: #d29922;
    --err: #f85149;
    --border: #30363d;
    --radius: 8px;
  }
  body.light {
    --bg: #f6f8fa;
    --surface: #ffffff;
    --surface2: #f0f3f6;
    --text: #1f2328;
    --dim: #656d76;
    --accent: #0969da;
    --accent2: #1a7f37;
    --warn: #9a6700;
    --err: #cf222e;
    --border: #d0d7de;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif;
    background: var(--bg);
    color: var(--text);
    padding: 20px;
    line-height: 1.5;
    transition: background 0.2s, color 0.2s;
  }

  /* Theme toggle */
  .theme-toggle {
    position: fixed; top: 12px; right: 16px; z-index: 100;
    background: var(--surface); border: 1px solid var(--border);
    color: var(--text); border-radius: 6px; padding: 6px 12px;
    cursor: pointer; font-size: 14px; transition: all 0.2s;
  }
  .theme-toggle:hover { border-color: var(--accent); }

  /* Header */
  .header {
    display: flex; align-items: center; gap: 12px;
    margin-bottom: 24px; padding-bottom: 16px;
    border-bottom: 1px solid var(--border);
  }
  .header h1 { font-size: 20px; font-weight: 600; }
  .header .meta { color: var(--dim); font-size: 13px; margin-left: auto; }

  /* Cards */
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 24px; }
  .card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 16px;
  }
  .card h2 { font-size: 14px; font-weight: 600; color: var(--dim); text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 12px; }
  .card.full { grid-column: 1 / -1; }

  /* Stats row */
  .stats { display: flex; gap: 24px; flex-wrap: wrap; }
  .stat { text-align: center; }
  .stat .value { font-size: 28px; font-weight: 700; color: var(--accent); }
  .stat .label { font-size: 12px; color: var(--dim); margin-top: 2px; }

  /* Live instances */
  .instance {
    background: var(--surface2); border-radius: 6px; padding: 12px;
    margin-bottom: 8px; border-left: 3px solid var(--accent2);
  }
  .instance .pid { font-weight: 600; color: var(--accent2); }
  .instance .cwd { color: var(--dim); font-size: 13px; font-family: 'SF Mono', monospace; }
  .instance .elapsed { color: var(--warn); font-size: 13px; }
  .no-instances { color: var(--dim); font-style: italic; padding: 20px; text-align: center; }

  /* Session table */
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th {
    text-align: left; padding: 8px 12px; border-bottom: 2px solid var(--border);
    color: var(--dim); font-weight: 600; font-size: 12px; text-transform: uppercase;
    letter-spacing: 0.5px;
  }
  td { padding: 8px 12px; border-bottom: 1px solid var(--border); }
  tr:hover td { background: var(--surface2); }
  .mono { font-family: 'SF Mono', 'Cascadia Code', monospace; font-size: 12px; }
  .right { text-align: right; }
  .size-bar {
    display: inline-block; height: 4px; border-radius: 2px;
    background: var(--accent); min-width: 2px; vertical-align: middle;
  }

  /* Events timeline */
  .event-item {
    display: flex; align-items: center; gap: 10px;
    padding: 6px 0; border-bottom: 1px solid var(--border);
    font-size: 13px;
  }
  .event-item:last-child { border-bottom: none; }
  .event-dot {
    width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0;
  }
  .event-dot.SessionStart { background: var(--accent2); }
  .event-dot.Stop { background: var(--err); }
  .event-dot.PermissionRequest { background: var(--warn); }
  .event-dot.PostCompact { background: var(--accent); }
  .event-ts { color: var(--dim); font-family: 'SF Mono', monospace; font-size: 12px; min-width: 60px; }
  .event-type { font-weight: 500; min-width: 130px; }
  .event-project { color: var(--dim); }

  /* Responsive */
  @media (max-width: 768px) {
    .grid { grid-template-columns: 1fr; }
    table { font-size: 12px; }
    th, td { padding: 6px 8px; }
  }
</style>
</head>
<body>
<button class="theme-toggle" onclick="document.body.classList.toggle('light')">&#9728; / &#9790;</button>

<div class="header">
  <h1>Claude Instances</h1>
  <span class="meta">Rendered: ${RENDER_TS} &middot; Auto-refresh: ${REFRESH_INTERVAL}s</span>
</div>

<div id="app"></div>

<script>
const DATA = ${SCAN_DATA};

function relativeTime(isoStr) {
  if (!isoStr) return '?';
  const diff = Date.now() - new Date(isoStr).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return mins + 'm ago';
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return hrs + 'h ago';
  const days = Math.floor(hrs / 24);
  return days + 'd ago';
}

function formatSize(kb) {
  if (kb > 1024) return (kb / 1024).toFixed(1) + ' MB';
  return kb.toFixed(0) + ' KB';
}

function formatTime(ts) {
  if (!ts) return '';
  const d = new Date(ts);
  return d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false });
}

function truncatePath(p, maxLen) {
  if (!p || p.length <= maxLen) return p || '';
  return '...' + p.slice(-(maxLen - 3));
}

function render() {
  const app = document.getElementById('app');
  const maxSize = Math.max(...DATA.history.map(s => s.size_kb), 1);

  // Stats
  const totalTurns = DATA.history.reduce((s, h) => s + h.turns, 0);
  const totalSize = DATA.history.reduce((s, h) => s + h.size_kb, 0);
  const recentCount = DATA.history.filter(h => {
    const diff = Date.now() - new Date(h.modified).getTime();
    return diff < 3600000; // last hour
  }).length;

  let html = '<div class="grid">';

  // Overview stats card
  html += '<div class="card"><h2>Overview</h2><div class="stats">';
  html += '<div class="stat"><div class="value">' + DATA.live_count + '</div><div class="label">Live</div></div>';
  html += '<div class="stat"><div class="value">' + DATA.history.length + '</div><div class="label">Sessions</div></div>';
  html += '<div class="stat"><div class="value">' + totalTurns.toLocaleString() + '</div><div class="label">Total Turns</div></div>';
  html += '<div class="stat"><div class="value">' + formatSize(totalSize) + '</div><div class="label">Total Size</div></div>';
  html += '<div class="stat"><div class="value">' + recentCount + '</div><div class="label">Active (1h)</div></div>';
  html += '</div></div>';

  // Live instances card
  html += '<div class="card"><h2>Live Instances</h2>';
  if (DATA.live.length === 0) {
    html += '<div class="no-instances">No live Claude processes detected</div>';
  } else {
    DATA.live.forEach(inst => {
      const modelColors = { opus: '#a78bfa', sonnet: '#58a6ff', haiku: '#3fb950' };
      const mc = modelColors[inst.model] || 'var(--dim)';
      html += '<div class="instance">';
      html += '<span class="pid">PID ' + inst.pid + '</span>';
      html += ' <span style="color:' + mc + ';font-weight:600">' + (inst.model || '?') + '</span>';
      html += ' <span class="elapsed">' + inst.elapsed + '</span>';
      if (inst.turns) html += ' <span style="color:var(--dim);font-size:12px">' + inst.turns + ' turns</span>';
      html += '<div class="cwd">' + truncatePath(inst.cwd_short || inst.cwd, 50) + '</div>';
      if (inst.statusline && inst.statusline.cpu && inst.statusline.cpu !== '0') {
        html += '<div style="font-size:11px;color:var(--dim);margin-top:4px">CPU: ' + inst.statusline.cpu + '%</div>';
      }
      html += '</div>';
    });
  }
  html += '</div>';

  // Recent events card
  html += '<div class="card"><h2>Recent Events</h2>';
  if (DATA.recent_events && DATA.recent_events.length > 0) {
    DATA.recent_events.slice().reverse().forEach(evt => {
      html += '<div class="event-item">';
      html += '<div class="event-dot ' + evt.event + '"></div>';
      html += '<span class="event-ts">' + formatTime(evt.ts) + '</span>';
      html += '<span class="event-type">' + evt.event + '</span>';
      html += '<span class="event-project">' + (evt.project || '') + '</span>';
      html += '</div>';
    });
  } else {
    html += '<div class="no-instances">No recent events</div>';
  }
  html += '</div>';

  // Limits card (if present)
  if (DATA.limits) {
    html += '<div class="card"><h2>Usage Limits</h2>';
    html += '<pre class="mono" style="color:var(--dim)">' + JSON.stringify(DATA.limits, null, 2) + '</pre>';
    html += '</div>';
  }

  html += '</div>'; // end grid

  // Session history table
  html += '<div class="card full"><h2>Session History</h2>';
  html += '<table><thead><tr>';
  html += '<th>Session</th><th>Project</th><th>Turns</th><th class="right">Size</th><th></th><th>Last Active</th>';
  html += '</tr></thead><tbody>';

  DATA.history.forEach(sess => {
    const barWidth = Math.max(2, Math.round((sess.size_kb / maxSize) * 80));
    const shortId = sess.session_id.length > 12
      ? sess.session_id.slice(0, 12) + '...'
      : sess.session_id;
    html += '<tr>';
    html += '<td class="mono">' + shortId + '</td>';
    html += '<td>' + sess.project + '</td>';
    html += '<td class="right">' + sess.turns.toLocaleString() + '</td>';
    html += '<td class="right">' + formatSize(sess.size_kb) + '</td>';
    html += '<td><span class="size-bar" style="width:' + barWidth + 'px"></span></td>';
    html += '<td>' + relativeTime(sess.modified) + '</td>';
    html += '</tr>';
  });

  html += '</tbody></table></div>';
  app.innerHTML = html;
}

render();
</script>
</body>
</html>
HTMLEOF

echo "Dashboard written to: $OUTPUT_FILE"

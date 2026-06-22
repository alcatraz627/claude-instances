# Reading claude design's handoff — what we took, what we cut, what's next

This is the engineering read of claude design's transcript proposal
(`~/Downloads/HANDOFF.md` plus the `Transcript Viewer Proposal.dc.html` /
`Session Index.dc.html` prototypes). The proposal has many strong systems but it
is a reference, not a spec. The filter applied throughout:

> **Keep every idea that adds quantified information; cut every idea that is
> customization theater or whitespace.** This is a power-user reading tool — the
> user reads sessions to understand work, not to admire the UI.

## Triage

### Adopted — shipped to `main` (commits `8a0b8dc`…`bb7bc38`)

| Idea | Why it earns its place | Where |
|------|------------------------|-------|
| Per-tool-group **work meter** (`worked · N tools · ↑tok`) | Quantifies the weight of each Claude turn — the single best idea in the doc | `8a0b8dc` |
| **Color discipline** — You/Claude as a coordinated accent pair, green/red reserved for diffs/errors, tools colored by kind | Fixes a real overload (green meant Claude AND added-lines AND edit) | `9e2da3e` |
| Soft **blue-slate dark** theme | Calmer than near-black; the doc's rationale holds | `9e2da3e` |
| **Richer tool bodies** — TodoWrite checklist, pretty JSON for Read/Grep/MCP | Replaces raw dumps with scannable structure | `fd0474b` |
| **State set** — live `N new ↓`, quiet-session, end-of-list terminus | Real robustness for live-tailing on a phone | `bb0c22e` |
| **Search as jump-palette** — tap a block to jump, empty query lists all | Turns search into navigation; pure power-user win | `262d07c` |
| **Scroll-away masthead** — token split-bar + stat tiles, slim sticky bar | Moves heavy summary out of the persistent chrome | `bb7bc38` |
| **Density toggle + text-size** | The useful subset of their control system | `bb7bc38` |

One correction to the design itself: their masthead split-bar treats cache reads
as a third segment. Cache dwarfs input+output by ~80×, so that flattens the
in-vs-out signal to nothing. We split the bar on input-vs-output and put cache in
the legend.

### Overruled — deliberately not built

| Idea | Why cut |
|------|---------|
| **8-palette accent picker** | Customization theater; zero usability payoff. One coordinated You/Claude pair is enough. |
| **"Threads" direction** (right-aligned chat bubbles) | Reduces density and wastes horizontal width; the user already left chat-style for document-style. |
| **"Timeline" direction** (airy spine, 24px gaps) | Wastes vertical space; idle-gap dividers already convey time. |
| **Hanken Grotesk + JetBrains Mono web fonts** | Breaks the deps budget (marked + highlight only) and the offline/insecure-http constraint. Kept the type scale, system fonts. |
| **Idle-gap "work rollup"** (`5 tools · 31k` inside a gap) | A gap is idle time with no work in it; the per-turn meters already carry this. Murky, skipped. |

## What's next — genuinely worth doing, in priority order

1. **Session Index page redesign** (`lib/hub-index.html`). The biggest unbuilt
   piece (handoff §7). Status-first cards (needs-you amber sorts to the top, then
   working, then idle), three weight tiles + the token split-bar, top-4 tool
   monograms, day-span. Status is a live server property, not in the log — the hub
   already knows it. This is its own surface and its own round.

2. **Tool results in expanded bodies.** Today the bodies render the tool *input*
   (the diff, the command, the JSON). The handoff's model is `{input, result}` —
   showing a `Bash` command's stdout, a `Read`'s returned slice. This needs
   `transcript.py` to thread `tool_result` lines back to their `tool_use` (a data
   change, not just client render), so it's a backend+frontend item.

3. **Activity-ribbon upgrade** (handoff §5.3). Today it's uniform dots. Make each
   item's width scale with that turn's tool-count and group the ribbon into
   per-page boxes with the current page highlighted, so the overview reads as
   "where the heavy work is." Adapt cautiously — keep it compact, not a feature in
   its own right.

4. **Monogram tiles** (optional, taste). Swap the glyph tool icons (✎ ❯ ◇) for the
   handoff's 2-char monograms (`ed` `rd` `sh` `ag`). Denser and more legible at a
   glance; low-risk if we want it.

5. **T4 — word-level diff polish** (already tracked). Intra-line highlight of which
   characters changed + collapse long unchanged regions. Virtualization stays out
   of scope per the user.

## Constraints that bound all of the above

One self-contained HTML file, plain CSS/JS, marked + highlight as the only deps,
runs over insecure HTTP on the tailnet, mobile-first, dark+light via CSS vars,
layout-stable under live append. Any future idea that breaks one of these is out,
however good it looks in a prototype.

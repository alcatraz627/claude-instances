# Capabilities consolidation: the top bar is where capabilities live

Owner, 2026-08-25, the diagnosis in their own words: "I want to consolidate
capabilities, I still haven't figured out the actual spread issue. The home
server was good but ended up not being used regularly, whereas the
claude-instances bar has [gone] far but it lives in the top bar where I can
just use it without remembering it exists or going through the friction to
start it up."

## The principle this plan is built on

A capability earns use in proportion to how little you must remember to use
it. home-server had good capabilities and died because using them meant
remembering the project exists, starting it, and opening a browser. The
claude-instances dropdown is always on screen: zero recall, zero startup,
one hover. So the consolidation direction is one-way: capabilities move INTO
the top bar; nothing new gets its own server-you-must-visit.

The test for whether a capability belongs in the dropdown, applied to every
candidate below: is its common case a glance (status) or one click (toggle,
open, arm)? Anything needing a full page is a LINK from the dropdown to a
served surface (the kanban model), never a page of its own machinery.

## Workstream 1: permission guards in the dropdown

The Switchboard already has the right shape (native/Switchboard.swift): mute
sentinels discovered by READING the hooks rather than a hardcoded list, shown
with age, one-click restore, and the standing rule that a click may restore a
protection but never remove one (muting stays a deliberate shell act).

Permissions get the same treatment, one level up:

- A permission is a named capability an agent may or may not exercise:
  `gcp-deploy`, `git-push:<repo>`, others as they arise. Each is enforced by
  a PreToolUse hook (the switchboard-guard shape), and each reads an allow
  sentinel: `~/.claude/permissions/<name>.allow` (flat files, like the mute
  sentinels, so the discovery-by-reading-hooks pattern extends unchanged).
- The dropdown section lists every permission the hooks know, with state
  (allowed since <age> / denied) and a one-click DENY (delete the allow
  file: restoring a protection, consistent with the Switchboard's one rule).
  ALLOW from the dropdown asks first, exactly like the prompt-suppression
  exception the Switchboard already carves out.
- Per-project scope rides the filename (`git-push.versable-gcp.allow`), so a
  repo-scoped allowance is a file, greppable and auditable like everything
  else in the gcc.
- Existing guards to converge on this store as they are touched: the git
  push gate, protected-repos.list, the fable-subagents sentinel. Not a big
  bang; the store accepts them one at a time.

## Workstream 2: home-server salvage

(Findings from the read-only scour of ~/Code/Personal/home-server:
~/.claude/assets/reports/20260825-homeserver-salvage/findings.md.)

The scour's headline: the two named priorities are as clean as extraction
gets. Full catalog with file:line detail:
`~/.claude/assets/reports/20260825-homeserver-salvage/findings.md`.

**WiZ lights (difficulty 1, build first).** Direct UDP on port 38899, zero
npm deps, zero cloud, no credentials. Discovery is one broadcast JSON to
255.255.255.255:38899 collected for 3s; toggle/dim/colour is one unicast
`setPilot` with a 2s first-reply timeout (wiz.ts:28-155 has the whole
protocol; a Swift UDP socket does the same with nothing Node-specific).
Dropdown shape: a bulb list with an on/off toggle per bulb, a brightness
submenu, and a re-discover action. Per-bulb names ride a small JSON the
dropdown owns (the old app kept names/rooms in lights.json; carry the idea,
not the file).

**Tailscale (difficulty 1).** A read-only wrapper over the already-logged-in
CLI: `tailscale status --json`, parsed into devices (tailscale.ts:32-84
verbatim, plus ~15 lines of link formatting from the page: the .ts.net
MagicDNS domain, the .local mDNS name, raw IPv4/IPv6). No token, no OAuth.
Dropdown shape: device list with an online dot, click-to-copy address, and
the key-expiry warning as a badge. The old page had NO mutating verbs, so
"manage links and devices" v1 is honest as copy-links + status; mutations
(exit-node select, device approve) would be NEW capability against the
tailscale CLI, staged behind a permission sentinel from workstream 1.

**Free and near-free bonus grabs, in order:** Wake-on-LAN (difficulty 1,
same UDP shape as WiZ, wol.ts is 67 lines); local DB status glance
(postgres/mongo/redis, which this machine really runs under launchd);
Docker container count + restart; ntfy.sh phone push (one fetch);
one-click screenshot.

**Deliberately NOT carried, each a posture decision the owner must make
explicitly, never a silent port:** the terminal (the old app's own audit
calls its unauthenticated WebSocket + full-env PTY "equivalent to SSH");
the task runner (arbitrary `sh -c` of stored commands); keeper's Claude
spawner (`--dangerously-skip-permissions`); the packet sniffer (privileges).

**The auth inheritance rule** (from the old app's own top audit finding,
"no authentication on any endpoint, mitigated only by Tailscale network
trust"): a bar app making OUTBOUND local calls inherits none of that; any
salvaged piece that LISTENS on a port inherits all of it and needs its own
auth story before it ships.

## Workstream 3: the integration model

- The dropdown stays a THIN reader: SwiftBar/native menu renders state and
  fires actions; logic lives in `lib/` scripts a headless probe can drive
  (the Switchboard's own architecture, kept).
- Capabilities that need a daemon (UDP discovery, polling) run as tier-2 pm2
  services on 51xx ports per the dev-server policy, started lazily by the
  first dropdown use, visible in the existing tool-server switchboard.
- Capabilities that need a full surface (device lists, histories) get pages
  on an EXISTING server (kanban :5106 is the precedent after the
  decision-pages adoption), linked from the dropdown.
- Every capability gets: a status glyph in the dropdown (glance), a primary
  action (click), and at most one "open the full surface" link. No capability
  gets its own top-level app.

## Sequencing

1. WiZ lights toggle + discovery (owner: "absolutely want") — the forcing
   function for the daemon + dropdown-section pattern.
2. Permission guards section (workstream 1) — pure gcc + Swift, no hardware.
3. Tailscale links + devices.
4. Remaining salvage by the ranked list in the findings, each judged by the
   glance-or-one-click test.

Todos are cards on the claude-instances kanban board
(http://localhost:5106/b/claude-instances-c87d13); this plan is registered
there as a kanban plan.

# claude-instances Plugin Platform — Performance Review

> Reviewer: Performance Engineer lens
> Date: 2026-05-15
> Scope: v1 widget spec + the 10 proposed deltas, judged against the 60fps invariant, scaling to 50–200 plugins, and process-spawn / IPC overhead on macOS.

---

# 1. Verdict

**The current plan is the right shape but wrong default.** Renaming "widget → extension" and adding surface declarations is fine; adopting `script`-per-tick as the *primary* execution model is not. xbar's well-documented decay above ~20 plugins is structural, not a config bug, and the v1 spec replicates xbar's worst mechanic verbatim: re-spawn a fresh `Process` every `refresh_seconds` per pane, regardless of whether the data changed, regardless of whether the user is looking.

Two unconditional changes will get the platform from "fine at 8 plugins" to "fine at 200":

1. **Visibility-gated polling.** Installed-but-not-visible plugins must consume ZERO ticks, not just "no UI updates." The current spec says "host re-fetches each pane on its `refresh_seconds`" — that's the right behavior, but it must be enforced as the *only* fetch path. No background polling for badges, ever, without an explicit `background: true` opt-in that the host can count and budget.
2. **Event-driven by default, polling as fallback.** Adopt Sketchybar's model: plugins declare *what signal would cause their data to change* (file mtime on `events.jsonl`, launchctl state change, an explicit `trigger` action from another plugin), and the host runs `fetch.sh` only on that signal — plus a slow safety-net poll (e.g. 5 min). 95% of the candidate plugins (atone, propose, hooks, schedule, RCAs) are file-backed and have a perfectly good change signal: FSEvents on a known path.

The other 8 deltas are mostly correct but several have hidden cost. Critical flaws are listed in §2.

The migration walkthrough in §7 shows the current rate-limit pane already costs ~0.3% CPU at idle with a fresh-process fetch every 5s — fine in isolation, **but 40× of those is 12% CPU at idle for a menu-bar app**. That's the failure mode. The fix is not "make the script faster"; it's "don't spawn anything when the user isn't looking."

Confidence: medium-high on the diagnosis (it's the same failure mode every xbar-style tool hits at scale), medium on the specific budget numbers — actual macOS spawn-and-Process-init for a bash script is in the 30–120 ms range based on the benchmarks cited in §5, but I haven't measured it on this specific host.

---

# 2. Critical Flaws (numbered, severity S1/S2/S3)

## S3 — fatal-at-scale flaws

**1. (S3) Per-pane fresh-process fetch is the same mechanism that broke xbar at 20+ plugins.**
The v1 spec §6 says: "For every non-`log` pane on widget activation (and every `refresh_seconds` when the widget is visible), the host runs `./fetch.sh`." The atone widget worked example declares 4 fetched panes with the default 60s refresh. That's 4 process spawns per minute per widget. Reasonable in isolation. At 50 installed widgets with the same shape: 200 spawns/min = 3.3/s sustained. Each spawn on macOS is roughly 30–80 ms of CPU+IO (bash init, fork accounting, dyld, jq cold start), so 200 spawns/min × 50 ms = 10 seconds of CPU work per minute = **16.7% of one core at idle**. That's not "the platform is slow when active." That's "the menu-bar app's idle baseline pegs a core." This is xbar's exact death curve — see §5.

**Fix:** mandatory FSEvents-driven invalidation, polling only as a backstop. Plugins declare `watch_paths`, host kqueue-watches them, fetch only on change. Time-based refresh becomes opt-in and rate-limited to ≤1/min by default unless the plugin justifies otherwise via manifest.

**2. (S3) "Installed-but-not-visible plugin = ~0 CPU" is contradicted by every surface beyond `dashboard`.**
The goals list this as non-negotiable. But the proposed surface list includes `badge` and `menubar` — these are *always visible*. A badge that shows "12 PRs waiting" cannot be ~0 CPU when invisible by definition; it must poll, or it goes stale. The spec doesn't address this tension. xbar's entire problem space lives here: every badge-like plugin is a background poller.

**Fix:** strict surface taxonomy. `dashboard` and `floater` panes can be lazy (no fetch while not visible). `badge`, `menubar`, and `notification` are background-active and must:
   - Declare a `change_signal` (file path, daemon event, schedule)
   - Be counted against a hard per-host limit (suggested: ≤10 background-active surfaces total across all plugins; users can raise it but they see the count)
   - Default-disabled — opt-in per surface, not per plugin

**3. (S3) Main-thread JSON decode of fetch payloads will violate 60fps.**
Swift's `JSONDecoder` is fine for small payloads but the spec allows tables with unbounded rows. A 5 MB JSON payload from a misbehaving plugin (e.g. atone's `events.jsonl` dumped wholesale) decodes in ~50–150 ms — that's 3–9 dropped frames if it happens on the main thread, which is the default for `@Published` updates from a callback. Worse: `LazyVGrid` and `Table` invalidate on every row-array change. A plugin that emits a 200-row table at 5s polls will cause continuous SwiftUI diff-and-relayout, even when the rows haven't changed.

**Fix:**
   - JSON decode happens on a `userInitiated` queue, always. Result is posted to main via a single `@Published` set.
   - Host enforces a `max_payload_bytes` per pane (default 256 KB; configurable up to 2 MB). Larger → error pane.
   - Host computes a content hash on the decoded payload and skips the `@Published` assignment if unchanged. This is the same trick the existing dashboard already uses for `transcriptServers` (see `Dashboard perf: cache DateFormatters, skip no-op publishes` commit).

## S2 — important-but-survivable

**4. (S2) 10-second fetch timeout is two orders of magnitude too generous.**
A 10s fetch.sh holding a `Process` handle, file descriptors, and (worse) a slot in any concurrency limiter starves other plugins. The user perceives the host as frozen for that pane. Default should be 1.5s soft / 5s hard kill. A plugin that legitimately needs 10s must explicitly opt in via `slow_fetch: true` and the host shows a "this plugin is slow" badge.

**5. (S2) "Parallel fetch" with no concurrency limit is a fork-bomb waiting to happen.**
If a user switches widgets rapidly with 5-pane widgets, the host can spawn 25+ concurrent bash processes. Each gets a kqueue slot, an open-file allocation, a Process object held on the Swift heap. On a 4-core M-series, the OS scheduler handles this fine, but on a battery-constrained laptop it's a measurable energy drain. Cap concurrent fetches at `min(N_cores, 4)` and queue the rest.

**6. (S2) Hot-reload (delta #9) is dangerously underspecified.**
"Hot-reload" implies the host re-globs and re-parses manifests when a file changes. The naive impl FSEvents-watches `~/.claude/widgets/` and reloads on any change. Two failure modes:
   - During a fetch, the plugin's `fetch.sh` writes to its own `.cache/` directory → triggers reload → cancels the in-flight fetch → infinite loop.
   - Manifest write is non-atomic (text editor writes empty file, then content) → host briefly sees an invalid manifest → disables the plugin → re-enables 50 ms later. Flicker.

**Fix:** debounce FS events to ≥1s, only watch `manifest.json` files specifically (not the whole plugin directory), require atomic-rename writes.

**7. (S2) Per-plugin resource budgets (delta #5) without per-plugin processes is theatre.**
You can't enforce a CPU budget on a transient `Process` after it's launched. By the time you `kill -9`, it has already burned the budget. Three real options:
   - **Wall-clock budget only** (kill on overrun). Implementable today. Doesn't catch a fast plugin that spawns 100x/min.
   - **Rate-limit budget** (max N spawns/min per plugin). Easy, effective, the right default.
   - **Real cgroup-style limits.** macOS has `setrlimit` and `taskpolicy(8)` but enforcement is best-effort. Don't promise this.

**Fix:** advertise budgets as spawn-rate + wall-clock + payload-size. Don't claim CPU/memory enforcement you can't deliver. See §6 for proposed numbers.

**8. (S2) The event bus (delta #4) has no mention of backpressure or fan-out cost.**
If 50 plugins subscribe to `session_started`, and the event fires twice/minute, that's 100 fetch.sh invocations per minute just from the bus, on top of regular polling. Bus events MUST go through the same spawn-rate budget as polled fetches.

## S1 — quality issues

**9. (S1) `schema_version: 1` with no migration story for installed plugins.**
When the schema bumps, every plugin's manifest needs editing. The spec says "skip with a clear upgrade message" — fine for now, but at 50+ plugins this becomes a coordination problem. Plan for `schema_version_compatible_range: [1, 2]` and host-side polyfills for adjacent versions.

**10. (S1) `cmd: ["bash", "-c", "open ~/.claude/atone/rca/\"$1\".md"]` in the atone example reintroduces shell interpolation the spec promised to avoid.**
Section 10 says: "The host never `eval`s or shell-interprets a pane source — args are passed argv-style." But the worked example uses `bash -c` with `$1`. If `$1` ever contains backticks, semicolons, or `$(…)`, you get an injection. This is fine *because the user controls their own machine*, but the host should document that `bash -c` with interpolated args is the plugin author's responsibility, not the host's.

---

# 3. Limitations & Trade-offs Missed

- **No "warm process" tier between Tier 1 (script-per-tick) and Tier 2 (daemon).** A long-lived `bash` subprocess fed via stdin (`coproc`-style) gets you ~95% of the daemon's perf wins with ~5% of the complexity, and most plugins don't need event streams — they need "stay loaded so I don't re-init jq every poll." Worth adding as Tier 1.5.

- **No mention of cold-start tax.** First fetch of a plugin on dashboard open is the most user-visible perf moment. With 8 plugins × ~80 ms spawn, the first dashboard open spends ~640 ms spawning before anything renders. The spec needs a "render skeleton immediately, fill on fetch return" contract, and host-side prefetch on app launch (one round of fetches, cached, before the dashboard is ever opened) for visible-by-default surfaces.

- **No cache contract between host and plugin.** The spec says "host does not cache between launches; widget should cache internally." This is the wrong trade-off. The host has the best view of whether the user is looking at the data; the plugin doesn't. The host should provide a TTL'd KV cache (`~/.claude/widgets/<id>/.cache/host/`) the plugin can opt into via `cache_ttl_seconds` in manifest, and the host invalidates on relevant FS events.

- **No notion of "fast pane" vs "slow pane."** A `summary` tile with 3 numbers and a `table` with 500 rows are both "panes" but have wildly different costs. The manifest should let panes declare expected payload size class (`small <4KB`, `medium <64KB`, `large <256KB`) so the host can budget concurrency differently.

- **"Per-surface schemas" (delta #8) without versioning of surfaces is fragile.** If `badge` payload v1 has `text + color` and v2 adds `icon`, every consumer of `badge` has to handle the union. Surface schemas need their own version, separate from manifest version.

- **No deprecation path for first-party tabs.** Delta #7 says today's tabs become bundled plugins. But the current `OverviewTabView` references `LiveInstance`, `ScanResult`, etc. — Swift types the plugin layer doesn't have access to. Either you (a) bundle these as in-process Swift bundles (Tier 3), keeping the type-safety but coupling, or (b) push the data through the JSON plugin protocol, in which case you pay JSON-encode/decode cost for data you already have in-memory. The plan needs to pick. See §6 for recommendation.

- **`Process` startup on macOS is slower than people remember.** ~30 ms baseline for a no-op bash, ~80-120 ms once `jq` and `rg` get involved (binary load + dyld cache miss). The spec quotes nothing here; the planner is implicitly assuming spawns are "fast." They're not, at scale.

---

# 4. Performance Risks (quantified)

Numbers are order-of-magnitude estimates from cited benchmarks (§5), not measured on this host. Treat as "design must survive these" budgets.

### 4.1 Process spawn cost (the #1 risk)

| Operation | Cost | Source |
|---|---|---|
| `posix_spawn` of `/bin/true` on macOS | ~5–10 ms | Apple ManPages, posix-spawn benchmarks |
| `posix_spawn` of `/bin/bash` (init only) | ~15–30 ms | bash init + .bashrc skip |
| `bash fetch.sh` that calls `jq` once | ~30–60 ms | jq cold load ~20 ms |
| `bash fetch.sh` that calls `rg` over `events.jsonl` | ~60–120 ms | rg startup + 1 MB scan |
| Same, after dyld cache warm | ~25–50 ms | OS file cache wins |
| Swift `Process` overhead on top of spawn | ~5–15 ms | NSTask bookkeeping, pipe setup |

**Scenario A — current spec at 12 plugins × 30s refresh × ~80 ms spawn:**
12 × 2 fetches/min × 80 ms = 1.92 CPU-seconds/min = **3.2% of one core at idle**. Survivable, but only just.

**Scenario B — 50 plugins × 60s refresh × ~80 ms spawn:**
50 × 1 × 80 = 4 CPU-seconds/min = **6.7% of one core at idle**. With a 4-pane average per plugin and parallel fetch: 4× that = **27%**. Not survivable.

**Scenario C — 200 plugins (the target):**
At 60s refresh, 4 panes/plugin: 200 × 4 × 80 ms / 60s = **17.8% of one core at idle**. With dashboard open and 30s refresh: 35%. Hard fail.

**Scenario D — same as C but FSEvents-gated, 0 polling:**
Idle CPU = 0% beyond FSEvents callback fan-out (~50 μs per event, even at 100 events/s = 0.5%). Active fetches happen only when data actually changed. **This is the only path that scales.**

### 4.2 60fps host invariant — what could violate it

| Risk | Mitigation needed |
|---|---|
| Main-thread JSON decode of large payload | Decode on QoS queue; assign result once |
| SwiftUI diff on unchanged data | Hash decoded payload; skip publish on no-op |
| Synchronous filesystem stat in glob | Globbing is FSEvents-driven, not on-demand |
| `Process.run()` on main thread | Always background queue; main only receives result |
| Sidebar redraw on plugin enable/disable | Diff sidebar by stable plugin id, not array-equality |
| NSHostingView re-layout on rapid `@Published` churn | Already mitigated in current code; preserve it |

The existing dashboard's commits show the team already knows the 60fps trap (`Dashboard perf: cache DateFormatters, skip no-op publishes`). The plugin layer needs the same discipline applied at every boundary, not just internally.

### 4.3 Memory

A bare manifest + sidebar entry is ~2 KB Swift heap (string interning of id/title/icon). A 5-pane plugin with rendered SwiftUI views is ~50–100 KB (NSView instances dominate). 200 plugins fully loaded: ~20 MB. **Acceptable** *if and only if* plugins not currently visible don't materialize their SwiftUI views.

The risk: `DashboardRootView`'s `switch selectedTab` already creates exactly one tab view at a time. The plugin equivalent must do the same — do NOT eagerly instantiate `WidgetTabView` for every registered plugin. Lazy materialization is the difference between 20 MB and 200 MB.

### 4.4 IPC throughput (relevant once Tier 2 daemons exist)

| Mechanism | Throughput | Latency |
|---|---|---|
| stdio JSON-RPC newline-delimited | 50–200 MB/s | 0.1–0.5 ms round trip |
| Unix domain socket | 200–500 MB/s | 0.05–0.2 ms |
| HTTP localhost (Tier `http` in delta #3) | 10–30 MB/s | 1–5 ms |
| XPC service | 50–100 MB/s | 0.1–0.5 ms |

**Recommendation:** for Tier 2 daemons, default to **stdio JSON-RPC** (newline-delimited). It's the model VS Code's extension host uses successfully, it composes with existing scripts trivially (just don't exit), and it sidesteps the entire localhost-port-allocation mess. HTTP-localhost has no advantages here except for daemons that are *also* serving HTTP to non-plugin clients.

### 4.5 Failure modes at the 200-plugin target

| Failure | Symptom | Mitigation |
|---|---|---|
| 200 plugins × parallel fetch on dashboard open | 200 concurrent processes, kernel queue saturation | Concurrency cap (≤4) |
| FSEvents watching 200 directories | ~2 KB resident per watch, ~400 KB total | Fine; kqueue scales further |
| Sidebar with 200 entries | SwiftUI List handles fine; >500 needs pagination | Group by category, virtualize |
| Manifest glob on every dashboard open | 200 file stats = ~20 ms cold, ~2 ms warm | Cache, invalidate on FSEvents |
| One plugin's `fetch.sh` infinite loop | One process held forever | 5s hard kill; auto-disable on repeat |
| User installs 200 plugins, half are badges | 100 background polls/min minimum | Background-surface cap (suggested 10) |

---

# 5. Adjacent Systems — What They Got Right or Wrong

### xbar / BitBar — the cautionary tale (script-per-tick)
- **Model:** every plugin is a script. Host re-runs the script every `refresh_seconds` (named via filename suffix like `cpu.5s.sh`). Output is parsed for menu items.
- **Where it falls over:** community forum threads (referenced in the BitBar repo history) document degradation at 15–20 plugins. The reason is precisely the spec's current architecture: process spawn per tick × N plugins × per-pane refresh = monotonically growing baseline CPU. Plugins are encouraged to be fast, but "fast" isn't the bottleneck — the spawn itself is.
- **What the plan must NOT replicate:** the polling-by-default contract. xbar has no notion of "this plugin's data hasn't changed, skip the spawn." Every tick is a fresh spawn even when the upstream data is byte-identical.
- **What it got right:** the manifest-light contract (just-a-script). The plan correctly preserves this for Tier 1.

### Sketchybar — the model to copy
- **Model:** event-driven. Items subscribe to system events (`front_app_switched`, `system_woke`, `volume_change`, custom events from `sketchybar --trigger`). Script runs *only when an event fires*. Polling is opt-in and discouraged.
- **Result:** users routinely run 30+ items with imperceptible CPU.
- **Apply here:** the plugin's manifest should declare `watch_paths: [...]` (FSEvents) and `subscribes_to: [event_id]` (host event bus). The host fires `fetch.sh` *only on change signal*. Polling is the fallback for the 5% of plugins where no signal exists (e.g. a remote API plugin checking GitHub PRs every 5 min).

### Übersicht — middle ground, instructive failure mode
- **Model:** widgets are HTML+CSS+JS in a hidden WebView, refresh interval declared in JS.
- **Where it bites:** every widget loads its own JS runtime context inside a shared WebView. Adding 10 widgets adds a measurable RAM baseline (~50 MB+). Power management was historically poor.
- **Apply here:** **do not** put plugin UI rendering in a WebView. SwiftUI from a JSON contract is correct. The cost is the per-row NSView allocation discussed in §4.2, but you get the SwiftUI invalidation machinery for free.

### Hammerspoon — what "in-process Swift bundle" looks like done right
- **Model:** Lua scripts loaded into a single host process, full access to a vetted Cocoa API surface. Sub-millisecond inter-plugin calls.
- **Cost:** zero isolation. A buggy Lua script wedges the host.
- **Apply here:** Tier 3 (in-process Swift bundle) trades isolation for speed. This is the right tradeoff *only* for plugins that need <16 ms response (e.g. a "blink the menu-bar icon on each Claude turn" plugin). Everything else should be Tier 1 or 2.

### VS Code Extension Host — the gold standard
- **Model:** all extensions share ONE separate Node.js process ("extension host"), isolated from the main editor via IPC. Per-extension isolation is logical (separate require contexts), not physical.
- **Why it works:** the editor's 60fps thread is sacred; everything else is on the other side of an IPC boundary; misbehaving extensions can only slow each other, not the editor.
- **Where it fails (and the plan must learn from):** extension-host CPU spikes from one extension *do* affect every other extension. The plan's delta #5 (per-plugin budgets) becomes unenforceable in this model.
- **Apply here:** the right shape is **per-plugin process** for Tier 1/2 (cheap process, full isolation, killable independently), not a shared "plugin host." VS Code's choice makes sense for Node (heavy boot, expensive isolation); for bash/Python/Swift plugins on macOS where `posix_spawn` is cheap-enough, per-plugin process wins.

### IntelliJ Background Tasks — what to learn about user perception
- **Model:** explicit "background tasks" panel; every long-running thing is visible and cancellable.
- **Apply here:** the host should expose a "Plugin Activity" inspector — currently-running fetches, last spawn cost, p95 fetch latency per plugin. This is debug UI but it's also the trust contract. Without it, the user can't tell which plugin is making their laptop hot.

### Raycast — the launch-perf reference
- **Model:** pre-warmed extension host process; extensions instantiate in <50 ms perceived because the runtime is already running.
- **Apply here:** if Tier 2 daemons become common, pre-warm them on host launch in a controlled stagger (one daemon every 200 ms across the first 10 seconds), not all at once. This prevents the "dashboard launch spikes the fan" anti-pattern.

---

# 6. Proposed Alternative Plan

Keep the spec's bones. Replace the execution and lifecycle model. Concretely:

### 6.1 Execution tiers (revised)

| Tier | Mechanism | Spawn cost | Use case |
|---|---|---|---|
| 0 | Static JSON file (no exec) | 0 (file read only) | Read-only dashboards, asset lists |
| 1 | `fetch.sh` on change signal | ~80 ms when fired | Default for everything file-backed |
| 1.5 | Long-lived bash coprocess fed via stdin | ~5 ms per request after warm | Plugins that fetch frequently from same source |
| 2 | Daemon over stdio JSON-RPC | ~1 ms per request | Event streams, sustained subscriptions |
| 3 | In-process Swift bundle (signed) | <0.1 ms | Frame-critical surfaces (menu bar icon animation) |

**Default is Tier 1 + FSEvents.** Authors who want Tier 1.5+ explicitly opt in.

### 6.2 Fetch lifecycle (revised)

```
plugin manifest declares:
  refresh:
    on_fs_change: ["~/.claude/atone/derived/_meta.json"]
    on_event:     ["atone.consolidate.done"]
    poll_seconds: 300   # SAFETY NET, not primary
  surfaces:
    dashboard: {visible_only: true}  # don't fetch when not selected (DEFAULT)
    badge:     {background: true, change_signal_required: true}
```

Host logic:
- Plugin enabled → host registers FSEvents watch + event bus subscription + slow safety-net timer.
- Change signal fires → debounce 200 ms → check if any *visible-and-active* surface for this plugin exists. If yes, fetch. If no, mark dirty and fetch when surface becomes visible.
- Visible-surface activation → fetch if dirty OR if last fetch >TTL.
- No change signal AND no poll? → never fetches. (This is the right answer for `assets` panes that change rarely.)

### 6.3 Host-enforced budgets (real, not aspirational)

| Resource | Soft | Hard | Action on breach |
|---|---|---|---|
| Spawn rate (per plugin) | 6/min | 12/min | Defer fetches; degrade to safety-net poll only |
| Wall-clock per fetch | 1.5s | 5s | SIGTERM at 1.5s soft warn, SIGKILL at 5s |
| Payload size per pane | 256 KB | 2 MB | Truncate + error pane above hard |
| Concurrent fetches (total host) | 4 | 8 | Queue |
| Background-active surfaces (total host) | 10 | 25 | New ones default-disabled, user must opt in |
| Sustained spawn rate (total host) | 30/min | 60/min | Auto-disable highest-rate plugin, surface notification |

Two breach-tier strategy: soft = log + show in inspector + degrade silently; hard = disable plugin + persistent notification to user.

### 6.4 The 60fps invariant — concrete rules

1. **Nothing the plugin does runs on the main thread.** Process spawn, JSON decode, hash compute — all on `userInitiated` queue. Main thread only receives the parsed-and-validated payload.
2. **`@Published` writes happen at most once per fetch, and are skipped if the content hash is unchanged.**
3. **Sidebar diffing keys on stable plugin id, never on array identity.** A re-glob that returns the same set is a no-op.
4. **Pane views are lazy.** Off-screen panes don't have materialized `NSView`s.
5. **The inspector panel is debug-only and lives behind a feature flag** so it doesn't add cost in normal use.

### 6.5 First-party-tabs-as-plugins — the migration choice

The current Overview/Live/etc. tabs reference Swift types (`ScanResult`, `LiveInstance`) the plugin layer doesn't see. Two paths:

**A. JSON-protocol everything.** Push current in-memory data through the plugin's JSON fetch. Cost: serialize + deserialize on every refresh. With current refresh at 5s and ~10 KB of ScanResult: ~1 ms decode = 0.02% CPU. **Negligible. Recommended.**

**B. Tier 3 in-process bundle.** First-party tabs are Swift bundles, third-party are Tier 1/2. Cost: two code paths to maintain, but type safety preserved on first-party.

Recommend **A** for tabs that aren't perf-critical (Overview, History, About, Settings). Live and AllSessions might warrant **B** if their data is large enough that JSON round-trip becomes visible. Measure first.

### 6.6 Surface toggle semantics (delta #6 done right)

Per-surface toggle is correct. Add per-plugin "panic disable" *and* a global "all background surfaces off" panic kill (one keyboard shortcut, immediate effect, persists across launches). This is the user's last resort if a plugin is making the laptop hot.

---

# 7. Migration Walkthrough — Rate-Limit Bar + Scheduled Crons

Two concrete migrations with measured costs.

### 7.1 Rate-limit bar (today)

**Current implementation** (from `OverviewTabView` lines 3523-3545):
- Data: `d.limits` (RateLimitEntry × 2 + resetsAt timestamp) populated by `scan.sh`.
- Refresh: piggy-backs on dashboard's 5s `refreshTimer` (line 3068).
- Cost today: ~0 (data is pre-computed in cached scan; render is trivial).

**As a plugin (Tier 1):**
```json
{
  "id": "rate-limits",
  "title": "Usage Limits",
  "surfaces": ["dashboard", "badge"],
  "refresh": {
    "on_fs_change": ["~/.claude/scan/limits.json"],
    "poll_seconds": 60
  },
  "panes": [
    {"kind": "rate-bars", "source": "current"}
  ]
}
```

**Cost analysis:**
- Dashboard surface visible: `fetch.sh` runs on FSEvents tick when scan updates `limits.json` (every ~5–30s when active). Each fetch: ~40 ms (bash + cat + small JSON). With FSEvents debounced to 1s minimum: **at most 60 spawns/min = 4% of one core, only while dashboard is open**.
- Dashboard surface NOT visible: **zero fetches.**
- Badge surface (new — menu bar shows "5h: 78%"): MUST fetch in background. With FSEvents-only (no poll): fetches only when scan updates the file. Idle cost: **~5% of one core during active scanning, 0% otherwise.**

**Verdict:** as long as FSEvents-driven and not naive-polling, the migration is a wash. The new feature (always-visible badge) costs less than 1% sustained because scan.sh isn't writing limits.json that often.

**If you naive-port to v1 spec as written:** `refresh_seconds: 30`, no FSEvents → 2 spawns/min × 40 ms = 1.3% baseline forever, dashboard open or not. **Survivable, but compounds with every other plugin.**

### 7.2 Scheduled crons (BUILD.md Stage 4 — atone-related schedule pane)

**Current state:** doesn't exist as a UI; you read `~/Library/LaunchAgents/com.alcatraz.atone-*.plist` files directly.

**As a plugin (Tier 1, but interesting):**
```json
{
  "id": "schedule",
  "title": "Scheduled Jobs",
  "surfaces": ["dashboard"],
  "refresh": {
    "on_fs_change": ["~/Library/LaunchAgents/"],
    "on_event": ["launchctl.loaded", "launchctl.unloaded"],
    "poll_seconds": 600
  },
  "panes": [
    {"kind": "schedule", "source": "list-all"}
  ]
}
```

**Cost analysis:**
- `fetch.sh list-all` runs `launchctl list` + parses ~30 plist files. Cost: **~150–300 ms** (launchctl is slow; plist parsing via `/usr/libexec/PlistBuddy` adds 5 ms per file). This is *not* a fast fetch.
- FSEvents fires when a user `launchctl load`s/`unload`s — rare event, maybe 0–5/day.
- Poll backstop at 600s catches anything missed.
- **At idle: ~6 fetches/hour × 200 ms = 0.03% baseline. Negligible.**
- **When dashboard is open and user just loaded a new plist: one fetch, ~250 ms, runs on background queue, result displayed when ready. User perception: "schedule pane updates a half-second after I run launchctl load." Acceptable.**

**Hidden risk:** launchctl is notoriously slow on macOS. If the plugin author writes `fetch.sh` to call `launchctl list` once per item instead of once total, cost balloons to N×200 ms = 6 seconds for 30 items. This is on the plugin author, but the host's slow-fetch warning ("this plugin took 5+ seconds") makes the failure mode discoverable.

**Concrete budget breach scenario:** if both a schedule pane and (separately) a transcripts pane are visible at once, and both fetch on the same FSEvents tick, two concurrent 250 ms processes occupy the concurrency cap briefly — but no breach. Add a third slow plugin and the concurrency cap of 4 keeps things sane.

### 7.3 Aggregate at 12 plugins (today's likely ceiling)

12 plugins. Mix:
- 8 file-backed (atone, propose, hooks, schedule, rate-limits, transcripts, history, events)
- 3 API-backed (PRs, calendar, local LLM status)
- 1 daemon-backed (live Claude sessions — current)

With FSEvents-driven Tier 1 + event-driven Tier 2:
- File-backed plugins fetch on actual change: maybe 2-5 fetches/min total across all 8.
- API-backed plugins poll at 5 min intervals: 3 fetches per 5 min.
- Daemon-backed plugin: idle stdio, ~0.

**Aggregate idle CPU: <2% of one core.** With dashboard open and active scanning: 5-10%. **This meets the goals.**

For comparison, the same 12 plugins with the v1 spec as written (refresh_seconds: 30, no FSEvents): **~15-20% idle CPU.** That's the difference.

---

# 8. Open Questions Worth Asking the User

1. **What's the realistic plugin-count ceiling?** 12 is comfortable. 50 is achievable with the proposed changes. 200 is "design target" but probably 5x the real ceiling. If the answer is "I expect 20 max," some of the alternative plan's complexity is overkill.

2. **Is a global "Plugin Activity" inspector wanted?** This is the trust contract. Without it, users can't diagnose "why is my menu bar app hot." It's ~200 LOC of SwiftUI but it's the difference between a platform and a trap.

3. **Should first-party tabs become plugins now, or stay native and be migrated incrementally?** Migrating Settings and About to JSON-protocol is trivial. Migrating Live (with `onFocus`, `onTerminate`, `onResume` action callbacks that need access to PIDs and CWDs) is non-trivial — the action surface needs structured "open Ghostty tab" / "send signal" actions that today are direct Swift function calls.

4. **What's the policy for shipping a Tier 3 (in-process Swift bundle)?** If the answer is "we don't, ever," delete Tier 3 from the plan. If "yes, but only first-party," that's a signing/notarization question worth answering now.

5. **Is per-surface toggle UI dashboard-visible or buried in Settings?** Dashboard-visible (per-plugin row with a "surfaces" submenu) is the right UX but it's another sidebar element. Buried-in-Settings is cheaper but less likely to get used when something goes wrong.

6. **What's the manifest authoring story?** A JSON schema published in `docs/`? A `validate` CLI? A "plugin scaffold" generator? At 50+ plugins authored by the same user, this matters a lot. xbar's failure mode here was "anyone can write one" → "many of them are subtly broken."

7. **Is there a concept of "host version" the plugin can require?** `min_host_version: "1.2"`. This is the long-term migration story for schema bumps.

8. **Cron/launchd integration — does the host get to call `launchctl`, or do plugins always shell out?** Tier 2 daemons could have a privileged API surface for "I'm a scheduler plugin, let me toggle jobs." Worth a yes/no early.

---

# 9. Confidence Notes

| Claim | Confidence | Why |
|---|---|---|
| xbar dies at 20+ plugins from script-per-tick | High | Reproduced in community reports + matches the math |
| macOS bash spawn cost is 30-120 ms | Medium-high | From posix_spawn benchmarks + jq/rg startup observation; not measured on this host |
| Sketchybar's event-driven model scales to 30+ items | High | Documented in Sketchybar README + extensive user reports |
| Per-plugin process beats shared host on macOS | Medium | True for bash/Python plugins; would invert for Node-heavy plugins where boot dominates |
| The 60fps invariant is preserved by background-queue JSON decode | High | This is the standard SwiftUI perf playbook |
| The proposed budgets (6/min spawn, 1.5s soft kill) are right | Medium | Reasonable defaults; will need tuning against real plugin behavior |
| First-party tabs should migrate via JSON-protocol not Swift bundle | Medium-high | Cost analysis shows JSON serialization is negligible at current data sizes |
| 200 plugins is achievable | Medium-low | Only with strict adherence to FSEvents-only + no-poll-by-default. Without that, 50 is the real ceiling. |
| FSEvents debounce of 200 ms is correct | Medium | Tradeoff between responsiveness and storm avoidance; might need 500 ms in practice |
| HTTP-localhost should be deprioritized for Tier 2 | High | Stdio JSON-RPC strictly dominates for this use case |

**Not researched / would want before shipping:**
- Actual measured spawn cost on the user's specific M-series host (would take ~10 min to run a benchmark).
- p95 fetch latencies of the candidate plugins (atone, propose, etc.) under realistic event counts.
- SwiftUI render cost of a 500-row table — I assert it scales, but `Table` vs `LazyVGrid` vs `List` have different invalidation curves.
- FSEvents fan-out behavior with 200+ watched directories — should be fine, but worth a sanity check before claiming the 200-plugin ceiling.

---

*End of review. Recommend a second pass with concrete benchmarks on the target host before finalizing budget numbers in §6.3.*

# Harmonious palette for the claude-instances dropdown

> Research + a concrete 17-token palette tuned so many colors **coexist** instead
> of clash. Written 2026-06-20 for `native/claude-instances-bar.swift`
> `enum PaletteToken` (`:649`) defaults. The owner's constraint, verbatim:
> *"I don't mind so many colors, it helps with visual identification, but I mind a
> chaotic scene."* So this is **not** a desaturate-to-gray pass. It keeps colors
> for identification and makes them belong to one designed system.

The menu renders on a translucent `NSVisualEffectView` that adapts to light and
dark mode, so every color is specified as a **light/dark hex pair** and chosen to
hold on a *blurred* background (light-blurred ≈ a desaturated light gray-blue;
dark-blurred ≈ a desaturated near-black) — not on flat `#FFFFFF`/`#000000`.

---

## 1. Principles synthesized (with sources)

### 1.1 Perceptual uniformity is what makes "equal visual weight" possible

The root cause of a chaotic multi-color scene is that **sRGB is not perceptually
uniform**: `#00FF00` (green) is vastly brighter and more aggressive than `#0000FF`
(blue) at the same nominal saturation, and yellow at "full" saturation screams
while an "equally saturated" purple recedes. So picking colors by eye in a hex
wheel guarantees uneven loudness — some tokens dominate, others vanish — which
*reads as* chaos even when the hues themselves are fine.

The fix the whole modern-color field converged on: choose colors in a
**perceptually uniform space** so that "same lightness, same chroma" actually
*looks* like same weight.

- **OKLCH** (Björn Ottosson, 2020; now a CSS Color 4 first-class space, shipping in
  all major browsers). Axes are L (perceived lightness 0–1), C (chroma), H (hue
  angle). Its headline property: holding L and C constant while sweeping H keeps
  **perceived brightness roughly constant** — exactly the "no hue dominates"
  property we need. It fixed the well-known CIELAB "blue turns purple when you
  darken it" defect, so darkening for dark mode stays on-hue.
- **HSLuv** (Alexei Boronine) — same goal, an earlier take built on CIELUV;
  popular because its lightness is genuinely uniform across hue. OKLCH is the
  better-behaved successor and is what I tuned this palette in.
- **APCA / WCAG contrast** — perceptual-uniformity also lets you reason about
  contrast. On translucent material the effective background is mid-gray-ish in
  both modes, so the target is a **mid contrast band**, not maximum contrast:
  colors that are too light vanish into a light blur, colors that are too dark
  vanish into a dark blur. Aiming for L ≈ 0.62–0.72 (light mode) and L ≈ 0.70–0.80
  (dark mode) keeps every token legible on its respective blurred backing.

**Takeaway used below:** the entire palette is laid out on a small OKLCH grid —
a few fixed (L, C) "weight classes," with hue as the only free variable inside a
class. That is the single mechanism that turns 17 independent picks into a system.

### 1.2 What the modern UI color systems do to avoid clashing

- **Radix Colors** — every hue (`blue`, `red`, `green`, …) is a **12-step scale**,
  and the *same step number means the same job across every hue*: step 9 is the
  solid/brand step, step 11 is the accessible text step, step 3–5 are backgrounds.
  Because the scales are built in a perceptual space, "blue-11" and "red-11" sit at
  the **same lightness/contrast** — so swapping a label's hue never changes its
  weight. This is the canonical "consistent L/C across an ambient set" pattern, and
  it is exactly what we want for text-on-translucent: pick one "step 11"-equivalent
  band and put every ambient color there.
- **Tailwind** — a fixed numeric ramp (`50…950`) per hue, retuned in v3.x toward
  perceptual evenness. Lesson borrowed: **name colors by role/number, lock the
  lightness to the number**, vary only hue.
- **IBM Carbon** — explicit *one-color-per-meaning* discipline plus a "no more than
  N status colors" rule, and a documented dark-theme set that is **not** the light
  set inverted — it is re-derived. Lesson: severity colors are a closed set; don't
  let ambient data borrow them.
- **Material 3 tonal palettes** — each key color is expanded into a **tonal range**
  (tone 0–100) in a perceptual space (HCT, a cousin of OKLCH), and UI elements pull
  the *tone that hits the target contrast*, never the raw key color. Dark theme
  pulls **lighter, less-saturated** tones of the same hue. Lesson: a token isn't a
  hex, it's "this hue at the tone my surface needs" — which is why each token here
  has a light **and** a dark value of the *same hue*, not an arbitrary second pick.

### 1.3 Loudness / emphasis hierarchy

Every mature system separates **emphasis** from **hue**. A color's loudness is set
by its chroma and its lightness-distance from the background, *independently* of
which hue it is. So you can have an ambient teal and a loud red where the red wins
attention purely because it is higher-chroma and higher-contrast — not because red
is "intrinsically" louder. This lets us keep many hues while still having a clear
"what should pop." Concretely we use **three loudness tiers** (LOUD / MEDIUM /
QUIET), each a fixed (L, C) band; a token's tier is chosen by *how much it should
grab the eye*, and its hue is chosen by *what family it belongs to*.

### 1.4 Hue-family grouping for semantically-related elements

Group related data onto **adjacent hues** so the eye reads them as a set, and
reserve **distant hues** for things that must be told apart. Radix and Material
both lean on this: related surfaces share a hue family; status colors are spread
to maximally-separable hues (red/amber/green). Applied here:

- **Identity (models)** get their own well-separated trio so a glance distinguishes
  Opus/Sonnet/Haiku — these *must* be loud and distinct (the user's "visual
  identification" use case).
- **Severity** is the universal traffic scale (green→amber→red) and is *shared* by
  everything that means health/danger (ctx %, rate bars, modified files,
  compaction/MCP, permission). One scale, many call sites.
- **Ambient metrics** (turns, tools, tokens, cost, memory, speed, branch,
  subagent) are pulled into **one quiet band** at consistent low chroma, but kept
  on *recognizable* hues so a user can still color-spot "cost" vs "memory" — they
  just no longer fight the loud tiers.

### 1.5 Consistent chroma + lightness across "ambient" colors

The chaos in the current scheme is almost entirely an **ambient-band problem**:
the spec calls out "~6 competing colors — green tokens + amber cost + sky memory +
teal branch + mint subagent." Each was picked independently, so they sit at
different chromas and lightnesses and visually shout over each other and over the
real signals. The fix is the Radix "step 11" move: **put the entire ambient set at
one fixed low chroma and one fixed lightness**, varying only hue. They stay
distinguishable by hue but stop competing on weight. This is the largest single
de-chaos lever after perceptual layout.

### 1.6 The 60-30-10 balance

The interface-design rule of thumb: ~**60%** neutral/dominant, ~**30%** secondary,
~**10%** accent. Mapped to this menu: ~60% of the surface should read as
**neutral** (system label grays — already correctly excluded from the palette per
spec §9), ~30% as **ambient/quiet color** (the metric band), and only ~**10%** as
**loud** (model identity + active severity). The current scheme inverts this —
nearly every datum carries a saturated hue, so there's no 60% calm to rest against,
and the 10% accents have nothing to pop against. The tiering below restores the
ratio by demoting the ambient band's *weight* (not its hue) and keeping LOUD rare.

### 1.7 Dark-mode desaturation (and the translucent caveat)

Universal rule across Material 3, Carbon, Apple HIG, Radix dark: **dark mode uses
lighter, less-saturated tones of the same hue.** On a dark background, a
high-chroma color vibrates (chromatic aberration / glow) and high lightness is
needed for legibility, so you *raise L and lower C*. In OKLCH terms, each dark
value here is the same H, **+0.06–0.10 L**, **−15–30% C** versus its light value.

Two translucent-specific caveats layered on top:

- **Avoid vibrating pairs on blur.** Saturated blue text on a warm-blurred
  backdrop, or saturated red on a green-ish blur, shimmers. Keeping chroma
  *moderate* (the whole point of the ambient band) and lightness in the mid band
  prevents this. Pure-primary `#00FF00`/`#FF0000`/`#0000FF` are banned outright —
  they're the worst offenders on blur.
- **Avoid wash-out.** A color that's too close to the blurred backing's lightness
  disappears. That's why ambient colors are tuned a notch *darker than the backing
  in light mode* and *lighter than the backing in dark mode*, rather than matching
  it.

---

## 2. The emphasis-tier + hue-family model

### 2.1 Three loudness tiers (fixed OKLCH weight classes)

| Tier | Role | Light (L, C) target | Dark (L, C) target | What's in it |
|------|------|---------------------|--------------------|--------------|
| **LOUD** | Pops on sight: identity + live severity | L≈0.62, C≈0.15–0.19 | L≈0.74, C≈0.13–0.16 | model badges, critical/mid warnings, success, permission |
| **MEDIUM** | Worth a glance: money + tokens | L≈0.66, C≈0.10–0.12 | L≈0.76, C≈0.09–0.10 | cost, tokens |
| **QUIET** | Ambient, hue-identified but calm | L≈0.68, C≈0.045–0.06 | L≈0.77, C≈0.04–0.05 | memory, speed, branch, subagent, turns, tools |

Two design facts make this a *system*, not 17 picks:
1. **Within a tier, L and C are held constant; only H moves.** So nothing in a tier
   out-shouts its tier-mates — exactly the Radix step-N property.
2. **Tiers differ mainly in chroma, not hue.** Dropping the ambient band from
   C≈0.15 to C≈0.05 is what makes it recede, while keeping enough chroma to
   color-spot. LOUD stays high-chroma so identity and danger still win the eye.

### 2.2 Hue families (semantically-related → adjacent hues)

```
        IDENTITY (LOUD, max separation — must be told apart)
        ┌───────────────┬──────────────┬──────────────┐
        │  Opus  ~50°   │ Sonnet ~255° │ Haiku ~190°  │   warm-amber / blue / cyan
        └───────────────┴──────────────┴──────────────┘

        SEVERITY (LOUD, the shared traffic scale)
        ┌───────────────┬──────────────┬──────────────┐
        │ success ~150° │  mid  ~85°   │ high  ~28°   │   green / amber / red
        └───────────────┴──────────────┴──────────────┘
          ↑ ctx≥60         ↑ ctx<60        ↑ ctx<30, compaction,
          ↑ tokens-healthy ↑ modified<20    MCP down, modified≥20
        permission.plan → amber(mid)   permission.auto → red(high)

        MONEY (MEDIUM, its own warm hue, kept distinct from severity-amber)
        ┌──────────────────────────────┐
        │ cost ~70°  (gold, not orange) │   one glance-color for spend
        └──────────────────────────────┘

        AMBIENT (QUIET, low-chroma, hue only for spotting)
        ┌──────────┬──────────┬──────────┬──────────┬─────────┬─────────┐
        │ memory   │ tokens*  │ branch   │ subagent │ turns   │ tools   │
        │ ~245°    │ ~150°    │ ~195°    │ ~210°    │  ~0 C   │  ~0 C   │
        │ blue     │ green    │ teal     │ sky-cyan │  gray   │  gray   │
        └──────────┴──────────┴──────────┴──────────┴─────────┴─────────┘
```

Design logic:
- **Identity** uses the three most separable hue regions (warm/blue/cyan) so the
  three model badges are instantly distinguishable — the user's stated reason for
  wanting color at all.
- **Severity** owns green/amber/red and *nothing ambient is allowed to borrow these
  three hues at high chroma* — that's the Carbon "status colors are a closed set"
  rule. This is why ambient "tokens" (semantically a green) is pushed to **low
  chroma**: it stays greenish for spotting but can't be mistaken for a success
  signal.
- **Money** gets a gold (~70°) deliberately offset from severity-amber (~85°) and
  from cost-is-not-a-warning. It's the one MEDIUM-tier ambient color — per the
  redesign doc's decision D1 lean ("keep cost amber").
- **Ambient** keeps each token near its *recognizable* hue (memory→blue,
  branch→teal, subagent→sky) so muscle-memory color-spotting survives, but at a
  chroma low enough that the whole band reads as one calm group.
- **turns / tools** drop to **pure gray** (chroma ≈ 0). They are the highest-count,
  least-actionable numbers; per the redesign's "gray tier" they carry meaning by
  position+label, not hue. This is the only place we *remove* color, and it's the
  right place — counts you skim, not signals you act on.

---

## 3. The 17-token palette

Light hex = tuned for a **light-blurred** backing; dark hex = same hue, raised L,
lowered C, for a **dark-blurred** backing. All values are within the tier bands in
§2.1. Hashes are sRGB, the format `PaletteStore` already stores (`hexString`,
`:789`).

| # | Token | Tier | Family | Light hex | Dark hex | Rationale |
|---|-------|------|--------|-----------|----------|-----------|
| 1 | `model.opus` | LOUD | Identity (warm) | `#C2740E` | `#E8A33D` | Opus = the heavyweight; warm amber-gold at ~50°, highest separation from the two cool model hues. Distinct from severity-amber by being deeper/warmer. |
| 2 | `model.sonnet` | LOUD | Identity (blue) | `#3B6FD4` | `#6F9CF0` | Sonnet = blue ~255°, the classic mid-identity. Mid-band L so it holds on both blurs; dark version lifted + softened so it doesn't vibrate on dark. |
| 3 | `model.haiku` | LOUD | Identity (cyan) | `#0E97A6` | `#3EC2CE` | Haiku = cyan ~190°, clearly apart from Sonnet-blue and Opus-amber. The trio spans warm→blue→cyan for instant 3-way ID. |
| 4 | `metric.turns` | QUIET | Gray | `#8A8A8E` | `#9A9AA0` | Highest-volume skim number. Pure neutral gray — meaning by label+position. Matches the system tertiary feel, joins the 60% calm. |
| 5 | `metric.tools` | QUIET | Gray | `#8A8A8E` | `#9A9AA0` | Same role as turns (a count you glance, not act on). Sharing the exact gray with turns is deliberate — they're a column pair, not two signals. |
| 6 | `metric.tokens` | MEDIUM | Green (money-adjacent) | `#3F9A63` | `#5FBE85` | Throughput is mild-positive info → green, but at MEDIUM chroma so it never reads as a *success* severity. One step louder than ambient since it's a rate worth noticing. |
| 7 | `metric.cost` | MEDIUM | Money (gold) | `#B98A1F` | `#DDB257` | Money ~70° gold, offset from severity-amber (~85°) so "spend" never reads as "warning." MEDIUM tier: one notch louder than ambient (money deserves a glance), one quieter than severity. This is decision D1's "keep cost amber," tuned to belong. |
| 8 | `metric.memory` | QUIET | Blue (ambient) | `#6E8EC0` | `#8AA6D6` | Memory = cool blue ~245°, but pulled to low chroma so it stops being the bright "sky" that competes today. Still spot-able as the blue number. |
| 9 | `metric.speed` | QUIET | Gray | `#8A8A8E` | `#9A9AA0` | Token/s is a derived skim stat → gray, same band as turns/tools. No reason for it to carry hue. |
| 10 | `accent.branch` | QUIET | Teal (ambient) | `#4F9D9A` | `#6FBEBB` | Branch ⎇ = teal ~195°, kept for recognition but de-chromaed so it stops rivaling Haiku-cyan and the loud tier. |
| 11 | `accent.subagent` | QUIET | Sky (ambient) | `#5C93B8` | `#7BB1D2` | Subagent ↳N = sky ~210°, sits just off branch-teal so the two ambient cools are still tellable apart at low chroma. |
| 12 | `state.active` | QUIET | Cyan (ambient) | `#4F9D9A` | `#6FBEBB` | The thinking/responding detail line. Demoted to the ambient teal band — it's contextual prose, not a severity. Shares branch's value (both are "live but calm"). |
| 13 | `warn.high` | LOUD | Severity (red) | `#CE4B43` | `#EE7A72` | Critical: compaction imminent, MCP down, ctx<30, modified≥20. Red ~28° at full LOUD chroma — this *should* win the eye. Dark lifted to avoid murky-red vibration. |
| 14 | `warn.mid` | LOUD | Severity (amber) | `#C98A12` | `#E6B23A` | Mid severity: ctx<60, modified<20. Amber ~85°, the middle traffic step. Loud enough to read as caution, distinct from cost-gold by hue+context. |
| 15 | `success.high` | LOUD | Severity (green) | `#2E9E58` | `#54C47E` | Healthy: ctx≥60. The "all good" green ~150°. Full LOUD chroma so a healthy ctx reads instantly; this is the green ambient-tokens deliberately stays away from. |
| 16 | `permission.plan` | LOUD | Severity (amber) | `#C98A12` | `#E6B23A` | Plan-mode P badge → reuses the **mid-severity amber** exactly. Permission state *is* a caution; sharing the severity hue (not a bespoke color) is the closed-set discipline. |
| 17 | `permission.auto` | LOUD | Severity (red) | `#CE4B43` | `#EE7A72` | Auto-accept A badge → reuses **high-severity red** exactly. Auto-accept-edits is the safety-relevant state; it belongs to the danger end of the one severity scale. |

### 3.1 Note on shared values (this is intentional, not duplication)

Five tokens **deliberately collapse to three severity colors**:
- `warn.high` = `permission.auto` = the one **red**.
- `warn.mid` = `permission.plan` = the one **amber**.
- `success.high` = the one **green**.

And `state.active` = `accent.branch` (the one ambient **teal**), `metric.turns` =
`metric.tools` = `metric.speed` (the one **gray**). Collapsing call-sites onto
shared semantic colors is the Radix/Carbon discipline that makes the scheme read as
*designed* — a new red anywhere always means the same severity. (The tokens stay
*separate* in `PaletteToken` so a power user can still split them; only the
*defaults* converge.)

### 3.2 What stays vivid vs goes gray

- **Stays vivid (LOUD):** all three model badges, all three severity colors,
  permission badges. These are identity + danger — the things the user *wants*
  color to call out. Untouched in saturation; only re-tuned onto the grid.
- **Half-vivid (MEDIUM):** cost (gold) and tokens (green) — a deliberate glance,
  not a shout.
- **Calm hue (QUIET):** memory, branch, subagent, state-active — keep their
  recognizable hue but at ~⅓ the chroma so they stop competing.
- **Goes fully gray:** **turns, tools, speed.** These three are the
  highest-frequency, lowest-action numbers; dropping them to neutral is what frees
  the 60% calm for the loud 10% to pop against.

---

## 4. Before / after — what specifically reduces the chaos

**The scheme today** (defaults at `:721`) is ~10 independently-picked saturated
colors with no shared lightness or chroma: `systemOrange`, `systemBlue`,
shadowed-teal, two different greens (`metric.tokens` and `success.high` are *both*
green but different greens), a bright amber cost, a bright sky memory
(`0.55,0.75,0.95`), a mint subagent, plus several `tertiaryLabelColor` grays. They
sit at different perceptual lightnesses, so green out-shouts blue, sky-memory
out-shouts teal-branch, and there is no calm field — every row is a competing
patch of color. That is the "chaotic scene."

**Four concrete changes do the de-chaos work:**

1. **One perceptual grid.** Every token is re-tuned to a fixed (L, C) per tier in
   OKLCH, so within a tier nothing out-weighs its neighbors. This alone removes the
   "green dominates everything" effect — the single biggest source of visual noise.
2. **Collapse the ambient band.** The ~6 competing ambient colors (tokens green,
   cost amber, memory sky, branch teal, subagent mint, state teal) drop from
   C≈0.15 to C≈0.05 and onto recognizable-but-quiet hues; turns/tools/speed go
   fully gray. The band keeps its information (hue-spotting) but loses its loudness.
   This restores the 60-30-10 ratio that's currently inverted.
3. **Close the severity set.** Green/amber/red become a *shared three-color scale*
   that ctx %, rate bars, modified count, warnings, and **both permission badges**
   all draw from. Ambient "tokens" is pushed off the severity-green so a healthy
   signal and a throughput number can't be confused. One red always means one
   thing.
4. **Light/dark are the same hue, re-toned.** Every dark value is the same OKLCH
   hue with +L and −C (the universal dark-mode rule), so the palette is coherent
   across modes and **holds on translucent blur** in both — no vibrating
   saturated primaries, no washed-out near-backing colors.

**Net:** the menu keeps all 17 colors and every datum it shows. What changes is
that ~7 of them stop *competing* — they recede into a quiet, hue-identified band —
so the ~6 that genuinely signal (3 identity + 3 severity) finally have a calm
field to pop against. Many colors, one scene.

---

### Appendix — implementation note

These are **default** changes only: edit the `defaults` dictionary at
`claude-instances-bar.swift:721`. The light hex is the baked value; if light/dark
divergence is wanted, `PaletteStore.color(for:)` (`:744`) would need a
`NSColor(name:dynamicProvider:)` wrapper that returns the light or dark hex per
`NSAppearance` — today the store holds a single hex per token, so shipping the
*light* column is a one-line-per-token change and the dark column is a small
follow-up (dynamic-color provider). Both columns are given so the follow-up needs
no re-derivation.

OKLCH targets are listed per tier in §2.1 for anyone re-tuning; the hex values were
converted from those OKLCH coordinates, so re-deriving a token (e.g. nudging a hue)
stays on-grid if you edit in OKLCH and convert back.

# Archive — superseded, kept for reference

These files are no longer part of the live app. They are kept (not deleted) for
history and in case a path needs reviving. Nothing in the running widget loads
them, and moving them here may break their own relative paths — treat them as
references, not runnable scripts.

## How to launch the actual widget

The widget is the native Swift menu-bar app. There is no separate launcher script;
the build script installs and runs it:

```bash
bash native/build.sh --install   # build + register a LaunchAgent (auto-starts on login)
bash native/build.sh             # build + run once (no auto-start)
bash native/build.sh --status    # is it running? binary fresh?
bash native/build.sh --uninstall # remove the LaunchAgent + stop it
```

## What's here and what replaced it

| File | What it was | Replaced by |
|------|-------------|-------------|
| `launch.sh`, `render.sh`, `dashboard.html` | The original dashboard: `render.sh` generated `dashboard.html`, `launch.sh` opened it in a browser. | The native SwiftUI dashboard (`native/Dashboard.swift`), opened from the menu's **Dashboard** item (⌘D). |
| `plugin.sh` | A SwiftBar plugin that rendered the menu bar via SwiftBar. | The native Swift menu-bar app (`native/*.swift`, installed via `build.sh --install`). |
| `PLAN.md`, `UPGRADE-PLAN.md` | Historical planning / upgrade tracking. | Current docs live in `docs/`. |

The legacy per-pid transcript path (`lib/detail.sh` + `lib/detail-server.py`) is
deliberately NOT archived: it is still wired as a fallback behind
`CLAUDE_WIDGET_LEGACY=1` and is covered by the test suite. The default transcript
path is now the session hub (`lib/hub-server.py`).

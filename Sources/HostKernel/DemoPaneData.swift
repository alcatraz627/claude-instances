import Foundation

/// Hand-crafted `PaneContent` samples used by Phase 3's surface router demo.
///
/// Lives in HostKernel so it can use the internal memberwise inits of the
/// schema types directly. When the registry-driven render path lands (Phase
/// 5), this file becomes a reference example; later it can become a fixture
/// for screenshot tests.
public enum DemoPaneData {
    public static let summary = SummaryContent(tiles: [
        .init(label: "Events recorded", value: "147", trend: "+3 this week"),
        .init(label: "Top pattern", value: "git-add-shape", badge: "S3", tone: .warn),
        .init(label: "Last consolidate", value: "2026-05-14", tone: .ok, progressPct: 73),
        .init(label: "Rate limit", value: "78%", trend: "resets in 2h", tone: .warn, progressPct: 78),
        .init(label: "Disk usage", value: "94%", tone: .error, progressPct: 94),
        .init(label: "Idle plugins", value: "12", tone: .dim)
    ])

    public static let table: TableContent = {
        let cols: [TableContent.Column] = [
            .init(id: "ts", label: "When", width: .fixed(140), align: nil),
            .init(id: "slug", label: "Pattern", width: .flex, align: nil),
            .init(id: "sev", label: "Sev", width: .fixed(50), align: .trailing)
        ]
        let rows: [TableContent.Row] = [
            .init(cells: ["ts": "2026-05-14 16:10", "slug": "staging-mistake", "sev": "S3"],
                  rowActions: [.init(label: "Open RCA", command: "atone.open-rca", args: nil, destructive: false)]),
            .init(cells: ["ts": "2026-05-13 09:42", "slug": "batch-verification-skip", "sev": "S2"]),
            .init(cells: ["ts": "2026-05-12 23:01", "slug": "git-add-shape", "sev": "S3"],
                  rowActions: [.init(label: "Open RCA", command: "atone.open-rca", args: nil, destructive: false),
                               .init(label: "Forget", command: "atone.forget", args: nil, destructive: true)]),
            .init(cells: ["ts": "2026-05-12 12:30", "slug": "render-before-judge", "sev": "S2"]),
            .init(cells: ["ts": "2026-05-11 18:55", "slug": "post-compact-stale", "sev": "S1"])
        ]
        return TableContent(columns: cols, rows: rows,
                            empty: "No events.",
                            truncatedAt: nil, hasMore: nil)
    }()

    public static let schedule = ScheduleContent(items: [
        .init(id: "atone-consolidate", source: "launchd",
              when: "Mon/Wed/Fri/Sun 09:00", nextRun: nil,
              command: "bash ~/.claude/scripts/atone-consolidate.sh",
              enabled: true, logPath: "~/.claude/atone/derived/_consolidate.log"),
        .init(id: "atone-snapshot", source: "launchd",
              when: "Daily 03:00", nextRun: nil,
              command: "bash ~/.claude/scripts/atone-snapshot.sh",
              enabled: true, logPath: nil),
        .init(id: "weekly-todo", source: "cron",
              when: "Mon 09:00", nextRun: nil,
              command: "bash ~/.claude/scripts/weekly-todo.sh ensure",
              enabled: true, logPath: nil),
        .init(id: "asset-cleanup", source: "cron",
              when: "Daily 02:00", nextRun: nil,
              command: "bash ~/.claude/assets/asset.sh cleanup",
              enabled: false, logPath: nil)
    ])

    public static let assets = AssetsContent(items: [
        .init(path: "~/.claude/assets/reports/20260514-1610-atone-system-design/BUILD.md",
              label: "atone system BUILD doc", sizeBytes: 38421,
              mtime: "2026-05-14T16:10:00Z", openWith: .auto),
        .init(path: "~/.claude/atone/derived/index.md",
              label: "atone derived index", sizeBytes: 9128,
              mtime: "2026-05-15T09:00:00Z", openWith: .auto),
        .init(path: "~/.claude/atone/rca/mist-20260514-1610-01.md",
              label: "RCA: staging-mistake", sizeBytes: 4203,
              mtime: "2026-05-14T16:10:00Z", openWith: .auto)
    ])

    public static let log = LogContent(label: "Last consolidate run", text: """
[2026-05-15 09:00:01] consolidate: starting
[2026-05-15 09:00:01] consolidate: reading events.jsonl (147 events)
[2026-05-15 09:00:02] consolidate: clustering by slug...
[2026-05-15 09:00:02] consolidate: 23 distinct slugs identified
[2026-05-15 09:00:02] consolidate: ranking by recurrence x severity
[2026-05-15 09:00:03] consolidate: writing derived/mistake-patterns.md (top 20)
[2026-05-15 09:00:03] consolidate: writing derived/clusters/{A..E}.md
[2026-05-15 09:00:03] consolidate: writing derived/_meta.json
[2026-05-15 09:00:03] consolidate: triggers.json synced
[2026-05-15 09:00:03] consolidate: done in 2.4s OK
""")

    public static let errorSample = PluginError(
        .fetchTimeout,
        "fetch.sh did not respond in 1500ms",
        stderrTail: "+ /usr/bin/jq -r .summary\n/usr/bin/env: 'jq': No such file or directory\nfetch.sh: line 12: jq: command not found",
        actionable: "Install with: brew install jq")
}

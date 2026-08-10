// Drives the real Switchboard state layer headlessly: reads against ground
// truth, mutations against a throwaway fixture tree, and the row click path.
// Run: bash tests/fixtures/switchboard-probe.sh
import AppKit

var failures: [String] = []
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print(String(format: "  %@ %@%@", ok ? "PASS" : "FAIL", name,
                 detail.isEmpty ? "" : "   (\(detail))"))
    if !ok { failures.append(name) }
}

// ── Fixture tree: every mutation runs here, never against the real config ────
let fixture = NSTemporaryDirectory() + "sb-probe-\(getpid())"
let fm = FileManager.default
try? fm.createDirectory(atPath: fixture + "/scripts/hooks", withIntermediateDirectories: true)

// A hook that looks for two sentinels, so discovery is exercised on real syntax.
try? """
#!/bin/bash
[ -f "$HOME/.claude/.no-fixture-gate" ] && exit 0
[ -f "$HOME/.claude/.fixture-thing-off" ] && exit 0
""".write(toFile: fixture + "/scripts/hooks/fake-hook.sh", atomically: true, encoding: .utf8)

let realRoot = SwitchboardPaths.gccRoot
SwitchboardPaths.gccRoot = fixture

print("\n── guard discovery + re-arm ──")
let known = Guards.knownSentinels()
check("discovers sentinels by reading hooks", known.contains(".no-fixture-gate") && known.contains(".fixture-thing-off"),
      known.joined(separator: ","))
check("no sentinel file means nothing muted", Guards.muted().isEmpty)

fm.createFile(atPath: fixture + "/.no-fixture-gate", contents: nil)
let muted = Guards.muted()
check("an existing sentinel reads as muted", muted.count == 1 && muted.first?.name == "fixture-gate",
      muted.map { $0.name }.joined())
check("re-arm deletes the sentinel", Guards.rearm(muted[0]) && !fm.fileExists(atPath: fixture + "/.no-fixture-gate"))
check("re-arm on an armed guard is a no-op, not a crash", Guards.rearm(muted[0]) == false)

// The policy lift must never appear as something to undo.
fm.createFile(atPath: fixture + "/.allow-fable-subagents", contents: nil)
try? "[ -f \"$HOME/.claude/.allow-fable-subagents\" ]".write(
    toFile: fixture + "/scripts/hooks/fable.sh", atomically: true, encoding: .utf8)
check("deliberate policy lift is not listed as muted",
      !Guards.muted().contains { $0.sentinel == ".allow-fable-subagents" })

// Regression: a sentinel one directory deeper was invisible, so a muted guard
// never appeared. Found by the validation gate 2026-08-10.
try? fm.createDirectory(atPath: fixture + "/atone", withIntermediateDirectories: true)
try? "[ -f \"$HOME/.claude/atone/.gate-off\" ] && exit 0".write(
    toFile: fixture + "/scripts/hooks/nested.sh", atomically: true, encoding: .utf8)
check("discovers a nested sentinel", Guards.knownSentinels().contains("atone/.gate-off"),
      Guards.knownSentinels().joined(separator: ","))
fm.createFile(atPath: fixture + "/atone/.gate-off", contents: nil)
let nested = Guards.muted().first { $0.sentinel == "atone/.gate-off" }
check("a nested sentinel reads as muted", nested != nil)
check("its display name drops the directory", nested?.name == "gate-off", nested?.name ?? "nil")
if let n = nested {
    check("re-arm deletes a nested sentinel",
          Guards.rearm(n) && !fm.fileExists(atPath: fixture + "/atone/.gate-off"))
}

print("\n── push approvals ──")
fm.createFile(atPath: fixture + "/.push-approved-DEADSESSION", contents: nil)
fm.createFile(atPath: fixture + "/.push-approved-LIVESESSION", contents: nil)
let approvals = PushApprovals.armed(liveSessionIDs: ["LIVESESSION"])
check("both approvals found", approvals.count == 2)
check("dead session flagged not-live", approvals.contains { $0.sessionID == "DEADSESSION" && !$0.sessionIsLive })
check("live session flagged live", approvals.contains { $0.sessionID == "LIVESESSION" && $0.sessionIsLive })
if let dead = approvals.first(where: { $0.sessionID == "DEADSESSION" }) {
    check("clear removes the approval", PushApprovals.clear(dead) && !fm.fileExists(atPath: fixture + "/.push-approved-DEADSESSION"))
}

print("\n── settings.json write safety ──")
let seed: [String: Any] = [
    "alwaysThinkingEnabled": true, "effortLevel": "xhigh",
    "skipAutoPermissionPrompt": true,
    "enabledPlugins": ["a@m": true, "b@m": false],
    "env": ["STATUSLINE_PROFILE": "custom"],
    "unrelatedKey": "must survive",
]
let seedData = try! JSONSerialization.data(withJSONObject: seed, options: .prettyPrinted)
try! seedData.write(to: URL(fileURLWithPath: fixture + "/settings.json"))

check("reads a bool flag", Settings.bool(.alwaysThinking) == true)
check("reads the effort enum", Settings.effortLevel() == "xhigh")
check("write returns true", Settings.write(key: "effortLevel", value: "medium"))
check("written value round-trips", Settings.effortLevel() == "medium")

let after = Settings.read()
check("every untouched key survives",
      after["unrelatedKey"] as? String == "must survive"
      && (after["enabledPlugins"] as? [String: Any])?.count == 2
      && (after["env"] as? [String: Any])?["STATUSLINE_PROFILE"] as? String == "custom"
      && after["skipAutoPermissionPrompt"] as? Bool == true,
      "\(after.keys.sorted())")
check("a backup was written", (try? fm.contentsOfDirectory(atPath: fixture))?.contains { $0.contains(Settings.backupTag) } == true)
check("no temp file left behind", (try? fm.contentsOfDirectory(atPath: fixture))?.contains { $0.contains(".tmp-") } == false)

// Regressions from the validation gate: backups grew without bound, were left
// behind by writes that failed, and pruning must never touch other tools' files.
fm.createFile(atPath: fixture + "/settings.json.bak-cligating-20260521", contents: Data("other tool".utf8))
for i in 0..<9 { _ = Settings.write(key: "effortLevel", value: "high"); _ = i; usleep(1_100_000) }
let backupsNow = ((try? fm.contentsOfDirectory(atPath: fixture)) ?? []).filter { $0.contains(Settings.backupTag) }
check("backups are capped", backupsNow.count <= Settings.backupsKept, "\(backupsNow.count) kept")
check("another tool's backup is never pruned",
      fm.fileExists(atPath: fixture + "/settings.json.bak-cligating-20260521"))

let ro = fixture + "/ro"
try? fm.createDirectory(atPath: ro, withIntermediateDirectories: true)
try! seedData.write(to: URL(fileURLWithPath: ro + "/settings.json"))
try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: ro + "/settings.json")
try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro)
SwitchboardPaths.gccRoot = ro
let roOK = Settings.write(key: "effortLevel", value: "low") == false
let roClean = ((try? fm.contentsOfDirectory(atPath: ro)) ?? []).filter { $0 != "settings.json" }.isEmpty
check("a failed write leaves no backup or temp", roOK && roClean,
      ((try? fm.contentsOfDirectory(atPath: ro)) ?? []).joined(separator: ","))
try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro)
SwitchboardPaths.gccRoot = fixture

// A valid but empty config is a real config, distinct from an unreadable one.
let emptyCfg = fixture + "/emptycfg"
try? fm.createDirectory(atPath: emptyCfg, withIntermediateDirectories: true)
try! Data("{}".utf8).write(to: URL(fileURLWithPath: emptyCfg + "/settings.json"))
SwitchboardPaths.gccRoot = emptyCfg
check("a valid empty config can be written to", Settings.write(key: "effortLevel", value: "low"))
check("and reads back", Settings.effortLevel() == "low")
try! Data("not json".utf8).write(to: URL(fileURLWithPath: emptyCfg + "/settings.json"))
check("an unreadable config is still refused", Settings.write(key: "x", value: 1) == false)
SwitchboardPaths.gccRoot = fixture

// Refuse to invent a config where none exists. The directory must EXIST with the
// file missing: pointing at a missing directory proves nothing, because the write
// then fails on the absent parent rather than on the guard. (Caught by mutation:
// deleting the guard left that weaker version of this check green.)
let emptyRoot = fixture + "/empty-root"
try? fm.createDirectory(atPath: emptyRoot, withIntermediateDirectories: true)
SwitchboardPaths.gccRoot = emptyRoot
check("refuses to create settings.json when the dir exists but the file does not",
      Settings.write(key: "x", value: 1) == false
      && !fm.fileExists(atPath: emptyRoot + "/settings.json"))
SwitchboardPaths.gccRoot = fixture

print("\n── badge colour rules ──")
// Light wants white type on a saturated fill, dark wants dark type on a lighter
// one. Picking the easier of black/white put dark text on every mid-tone fill.
for (mode, dark) in [("light", false), ("dark", true)] {
    var worstRatio: CGFloat = 99
    var wrongText = 0
    for tok in [PaletteToken.successHigh, .stateActive, .warnMid, .warnHigh] {
        let pair = accessibleBadgePair(PaletteStore.shared.color(for: tok), dark: dark)
        let isWhite = relativeLuminance(pair.text) > 0.5
        if isWhite == dark { wrongText += 1 }
        worstRatio = min(worstRatio, contrastRatio(pair.text, pair.fill))
    }
    check("\(mode): text is \(dark ? "dark" : "white") on every badge", wrongText == 0)
    check("\(mode): every badge clears 4.5:1", worstRatio >= 4.5,
          String(format: "worst %.2f:1", Double(worstRatio)))
}
// The floor must survive a user-chosen palette, not just the shipped one.
var floorHolds = true
for hex in ["#FFFF00", "#000000", "#FFFFFF", "#808080", "#E12D0F", "#781EC3", "#C3961E"] {
    for dark in [false, true] {
        let pair = accessibleBadgePair(NSColor.fromHex(hex)!, dark: dark)
        if contrastRatio(pair.text, pair.fill) < 4.5 { floorHolds = false }
    }
}
check("the floor survives adversarial palette choices", floorHolds)

print("\n── shell timeout (gate finding: a wedged subprocess leaked a thread) ──")
let t0 = Date()
let wedged = Services.shell("/bin/sleep", ["30"], timeout: 1.0)
let elapsed = Date().timeIntervalSince(t0)
check("a wedged command is capped, not waited on", elapsed < 3.0,
      String(format: "returned after %.2fs", elapsed))
check("a killed command yields no output", wedged.isEmpty)
// A child that outruns the 64K pipe buffer deadlocks if nobody drains it, which
// would make the cap itself unreachable.
let big = Services.shell("/bin/zsh", ["-lc", "head -c 300000 /dev/zero | tr '\\0' 'x'"], timeout: 5.0)
check("output larger than the pipe buffer still returns", big.count >= 300_000, "\(big.count) bytes")
let quick = Services.shell("/bin/echo", ["alive"], timeout: 4.0)
check("a fast command is untouched by the cap", quick.contains("alive"))

print("\n── row click path (the defect class that shipped inert) ──")
var clicks = 0
let row = MenuRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
row.onClick = { clicks += 1 }
let ev = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 60, y: 12),
                            modifierFlags: [], timestamp: 0, windowNumber: 0,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
row.mouseUp(with: ev)
check("an enabled row fires", clicks == 1)
row.rowEnabled = false
row.mouseUp(with: ev)
check("a disabled row stays inert", clicks == 1)

print("\n── reads against the real config (no mutation) ──")
SwitchboardPaths.gccRoot = realRoot
let realMuted = Guards.muted()
let shellCount = Services.shell("/bin/zsh", ["-lc",
    "ls -a \(realRoot) | grep -E '^\\.(no|allow)-|-off$' | grep -v fable | wc -l"])
    .trimmingCharacters(in: .whitespacesAndNewlines)
check("muted count matches the shell's view", String(realMuted.count) == shellCount,
      "swift=\(realMuted.count) shell=\(shellCount)")
check("settings.json parses", !Settings.read().isEmpty)

try? fm.removeItem(atPath: fixture)
print("\n" + (failures.isEmpty
      ? "ALL PASS (\(failures.count) failures)"
      : "FAILURES: " + failures.joined(separator: ", ")))
exit(failures.isEmpty ? 0 : 1)

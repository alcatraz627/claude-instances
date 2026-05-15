import Foundation
import HostKernel

/// Fixture-driven smoke test for the manifest loader + registry.
///
/// Each fixture folder under `plugins/_test-fixtures/` contains a
/// `manifest.json` plus an `expected.json` describing the load outcome.
/// We load every fixture, compare against `expected`, and exit non-zero
/// if any disagreement. This stands in for XCTest until Xcode is installed.

struct Expected: Decodable {
    let ok: Bool
    let errorCode: String?
    let warnings: [String]?   // substrings; each must appear in some warning message
}

@MainActor
func main() async {
    let fixturesRoot = URL(fileURLWithPath: "plugins/_test-fixtures",
                           isDirectory: true,
                           relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    let fm = FileManager.default

    guard let children = try? fm.contentsOfDirectory(at: fixturesRoot,
        includingPropertiesForKeys: [.isDirectoryKey]) else {
        fputs("[FAIL] no fixtures directory at \(fixturesRoot.path)\n", stderr)
        exit(1)
    }

    let dirs = children
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    let registry = Registry(hostVersion: HostKernel.semver)
    var passed = 0
    var failed = 0

    print("manifest-test  host=\(HostKernel.version)  fixtures=\(dirs.count)")
    print(String(repeating: "─", count: 70))

    for dir in dirs {
        let name = dir.lastPathComponent
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let expectedURL = dir.appendingPathComponent("expected.json")

        guard fm.fileExists(atPath: manifestURL.path),
              fm.fileExists(atPath: expectedURL.path) else {
            print("  \(name.padding(toLength: 36, withPad: " ", startingAt: 0))  SKIP (missing manifest or expected)")
            continue
        }

        let expected: Expected
        do {
            let data = try Data(contentsOf: expectedURL)
            expected = try JSONDecoder().decode(Expected.self, from: data)
        } catch {
            print("  \(name)  FAIL (could not read expected.json: \(error))")
            failed += 1
            continue
        }

        let outcome = registry.load(manifestURL: manifestURL)
        let (verdict, detail) = compare(outcome: outcome, expected: expected)
        let pad = name.padding(toLength: 36, withPad: " ", startingAt: 0)
        let mark = verdict ? "PASS" : "FAIL"
        print("  \(pad)  \(mark)  \(detail)")
        if verdict { passed += 1 } else { failed += 1 }
    }

    print(String(repeating: "─", count: 70))
    print("\(passed) passed  \(failed) failed  of \(passed + failed)")
    exit(failed == 0 ? 0 : 1)
}

/// Returns (passed, detail) for a single fixture.
func compare(outcome: LoadOutcome, expected: Expected) -> (Bool, String) {
    // Did we expect success?
    if expected.ok {
        guard outcome.ok, let _ = outcome.manifest else {
            let actualCode = outcome.error?.code.rawValue ?? "none"
            return (false, "expected ok, got error: \(actualCode) — \(outcome.error?.message ?? "")")
        }
        // Check expected warning substrings, if any
        if let want = expected.warnings {
            for needle in want {
                let hit = outcome.warnings.contains(where: { $0.message.contains(needle) })
                if !hit {
                    return (false, "expected warning containing '\(needle)' — got \(outcome.warnings.map(\.message))")
                }
            }
        }
        let summary: String = {
            let ws = outcome.warnings.count
            return ws == 0 ? "ok" : "ok (\(ws) warning(s))"
        }()
        return (true, summary)
    }

    // Expected failure
    guard let err = outcome.error else {
        return (false, "expected error '\(expected.errorCode ?? "?")', got ok")
    }
    if let wantCode = expected.errorCode, err.code.rawValue != wantCode {
        return (false, "expected error '\(wantCode)', got '\(err.code.rawValue)' — \(err.message)")
    }
    return (true, "error '\(err.code.rawValue)' (expected)")
}

await main()

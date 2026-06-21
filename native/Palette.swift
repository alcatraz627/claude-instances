// Palette.swift
// PaletteToken, PaletteStore, NSColor helpers, model display.
// (split from claude-instances-bar.swift — one module, same binary)

import AppKit
import Foundation
import SwiftUI

enum PaletteToken: String, CaseIterable {
    case modelOpus      = "model.opus"       // Opus model badge
    case modelSonnet    = "model.sonnet"     // Sonnet model badge
    case modelHaiku     = "model.haiku"      // Haiku model badge
    case metricTurns    = "metric.turns"     // Nt turn counts (ambient)
    case metricTools    = "metric.tools"     // 🔧N tool counts (ambient)
    case metricTokens   = "metric.tokens"    // ↑NK output tokens
    case metricCost     = "metric.cost"      // $ cost values
    case metricMemory   = "metric.memory"    // MB memory values
    case metricSpeed    = "metric.speed"     // Nt/s rate (ambient)
    case accentBranch   = "accent.branch"    // ⎇ branch badge
    case accentSubagent = "accent.subagent"  // ↳N subagent badge
    case stateActive    = "state.active"     // state-detail row (thinking/responding)
    case warnHigh       = "warn.high"        // compaction-imminent, MCP-down, ctx <30
    case warnMid        = "warn.mid"         // modified <20, ctx <60
    case successHigh    = "success.high"     // ctx ≥60%, ↑tokens
    case permissionPlan = "permission.plan"  // Plan-mode badge (P)
    case permissionAuto = "permission.auto"  // Auto-accept-edits badge (A — safety-relevant)

    /// Short human-readable name shown in the Settings table.
    var displayName: String {
        switch self {
        case .modelOpus:      return "Opus"
        case .modelSonnet:    return "Sonnet"
        case .modelHaiku:     return "Haiku"
        case .metricTurns:    return "Turns"
        case .metricTools:    return "Tool calls"
        case .metricTokens:   return "Tokens"
        case .metricCost:     return "Cost"
        case .metricMemory:   return "Memory"
        case .metricSpeed:    return "Speed"
        case .accentBranch:   return "Branch"
        case .accentSubagent: return "Subagent"
        case .stateActive:    return "Active state"
        case .warnHigh:       return "Warning (high)"
        case .warnMid:        return "Warning (mid)"
        case .successHigh:    return "Success"
        case .permissionPlan: return "Permission: plan"
        case .permissionAuto: return "Permission: auto"
        }
    }

    /// What this token is used for. One sentence; surfaces in the Settings UI.
    var usage: String {
        switch self {
        case .modelOpus:      return "Opus model badge ◆"
        case .modelSonnet:    return "Sonnet model badge ●"
        case .modelHaiku:     return "Haiku model badge ○"
        case .metricTurns:    return "Turn counts (Nt)"
        case .metricTools:    return "Tool-call count (🔧N)"
        case .metricTokens:   return "Output token counts (↑NK)"
        case .metricCost:     return "Per-session cost values ($N.NN)"
        case .metricMemory:   return "Resident memory (NMB)"
        case .metricSpeed:    return "Token throughput (Nt/s)"
        case .accentBranch:   return "Git branch badge (⎇branch)"
        case .accentSubagent: return "Subagent count badge (↳N)"
        case .stateActive:    return "Active-state row (thinking / responding / tool use)"
        case .warnHigh:       return "Critical warnings: compaction imminent, MCP down, modified ≥20"
        case .warnMid:        return "Mid-severity: ctx <60%, modified <20"
        case .successHigh:    return "Healthy state: ctx ≥60%, fast token rate"
        case .permissionPlan: return "Plan-mode badge (P) — session is in plan mode"
        case .permissionAuto: return "Auto-accept-edits badge (A) — safety-relevant"
        }
    }
}

final class PaletteStore {
    static let shared = PaletteStore()

    static let didChangeNotification = Notification.Name("PaletteStore.didChange")

    /// Baked-in defaults. Survive user reset.
    ///
    /// The harmonious palette from docs/dropdown-redesign.md: three emphasis tiers
    /// on one perceptual grid so colours coexist instead of compete. Identity
    /// (models) and severity (green/amber/red) stay loud; ambient metrics recede
    /// to a low-chroma band; turns/tools/speed go neutral gray. These are the
    /// light-tuned values; a dark-appearance variant is a planned follow-up.
    private let defaults: [PaletteToken: NSColor] = [
        // Identity — loud, three separable hues
        .modelOpus:      NSColor.fromHex("#C2740E")!,
        .modelSonnet:    NSColor.fromHex("#3B6FD4")!,
        .modelHaiku:     NSColor.fromHex("#0E97A6")!,
        // Severity — one closed green→amber→red scale (shared by warnings + permission)
        .successHigh:    NSColor.fromHex("#2E9E58")!,
        .warnMid:        NSColor.fromHex("#C98A12")!,
        .warnHigh:       NSColor.fromHex("#CE4B43")!,
        .permissionPlan: NSColor.fromHex("#C98A12")!,
        .permissionAuto: NSColor.fromHex("#CE4B43")!,
        // Money — medium, one glance-colour (gold, offset from severity-amber)
        .metricCost:     NSColor.fromHex("#B98A1F")!,
        .metricTokens:   NSColor.fromHex("#3F9A63")!,
        // Ambient — quiet, low-chroma but still hue-spottable
        .metricMemory:   NSColor.fromHex("#6E8EC0")!,
        .accentBranch:   NSColor.fromHex("#4F9D9A")!,
        .stateActive:    NSColor.fromHex("#4F9D9A")!,
        .accentSubagent: NSColor.fromHex("#5C93B8")!,
        // Skim counts — neutral gray (meaning by label + position)
        .metricTurns:    NSColor.fromHex("#8A8A8E")!,
        .metricTools:    NSColor.fromHex("#8A8A8E")!,
        .metricSpeed:    NSColor.fromHex("#8A8A8E")!,
    ]

    private let prefix = "palette."

    /// Returns the user-set override if present, else the baked-in default.
    func color(for token: PaletteToken) -> NSColor {
        if let hex = UserDefaults.standard.string(forKey: prefix + token.rawValue),
           let c = NSColor.fromHex(hex) {
            return c
        }
        return defaults[token] ?? .labelColor
    }

    /// Returns the hex string ("#RRGGBB") of the current value (user or default).
    func hex(for token: PaletteToken) -> String {
        return color(for: token).hexString
    }

    /// True if the user has overridden this token.
    func isOverridden(_ token: PaletteToken) -> Bool {
        return UserDefaults.standard.string(forKey: prefix + token.rawValue) != nil
    }

    func set(_ token: PaletteToken, hex: String) {
        UserDefaults.standard.set(hex, forKey: prefix + token.rawValue)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func reset(_ token: PaletteToken) {
        UserDefaults.standard.removeObject(forKey: prefix + token.rawValue)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func resetAll() {
        for t in PaletteToken.allCases {
            UserDefaults.standard.removeObject(forKey: prefix + t.rawValue)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Default value (without user override) — used by the Settings UI to
    /// label the "reset" button's destination.
    func defaultColor(for token: PaletteToken) -> NSColor {
        return defaults[token] ?? .labelColor
    }
}

// MARK: NSColor ↔ hex
extension NSColor {
    /// "#RRGGBB" (drops alpha — palette colors are opaque).
    var hexString: String {
        let c = self.usingColorSpace(.sRGB) ?? self
        let r = Int(round(c.redComponent   * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent  * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Parses "#RRGGBB" or "RRGGBB". Returns nil for invalid input.
    static func fromHex(_ s: String) -> NSColor? {
        var hex = s.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let val = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >>  8) & 0xFF) / 255.0
        let b = CGFloat( val        & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

// ─── Per-color accessor constants (read from PaletteStore at call time) ──────
//
// Computed vars so each access reads the current PaletteStore value. User
// changes via the Settings tab propagate to the next render with zero plumbing.

var menuGreen:     NSColor { PaletteStore.shared.color(for: .successHigh)    }
var menuYellow:    NSColor { PaletteStore.shared.color(for: .warnMid)        }
var menuCyan:      NSColor { PaletteStore.shared.color(for: .accentSubagent) } // legacy alias
var menuTeal:      NSColor { PaletteStore.shared.color(for: .accentBranch)   }
var menuRed:       NSColor { PaletteStore.shared.color(for: .warnHigh)       }
var costColor:     NSColor { PaletteStore.shared.color(for: .metricCost)     }
var tokensColor:   NSColor { PaletteStore.shared.color(for: .metricTokens)   }
var memColor:      NSColor { PaletteStore.shared.color(for: .metricMemory)   }
var turnsColor:    NSColor { PaletteStore.shared.color(for: .metricTurns)    }
var toolsColor:    NSColor { PaletteStore.shared.color(for: .metricTools)    }
var speedColor:    NSColor { PaletteStore.shared.color(for: .metricSpeed)    }
var subagentColor: NSColor { PaletteStore.shared.color(for: .accentSubagent) }
var coralAccent:   NSColor { .systemGray }   // structural, not in palette

func modelDisplay(_ name: String?) -> ModelDisplay {
    // Resolve model color from PaletteStore at call time so user changes via
    // Settings propagate without needing to rebuild modelConfig.
    guard let n = name else { return defaultModel }
    switch n {
    case "opus":   return ModelDisplay(badge: "◆", label: "Opus",
                                       color: PaletteStore.shared.color(for: .modelOpus))
    case "sonnet": return ModelDisplay(badge: "●", label: "Sonnet",
                                       color: PaletteStore.shared.color(for: .modelSonnet))
    case "haiku":  return ModelDisplay(badge: "○", label: "Haiku",
                                       color: PaletteStore.shared.color(for: .modelHaiku))
    default:       return defaultModel
    }
}

// ─── Ghostty AppleScript bridge ──────────────────────────────────────────────


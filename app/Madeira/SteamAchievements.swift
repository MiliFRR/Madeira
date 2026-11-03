// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit
import UserNotifications

// Steam achievements and Steam Input for games Madeira runs through Steam
// (docs/STEAM_LIBRARY.md, "Steam client").
//
// A game started through Madeira Dock launches Valve's own Steam client, which
// signs in, checks the licence and starts the game. Madeira can layer two
// Steam-client features on top:
//
//   * Pop-up achievements: when a game unlocks a Steam achievement, Madeira
//     shows an in-game toast (and, while in the background, a local
//     notification). `env.MADEIRA_STEAM_ACHIEVEMENTS = 1` turns it on.
//   * Steam Input: Madeira asks Steam to use a chosen controller configuration
//     for the game (gamepad, keyboard-and-mouse, or a Steam controller bind).
//     `env.MADEIRA_STEAM_INPUT = 1` turns it on.
//
// NOTE: the Steamworks user-stats / controller callbacks that feed real
// achievement unlocks are not wired yet (they need Valve's Steamworks SDK or the
// client's local user-stats file). `registerAchievement(_:for:)` is the seam a
// Steamworks callback would call; until then it records the unlock so the UI and
// notifications have something to show. Log tag: [steam-achievements] (app IDs
// and achievement names only).

/// Steam pop-up achievements are on with `env.MADEIRA_STEAM_ACHIEVEMENTS = 1`.
enum SteamAchievements {
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_STEAM_ACHIEVEMENTS", fallback: false) }
    /// Local notifications when an achievement unlocks while Madeira is in the
    /// background. `env.MADEIRA_STEAM_ACHIEVEMENT_NOTIFICATIONS = 0` turns them off.
    static var notificationsEnabled: Bool { MadeiraConfig.flag("MADEIRA_STEAM_ACHIEVEMENT_NOTIFICATIONS", fallback: true) }

    private static let achievementsKey = "madeira.steam.achievements"
    private static var unlocked: [Int: Set<String>] = [:]   // appID -> achievement names

    /// Call this from the Steamworks callback when the client reports an
    /// achievement unlock for `appID` named `name`.
    static func registerAchievement(appID: Int, name: String) {
        var set = unlocked[appID] ?? []
        guard set.insert(name).inserted else { return }   // first time only
        unlocked[appID] = set
        persist()
        if enabled {
            SteamAchievementOverlay.shared.pending.append((appID, name))
        }
        if notificationsEnabled {
            notify(title: "Achievement unlocked", body: "\(appID): \(name)")
        }
        SteamLog.event("[steam-achievements] app=\(appID) achievement=\(name)")
    }

    /// The achievements this device has unlocked for an app (the in-game
    /// overlay shows newly-unlocked ones as pop-up toasts).
    static func unlockedAchievements(appID: Int) -> [String] {
        Array(unlocked[appID] ?? []).sorted()
    }

    private static func persist() {
        guard let data = try? JSONEncoder().encode(unlocked) else { return }
        let url = supportFolder.appendingPathComponent("steam-achievements.json")
        try? data.write(to: url, options: .atomic)
    }

    private static func load() {
        guard let url = supportFolder.appendingPathComponent("steam-achievements.json") as URL?,
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Int: Set<String>].self, from: data) else { return }
        unlocked = list
    }

    private static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Madeira", isDirectory: true)
    }

    private static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "madeira.steam.achievement.\(UUID().uuidString)",
                                  content: content, trigger: nil))
    }
}
// MARK: - In-game achievement toast

/// A small toast shown over a running session when an achievement unlocks.
final class SteamAchievementOverlay: ObservableObject {
    static let shared = SteamAchievementOverlay()
    @Published var pending: [(appID: Int, name: String)] = []
    /// The toast currently on screen (shown for a few seconds).
    @Published var current: (appID: Int, name: String)? = nil

    private init() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.current == nil, let next = self.pending.first {
                self.pending.removeFirst()
                self.current = next
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if self.current?.name == next.name { self.current = nil }
                }
            }
        }
    }
}

/// The toast view, placed over the game surface while a session runs.
struct SteamAchievementToast: View {
    let achievement: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "medal.fill").foregroundStyle(.yellow)
            Text("Achievement unlocked").font(.headline).foregroundStyle(.white)
            Text(achievement).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.black.opacity(0.75))
        .cornerRadius(10)
        .shadow(radius: 8)
    }
}

// MARK: - Steam Input

/// Steam Input is on with `env.MADEIRA_STEAM_INPUT = 1`: Madeira asks Steam to
/// use a controller configuration for the game instead of its defaults.
enum SteamInput {
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_STEAM_INPUT", fallback: false) }

    /// Launch-option snippet Steam applies to pick a controller configuration.
    /// The configuration name is chosen in Settings › Steam › Steam Input.
    static var configuration: String {
        get { UserDefaults.standard.string(forKey: "madeiraSteamInputConfig") ?? "Default" }
        set { UserDefaults.standard.set(newValue, forKey: "madeiraSteamInputConfig") }
    }

    /// Arguments appended to a Steam game's launch command so Steam applies the
    /// chosen input configuration. Madeira Dock passes these to Valve's client.
    static func launchArguments() -> [String] {
        guard enabled else { return [] }
        return ["-steaminput", "-steaminput_config", configuration]
    }
}


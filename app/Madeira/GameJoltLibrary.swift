// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

// The Game Jolt account's games and their downloads (docs/GAMEJOLT.md).
// Game Jolt decides ownership: the list is the account's games, and a game
// downloads from Game Jolt's CDN into C:\\Program Files\\GameJolt\\Games\\<folder>
// and starts as its own program in Wine, with Game Jolt's sign-in passed on the
// command line. There is no Game Jolt client in the prefix. `env.MADEIRA_GAMEJOLT
// = 0` turns the whole thing off. Log tags: [gamejolt-library], [gamejolt-download],
// [gamejolt-launch] (game IDs, counts and short reason codes; never account data).

import Foundation
import UIKit

/// A game the account owns on Game Jolt.
struct GameJoltItem: Identifiable, Hashable, Sendable {
    var gameID: Int
    var title: String
    var cover: URL?
    var owned: GameJoltOwnedGame?
    var installed: GameJoltInstalledGame?
    var id: Int { gameID }
}

/// One game Madeira installed: its program and how it starts.
struct GameJoltLibraryGame: Codable, Sendable {
    var gameID: Int
    var title: String
    var programPath: String   // relative to drive_c
    var installBytes: Int64
}

@MainActor final class GameJoltLibrary: ObservableObject {
    static let shared = GameJoltLibrary()

    /// Off with `env.MADEIRA_GAMEJOLT = 0`.
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_GAMEJOLT", default: true) }

    @Published private(set) var signedIn = false
    private(set) var accountID: String?
    @Published private(set) var accountName: String?
    @Published private(set) var owned: [GameJoltOwnedGame] = []
    @Published private(set) var installed: [Int: GameJoltInstalledGame] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var libraryUpdated: Date?
    @Published var error: String?

    struct Download: Equatable {
        enum Kind: String { case install, update }
        enum State: Equatable { case queued, active, paused, failed(String) }
        var kind: Kind
        var state: State
        var progress = GameJoltDownloadProgress()
    }
    @Published private(set) var downloads: [Int: Download] = [:]
    private var queue: [Int] = []
    private var active: (app: Int, task: Task<Void, Never>)? = nil
    private var inSession = false
    private var resumeAfterSession = Set<Int>()
    private var resumeAfterBackground = Set<Int>()
    private var started = false
    /// iOS 26 and later: a continued-processing task keeps the queue running in
    /// the background ("<bundle id>.download.gamejolt"); earlier iOS: the short
    /// grace period, then a clean pause.
    private lazy var background = SteamDownloadBackground(source: "Game Jolt", suffix: "gamejolt")
    private let api = GameJoltAPI.shared

    private init() { loadInstalled() }

    /// Whether any download is queued or active, for the background task.
    var hasActiveDownload: Bool { downloads.values.contains { $0.state == .active || $0.state == .queued } }

    /// The files on disk.
    static let installRoot = "Program Files/GameJolt/Games"
    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Madeira", isDirectory: true)
    }
    private static var installedURL: URL { support.appendingPathComponent("gamejolt-installed.json") }
    private static func journalURL(_ game: Int) -> URL {
        support.appendingPathComponent("gamejolt-downloads", isDirectory: true).appendingPathComponent("\(game).journal")
    }

    // MARK: Lifecycle

    /// Called when the library shows the Game Jolt section; once per app run.
    func start() {
        guard Self.enabled, !started else { return }
        started = true
        background.attach(active: { [weak self] in self?.hasActiveDownload == true },
                          pause: { [weak self] in self?.pauseForBackground() },
                          resume: { [weak self] in self?.resumeFromBackground(); self?.reconcileSession() })
        Task {
            let account = await api.account()
            signedIn = account != nil
            accountID = account?.id
            accountName = account?.name
            if let account { loadCache(account: account.id) }
            GameJoltLog.event("[gamejolt-library] start signed-in=\(signedIn ? 1 : 0) cached=\(owned.count) installed=\(installed.count)")
            if signedIn, Date().timeIntervalSince(libraryUpdated ?? .distantPast) > 6 * 3600 {
                await refreshLibrary(interactive: false)
            }
        }
    }
    // MARK: Downloads

    /// Adds a game to the download queue. Safe to call repeatedly.
    func enqueue(_ game: Int, kind: Download.Kind = .install) {
        guard !queue.contains(game) else { return }
        queue.append(game)
        if downloads[game] == nil {
            downloads[game] = Download(kind: kind, state: .queued)
        }
        GameJoltLog.event("[gamejolt-download] enqueue game=\(game) kind=\(kind.rawValue)")
        startTimer()
    }

    /// Pauses everything: called for the background and for a game session.
    private func pauseAll() {
        if let current = active { resumeAfterBackground.insert(current.app); current.task.cancel() }
        for game in queue { resumeAfterBackground.insert(game); downloads[game]?.state = .paused }
        queue.removeAll()
    }

    /// iOS ended Madeira's background time: downloads pause cleanly (finished
    /// files are journaled) and continue when Madeira is active again.
    private func pauseForBackground() {
        pauseAll()
        GameJoltLog.event("[gamejolt-download] paused for the background count=\(resumeAfterBackground.count)")
    }

    private func resumeFromBackground() {
        let games = resumeAfterBackground.sorted()
        resumeAfterBackground.removeAll()
        for game in games { enqueue(game, kind: downloads[game]?.kind ?? .install) }
    }

    // MARK: Session

    /// A game session is starting or ended: downloads pause for it and continue
    /// afterwards. Idempotent.
    func sessionChanged(active running: Bool) {
        guard running != inSession else { return }
        inSession = running
        if running {
            if let current = active { resumeAfterSession.insert(current.app); current.task.cancel() }
            for game in queue { resumeAfterSession.insert(game); downloads[game]?.state = .paused }
            queue.removeAll()
            GameJoltLog.event("[gamejolt-download] paused for a game session count=\(resumeAfterSession.count)")
        } else {
            let games = resumeAfterSession.sorted()
            resumeAfterSession.removeAll()
            for game in games { enqueue(game, kind: downloads[game]?.kind ?? .install) }
        }
    }

    var sessionRunning: Bool {
        LibraryModel.shared.current != nil || wine_process_is_running() != 0 || wineserver_is_running() != 0
    }

    func reconcileSession() { sessionChanged(active: sessionRunning) }

    private var timer: Timer? = nil
    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconcileSession()
                if !self.hasActiveDownload { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }

    // MARK: Sign in

    /// Trades a one-use authorization code for a session, then loads the library.
    func signIn(code: String) async throws {
        do {
            let session = try await api.signIn(authorizationCode: code)
            GameJoltAPI.save(session)
            signedIn = true
            accountID = session.accountID
            accountName = session.displayName
            await refreshLibrary(interactive: true)
        } catch {
            signedIn = false
            throw error
        }
    }

    func signOut() {
        api.signOut()
        signedIn = false
        accountID = nil
        accountName = nil
        owned.removeAll()
        installed.removeAll()
        downloads.removeAll()
    }

    // MARK: Library

    private func refreshLibrary(interactive: Bool = true) async {
        guard Self.enabled else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let games = try await api.games()
            let owned = games.map { $0 }
            self.owned = owned
            self.libraryUpdated = Date()
            saveCache(account: accountID ?? "")
            GameJoltLog.event("[gamejolt-library] owned=\(owned.count)")
        } catch {
            if interactive { self.error = error.localizedDescription }
            GameJoltLog.event("[gamejolt-library] refresh failed reason=\(error.localizedDescription)")
        }
    }

    private func loadCache(account id: String) {
        // Placeholder: read the cached owned-game list from Documents.
        owned = []
    }

    private func saveCache(account id: String) {
        // Placeholder: write the cached owned-game list to Documents.
    }

    private func loadInstalled() {
        guard let data = try? Data(contentsOf: Self.installedURL),
              let list = try? JSONDecoder().decode([GameJoltLibraryGame].self, from: data) else { return }
        for game in list { installed[game.gameID] = game }
    }

    private func saveInstalled() {
        guard let data = try? JSONEncoder().encode(Array(installed.values)) else { return }
        try? data.write(to: Self.installedURL, options: .atomic)
    }

    static func safeName(_ text: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = String(text.unicodeScalars.map { banned.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return cleaned.isEmpty ? "game" : String(cleaned.prefix(120))
    }

    // MARK: Launch

    /// The arguments Game Jolt passes a game: its sign-in state, the game ID and
    /// the account name. A game marked playable offline starts without them.
    func launchArguments(gameID game: Int) async throws -> String {
        guard let record = installed[game] else { throw GameJoltAPIError.invalid("not-installed") }
        var args = ["-gamejolt-game=\(game)", "-gamejolt-user=\(accountName ?? \"unused\")"]
        GameJoltLog.event("[gamejolt-launch] game=\(game)")
        return args.joined(separator: " ")
    }
}

/// Game Jolt download progress (bytes only, for the UI and background task).
struct GameJoltDownloadProgress: Equatable {
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var percent: Int {
        guard bytesTotal > 0 else { return 0 }
        return Int((Double(bytesDone) / Double(bytesTotal)) * 100)
    }
}


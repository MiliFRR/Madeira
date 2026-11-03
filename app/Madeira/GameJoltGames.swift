// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import WebKit

// The Game Jolt section of the library: a game's download sheet, its Game details
// page, and the sign-in sheet (docs/GAMEJOLT.md).

struct GameJoltGamesRules {
    /// The account's games and Madeira's installs, by game ID, filtered by the search.
    static func items(_ library: GameJoltLibrary, search: String) -> [GameJoltItem] {
        var byID: [Int: GameJoltItem] = [:]
        for game in library.owned {
            byID[game.gameID] = GameJoltItem(gameID: game.gameID, title: game.title, cover: game.cover, owned: game)
        }
        for (id, record) in library.installed {
            byID[id, default: GameJoltItem(gameID: id, title: record.title)].installed = record
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        return byID.values
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// A download's state, as far as the status needs it.
    enum Transfer: Equatable { case queued, active(percent: Int), paused, failed }

    static func status(installed: GameJoltLibraryGame?, transfer: Transfer?) -> String? {
        if let transfer {
            switch transfer {
            case .queued: return "Waiting"
            case .active(let percent): return "Downloading \(max(0, min(100, percent)))%"
            case .paused: return "Paused"
            case .failed: return "Download failed"
            }
        }
        return installed != nil ? nil : "Not installed"
    }
}

extension LibraryModel {
    /// A Game Jolt game's library entry; a game without one gets a new entry.
    func gamejoltEntry(_ game: GameJoltInstalledGame) -> LibraryEntry {
        if var entry = entries.first(where: { $0.gamejoltAppName == "\(game.gameID)" }) {
            entry.relativePath = game.programPath
            return entry
        }
        var entry = LibraryEntry(title: game.title, relativePath: game.programPath, bits: 0)
        entry.gamejoltAppName = "\(game.gameID)"
        entry.folderBytes = game.installBytes
        return entry
    }
}
// MARK: - Library section

struct GameJoltGamesSection: View {
    let search: String
    var layout = "cards"
    var width: CGFloat = 390
    /// Opens a game's Game details page (LibraryView's details sheet).
    let open: (LibraryEntry) -> Void
    @ObservedObject private var library = GameJoltLibrary.shared
    @ObservedObject private var model = LibraryModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("madeiraLibraryHideGameJolt") private var hidden = false
    @AppStorage("madeiraGameJoltShowUninstalled") private var showUninstalled = true
    @State private var showSignIn = false

    var body: some View {
        let items = GameJoltGamesRules.items(library, search: search)
        let mine = items.filter { $0.installed != nil || library.downloads[$0.id] != nil }
        VStack(alignment: .leading, spacing: 14) {
            LibrarySectionHeader(title: "Game Jolt", count: mine.count, collapsed: nil) {
                if library.refreshing { ProgressView().accessibilityLabel("Refreshing Game Jolt library") }
            }
            if items.isEmpty {
                Text(search.isEmpty
                     ? "Sign in to Game Jolt to see your games."
                     : "No Game Jolt games match your search.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    GameJoltGameCard(item: item, open: open)
                }
            }
            GameJoltSignInCard(signedIn: library.signedIn) { showSignIn = true }
        }
        .sheet(isPresented: $showSignIn) { GameJoltSignInView() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { GameJoltLibrary.shared.reconcileSession() }
        }
    }
}

/// One game's card: its cover, title, download status and a play/download button.
struct GameJoltGameCard: View {
    let item: GameJoltItem
    let open: (LibraryEntry) -> Void
    @ObservedObject private var library = GameJoltLibrary.shared

    var body: some View {
        let status = GameJoltGamesRules.status(installed: item.installed,
                                               transfer: downloadStatus(item.id))
        VStack(alignment: .leading, spacing: 6) {
            if let cover = item.cover { AsyncImage(url: cover) { $0.resizable().scaledToFit() } }
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            if let status { Text(status).font(.caption2).foregroundStyle(.secondary) }
            Button { play(item) } label: { Label("Play", systemImage: "play.fill") }
        }.padding(8)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func downloadStatus(_ id: Int) -> GameJoltGamesRules.Transfer? {
        guard let d = library.downloads[id] else { return nil }
        switch d.state {
        case .queued: return .queued
        case .active: return .active(percent: d.progress.percent)
        case .paused: return .paused
        case .failed: return .failed
        }
    }

    private func play(_ item: GameJoltItem) {
        guard let record = item.installed,
              let entry = model.entries.first(where: { $0.gamejoltAppName == "\(item.id)" }) else { return }
        Task {
            do {
                let args = try await GameJoltLibrary.shared.launchArguments(gameID: item.id)
                LibraryModel.setTransientArguments(args, for: entry.id)
                open(entry)
            } catch {
                GameJoltLibrary.shared.error = error.localizedDescription
            }
        }
    }
}

/// The sign-in card: offered when not signed in.
struct GameJoltSignInCard: View {
    var signedIn: Bool
    var signIn: () -> Void
    var body: some View {
        if signedIn { EmptyView() } else {
            Button(action: signIn) {
                Label("Sign in to Game Jolt…", systemImage: "person.crop.circle")
            }
        }
    }
}

// MARK: - Sign in

struct GameJoltSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var reload = 0
    @State private var busy = false
    @State private var failure: String?
    @State private var pasted = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Sign in to Game Jolt") {
                    TextField("authorization code", text: $pasted).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Enter code") { submit(pasted) }
                        .disabled(busy || pasted.isEmpty)
                    if busy { ProgressView() }
                    if let failure {
                        Text(failure).foregroundStyle(.red).font(.footnote)
                    }
                    Link(destination: GameJoltAPI.loginURL) {
                        Label("Open the login page in Safari", systemImage: "safari")
                    }
                    Text("Open the login page in Safari and sign in. Game Jolt then shows a short text with an authorization code. Copy the code and paste it here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Game Jolt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .sheet(isPresented: Binding(get: { reload > 0 }, set: { if !$0 { reload = 0 } })) {
            GameJoltLoginWebView(reload: reload) { code in submit(code) }
        }
    }

    private func submit(_ text: String) {
        guard !busy else { return }
        guard let code = GameJoltAPI.authorizationCode(in: text) else {
            failure = GameJoltAPI.correctiveAction(in: text).map { "Game Jolt: \($0)" }
                ?? "This is not a Game Jolt sign-in code."
            return
        }
        busy = true
        Task {
            do {
                try await GameJoltLibrary.shared.signIn(code: code)
                busy = false
                dismiss()
            } catch {
                busy = false
                failure = error.localizedDescription
            }
        }
    }
}

/// WKWebView with Game Jolt's login page, in a private (non-persistent) data store.
struct GameJoltLoginWebView: UIViewRepresentable {
    var reload: Int
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: GameJoltAPI.loginURL))
        context.coordinator.loadedReload = reload
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onCode = onCode
        if context.coordinator.loadedReload != reload {
            context.coordinator.loadedReload = reload
            context.coordinator.delivered = false
            view.load(URLRequest(url: GameJoltAPI.loginURL))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onCode: (String) -> Void
        var loadedReload = 0
        var delivered = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !delivered, GameJoltAPI.isRedirectPage(webView.url) else { return }
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
                guard let self, !self.delivered, let text = result as? String,
                      GameJoltAPI.authorizationCode(in: text) != nil || GameJoltAPI.correctiveAction(in: text) != nil else { return }
                self.delivered = true
                self.onCode(text)
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}


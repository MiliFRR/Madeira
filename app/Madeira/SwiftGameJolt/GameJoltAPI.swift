// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import CryptoKit
import Foundation
import Security

// Game Jolt's account API (docs/GAMEJOLT.md): sign in through Game Jolt's web
// login, trade its one-use authorization code for an access token, and list the
// account's games. The tokens live in one Keychain item; nothing else stores
// them. Sign in is off with `env.MADEIRA_GAMEJOLT = 0`.
// NOTE: Game Jolt's real API endpoints and the game/client credentials below are
// placeholders. Fill them in from Game Jolt's API documentation before the store
// works end to end; the sign-in flow (web view -> authorization code -> token)
// follows Epic's exactly (SwiftEpic/EpicAPI.swift).
// Log tag: [gamejolt] (methods and short codes; never a token, code or account id).

/// The signed-in account, as stored in the Keychain.
struct GameJoltSession: Codable, Sendable {
    var accountID: String
    var displayName: String
    var accessToken: String
    var accessExpires: Date
    var refreshToken: String
    var refreshExpires: Date
}

enum GameJoltAPIError: LocalizedError, Equatable {
    case signedOut
    case gamejolt(code: String, message: String)
    case http(Int)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in to Game Jolt to continue."
        case .gamejolt(let code, let message):
            return message.isEmpty ? "Game Jolt refused the request (\(code))." : message
        case .http(let status): return "Game Jolt's server answered with HTTP \(status). Try again later."
        case .invalid(let what): return "Game Jolt sent an unexpected answer (\(what))."
        }
    }

    /// Short and credential-free, for the log.
    var reason: String {
        switch self {
        case .signedOut: return "signed-out"
        case .gamejolt(let code, _): return code
        case .http(let status): return "http-\(status)"
        case .invalid(let what): return "invalid-\(what)"
        }
    }
}

/// One game the account owns.
struct GameJoltOwnedGame: Codable, Identifiable, Hashable, Sendable {
    var gameID: Int
    var title: String
    var cover: URL?
    var id: Int { gameID }
}

/// A game Madeira installed: where and how it starts.
struct GameJoltInstalledGame: Codable, Sendable {
    var gameID: Int
    var title: String
    /// The program, relative to drive_c ("Program Files/GameJolt/Games/<folder>/game.exe").
    var programPath: String
    var installBytes: Int64
}

/// Game Jolt's API client.
final class GameJoltAPI {
    static let shared = GameJoltAPI()

    /// Off with `env.MADEIRA_GAMEJOLT = 0`.
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_GAMEJOLT", default: true) }

    /// Placeholder credentials. Replace with a real Game Jolt game ID / client ID.
    /// See docs/GAMEJOLT.md "Credentials".
    private static let gameID = "0"
    private static let clientID = ""
    private static let service = "madeira.gamejolt.tokens"
    private static let account = "session"

    static func load() -> GameJoltSession? {
        guard let data = KeychainItem.read(service: service, account: account) else { return nil }
        return (try? JSONDecoder().decode(GameJoltSession.self, from: data))
    }

    @discardableResult static func save(_ session: GameJoltSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        return KeychainItem.write(service: service, account: account, data: data)
    }

    static func delete() { KeychainItem.delete(service: service, account: account) }

    /// Game Jolt's login page, opened in a private WKWebView. Its redirect page
    /// carries the one-use authorization code.
    static let loginURL: URL = {
        var components = URLComponents(string: "https://gamejolt.com/login")!
        return components.url!
    }()

    /// Whether a web view has landed on Game Jolt's post-login redirect page.
    static func isRedirectPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.host?.contains("gamejolt.com") == true && url.path.contains("/signin/callback")
    }

    /// Pulls an authorization code (or Game Jolt's request to act on the account)
    /// out of the redirect page's plain text.
    static func authorizationCode(in text: String) -> String? {
        if let pattern = try? NSRegularExpression(pattern: #"authorization_code\s*[:=]\s*([0-9A-Za-z_\-]+)#\"),
           let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
        return nil
    }

    /// Game Jolt's request that the user act on the account first (terms, etc.).
    static func correctiveAction(in text: String) -> String? {
        let lower = text.lowercased()
        for key in ["corrective action required", "accept the terms", "terms of service"]
            where lower.contains(key) { return key }
        return nil
    }

    private func stored() -> GameJoltSession? { Self.load() }

    /// The signed-in account, or nil when the session is gone.
    func account() -> (id: String, name: String)? {
        guard let session = stored(), session.accessExpires > Date() else { return nil }
        return (session.accountID, session.displayName)
    }

    /// Trades the one-use sign-in code for an access + refresh token.
    func signIn(authorizationCode code: String) async throws -> GameJoltSession {
        // Placeholder: real Game Jolt token exchange endpoint goes here.
        throw GameJoltAPIError.invalid("token exchange not yet wired to Game Jolt's API")
    }

    func signOut() { Self.delete() }

    /// A valid session, refreshing with the refresh token when the access token
    /// is stale (Epic's pattern: refresh before every call that needs it).
    func validSession() async throws -> GameJoltSession {
        guard let session = stored() else { throw GameJoltAPIError.signedOut }
        guard session.accessExpires > Date() else {
            // Placeholder: refresh the token here.
            throw GameJoltAPIError.signedOut
        }
        return session
    }

    /// The account's owned games.
    func games() async throws -> [GameJoltOwnedGame] {
        // Placeholder: real Game Jolt owned-games list endpoint goes here.
        throw GameJoltAPIError.invalid("owned games not yet wired to Game Jolt's API")
    }

    private static func event(_ message: String) {
        GameJoltLog.event("[gamejolt] " + message)
    }
}

// MARK: - Keychain helper

private enum KeychainItem {
    static func read(service: String, account: String) -> Data? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    static func write(service: String, account: String, data: Data) -> Bool {
        delete(service: service, account: account)
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(service: String, account: String) {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// Game Jolt log lines.
enum GameJoltLog {
    static func event(_ message: String) {
        #if DEBUG
        fputs("\(message)\n", stderr)
        #endif
    }
}

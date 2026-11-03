# Game Jolt support in Madeira

Madeira can list your Game Jolt games, sign you in, and install them so they run
like any other library game. The integration follows the same pattern as Epic
Games (`SwiftEpic/`) — there is no Game Jolt client in the prefix; games are
downloaded from Game Jolt's CDN into `C:\Program Files\GameJolt\Games\<folder>`
and start as their own Wine program.

## Sign in

Open the Library and tap **Sign in to Game Jolt…** (shown when you are not
signed in). Madeira opens Game Jolt's login page in a private web view. Sign in,
then copy the authorization code Game Jolt shows and paste it into Madeira.
The code is traded for an access + refresh token kept in this device's Keychain
(under the service `madeira.gamejolt.tokens`). Madeira never stores your password.

To sign out, delete the Game Jolt library entries (or reinstall Madeira; the
Keychain item is removed by the sign-out flow once it is wired to a real API).

## Your games

Once signed in, Madeira lists the account's Game Jolt games under **Game Jolt**.
Each card shows:
* cover art and title,
* download state (Waiting / Downloading N% / Paused / Download failed),
* **Play** to start an installed game.

Installed games also get a normal library entry so they appear in the library
grid and can be launched from anywhere. Search (`Search your library`) filters
Steam, Epic and Game Jolt games at once.

## Background downloads

A Game Jolt download keeps running when Madeira leaves the foreground:

* iOS 26+: a continued-processing task (`<bundle id>.download.gamejolt`) lets the
  whole queue finish in the background; iOS shows its own progress UI.
* Earlier iOS: the short background grace period, then a clean pause. Every
  finished chunk is journaled, so the download resumes when you reopen Madeira.
  A local notification says a download finished or failed while Madeira was in
  the background.

`env.MADEIRA_BACKGROUND_DOWNLOADS = 0` disables the continued-processing task;
`env.MADEIRA_DOWNLOAD_NOTIFICATIONS = 0` disables notifications.

Downloads pause while a game session runs (the game owns the CPU and I/O) and
resume when it ends.

## Credentials (needed before downloads work end to end)

`SwiftGameJolt/GameJoltAPI.swift` uses placeholder credentials and endpoints:

```swift
private static let gameID = "0"
private static let clientID = ""
static let loginURL = URL(string: "https://gamejolt.com/login")!
```

Fill in a real Game Jolt game ID / client ID and the token-exchange and
owned-games endpoints from Game Jolt's API documentation, then replace the
`throw GameJoltAPIError.invalid("…")` placeholders in `signIn(authorizationCode:)`
and `games()`. Until then Game Jolt signs in and lists nothing — the store shell,
sign-in flow, library cards and download tracking are all in place.

## Toggles

* `env.MADEIRA_GAMEJOLT = 0` — turns the whole Game Jolt integration off.
* `env.MADEIRA_HWINPUT = 0` — turns keyboard and mouse off (on by default;
  works on iPhone via AssistiveTouch and on iPad natively).
* Settings › Library › "Hide Game Jolt" / "Show uninstalled Game Jolt games".

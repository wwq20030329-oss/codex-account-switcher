# Codex Account Switcher

Codex Account Switcher is a native macOS menu bar app for saving local Codex login snapshots and switching between them quickly.

It combines a SwiftUI menu bar frontend with a bundled Python CLI backend, so you can manage multiple local Codex accounts without manually rebuilding your session every time.

## What It Does

- Save the current local Codex login state as a named profile
- Switch between saved profiles with one click
- Show per-account Codex plan and quota information
- Sort by smart score or `5h` remaining quota
- Search by profile name, email, or plan
- Highlight the best account to use next
- Send low-quota notifications for the current active account
- Capture multiple accounts in sequence with continuous add mode
- Toggle launch at login from inside the app
- Check for newer published versions from the app
- Bundle the backend CLI, app icon, and build metadata into the app bundle

## Install

Build the app bundle:

```bash
./build.sh
```

Install it into `~/Applications`:

```bash
./scripts/install.sh
```

After installation, open:

```text
~/Applications/Codex Account Switcher.app
```

The build output is also available in:

```text
dist/Codex Account Switcher.app
```

## First Use

1. Open Codex and log in to one account.
2. Open Codex Account Switcher.
3. Click `Save Current Account` to create the first profile.
4. Repeat the login and save flow for each additional account.
5. Use `Quick Switch` or `Switch Other Accounts` to move between profiles later.

If you use the `Continuous Add` mode, the app can watch for a new local Codex login and save it automatically as soon as you finish signing in.

## Build From Source

The project is macOS-only and expects the local Swift toolchain that ships with Xcode or Xcode Command Line Tools.

```bash
./build.sh
```

Optional build overrides:

```bash
TARGET_APP="$HOME/Desktop/Codex Account Switcher.app" ./build.sh
```

```bash
VERSION=1.2.3 BUILD_NUMBER=42 ./build.sh
```

## Runtime Resolution

At launch, the app resolves the backend CLI in this order:

1. `CODEX_SWITCHER_CLI_PATH`
2. the bundled app resource `codex-account-switcher`
3. `~/.local/bin/codex-account-switcher`

## How It Works

The app stores local Codex auth snapshots and app session state under:

```text
~/.codex-account-switcher
```

The repository does not contain account snapshots or tokens.

## Product Polish

- `More -> Launch at Login` can register the app as a macOS login item
- `More -> Check for Updates` checks the latest published GitHub release
- `More -> Open Profiles Directory` jumps straight to the local snapshot folder
- The footer shows the current build version and highlights a newer available version when detected

## Known Limitations

- This is a local-session tool, not a true multi-login Codex manager.
- Some account actions can still require Codex re-authentication or MFA.
- Quota and usage data depend on the currently available Codex endpoints and the current local login state.
- Update checks work best once the repository has published GitHub releases.
- The app is macOS-only.

## Project Layout

- `CodexMenuBarApp.swift` - native menu bar app
- `build.sh` - build script
- `assets/AppIcon.icns` - bundled app icon
- `scripts/codex-account-switcher` - CLI backend
- `scripts/generate_icon.swift` - icon generation helper
- `scripts/install.sh` - install helper for `~/Applications`
- `RELEASE.md` - release and publishing checklist

## Notes

- This project is not affiliated with OpenAI.
- Version metadata is embedded from the current git repository when available.
- If the app cannot find the bundled backend, it falls back to `~/.local/bin/codex-account-switcher`.

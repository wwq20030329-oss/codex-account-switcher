# Codex Account Switcher

Codex Account Switcher is a native macOS menu bar app for saving multiple local Codex login snapshots and switching between them quickly.

It combines:

- a SwiftUI menu bar frontend
- a bundled Python CLI backend
- local snapshot storage for Codex auth and app session state

This project is intended for personal local account management on macOS.

## Features

- Save the current local Codex login state as a named profile
- Switch between saved profiles with one click
- Display per-account Codex quota and plan information
- Sort by smart score or `5h` remaining quota
- Search by profile name, email, or plan
- Highlight the best account to switch to next
- Low-quota notifications for the current active account
- Continuous add mode for importing multiple accounts in sequence
- Native app icon, bundled backend CLI, and reproducible local build

## How It Works

The app reads the current local Codex login state on your Mac and stores per-account snapshots under:

```text
~/.codex-account-switcher
```

The repository does not contain account snapshots or tokens.

## Quick Start

Build the app:

```bash
./build.sh
```

Install it into your user Applications folder:

```bash
./scripts/install.sh
```

Open the built app from:

```text
dist/Codex Account Switcher.app
```

Or, after install:

```text
~/Applications/Codex Account Switcher.app
```

## Build Outputs

By default, `build.sh` writes the app bundle to:

```text
dist/Codex Account Switcher.app
```

You can override the output path:

```bash
TARGET_APP="$HOME/Desktop/Codex Account Switcher.app" ./build.sh
```

The build also embeds:

- the bundled CLI backend
- the app icon
- app version metadata from the current git repository when available

## Runtime CLI Resolution

At launch, the app resolves the backend CLI in this order:

1. `CODEX_SWITCHER_CLI_PATH`
2. the bundled app resource `codex-account-switcher`
3. `~/.local/bin/codex-account-switcher`

## Project Layout

- `CodexMenuBarApp.swift` — native menu bar app
- `build.sh` — app build script
- `assets/AppIcon.icns` — bundled app icon
- `scripts/codex-account-switcher` — CLI backend
- `scripts/generate_icon.swift` — icon generation helper
- `scripts/install.sh` — install built app to `~/Applications`

## Notes

- This project is not affiliated with OpenAI.
- Usage display depends on the current Codex login state and available endpoints.
- The app is designed around local session snapshots, not true multi-session sign-in.
- This is a macOS-only project.

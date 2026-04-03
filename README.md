# Codex Account Switcher

Codex Account Switcher is a native macOS menu bar app for saving multiple local Codex login snapshots and switching between them quickly.

It pairs a SwiftUI menu bar frontend with a bundled Python CLI that manages local profile snapshots, usage lookups, refresh timing, and account switching.

## What It Does

- Saves the current local Codex login state as a named profile
- Switches between saved profiles with one click
- Shows Codex plan and quota state for each profile
- Highlights the best account to switch to next
- Supports low-quota notifications, search, sorting, and filtering
- Supports continuous add mode for capturing multiple accounts in sequence

## How It Works

The app uses the current local Codex auth state and app storage on your Mac, then stores per-account snapshots under:

- `~/.codex-account-switcher`

No account snapshots are stored in this repository.

## Project Layout

- `CodexMenuBarApp.swift` — native menu bar app
- `scripts/codex-account-switcher` — bundled CLI backend
- `build.sh` — local build script that outputs the app bundle into `dist/`

## Build

```bash
./build.sh
```

By default, the built app is written to:

```text
dist/Codex Account Switcher.app
```

You can override the output path if needed:

```bash
TARGET_APP="$HOME/Desktop/Codex Account Switcher.app" ./build.sh
```

## Runtime CLI Resolution

At launch, the app resolves the backend CLI in this order:

1. `CODEX_SWITCHER_CLI_PATH`
2. Bundled app resource: `codex-account-switcher`
3. `~/.local/bin/codex-account-switcher`

## Notes

- This project is not affiliated with OpenAI.
- Usage display depends on the current Codex login state and available endpoints.
- The app is intended for personal local account management on macOS.

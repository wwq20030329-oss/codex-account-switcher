# Release Checklist

This file is a lightweight guide for publishing and maintaining Codex Account Switcher.

## Before Release

- Run `./build.sh`
- Run `./scripts/install.sh`
- Open the built app and verify the menu bar icon, account list, and refresh flow
- Confirm the app opens the bundled backend CLI correctly
- Check that the README still matches the current UI
- Review the repository for accidental local paths or credentials

## Versioning

- Use the git tag or build metadata produced by `build.sh`
- Bump `VERSION` and `BUILD_NUMBER` when preparing a new release
- Prefer a small release note that mentions user-facing changes only

## Packaging Suggestion

For GitHub releases, publish a zip containing:

- `Codex Account Switcher.app`
- the short release notes
- any setup caveats, such as the need for macOS and local login state

## Suggested Release Notes

- New account handling or switcher behavior
- Performance or refresh improvements
- UI polish
- Changes to install or build steps

## Post Release

- Verify the public repository README still points to the current install path
- Confirm the app launches after a clean download
- Update the changelog or release notes if the behavior changes

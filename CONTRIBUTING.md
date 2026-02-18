# Contributing to TokenBar

Thanks for your interest in contributing. Here's how to get started.

## Development Setup

```bash
git clone https://github.com/saphid/TokenBar.git
cd TokenBar
make run
```

Requires macOS 14+ and Swift 5.10+.

## Making Changes

1. Fork the repo and create a feature branch from `main`
2. Make your changes
3. Run `swift build` to verify compilation
4. Run `swift test` to verify tests pass
5. Open a pull request

## Adding a Provider

TokenBar has two types of providers:

### Detection-Only Provider

These just detect that a tool is installed. Create a new file in `Sources/TokenBarLib/Providers/DetectionOnly/` and register it in `ProviderRegistry`.

You need to define:
- `typeId` -- unique identifier (e.g., `"aider"`)
- `defaultName` -- display name
- `pathsToCheck` -- file paths that indicate the tool is installed
- `commandsToCheck` -- CLI commands to check via `which`
- `extensionPatterns` -- VS Code/Cursor extension prefixes

### Trackable Provider

These connect to APIs to fetch usage data. Implement the `RegisteredProvider` protocol and the `UsageProvider` protocol for the actual polling logic.

Key things to implement:
- `configFields` -- what config the user needs to provide (API key, org ID, etc.)
- `create()` -- factory method that builds the `UsageProvider` from config
- `fetchUsage()` -- async method that calls the provider API and returns usage stats

Look at `OpenAIProvider.swift` or `CursorProvider.swift` for reference implementations.

## Code Style

- Follow existing patterns in the codebase
- No external dependencies -- TokenBar is pure Swift/SwiftUI
- Store secrets in Keychain via `KeychainHelper`, never in UserDefaults or plain text
- Keep providers self-contained -- each provider defines its own config schema

## Reporting Issues

Use the [GitHub issue templates](.github/ISSUE_TEMPLATE/) to report bugs or request features.

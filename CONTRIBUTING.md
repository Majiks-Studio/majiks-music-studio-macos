# Contributing to Majik's Music Studio

Thanks for your interest in contributing! This guide covers the essentials for building, testing, and submitting changes.

## Prerequisites

- macOS 14+ (Sonoma or later)
- Apple Silicon Mac (M1/M2/M3/M4)
- Swift 6 toolchain (comes with Xcode 16+)
- Python 3.12

## Build

```bash
cd src/swift
swift build
```

The app launches a Python backend as a subprocess. On first launch, the Setup Wizard downloads ACE-Step model weights and your chosen chat LLM.

## Test

```bash
cd src/swift
swift test
```

## Project Structure

See [CLAUDE.md](CLAUDE.md) for the full architecture overview, key files, and conventions.

**Quick summary**: Swift/SwiftUI frontend communicates with a Python backend via JSON-RPC over stdin/stdout. The frontend handles UI; the backend handles LLM chat, parameter extraction, and ACE-Step music generation.

### Publisher Module

The `Publisher/` directory and `publisher_rpc.py` are part of the paid Pro Suite and are **not included** in the open-source repository. Code gated behind `#if PUBLISHER_ENABLED` relates to this module.

## Key Conventions

- **Swift 6 strict concurrency** -- the project uses Swift 6's full concurrency checking. All `@MainActor` annotations and `Sendable` conformances are intentional.
- **No `print()` in Python backend** -- stdout is the JSON-RPC transport channel. Any `print()` call corrupts the protocol. Use `sys.stderr.write()` or the `logging` module instead.
- **Sequential model loading** -- Chat LLM, extraction model, and ACE-Step must load/unload one at a time. Never have multiple models in memory simultaneously.
- **No apostrophe in file paths** -- The display name is "Majik's Music Studio" but all file paths, bundle IDs, and build variables use `Majiks` (no apostrophe) to avoid shell escaping issues.

## Submitting Changes

1. Fork the repository
2. Create a feature branch from `main`
3. Make your changes
4. Run `swift build` and `swift test` to verify
5. Submit a pull request with a clear description of what changed and why

### Issues

Use the [issue tracker](https://git.unicorncommander.ai/MajiksStudio/majiks-music-studio-macos/issues) to report bugs or request features. Include macOS version, chip (M1/M2/etc.), and memory when reporting bugs.

# Contributing to AppAgent

Thank you for your interest in contributing to AppAgent! This document provides guidelines and instructions for contributing.

## Getting Started

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/your-username/AppAgent.git
   cd AppAgent
   ```
3. Open the Package in Xcode to explore the SDK:
   ```bash
   open Package.swift
   ```
4. Or build and test via SPM:
   ```bash
   swift build
   swift test
   ```

## Development Setup

### Prerequisites
- Xcode 15.0+
- Swift 5.9+
- iOS 15.0+ deployment target

### Running the Demo App
1. Copy the config template:
   ```bash
   cp Examples/iOS/Resources/config.json.example Examples/iOS/Resources/config.json
   ```
2. Edit `Examples/iOS/Resources/config.json` with your API key and settings
3. Open `Package.swift` in Xcode, select the `AppAgentDemoApp` scheme
4. Build and run on a simulator or device

## Making Changes

### Branching Strategy
- Create a feature branch from `main`: `feature/your-feature-name`
- Create a bugfix branch from `main`: `fix/your-fix-description`

### Code Style
- Follow existing code conventions in the project
- Use Swift naming conventions (camelCase for variables/functions, PascalCase for types)
- Add `public` access control for any new SDK API surfaces
- Keep internal implementation details `private` or `internal`

### Adding a New LLM Provider
See [docs/Providers.md](docs/Providers.md) for a guide on implementing the `LLMProvider` protocol.

### Adding a New Tool
See [docs/Tools.md](docs/Tools.md) for a guide on implementing the `Tool` protocol.

## Pull Request Process

1. Ensure your code compiles without warnings
2. Run tests: `swift test`
3. Update documentation if you changed public APIs
4. Update `CHANGELOG.md` with your changes under `[Unreleased]`
5. Submit a pull request with a clear description of the changes

## Reporting Issues

- Use GitHub Issues to report bugs
- Include steps to reproduce, expected behavior, and actual behavior
- Include Xcode version, iOS version, and device/simulator info

## License

By contributing to AppAgent, you agree that your contributions will be licensed under the Apache License 2.0.

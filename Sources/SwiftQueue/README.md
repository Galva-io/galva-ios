# SwiftQueue - Internal Fork

This directory contains a modified fork of [SwiftQueue](https://github.com/lucas34/SwiftQueue), a robust job queue library for iOS/macOS applications.

## About This Fork

This is an internal fork of SwiftQueue v5.0.0+ that has been modified specifically for use within the RevFlow SDK. The main modifications include:

1. **Access Control**: All `public` and `open` access modifiers have been removed to make the library internal-only
2. **Namespace Changes**: The `Job` protocol has been renamed to `SwiftQueueJob` to avoid conflicts with RevFlow's existing types
3. **Module Integration**: The library is now part of the RevFlow SDK module rather than a separate SwiftQueue module

## Original Author

SwiftQueue was created by **Lucas Nelaupe** (@lucas34) and is licensed under the MIT License.

- GitHub: https://github.com/lucas34/SwiftQueue
- License: MIT (see individual file headers)

## Why Fork?

We chose to fork SwiftQueue rather than use it as a dependency to:
- Prevent exposing SwiftQueue's API surface to RevFlow SDK consumers
- Maintain full control over the job queue implementation
- Avoid dependency conflicts for SDK users who might also use SwiftQueue

## Usage

This fork is for internal use only within the RevFlow SDK. The APIs are not exposed to SDK consumers and should only be used by RevFlow's internal implementation.

## Updates

To update this fork with upstream changes:
1. Check the original repository for updates: https://github.com/lucas34/SwiftQueue
2. Apply relevant changes manually, ensuring access modifiers remain internal
3. Test thoroughly with `swift test`

## License

This fork maintains the original MIT License. See individual source files for the complete license text.
# SwiftQueue Acknowledgement

This directory contains a modified version of SwiftQueue, originally created by Lucas Nelaupe.

## Original Project
- **Name**: SwiftQueue
- **Author**: Lucas Nelaupe
- **License**: MIT License
- **Source**: https://github.com/lucas34/SwiftQueue
- **Copyright**: Copyright (c) 2022 Lucas Nelaupe

## Modifications
This is a fork of SwiftQueue that has been modified for internal use within the RevFlow SDK:
- All public/open access modifiers have been removed to prevent exposing symbols to SDK consumers
- The `Job` protocol has been renamed to `SwiftQueueJob` to avoid naming conflicts
- The library is now integrated as part of the RevFlow SDK module rather than a separate module

## License
The original SwiftQueue library is licensed under the MIT License, which permits modification and redistribution. The full license text is preserved in each source file.

## Gratitude
We thank Lucas Nelaupe and all contributors to the SwiftQueue project for creating this excellent job queue implementation for iOS/macOS.
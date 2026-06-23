# frozen_string_literal: true
#
# galva-build.rb — single source of truth for the Galva iOS SDK's CocoaPods
# build settings, mirroring Package.swift.
#
# Galva is distributed publicly via Swift Package Manager ONLY. This file
# exists solely so `galva-react-native` can compile a *vendored snapshot* of
# `Sources/` into its own pod — there is no public Galva pod and nothing is
# ever pushed to the CocoaPods trunk (which goes permanently read-only on
# 2026-12-02 anyway). The React Native vendor step copies this file alongside
# `Sources/`, and that package's podspec applies it:
#
#     require_relative 'ios/galva/galva-build.rb'
#     Pod::Spec.new do |s|
#       # ...glue + vendored source_files...
#       galva_apply_build_settings(s)
#     end
#
# Keeping the settings here — versioned next to the code — means any change to
# Package.swift's platform / Swift / linker requirements lands in the same
# commit as the code that needs it, so the pod can't silently drift from SPM.
#
# Mirrors Package.swift:
#   • platforms: .iOS(.v15)         -> s.platform       = :ios, '15.0'
#   • swift-tools-version: 6.0      -> s.swift_versions = ['6.0']
#   • linkerSettings .linkedLibrary -> s.library        = 'sqlite3'
#
# System frameworks (UIKit, WebKit, StoreKit, UserNotifications, AdServices)
# are intentionally NOT listed. Swift autolinking emits each one's link
# directive from its `import` statement (every import sits behind a
# `#if canImport(...)` gate), exactly as under SPM — so listing them here
# would be a second source of truth that could drift from the code.
#
# iOS-only: the React Native pod targets iOS, so the macOS platform that
# Package.swift also supports is deliberately omitted here.
def galva_apply_build_settings(s)
  s.platform       = :ios, '15.0'
  s.swift_versions = ['6.0']
  s.library        = 'sqlite3'
end

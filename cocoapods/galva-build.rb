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
#     require_relative 'ios/galva-src/galva-build.rb'
#     Pod::Spec.new do |s|
#       # ...glue + vendored source_files...
#       galva_apply_build_settings(s)
#       galva_apply_privacy_manifest(s, 'ios/galva-src/Sources')
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
#   • resources (privacy manifest)  -> galva_apply_privacy_manifest
#
# System frameworks (UIKit, WebKit, StoreKit, UserNotifications, AdServices)
# are intentionally NOT listed. Swift autolinking emits each one's link
# directive from its `import` statement, exactly as under SPM — so listing
# them here would be a second source of truth that could drift from the code.
#
# iOS-only: the React Native pod targets iOS, so the macOS platform that
# Package.swift also supports is deliberately omitted here.
def galva_apply_build_settings(s)
  s.platform       = :ios, '15.0'
  s.swift_versions = ['6.0']
  s.library        = 'sqlite3'
end

# Ships the SDK's privacy manifest in the pod, as Package.swift's
# `resources: [.copy("Resources/PrivacyInfo.xcprivacy")]` does for SPM, so
# React Native apps get the SDK's declarations: the data it collects, and
# its two required-reason APIs, UserDefaults (CA92.1) and system boot time
# (35F9.1). Pass the vendored `Sources/` directory, relative to the podspec:
#
#     galva_apply_privacy_manifest(s, 'ios/galva-src/Sources')
#
# Where it lands depends on how the app links pods:
#   • Static libraries (React Native's default) or static frameworks
#     (common with Expo): a `GalvaPrivacy` resource bundle at the app's
#     root. A bare file would collide with the app's own
#     PrivacyInfo.xcprivacy, and React Native's pod-install aggregation
#     reads pods' manifests from resource bundles.
#   • USE_FRAMEWORKS=dynamic: the root of Galva.framework, where Apple puts
#     a framework's manifest. Galva's code is in that framework's binary,
#     not the app's, so the app's manifest doesn't cover it. React Native
#     0.71+ sets USE_FRAMEWORKS from the Podfile's `use_frameworks!`.
#
# Raises when the manifest isn't there (a stale vendor sync, or a moved
# file): `pod install` and the build would otherwise ship an empty bundle.
# Opt-in so existing podspecs keep working until they call it. It sets
# `resources` or `resource_bundles`, replacing any the podspec set before.
def galva_apply_privacy_manifest(s, sources_dir)
  manifest = "#{sources_dir}/Resources/PrivacyInfo.xcprivacy"
  # CocoaPods evaluates a podspec from its own directory, so this resolves
  # the same way the file patterns do.
  unless File.exist?(manifest)
    raise "Galva privacy manifest not found at #{manifest}. The vendored " \
          "Sources/ is out of sync with galva-build.rb; re-run sync-galva"
  end

  if ENV['USE_FRAMEWORKS'].to_s.downcase == 'dynamic'
    s.resources = [manifest]
  else
    s.resource_bundles = { 'GalvaPrivacy' => [manifest] }
  end
end

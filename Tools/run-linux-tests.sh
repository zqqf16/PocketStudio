#!/usr/bin/env bash
# 需要 Swift 6.2+ 工具链。
# 在 Linux/macOS 上用 SwiftPM 运行平台无关协议层（PocketStudio/Core）的单元测试。
# 不会在仓库中留下 Package.swift：在临时目录生成包并软链源码。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/pocketstudiocore-tests"
rm -rf "$TMP"; mkdir -p "$TMP/Sources" "$TMP/Tests"
ln -s "$ROOT/PocketStudio/Core" "$TMP/Sources/PocketStudioCore"
ln -s "$ROOT/PocketStudioTests" "$TMP/Tests/PocketStudioCoreTests"
cat > "$TMP/Package.swift" <<'PKG'
// swift-tools-version:6.2
import PackageDescription
// 与 Xcode 26 新工程默认值一致：Swift 6、默认 MainActor 隔离、Approachable Concurrency。
// 可用环境变量 ISOLATION=nonisolated 切换默认隔离再测一次。
import Foundation
let iso: [SwiftSetting] = ProcessInfo.processInfo.environment["ISOLATION"] == "nonisolated" ? [] : [.defaultIsolation(MainActor.self)]
let strict: [SwiftSetting] = iso + [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .unsafeFlags(["-warnings-as-errors"]),
]
let package = Package(name: "PocketStudioCore",
  targets: [
    .target(name: "PocketStudioCore", path: "Sources/PocketStudioCore", swiftSettings: strict),
    .testTarget(name: "PocketStudioCoreTests", dependencies: ["PocketStudioCore"], path: "Tests/PocketStudioCoreTests", swiftSettings: strict),
  ],
  swiftLanguageModes: [.v6])
PKG
cd "$TMP" && swift test "$@"

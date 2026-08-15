import Testing
import Foundation
@testable import MediaBridge

/// Repository root relative to the test file.
///
/// Five levels from the file itself to the root: the file lives in
/// Packages/NotchKit/Tests/MediaBridgeTests/, and each call strips one
/// path component (including the file name on the first step).
private var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AdapterProcessIntegrationTests.swift -> MediaBridgeTests
        .deletingLastPathComponent()  // MediaBridgeTests -> Tests
        .deletingLastPathComponent()  // Tests -> NotchKit
        .deletingLastPathComponent()  // NotchKit -> Packages
        .deletingLastPathComponent()  // Packages -> repository root
}

/// Shared paths for the file's tests — factored out so the `.enabled(if:)`
/// trait condition and the test body don't disagree on what counts as the path.
private var adapterPaths: AdapterPaths {
    AdapterPaths.vendored(repoRoot: repoRoot)
}

@Test("vendored adapter paths are absolute")
func vendoredPathsAreAbsolute() {
    let paths = adapterPaths
    #expect(paths.script.path.hasPrefix("/"))
    #expect(paths.framework.path.hasPrefix("/"))
    #expect(paths.perl.path == "/usr/bin/perl")
}

/// Requires a built framework. Skipped via the `.enabled(if:)` trait,
/// not via a `#require` failure: the trait condition is evaluated BEFORE
/// the test body, so Swift Testing honestly marks the test as skipped
/// rather than failed. A `#require` failure inside the body is always a
/// failed test, not a skipped one, as the first run of this file showed
/// (adapter not built → red test with "skipped" text in the error message,
/// which is misleading).
@Test(
    "adapter stream yields at least one parsed line",
    .enabled(if: adapterPaths.existsOnDisk, "adapter not built, test skipped")
)
func streamYieldsParsedLine() async throws {
    let paths = adapterPaths
    let adapter = AdapterProcess(paths: paths)
    var received: AdapterLine?
    for await line in await adapter.lines() {
        received = line
        break
    }
    await adapter.stop()
    #expect(received != nil)
}

/// A one-shot `get` against a real process — same trait rationale as
/// streamYieldsParsedLine() above. Doesn't check the snapshot's contents:
/// whether something is playing right now on the machine running the test
/// is environment state, not a property of the code, and both nil ("nothing
/// is playing right now") and a non-empty snapshot are legitimate outcomes
/// of a live request. What's being checked is what can't be checked any
/// other way without a real process: that a request to the live adapter
/// runs to completion (doesn't throw, doesn't hang reading the output pipe).
@Test(
    "get doesn't hang and returns a recognized response from the live adapter",
    .enabled(if: adapterPaths.existsOnDisk, "adapter not built, test skipped")
)
func getReturnsStateFromLiveAdapter() async throws {
    let paths = adapterPaths
    let adapter = AdapterProcess(paths: paths)
    _ = try await adapter.get()
}

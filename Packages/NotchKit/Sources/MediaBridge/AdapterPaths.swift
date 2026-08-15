import Foundation

/// Paths to the vendored adapter.
///
/// All must be absolute: a spike showed that with a relative path
/// the bridge fails with `Failed to load framework` — it resolves the framework from within
/// its own process and knows nothing about the caller's working directory.
public struct AdapterPaths: Sendable, Equatable {
    public let perl: URL
    public let script: URL
    public let framework: URL

    public init(perl: URL, script: URL, framework: URL) {
        self.perl = perl
        self.script = script
        self.framework = framework
    }

    /// Layout of the vendored copy in the repository.
    public static func vendored(repoRoot: URL) -> AdapterPaths {
        AdapterPaths(
            perl: URL(fileURLWithPath: "/usr/bin/perl"),
            script: repoRoot.appending(path: "vendor/mediaremote-adapter/bin/mediaremote-adapter.pl"),
            framework: repoRoot.appending(path: "vendor/mediaremote-adapter/.build/MediaRemoteAdapter.framework")
        )
    }

    public var existsOnDisk: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: perl.path)
            && fm.fileExists(atPath: script.path)
            && fm.fileExists(atPath: framework.path)
    }
}

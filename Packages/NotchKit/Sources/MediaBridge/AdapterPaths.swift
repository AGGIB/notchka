import Foundation

/// Пути к вендоренному адаптеру.
///
/// Все обязаны быть абсолютными: спайк показал, что с относительным путём
/// бридж падает с `Failed to load framework` — он резолвит фреймворк изнутри
/// собственного процесса и ничего не знает о рабочем каталоге вызывающего.
public struct AdapterPaths: Sendable, Equatable {
    public let perl: URL
    public let script: URL
    public let framework: URL

    public init(perl: URL, script: URL, framework: URL) {
        self.perl = perl
        self.script = script
        self.framework = framework
    }

    /// Раскладка вендоренной копии в репозитории.
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

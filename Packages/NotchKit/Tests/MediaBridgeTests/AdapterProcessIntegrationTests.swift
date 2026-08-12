import Testing
import Foundation
@testable import MediaBridge

/// Корень репозитория относительно файла теста.
///
/// От самого файла до корня — пять уровней: файл лежит в
/// Packages/NotchKit/Tests/MediaBridgeTests/, и каждый вызов снимает один
/// компонент пути (включая имя файла на первом шаге).
private var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AdapterProcessIntegrationTests.swift -> MediaBridgeTests
        .deletingLastPathComponent()  // MediaBridgeTests -> Tests
        .deletingLastPathComponent()  // Tests -> NotchKit
        .deletingLastPathComponent()  // NotchKit -> Packages
        .deletingLastPathComponent()  // Packages -> корень репозитория
}

@Test("пути к вендоренному адаптеру абсолютны")
func vendoredPathsAreAbsolute() {
    let paths = AdapterPaths.vendored(repoRoot: repoRoot)
    #expect(paths.script.path.hasPrefix("/"))
    #expect(paths.framework.path.hasPrefix("/"))
    #expect(paths.perl.path == "/usr/bin/perl")
}

/// Требует собранного фреймворка. Пропускается, если его нет: собирать
/// адаптер ради теста незачем, а на машине разработчика он уже есть.
@Test("поток адаптера отдаёт хотя бы одну разобранную строку")
func streamYieldsParsedLine() async throws {
    let paths = AdapterPaths.vendored(repoRoot: repoRoot)
    try #require(paths.existsOnDisk, "адаптер не собран, тест пропущен")

    let adapter = AdapterProcess(paths: paths)
    var received: AdapterLine?
    for await line in await adapter.lines() {
        received = line
        break
    }
    await adapter.stop()
    #expect(received != nil)
}

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

/// Общие пути для тестов файла — вынесены, чтобы условие трейта
/// `.enabled(if:)` и тело теста не расходились в том, что считают путём.
private var adapterPaths: AdapterPaths {
    AdapterPaths.vendored(repoRoot: repoRoot)
}

@Test("пути к вендоренному адаптеру абсолютны")
func vendoredPathsAreAbsolute() {
    let paths = adapterPaths
    #expect(paths.script.path.hasPrefix("/"))
    #expect(paths.framework.path.hasPrefix("/"))
    #expect(paths.perl.path == "/usr/bin/perl")
}

/// Требует собранного фреймворка. Пропускается через трейт `.enabled(if:)`,
/// а не через провал `#require`: условие трейта вычисляется ДО тела теста,
/// и Swift Testing честно помечает тест как skipped, а не failed. Провал
/// `#require` внутри тела — это всегда упавший тест, а не пропущенный, как
/// показал первый прогон этого файла (не собран адаптер → красный тест
/// с текстом «пропущен» в сообщении об ошибке, что вводит в заблуждение).
@Test(
    "поток адаптера отдаёт хотя бы одну разобранную строку",
    .enabled(if: adapterPaths.existsOnDisk, "адаптер не собран, тест пропущен")
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

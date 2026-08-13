import Testing
import Foundation
@testable import NotchStore

@Test("база и блобы лежат внутри каталога приложения")
func pathsAreInsideApplicationSupport() {
    let location = StoreLocation(bundleID: "kz.mobilefirst.notchka")
    #expect(location.databaseURL.path.contains("Application Support/kz.mobilefirst.notchka"))
    #expect(location.blobsDirectory.path.contains("Application Support/kz.mobilefirst.notchka"))
    #expect(location.databaseURL.lastPathComponent == "notch.sqlite")
}

@Test("временное расположение изолировано и не трогает боевое")
func temporaryLocationIsIsolated() {
    let a = StoreLocation.temporary()
    let b = StoreLocation.temporary()
    #expect(a.databaseURL != b.databaseURL)
    #expect(a.databaseURL.path.contains("Application Support") == false)
}

@Test("каталоги создаются по требованию")
func directoriesAreCreated() throws {
    let location = StoreLocation.temporary()
    try location.createDirectories()
    #expect(FileManager.default.fileExists(atPath: location.blobsDirectory.path))
}

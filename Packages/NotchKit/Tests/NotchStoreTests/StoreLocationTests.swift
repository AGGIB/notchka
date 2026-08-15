import Testing
import Foundation
@testable import NotchStore

@Test("database and blobs live inside the app's directory")
func pathsAreInsideApplicationSupport() {
    let location = StoreLocation(bundleID: "kz.mobilefirst.notchka")
    #expect(location.databaseURL.path.contains("Application Support/kz.mobilefirst.notchka"))
    #expect(location.blobsDirectory.path.contains("Application Support/kz.mobilefirst.notchka"))
    #expect(location.databaseURL.lastPathComponent == "notch.sqlite")
}

@Test("temporary location is isolated and doesn't touch production")
func temporaryLocationIsIsolated() {
    let a = StoreLocation.temporary()
    let b = StoreLocation.temporary()
    #expect(a.databaseURL != b.databaseURL)
    #expect(a.databaseURL.path.contains("Application Support") == false)
}

@Test("directories are created on demand")
func directoriesAreCreated() throws {
    let location = StoreLocation.temporary()
    try location.createDirectories()
    #expect(FileManager.default.fileExists(atPath: location.blobsDirectory.path))
}

import Testing
import Foundation
@testable import MediaBridge

/// Реальный payload из спайка, обложка обрезана.
private let fullPayloadLine = """
{"type":"data","diff":false,"payload":{"playbackRate":1,"album":"","elapsedTime":200.349576,\
"timestamp":"2026-08-10T11:35:25Z","bundleIdentifier":"com.google.Chrome",\
"processIdentifier":59148,"artworkData":"/9j/4AAQSkZJRg==","title":"Deep Work Music",\
"artworkMimeType":"image/jpeg","duration":7279.961,"artist":"Deep Idle Room",\
"contentItemIdentifier":"F06E3460-AF16-445A-AF1E-2600F5CA2D5E","playing":true}}
"""

@Test("полный снимок разбирается со всеми полями")
func fullSnapshotParses() throws {
    guard case .snapshot(let snapshot?) = AdapterLine.parse(fullPayloadLine) else {
        Issue.record("ожидался снимок")
        return
    }
    #expect(snapshot.title == "Deep Work Music")
    #expect(snapshot.artist == "Deep Idle Room")
    #expect(snapshot.sourceBundleID == "com.google.Chrome")
    #expect(snapshot.isPlaying == true)
    #expect(snapshot.playbackRate == 1)
    #expect(abs(snapshot.duration - 7279.961) < 0.001)
    #expect(abs(snapshot.elapsedTime - 200.349576) < 0.001)
    #expect(snapshot.artworkData != nil)
    // Chrome в этом payload заявляет себя напрямую — родителя адаптер не
    // присылает, и это должно остаться nil, а не пустой строкой.
    #expect(snapshot.parentApplicationBundleID == nil)
}

/// Payload вспомогательного процесса Safari — эмпирическая находка Task 4:
/// `bundleIdentifier` указывает на процесс рендеринга WebKit, а настоящее
/// приложение приходит отдельным полем `parentApplicationBundleIdentifier`.
private let safariPayloadLine = """
{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.WebKit.GPU",\
"parentApplicationBundleIdentifier":"com.apple.Safari","title":"Трек",\
"artist":"Исполнитель","album":"","duration":200,"elapsedTime":0,\
"timestamp":"2026-08-10T11:35:25Z","playbackRate":1,"playing":true}}
"""

@Test("вспомогательный процесс несёт bundle id родителя отдельным полем")
func helperProcessCarriesParentBundleID() throws {
    guard case .snapshot(let snapshot?) = AdapterLine.parse(safariPayloadLine) else {
        Issue.record("ожидался снимок")
        return
    }
    #expect(snapshot.sourceBundleID == "com.apple.WebKit.GPU")
    #expect(snapshot.parentApplicationBundleID == "com.apple.Safari")
}

@Test("служебная первая строка потока значит «ничего не играет»")
func emptySnapshotMeansNoSession() {
    guard case .snapshot(let snapshot) = AdapterLine.parse(#"{"type":"data","diff":false,"payload":{}}"#) else {
        Issue.record("ожидался снимок")
        return
    }
    #expect(snapshot == nil)
}

@Test("дифф разбирается как частичный payload")
func diffParsesAsPartial() throws {
    guard case .diff(let payload) = AdapterLine.parse(#"{"type":"data","diff":true,"payload":{"playing":true}}"#) else {
        Issue.record("ожидался дифф")
        return
    }
    #expect(payload.playing == true)
    #expect(payload.title == nil)
}

@Test("дифф накладывается на снимок, не затирая незаданные поля")
func diffMergesWithoutClobbering() throws {
    guard case .snapshot(let base?) = AdapterLine.parse(fullPayloadLine),
          case .diff(let payload) = AdapterLine.parse(#"{"type":"data","diff":true,"payload":{"playing":false}}"#)
    else {
        Issue.record("подготовка не удалась")
        return
    }
    let merged = try #require(payload.applied(to: base))
    #expect(merged.isPlaying == false)
    #expect(merged.title == "Deep Work Music")
    #expect(merged.sourceBundleID == "com.google.Chrome")
}

@Test("текст таймаута опознаётся как временная осечка, а не как мусор")
func timeoutTextIsTransient() {
    let line = "Reading now playing information timed out after 2000 milliseconds"
    guard case .transientFailure(let text) = AdapterLine.parse(line) else {
        Issue.record("ожидалась временная осечка")
        return
    }
    #expect(text.contains("timed out"))
}

@Test("непонятная строка не роняет разбор")
func garbageIsUnrecognised() {
    guard case .unrecognized = AdapterLine.parse("{не json") else {
        Issue.record("ожидалась неопознанная строка")
        return
    }
}

@Test("пустая строка не считается событием")
func blankLineIsUnrecognised() {
    guard case .unrecognized = AdapterLine.parse("   ") else {
        Issue.record("ожидалась неопознанная строка")
        return
    }
}

@Test("дифф до первого снимка не даёт состояния")
func diffBeforeSnapshotIsIgnored() {
    guard case .diff(let payload) = AdapterLine.parse(#"{"type":"data","diff":true,"payload":{"playing":true}}"#) else {
        Issue.record("ожидался дифф")
        return
    }
    let result = payload.applied(to: nil)
    #expect(result == nil)
}

@Test("валидный JSON с «timed out» внутри разбирается как снимок, не как осечка")
func jsonWithTimeoutInDataIsNotTransientFailure() {
    let lineWithTimeoutInTitle = """
    {"type":"data","diff":false,"payload":{"title":"Reading timed out","artist":"Test","album":"","duration":0,"elapsedTime":0,"timestamp":"2026-08-10T11:35:25Z","bundleIdentifier":"test","playing":false}}
    """
    guard case .snapshot(let snapshot?) = AdapterLine.parse(lineWithTimeoutInTitle) else {
        Issue.record("ожидался снимок")
        return
    }
    #expect(snapshot.title == "Reading timed out")
}

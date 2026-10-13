import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import wallhaven

struct ReliabilityTests {
    private func fixtureApp(_ folder: URL, version: String, bundleID: String = "test.scena") throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "Scena", "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("Contents/Info.plist"))
        let executable = folder.appendingPathComponent("Contents/MacOS/Scena")
        try Data(version.utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    @Test func partialCopyNeverRemovesInstalledApplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("Scena.app"), staged = root.appendingPathComponent("new.app")
        try fixtureApp(current, version: "old")
        try fixtureApp(staged, version: "new")
        #expect(throws: CocoaError.self) {
            try AppReplacement.replace(staged: staged, current: current, bundleID: "test.scena") { _, target in
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        #expect(try String(contentsOf: current.appendingPathComponent("Contents/MacOS/Scena"), encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }

    @Test func successfulReplacementPublishesWholeApplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("Scena.app"), staged = root.appendingPathComponent("new.app")
        try fixtureApp(current, version: "old")
        try fixtureApp(staged, version: "new")
        try AppReplacement.replace(staged: staged, current: current, bundleID: "test.scena")
        #expect(try String(contentsOf: current.appendingPathComponent("Contents/MacOS/Scena"), encoding: .utf8) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }

    @Test func wrongApplicationCannotReplaceInstalledVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("Scena.app"), staged = root.appendingPathComponent("new.app")
        try fixtureApp(current, version: "old")
        try fixtureApp(staged, version: "new", bundleID: "another.app")
        #expect(throws: CocoaError.self) { try AppReplacement.replace(staged: staged, current: current, bundleID: "test.scena") }
        #expect(try String(contentsOf: current.appendingPathComponent("Contents/MacOS/Scena"), encoding: .utf8) == "old")
    }

    @Test func projectJSONAloneIsNotACompletedDownload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"file":"video.mp4"}"#.utf8).write(to: root.appendingPathComponent("project.json"))
        #expect(WorkshopDownloadReceipt.capture(folder: root) == nil)
    }

    @Test func removedOrTruncatedAssetInvalidatesReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"file":"video.mp4"}"#.utf8).write(to: root.appendingPathComponent("project.json"))
        let video = root.appendingPathComponent("video.mp4")
        try Data(repeating: 1, count: 100).write(to: video)
        let receipt = try #require(WorkshopDownloadReceipt.capture(folder: root))
        #expect(receipt.matches(folder: root))
        try Data(repeating: 1, count: 10).write(to: video)
        #expect(!receipt.matches(folder: root))
        try FileManager.default.removeItem(at: video)
        #expect(!receipt.matches(folder: root))
    }

    @Test @MainActor func rejectedHotKeyPreservesRegistrationAndPreferences() throws {
        let suite = "test.scena.hotkey.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var removed = 0
        let keys = GlobalHotKeys(defaults: defaults, registration: { combo, _ in
            combo.keyCode == 1 ? EventHotKeyRef(bitPattern: 1) : nil
        }, unregister: { _ in removed += 1 }, installsNativeHandler: false)
        let old = HotKeyCombo(keyCode: 1, modifiers: UInt32(cmdKey), display: "old")
        keys.set(old, for: .togglePause)
        let saved = defaults.data(forKey: "hotKey.togglePause")
        keys.set(HotKeyCombo(keyCode: 2, modifiers: UInt32(cmdKey), display: "conflict"), for: .togglePause)
        #expect(removed == 0)
        #expect(keys.combos[.togglePause] == old)
        #expect(defaults.data(forKey: "hotKey.togglePause") == saved)
        keys.set(nil, for: .togglePause)
        #expect(removed == 1)
    }
}

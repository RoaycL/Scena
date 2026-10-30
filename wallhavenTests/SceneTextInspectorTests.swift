import Foundation
import Testing
@testable import wallhaven

struct SceneTextInspectorTests {
    private let testDefaults = TestDefaults()

    /// 按 Wallpaper Engine 的 PKG 格式打包：版本字符串、条目数、每个条目的名称 / 偏移 / 长度，然后是数据区
    private func package(_ files: [(String, Data)]) -> Data {
        var data = Data()
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func string(_ value: String) { u32(value.utf8.count); data.append(contentsOf: value.utf8) }
        string("PKGV0024")
        u32(files.count)
        var offset = 0
        for (name, body) in files {
            string(name); u32(offset); u32(body.count)
            offset += body.count
        }
        for (_, body) in files { data.append(body) }
        return data
    }

    private func sceneFolder(objects: String) throws -> URL {
        let folder = testDefaults.makeDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type":"scene","file":"scene.json","title":"Text"}"#.utf8).write(to: folder.appendingPathComponent("project.json"))
        let scene = Data(#"{"general":{},"objects":\#(objects)}"#.utf8)
        try package([("materials/a.json", Data("{}".utf8)), ("scene.json", scene), ("models/b.json", Data("{}".utf8))])
            .write(to: folder.appendingPathComponent("scene.pkg"))
        return folder
    }

    @Test func readsTextLayersFromScenePackage() throws {
        let live = try sceneFolder(objects: #"[{"image":"models/b.json"},{"text":"——"},{"text":{"script":"export function update(){ return new Date().toString() }","value":"17:19"}}]"#)
        #expect(SceneTextInspector.info(for: live) == .init(hasText: true, hasLiveText: true))

        let plain = try sceneFolder(objects: #"[{"text":"Hello"},{"text":{"value":"static"}}]"#)
        #expect(SceneTextInspector.info(for: plain) == .init(hasText: true, hasLiveText: false))

        let none = try sceneFolder(objects: #"[{"image":"models/b.json"}]"#)
        #expect(SceneTextInspector.info(for: none) == .init())
    }

    @Test func liveTextScenesAreNotConvertedAutomatically() throws {
        let live = try #require(WorkshopItem.load(from: try sceneFolder(objects: #"[{"text":{"script":"x","value":"1"}}]"#), computeSize: false))
        let plain = try #require(WorkshopItem.load(from: try sceneFolder(objects: #"[{"text":"Hello"}]"#), computeSize: false))
        #expect(BakedWallpapers.canBake(live))
        #expect(!BakedWallpapers.shouldAutoBake(live))
        #expect(BakedWallpapers.shouldAutoBake(plain))
    }

    @Test func malformedPackagesAreIgnored() throws {
        let folder = testDefaults.makeDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a package".utf8).write(to: folder.appendingPathComponent("scene.pkg"))
        #expect(SceneTextInspector.info(for: folder) == .init())
        #expect(SceneTextInspector.sceneJSON(inPackage: folder.appendingPathComponent("scene.pkg")) == nil)
    }
}

//
//  SceneTextInspector.swift
//  wallhaven
//
//  读出场景壁纸里的文字图层：有没有文字、有没有脚本驱动的实时文字（时钟、日期等）。
//  只读 scene.pkg 的目录和其中的 scene.json，不读贴图；结果按文件修改时间缓存。
//

import Foundation

nonisolated enum SceneTextInspector {
    struct Info: Equatable {
        var hasText = false
        /// 文字由脚本每帧生成（时钟、日期、天气等），录成视频后会定格在录制时
        var hasLiveText = false
    }

    private static let cache = NSCache<NSString, Box>()
    private final class Box {
        let info: Info
        let stamp: Date
        init(info: Info, stamp: Date) { self.info = info; self.stamp = stamp }
    }

    static func info(for folder: URL) -> Info {
        guard let (source, stamp) = sceneSource(in: folder) else { return Info() }
        let key = source.path as NSString
        if let box = cache.object(forKey: key), box.stamp == stamp { return box.info }
        let data = source.pathExtension.lowercased() == "pkg" ? sceneJSON(inPackage: source) : try? Data(contentsOf: source)
        let info = data.map(parse) ?? Info()
        cache.setObject(Box(info: info, stamp: stamp), forKey: key)
        return info
    }

    static func parse(_ data: Data) -> Info {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let objects = root["objects"] as? [[String: Any]] else { return Info() }
        var info = Info()
        for object in objects {
            guard let text = object["text"], !(text is NSNull) else { continue }
            info.hasText = true
            if let script = (text as? [String: Any])?["script"] as? String, !script.isEmpty { info.hasLiveText = true }
        }
        return info
    }

    private static func sceneSource(in folder: URL) -> (URL, Date)? {
        for name in ["scene.pkg", "scenes/scene.pkg", "gifscene.pkg", "scene.json"] {
            let url = folder.appendingPathComponent(name)
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate { return (url, date) }
        }
        return nil
    }

    /// PKG：版本字符串、条目数，每个条目是名称、相对数据区的偏移和长度；数据区紧跟在目录后面
    static func sceneJSON(inPackage url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var offset: UInt64 = 0
        func read(_ count: Int) -> Data? {
            guard count >= 0, count < 1 << 26, (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            offset += UInt64(count)
            return data
        }
        func u32() -> UInt32? { read(4).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian } }
        func string() -> String? { u32().flatMap { read(Int($0)) }.flatMap { String(data: $0, encoding: .utf8) } }
        guard let version = string(), version.hasPrefix("PKGV"), let count = u32(), count < 100_000 else { return nil }
        var target: (offset: UInt32, size: UInt32)?
        for _ in 0..<count {
            guard let name = string(), let entryOffset = u32(), let size = u32() else { return nil }
            if name == "scene.json" { target = (entryOffset, size) }
        }
        guard let target else { return nil }
        offset += UInt64(target.offset)
        return read(Int(target.size))
    }
}

import Foundation

/// 选择、组移动及撤销合并的纯数据逻辑，保持原来的相对顺序。
nonisolated enum PlaylistEditing {
    static func selection(ids: [String], clicked: String, anchor: String?, current: Set<String>, shift: Bool, command: Bool) -> Set<String> {
        if shift, let anchor, let start = ids.firstIndex(of: anchor), let end = ids.firstIndex(of: clicked) {
            let range = Set(ids[min(start, end)...max(start, end)])
            return command ? current.union(range) : range
        }
        if command {
            var result = current
            if !result.insert(clicked).inserted { result.remove(clicked) }
            return result
        }
        return [clicked]
    }

    static func moving(ids: [String], selected: Set<String>, before: String?) -> [String] {
        guard !selected.isEmpty, before.map({ !selected.contains($0) }) ?? true else { return ids }
        let group = ids.filter { selected.contains($0) }
        guard !group.isEmpty else { return ids }
        var remaining = ids.filter { !selected.contains($0) }
        let index = before.flatMap { remaining.firstIndex(of: $0) } ?? remaining.count
        remaining.insert(contentsOf: group, at: index)
        return remaining
    }

    static func insertionAnchor(ids: [String], hovered: String?, after: Bool, selected: Set<String>) -> String? {
        guard let hovered, let index = ids.firstIndex(of: hovered) else { return nil }
        return ids.dropFirst(index + (after ? 1 : 0)).first { !selected.contains($0) }
    }

    /// 恢复删除项，保留当前列表中新添加、已重排和已存在的条目。
    static func restoring(current: [String], original: [String], removed: Set<String>) -> [String] {
        var result = current
        for (index, id) in original.enumerated() where removed.contains(id) && !result.contains(id) {
            if let next = original.dropFirst(index + 1).first(where: { result.contains($0) }), let position = result.firstIndex(of: next) {
                result.insert(id, at: position)
            } else if let previous = original.prefix(index).last(where: { result.contains($0) }), let position = result.firstIndex(of: previous) {
                result.insert(id, at: position + 1)
            } else { result.insert(id, at: 0) }
        }
        return result
    }
}

struct PlaylistRemoval {
    let playlistID: UUID
    let original: [PlaylistEntry]
    let removedIDs: Set<String>
    let previewID: String?
}

struct PlaylistDragPayload: Codable {
    let playlistID: UUID
    let ids: [String]
    var text: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    static func decode(_ text: String) -> Self? {
        text.data(using: .utf8).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
}

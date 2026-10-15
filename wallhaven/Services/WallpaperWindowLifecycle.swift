/// 新旧桌面窗口的所有权：重建被打断时，旧窗口仍留在待回收集合中。
@MainActor
final class WallpaperWindowLifecycle<Resource: AnyObject> {
    private(set) var generation = 0
    private(set) var active: [Resource] = []
    private(set) var retiring: [Resource] = []

    @discardableResult
    func beginReplacement() -> Int {
        generation += 1
        retiring.append(contentsOf: active)
        active.removeAll()
        return generation
    }

    func append(_ resource: Resource) {
        active.append(resource)
    }

    func isCurrent(_ resource: Resource, generation: Int) -> Bool {
        self.generation == generation && active.contains { $0 === resource }
    }

    /// 延迟回收只取走那一批旧窗口，不能误关之后新建的窗口；重复回调没有副作用。
    func removeRetiring(_ resources: [Resource]) -> [Resource] {
        let ids = Set(resources.map(ObjectIdentifier.init))
        let removed = retiring.filter { ids.contains(ObjectIdentifier($0)) }
        retiring.removeAll { ids.contains(ObjectIdentifier($0)) }
        return removed
    }

    func removeAll() -> [Resource] {
        generation += 1
        let resources = active + retiring
        active.removeAll()
        retiring.removeAll()
        return resources
    }
}

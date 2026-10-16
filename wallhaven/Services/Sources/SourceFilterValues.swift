import Foundation

nonisolated enum SourceFilterDate {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    static func string(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func date(_ value: String) -> Date? {
        guard let match = value.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})/),
              let year = Int(match.1), year >= 1900, let month = Int(match.2), let day = Int(match.3),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              string(date) == value else { return nil }
        return date
    }

    static var yesterday: Date { calendar.date(byAdding: .day, value: -1, to: Date())! }
}

extension SourceFilter {
    nonisolated static func bound(_ key: String, in selection: Set<String>) -> String? {
        selection.sorted().first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    nonisolated func normalized(_ selection: Set<String>) -> Set<String> {
        switch input {
        case .choices:
            let valid = selection.intersection(Set(options.map(\.id)))
            if mode == .oneOf || mode == .exactlyOne { return valid.sorted().first.map { [$0] } ?? [] }
            return valid
        case .numberRange, .dateRange:
            return Set(["min", "max"].compactMap { key -> String? in
                guard let value = Self.bound(key, in: selection) else { return nil }
                if input == .numberRange {
                    guard let number = Int(value), number >= 0, number <= 100_000_000 else { return nil }
                    return "\(key)=\(number)"
                }
                guard SourceFilterDate.date(value) != nil else { return nil }
                return "\(key)=\(value)"
            })
        case .date:
            return selection.sorted().first(where: { SourceFilterDate.date($0) != nil }).map { [$0] } ?? []
        case .text:
            guard let value = selection.sorted().first,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 128,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return [] }
            return [value]
        }
    }
}

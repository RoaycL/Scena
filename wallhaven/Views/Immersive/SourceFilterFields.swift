import SwiftUI

/// 少量原生输入控件放在独立边界中，文本编辑只更新对应条件。
struct SourceFilterFields: View {
    @EnvironmentObject private var viewModel: WallpaperViewModel
    let filter: SourceFilter
    private var selection: Set<String> { viewModel.filterSelections[filter.id] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch filter.input {
            case .numberRange:
                HStack {
                    TextField("最小值", text: numberBinding("min"))
                        .accessibilityLabel("\(filter.title)最小值")
                    Text("—").foregroundStyle(.secondary)
                    TextField("最大值", text: numberBinding("max"))
                        .accessibilityLabel("\(filter.title)最大值")
                }
                .textFieldStyle(.roundedBorder)
                .help("留空或 0 表示不限")
            case .dateRange:
                FlowLayout {
                    ForEach([7, 30, 365], id: \.self) { days in
                        let values = recentDates(days)
                        GlassChip(title: days == 365 ? "近一年" : "近\(days)天", isOn: selection == values) {
                            viewModel.setValues(values, in: filter)
                        }
                    }
                }
                dateRow("开始日期", key: "min")
                dateRow("结束日期", key: "max")
            case .date:
                HStack {
                    Toggle("指定日期", isOn: Binding(get: { !selection.isEmpty }, set: { enabled in
                        viewModel.setValues(enabled ? [SourceFilterDate.string(SourceFilterDate.yesterday)] : [], in: filter)
                    }))
                    if !selection.isEmpty {
                        DatePicker("榜单日期", selection: Binding(get: {
                            selection.first.flatMap(SourceFilterDate.date) ?? SourceFilterDate.yesterday
                        }, set: { viewModel.setValues([SourceFilterDate.string($0)], in: filter) }),
                            in: ...SourceFilterDate.yesterday, displayedComponents: .date)
                            .labelsHidden()
                    }
                }
            case .text:
                TextField("输入工具名称", text: Binding(get: { selection.first ?? "" }, set: {
                    viewModel.setValues($0.isEmpty ? [] : [$0], in: filter)
                }))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(filter.title)
            case .choices:
                EmptyView()
            }
            if !selection.isEmpty, filter.input != .date {
                Button("清除此条件") { viewModel.setValues([], in: filter) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .font(.system(size: 12))
        .environment(\.timeZone, SourceFilterDate.calendar.timeZone)
    }

    private func numberBinding(_ key: String) -> Binding<String> {
        Binding(get: { SourceFilter.bound(key, in: selection) ?? "" }, set: { value in
            var values = selection.filter { !$0.hasPrefix(key + "=") }
            if !value.isEmpty { values.insert("\(key)=\(value)") }
            viewModel.setValues(values, in: filter)
        })
    }

    private func dateRow(_ title: String, key: String) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { SourceFilter.bound(key, in: selection) != nil }, set: { enabled in
                setDate(key, enabled ? Date() : nil)
            }))
            if SourceFilter.bound(key, in: selection) != nil {
                DatePicker(title, selection: Binding(get: {
                    SourceFilter.bound(key, in: selection).flatMap(SourceFilterDate.date) ?? Date()
                }, set: { setDate(key, $0) }), displayedComponents: .date)
                    .labelsHidden().accessibilityLabel(title)
            }
        }
    }

    private func setDate(_ key: String, _ date: Date?) {
        var values = selection.filter { !$0.hasPrefix(key + "=") }
        if let date { values.insert("\(key)=\(SourceFilterDate.string(date))") }
        viewModel.setValues(values, in: filter)
    }

    private func recentDates(_ days: Int) -> Set<String> {
        let today = SourceFilterDate.calendar.startOfDay(for: Date())
        let start = SourceFilterDate.calendar.date(byAdding: .day, value: 1 - days, to: today)!
        return ["min=\(SourceFilterDate.string(start))", "max=\(SourceFilterDate.string(today))"]
    }
}
